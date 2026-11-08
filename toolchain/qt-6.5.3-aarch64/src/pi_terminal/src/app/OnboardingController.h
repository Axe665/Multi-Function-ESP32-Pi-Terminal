#pragma once

#include <QObject>
#include <QString>

namespace security {
class SessionManager;
class UserService;
}  // namespace security

// 首次开机向导（OOBE）的服务端。
//
// 触发条件只有一条：用户注册表里没有任何用户（UserService::hasAnyUser()
// 为 false）。判定在构造时做一次，之后不再变化——删光所有用户后下次启动
// 自然重新满足。
//
// 边界：QML 只拿到"是否可以向前 / 恢复码分组 / 错误码"，
// 不接触 SQLCipher、注册表、PIN 派生。明文 PIN 只在 createAdmin() 的
// 参数与本对象的 pendingPin_ 里短暂存在，跑完 KDF 立即清零。
//
// 与命令行初始化的关系：--init-admin 仍是可用的无头/救援路径，
// 两者都走 UserService::createInitialAdmin，不存在第二套创建逻辑。
class OnboardingController : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString recoveryCode READ recoveryCode NOTIFY recoveryCodeChanged)
    Q_PROPERTY(QString errorCode READ errorCode NOTIFY errorChanged)
    // 网络步骤只用本机接口状态（不发起任何外网请求）：
    // 注册表为空时联网策略默认全拒，向导不该替用户试探外网。
    Q_PROPERTY(bool networkConnected READ networkConnected NOTIFY networkChanged)
    Q_PROPERTY(QString networkSummary READ networkSummary NOTIFY networkChanged)

public:
    // required 由 TerminalApplication 判定：!bypass && !users.hasAnyUser()。
    OnboardingController(security::UserService &users, security::SessionManager *session,
                         bool required, QObject *parent = nullptr);

    bool active() const { return active_; }
    bool ready() const { return ready_; }
    bool busy() const { return busy_; }
    QString recoveryCode() const { return recoveryCode_; }
    QString errorCode() const { return errorCode_; }
    bool networkConnected() const { return networkConnected_; }
    QString networkSummary() const { return networkSummary_; }

    // 启动时由 TerminalApplication 调用一次：打开或跳过向导。
    // 判定条件由调用方给出（!bypass && !hasAnyUser），本类不重复读注册表。
    void setStartupRequirement(bool required);

    // 运行中把向导重新武装起来：最后一名用户（可能也是最后一名管理员）
    // 删掉自己后注册表为空，宿主调它直接回到首次开机向导，不用重启终端。
    // 与 setStartupRequirement 的区别是这里要清掉上一轮的恢复码与进度，
    // 否则新一轮向导会沿用旧码、甚至带着 ready=true 直接跳过创建。
    Q_INVOKABLE void rearm();

    // 进入恢复码步骤时调用。幂等：同一轮向导只生成一份码，
    // 用户返回上一步再回来看到的还是原来那份（避免"抄了旧码"）。
    Q_INVOKABLE void prepareRecoveryCode();

    // 第 index 组（0..5）的大写文本，供 QML 分行显示。
    Q_INVOKABLE QString recoveryGroup(int index) const;

    // 抄写确认：输入第 2 组（index 1）与第 5 组（index 4）。
    // 比对前做 normalize（去空格/连字符、转大写）。
    Q_INVOKABLE bool confirmRecovery(const QString &group2, const QString &group5);

    Q_INVOKABLE void clearError();

    // 重新读一次本机网络接口（有线/无线）。只读 QNetworkInterface，
    // 不发包、不改策略；“重试”按钮调它。
    Q_INVOKABLE void probeNetwork();

    // 最后一步。异步：先让 QML 画出 busy，再在下一轮事件循环跑
    // 600k 次 PBKDF2（约 0.8s），避免界面在点击瞬间冻结。
    // 成功创建后会尝试直接建立会话；失败时把 active 置 false，
    // 让 SessionGate 接管（用户下一次启动走登录页）。
    Q_INVOKABLE void createAdmin(const QString &displayName, const QString &pin,
                                 const QString &confirmPin);

    // 完成后由 QML 调用，关闭向导并进入桌面。
    Q_INVOKABLE void dismiss();

signals:
    void activeChanged();
    void readyChanged();
    void busyChanged();
    void recoveryCodeChanged();
    void errorChanged();
    void networkChanged();
    // ok=true 表示管理员已创建且会话已建立，QML 可以显示"进入桌面"。
    void finished(bool ok);

private:
    void performCreate();
    void fail(const QString &code);
    void setBusy(bool busy);

    security::UserService &users_;
    security::SessionManager *session_ = nullptr;
    bool active_ = false;
    bool ready_ = false;
    bool busy_ = false;
    QString recoveryCode_;
    QString errorCode_;
    bool networkConnected_ = false;
    QString networkSummary_;
    QString pendingName_;
    QString pendingPin_;
};
