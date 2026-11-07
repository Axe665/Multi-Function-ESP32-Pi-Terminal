#pragma once

#include "net/NetworkPolicy.h"

#include <QObject>
#include <QVariantList>
#include <QVariantMap>

class NetworkGate;
namespace security { class SessionManager; }

// QML 侧的 root 策略控制器：
//   - 读 /etc/orange-pi-terminal/network-policy.json（缺失=默认拒绝）；
//   - 把 enabled 灌进 NetworkGate，并让宿主重写 proxy 策略；
//   - 保存时先做管理员 PIN 重验，再经 Polkit/pkexec 调 root helper。
// 不在本类里做网络请求，也不把 PIN 落盘。
class NetworkPolicyController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList apps READ apps NOTIFY changed)
    Q_PROPERTY(QString lastError READ lastError NOTIFY changed)
    Q_PROPERTY(bool loaded READ loaded NOTIFY changed)
    // 部署状态：界面与开发者面板据此判断"保存会不会直接失败"。
    Q_PROPERTY(QString helperPath READ helperPath CONSTANT)
    Q_PROPERTY(QString policyPath READ policyPath CONSTANT)
    Q_PROPERTY(bool helperInstalled READ helperInstalled NOTIFY changed)

public:
    explicit NetworkPolicyController(QString path = {}, QObject *parent = nullptr);

    void setSessionManager(security::SessionManager *session);
    void setGate(NetworkGate *gate);
    void setHelperPath(const QString &path) { helperPath_ = path; }

    QVariantList apps() const;
    Q_INVOKABLE QVariantList modules() const;
    Q_INVOKABLE bool moduleNetworkEnabled(const QString &id) const;
    Q_INVOKABLE bool moduleFileEnabled(const QString &id) const;
    const NetworkPolicy::Policy &policy() const { return policy_; }
    QString lastError() const { return lastError_; }
    QString helperPath() const { return helperPath_; }
    QString policyPath() const { return path_; }
    bool helperInstalled() const;
    bool loaded() const { return loaded_; }

    // 重新读盘；失败时回到全拒绝，不保留上一份“看起来能用”的策略。
    Q_INVOKABLE void refresh();
    // 保存整份策略；pin 必须是当前管理员 PIN。
    Q_INVOKABLE QVariantMap save(const QVariantList &apps, const QVariantList &modules,
                                 const QString &pin);

signals:
    void changed();
    void policyApplied();

private:
    bool writeViaHelper(const QJsonObject &root, QString *error);
    void applyToGate();
    void setError(const QString &error);

    QString path_;
    QString helperPath_;
    QString lastError_;
    bool loaded_ = false;
    NetworkPolicy::Policy policy_;
    security::SessionManager *session_ = nullptr;
    NetworkGate *gate_ = nullptr;
};
