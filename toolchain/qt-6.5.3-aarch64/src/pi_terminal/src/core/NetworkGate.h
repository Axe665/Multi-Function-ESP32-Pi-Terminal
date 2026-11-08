#pragma once

#include <QHash>
#include <QObject>
#include <QString>
#include <QVariantMap>

// 联网总开关与分功能开关（报告 §9.3）。
//
// 报告原文拆成几件事，这里逐条对应：
//   1. 总开关只控**外网**，不关闭本地 BLE / Pogo / 受限局域连接
//   2. 各联网功能有**独立子开关**；关闭时阻止新建外网连接
//   3. 状态拆三态：**接口就绪 / 局域模块链路 / 互联网可达**，
//      不能因为"接口有 IP"就判定互联网可用
//   4. 离线健康功能照常工作；**无待上传队列**
//   5. 有限超时、有上限重试、用户主动重试、流量/缓存上限
//   6. **不因网络恢复自动下载大包**
//
// 本类只做策略判定与状态，不直接发请求；调用方在发起前问 allow()。
// 持久化不在这里做：宿主（TerminalApplication）监听 settingChanged 写 QSettings，
// 再在启动时把存下来的值灌回来。这样单元测试构造出来的 gate 不会碰真实配置。
class NetworkGate : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled NOTIFY changed)
    Q_PROPERTY(QString reason READ reason NOTIFY changed)

    // §9.3 第 3 条：三态互不替代。
    Q_PROPERTY(bool interfaceReady READ interfaceReady NOTIFY stateChanged)
    Q_PROPERTY(bool moduleLinkReady READ moduleLinkReady NOTIFY stateChanged)
    Q_PROPERTY(bool internetReachable READ internetReachable NOTIFY stateChanged)

    // 分功能开关（§9.3 第 2 条）。总开关关闭时全部读作"不允许"。
    Q_PROPERTY(bool browserAllowed READ browserAllowed NOTIFY changed)
    Q_PROPERTY(bool musicAllowed READ musicAllowed NOTIFY changed)
    Q_PROPERTY(bool tvAllowed READ tvAllowed NOTIFY changed)
    Q_PROPERTY(bool weatherAllowed READ weatherAllowed NOTIFY changed)
    Q_PROPERTY(bool timeSyncAllowed READ timeSyncAllowed NOTIFY changed)
    Q_PROPERTY(bool updatesAllowed READ updatesAllowed NOTIFY changed)

    // 当前进行中的外网请求数（关闭时据此判断是否已静默）。
    Q_PROPERTY(int inFlight READ inFlight NOTIFY changed)

public:
    // 外网用途。每一种对应设置页里的一个子开关。
    enum class Purpose {
        Browser,
        Music,
        Tv,
        Weather,
        TimeSync,
        Updates,
        Other,         // 兜底：不属于上面任何一类，只要总开关开着就放行
    };
    Q_ENUM(Purpose)

    explicit NetworkGate(QObject *parent = nullptr) : QObject(parent) {}

    bool enabled() const { return enabled_; }
    QString reason() const { return reason_; }

    bool interfaceReady() const { return interfaceReady_; }
    bool moduleLinkReady() const { return moduleLinkReady_; }
    bool internetReachable() const { return internetReachable_; }

    bool browserAllowed() const { return browserAllowed_; }
    bool musicAllowed() const { return musicAllowed_; }
    bool tvAllowed() const { return tvAllowed_; }
    bool weatherAllowed() const { return weatherAllowed_; }
    bool timeSyncAllowed() const { return timeSyncAllowed_; }
    bool updatesAllowed() const { return updatesAllowed_; }

    int inFlight() const { return inFlight_; }

    // 总开关只是紧急总闸。应用级权限由 root 策略加载，默认全部拒绝。
    void setEnabled(bool enabled);
    Q_INVOKABLE void setEnabledFromUi(bool enabled) { setEnabled(enabled); }

    // 分功能开关：只有在总开关打开时才有效；关掉总开关不会改写它们，
    // 于是重新打开总开关时各自的状态原样恢复。
    void setBrowserAllowed(bool allowed);
    void setMusicAllowed(bool allowed);
    void setTvAllowed(bool allowed);
    void setWeatherAllowed(bool allowed);
    void setTimeSyncAllowed(bool allowed);
    void setUpdatesAllowed(bool allowed);

    // QML 用统一入口：feature 取 "browser"/"music"/"tv"/"weather"/"timesync"/"updates"。
    Q_INVOKABLE bool setFeatureEnabledFromUi(const QString &feature, bool enabled);
    // QML 读分功能状态（字符串版，省得给每个开关写一个属性绑定）。
    Q_INVOKABLE bool featureEnabled(const QString &feature) const;

    // 第三方模块：按模块实例的独立联网开关，默认拒绝。
    // 持久化/管理员 UI 由上层接入；这里只做运行期判定。
    Q_INVOKABLE bool moduleNetworkAllowed(const QString &instance) const;
    Q_INVOKABLE bool setModuleNetworkAllowed(const QString &instance, bool allowed);
    Q_INVOKABLE bool moduleFileAllowed(const QString &instance) const;
    Q_INVOKABLE bool setModuleFileAllowed(const QString &instance, bool allowed);

    // 三态更新：由网络监视/模块链路分别驱动，不互相推导。
    void setInterfaceReady(bool ready);
    void setModuleLinkReady(bool ready);
    void setInternetReachable(bool reachable);

    // 纯查询：不改 reason、不发信号。给"在信号回调里判断"的调用方用——
    // 用 allow() 会 emit changed，在 changed 的回调里再调 allow() 会无限递归。
    bool permits(Purpose purpose) const;
    bool permits(const QString &purpose) const;

    // 请求放行。deny 时 reason() 给出可读原因。
    bool allow(Purpose purpose);
    // 便捷重载：用字符串标识（供 QML / 旧调用方）。
    // Q_INVOKABLE：QML 调用方必须在发外网请求前问这一处，
    // 而不是各自去读 enabled——否则分功能开关与 reason() 都会被绕过。
    Q_INVOKABLE bool allow(const QString &purpose);

    // 请求生命周期：放行成功后调用 begin()，结束调用 end()。
    void beginRequest();
    void endRequest();

    // 把六个开关一次性读成 {feature: bool}，供宿主持久化。
    Q_INVOKABLE QVariantMap snapshot() const;
    // 宿主启动时灌入。缺键按默认值处理。
    void restore(const QVariantMap &values);

signals:
    void changed();
    void stateChanged();
    // 只有用户改开关时才发；allow() 拒绝不发。宿主据此写盘。
    void settingChanged();
    // 第三方模块权限变化；broker/Nam 以此刷新。
    void moduleNetworkChanged(const QString &instance);
    void moduleFileChanged(const QString &instance);

private:
    void clearReason();
    static QString purposeName(Purpose purpose);

    bool enabled_ = true;
    QString reason_;

    bool interfaceReady_ = false;
    bool moduleLinkReady_ = false;
    bool internetReachable_ = false;

    // 默认拒绝：root 策略（NetworkPolicyController）加载后才逐项打开。
    // 策略缺失/损坏时保持 false，代理只拿到禁用通道。
    bool browserAllowed_ = false;
    bool musicAllowed_ = false;
    bool tvAllowed_ = false;
    bool weatherAllowed_ = false;
    bool timeSyncAllowed_ = false;
    bool updatesAllowed_ = false;

    // 模块实例 → 是否允许公网。缺省拒绝。
    QHash<QString, bool> moduleAllowed_;
    // 模块实例 → 是否允许文件 API（家目录只读 + app 数据可写）。缺省拒绝。
    QHash<QString, bool> moduleFileAllowed_;

    int inFlight_ = 0;
};
