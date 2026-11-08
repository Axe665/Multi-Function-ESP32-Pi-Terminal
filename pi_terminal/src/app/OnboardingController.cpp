#include "app/OnboardingController.h"

#include "security/PinPolicy.h"
#include "security/RecoveryCode.h"
#include "security/SessionManager.h"
#include "security/UserService.h"

#include <QHostAddress>
#include <QNetworkInterface>
#include <QTimer>

#include <utility>

OnboardingController::OnboardingController(security::UserService &users,
                                           security::SessionManager *session, bool required,
                                           QObject *parent)
    : QObject(parent), users_(users), session_(session), active_(required) {}

void OnboardingController::setStartupRequirement(bool required) {
    if (active_ == required) return;
    active_ = required;
    emit activeChanged();
}

void OnboardingController::rearm() {
    if (active_) return;
    // 上一轮向导留下的明文、恢复码与进度全部作废：新一轮必须重新生成
    // 恢复码、重新抄写确认，否则用户会拿到一份"已经展示过"的旧码。
    pendingPin_.fill(QChar(0));
    pendingPin_.clear();
    pendingName_.clear();
    if (!recoveryCode_.isEmpty()) {
        recoveryCode_.clear();
        emit recoveryCodeChanged();
    }
    if (ready_) {
        ready_ = false;
        emit readyChanged();
    }
    setBusy(false);
    clearError();
    // 网络摘要来自上一次启动的探测，回到向导第一步时先按"未探测"复位。
    if (networkConnected_ || !networkSummary_.isEmpty()) {
        networkConnected_ = false;
        networkSummary_.clear();
        emit networkChanged();
    }
    active_ = true;
    emit activeChanged();
}

void OnboardingController::prepareRecoveryCode() {
    if (!recoveryCode_.isEmpty()) return;
    recoveryCode_ = security::RecoveryCode::generate();
    emit recoveryCodeChanged();
}

QString OnboardingController::recoveryGroup(int index) const {
    if (index < 0 || index >= security::RecoveryCode::kGroups) return {};
    const QString normalized = security::RecoveryCode::normalize(recoveryCode_);
    return normalized.mid(index * security::RecoveryCode::kGroupSize,
                          security::RecoveryCode::kGroupSize);
}

bool OnboardingController::confirmRecovery(const QString &group2, const QString &group5) {
    if (recoveryCode_.isEmpty()) return false;
    const bool ok = security::RecoveryCode::normalize(group2) == recoveryGroup(1)
                    && security::RecoveryCode::normalize(group5) == recoveryGroup(4);
    if (!ok) fail(QStringLiteral("recovery_mismatch"));
    else clearError();
    return ok;
}

void OnboardingController::clearError() {
    if (errorCode_.isEmpty()) return;
    errorCode_.clear();
    emit errorChanged();
}

void OnboardingController::probeNetwork() {
    bool connected = false;
    QString summary;
    const auto interfaces = QNetworkInterface::allInterfaces();
    for (const QNetworkInterface &iface : interfaces) {
        const auto flags = iface.flags();
        if (!(flags & QNetworkInterface::IsUp) || !(flags & QNetworkInterface::IsRunning))
            continue;
        if (flags & QNetworkInterface::IsLoopBack) continue;
        for (const QNetworkAddressEntry &entry : iface.addressEntries()) {
            const QHostAddress address = entry.ip();
            if (address.protocol() != QAbstractSocket::IPv4Protocol || address.isLoopback())
                continue;
            connected = true;
            summary = iface.humanReadableName() + QStringLiteral(" · ") + address.toString();
            break;
        }
        if (connected) break;
    }
    if (connected == networkConnected_ && summary == networkSummary_) return;
    networkConnected_ = connected;
    networkSummary_ = summary;
    emit networkChanged();
}

void OnboardingController::setBusy(bool busy) {
    if (busy_ == busy) return;
    busy_ = busy;
    emit busyChanged();
}

void OnboardingController::fail(const QString &code) {
    errorCode_ = code;
    emit errorChanged();
}

void OnboardingController::createAdmin(const QString &displayName, const QString &pin,
                                       const QString &confirmPin) {
    if (busy_ || ready_) return;
    if (recoveryCode_.isEmpty()) prepareRecoveryCode();

    const QString name = displayName.trimmed();
    if (name.size() < 2 || name.size() > 24) {
        fail(QStringLiteral("name_invalid"));
        return;
    }
    if (pin != confirmPin) {
        fail(QStringLiteral("pin_mismatch"));
        return;
    }
    if (!security::PinPolicy::validPin(pin)) {
        fail(QStringLiteral("pin_invalid"));
        return;
    }

    clearError();
    pendingName_ = name;
    pendingPin_ = pin;
    setBusy(true);
    // 先让 QML 画出 busy 状态，再在下一轮事件循环里跑 600k 次 PBKDF2。
    QTimer::singleShot(0, this, &OnboardingController::performCreate);
}

void OnboardingController::performCreate() {
    const QString userId = users_.createInitialAdmin(pendingName_, pendingPin_, recoveryCode_);
    if (userId.isEmpty()) {
        // 明文 PIN 不再有用；清零后再报告失败。
        pendingPin_.fill(QChar(0));
        pendingPin_.clear();
        setBusy(false);
        fail(QStringLiteral("create_failed"));
        emit finished(false);
        return;
    }

    QString loginError;
    if (session_) loginError = session_->login(userId, pendingPin_);
    pendingPin_.fill(QChar(0));
    pendingPin_.clear();
    setBusy(false);

    if (!loginError.isEmpty()) {
        // 管理员已经写进注册表，只是自动登录失败（例如 KDF/库打不开）。
        // 状态是一致的：下次启动走登录页，用户用刚设的 PIN 登录即可。
        fail(QStringLiteral("login_failed"));
        active_ = false;
        emit activeChanged();
        emit finished(false);
        return;
    }

    ready_ = true;
    emit readyChanged();
    emit finished(true);
}

void OnboardingController::dismiss() {
    if (!ready_) return;
    active_ = false;
    emit activeChanged();
}
