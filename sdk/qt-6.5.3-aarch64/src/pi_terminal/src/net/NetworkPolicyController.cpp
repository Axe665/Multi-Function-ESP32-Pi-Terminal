#include "net/NetworkPolicyController.h"

#include "core/NetworkGate.h"
#include "security/SessionManager.h"

#include <QCoreApplication>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QStandardPaths>

namespace {
QString defaultPath() {
    const QString override = qEnvironmentVariable("ORANGE_PI_NETWORK_POLICY");
    if (!override.isEmpty()) return override;
    return QStringLiteral("/etc/orange-pi-terminal/network-policy.json");
}

QString defaultHelper() {
    const QString override = qEnvironmentVariable("ORANGE_PI_NET_POLICY_HELPER");
    if (!override.isEmpty()) return override;
#ifdef PI_NET_POLICY_HELPER
    return QStringLiteral(PI_NET_POLICY_HELPER);
#else
    return QStringLiteral("/usr/libexec/orange-pi-terminal/net-policy-helper");
#endif
}

QVariantMap appToMap(const NetworkPolicy::AppPolicy &app) {
    QVariantMap map;
    map.insert(QStringLiteral("id"), app.id);
    map.insert(QStringLiteral("name"), NetworkPolicy::displayName(app.id));
    map.insert(QStringLiteral("enabled"), app.enabled);
    return map;
}
}  // namespace

NetworkPolicyController::NetworkPolicyController(QString path, QObject *parent)
    : QObject(parent), path_(path.isEmpty() ? defaultPath() : std::move(path)),
      helperPath_(defaultHelper()), policy_(NetworkPolicy::defaults())
{
    refresh();
}

void NetworkPolicyController::setSessionManager(security::SessionManager *session) {
    session_ = session;
}

void NetworkPolicyController::setGate(NetworkGate *gate) {
    gate_ = gate;
    applyToGate();
}

bool NetworkPolicyController::helperInstalled() const {
    return QFileInfo(helperPath_).isExecutable();
}

QVariantList NetworkPolicyController::apps() const {
    QVariantList out;
    for (const NetworkPolicy::AppPolicy &app : policy_.apps) out.append(appToMap(app));
    return out;
}

QVariantList NetworkPolicyController::modules() const {
    QVariantList out;
    for (const NetworkPolicy::ModulePolicy &module : policy_.modules) {
        out.append(QVariantMap{{QStringLiteral("id"), module.id},
                               {QStringLiteral("network"), module.network},
                               {QStringLiteral("file"), module.file}});
    }
    return out;
}

bool NetworkPolicyController::moduleNetworkEnabled(const QString &id) const {
    for (const NetworkPolicy::ModulePolicy &module : policy_.modules)
        if (module.id == id) return module.network;
    return false;
}

bool NetworkPolicyController::moduleFileEnabled(const QString &id) const {
    for (const NetworkPolicy::ModulePolicy &module : policy_.modules)
        if (module.id == id) return module.file;
    return false;
}

void NetworkPolicyController::setError(const QString &error) {
    if (lastError_ == error) return;
    lastError_ = error;
    emit changed();
}

void NetworkPolicyController::refresh() {
    QString error;
    policy_ = NetworkPolicy::loadFile(path_, &error);
    loaded_ = error.isEmpty();
    if (!loaded_) {
        // 读不到/损坏 = 默认拒绝；不要沿用上次的内存策略。
        policy_ = NetworkPolicy::defaults();
        lastError_ = error;
    } else {
        lastError_.clear();
    }
    applyToGate();
    emit changed();
}

void NetworkPolicyController::applyToGate() {
    if (!gate_) return;
    // 总闸是运行期紧急开关，策略刷新不能把它重新打开。
    for (const NetworkPolicy::AppPolicy &app : policy_.apps) {
        gate_->setFeatureEnabledFromUi(NetworkPolicy::purposeForApp(app.id), app.enabled);
    }
    emit policyApplied();
}

QVariantMap NetworkPolicyController::save(const QVariantList &apps,
                                          const QVariantList &modules,
                                          const QString &pin) {
    QVariantMap result{{QStringLiteral("ok"), false},
                       {QStringLiteral("code"), QStringLiteral("NOT_AUTHORIZED")},
                       {QStringLiteral("error"), QString()}};
    if (!session_ || !session_->loggedIn() || !session_->isAdmin()) {
        result.insert(QStringLiteral("error"), QStringLiteral("需要管理员会话"));
        return result;
    }
    const QVariantMap auth = session_->verifyAdminPinForPolicy(pin);
    if (!auth.value(QStringLiteral("ok")).toBool()) {
        result.insert(QStringLiteral("code"), auth.value(QStringLiteral("code")));
        result.insert(QStringLiteral("retryAfterMs"), auth.value(QStringLiteral("retryAfterMs")));
        result.insert(QStringLiteral("error"), QStringLiteral("管理员 PIN 验证失败"));
        return result;
    }

    QJsonObject appObject;
    for (const QString &id : NetworkPolicy::appIds()) {
        for (const QVariant &value : apps) {
            const QVariantMap entry = value.toMap();
            if (entry.value(QStringLiteral("id")).toString() != id) continue;
            QJsonObject json{{QStringLiteral("enabled"), entry.value(QStringLiteral("enabled")).toBool()}};
            appObject.insert(id, json);
            break;
        }
    }
    const QJsonObject root{{QStringLiteral("schema"), QLatin1String(NetworkPolicy::Schema)},
                           {QStringLiteral("version"), NetworkPolicy::Version},
                           {QStringLiteral("apps"), appObject},
                           {QStringLiteral("modules"), [&] {
                                QJsonObject out;
                                for (const QVariant &value : modules) {
                                    const QVariantMap entry = value.toMap();
                                    const QString id = entry.value(QStringLiteral("id")).toString();
                                    if (id.isEmpty()) continue;
                                    out.insert(id, QJsonObject{
                                        {QStringLiteral("network"), entry.value(QStringLiteral("network")).toBool()},
                                        {QStringLiteral("file"), entry.value(QStringLiteral("file")).toBool()}});
                                }
                                return out;
                            }()}};
    NetworkPolicy::Policy parsed;
    QString error;
    if (!NetworkPolicy::parse(root, &parsed, &error)) {
        result.insert(QStringLiteral("code"), QStringLiteral("INVALID_POLICY"));
        result.insert(QStringLiteral("error"), error);
        return result;
    }
    if (!writeViaHelper(root, &error)) {
        result.insert(QStringLiteral("code"), QStringLiteral("WRITE_FAILED"));
        result.insert(QStringLiteral("error"), error);
        return result;
    }
    refresh();
    if (!loaded_) {
        result.insert(QStringLiteral("code"), QStringLiteral("READ_FAILED"));
        result.insert(QStringLiteral("error"), lastError_);
        return result;
    }
    result.insert(QStringLiteral("ok"), true);
    result.insert(QStringLiteral("code"), QStringLiteral("OK"));
    result.insert(QStringLiteral("error"), QString());
    return result;
}

bool NetworkPolicyController::writeViaHelper(const QJsonObject &root, QString *error) {
    const QByteArray payload = QJsonDocument(root).toJson(QJsonDocument::Compact);
    const QFileInfo helper(helperPath_);
    if (!helper.isExecutable()) {
        // 安全模型不做降级：没有 helper 就拒绝保存（fail-closed）。
        // 开发/部署都必须先把 helper 装到 helperPath_，见 docs/devdocs 的部署步骤。
        if (error) *error = QStringLiteral("策略 helper 不存在或不可执行：%1（请先安装 net-policy-helper）").arg(helperPath_);
        return false;
    }

    QString program;
    QStringList arguments;
    // 测试/开发：显式 helper 环境变量时直接调用，并用 --policy 指向临时文件。
    // 生产：pkexec 以 root 调 helper，helper 只写固定系统路径。
    if (!qEnvironmentVariable("ORANGE_PI_NET_POLICY_HELPER").isEmpty()) {
        program = helperPath_;
        arguments << QStringLiteral("--policy") << path_;
    } else {
        program = QStringLiteral("pkexec");
        arguments << helperPath_;
    }

    QProcess process;
    process.setProcessChannelMode(QProcess::SeparateChannels);
    process.start(program, arguments);
    if (!process.waitForStarted(5000)) {
        if (error) *error = QStringLiteral("无法启动策略 helper（pkexec 缺失？）");
        return false;
    }
    process.write(payload);
    process.closeWriteChannel();
    if (!process.waitForFinished(60000)) {
        process.kill();
        process.waitForFinished(1000);
        if (error) *error = QStringLiteral("策略 helper 超时");
        return false;
    }
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        const QString stderrText = QString::fromLocal8Bit(process.readAllStandardError()).trimmed();
        if (error) *error = stderrText.isEmpty()
            ? QStringLiteral("策略 helper 失败（退出码 %1）").arg(process.exitCode())
            : stderrText;
        return false;
    }
    return true;
}
