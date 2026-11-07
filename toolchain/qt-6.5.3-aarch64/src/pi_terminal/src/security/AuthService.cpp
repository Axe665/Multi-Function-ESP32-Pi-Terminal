#include "security/AuthService.h"

#include "security/KeyWrap.h"
#include "security/PinPolicy.h"
#include "security/UserService.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QStandardPaths>

namespace security {


namespace {

QString defaultLockPath() {
    return QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation)
        + QStringLiteral("/auth_locks.json");
}

qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }

}  // namespace

AuthService::AuthService(UserService &users, QString lockStatePath)
    : users_(users)
    , lockStatePath_(lockStatePath.isEmpty() ? defaultLockPath() : std::move(lockStatePath)) {}

AuthService::LockState AuthService::lockFor(const QString &userId) const {
    QFile file(lockStatePath_);
    if (!file.open(QIODevice::ReadOnly)) return {};
    const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
    const QJsonObject entry = root.value("locks").toObject().value(userId).toObject();
    LockState state;
    state.failures = entry.value("failures").toInt();
    state.lockedUntilMs = static_cast<qint64>(entry.value("locked_until_ms").toDouble());
    state.recoveryFailures = entry.value("recovery_failures").toInt();
    state.recoveryLockedUntilMs =
        static_cast<qint64>(entry.value("recovery_locked_until_ms").toDouble());
    return state;
}

void AuthService::storeLock(const QString &userId, const LockState &state) {
    QJsonObject root;
    QFile file(lockStatePath_);
    if (file.open(QIODevice::ReadOnly)) root = QJsonDocument::fromJson(file.readAll()).object();
    file.close();

    QJsonObject locks = root.value("locks").toObject();
    if (state.failures == 0 && state.lockedUntilMs == 0
        && state.recoveryFailures == 0 && state.recoveryLockedUntilMs == 0)
        locks.remove(userId);
    else locks[userId] = QJsonObject{
        {"failures", state.failures},
        {"locked_until_ms", static_cast<double>(state.lockedUntilMs)},
        {"recovery_failures", state.recoveryFailures},
        {"recovery_locked_until_ms", static_cast<double>(state.recoveryLockedUntilMs)}};
    const QJsonDocument document(QJsonObject{{"schema", "p0-auth-locks-v1"}, {"locks", locks}});

    QDir().mkpath(QFileInfo(lockStatePath_).absolutePath());
    QSaveFile out(lockStatePath_);
    if (!out.open(QIODevice::WriteOnly)) return;
    if (!out.setPermissions(QFile::ReadOwner | QFile::WriteOwner)) return;
    if (out.write(document.toJson(QJsonDocument::Compact)) < 0) { out.cancelWriting(); return; }
    out.commit();
    QFile::setPermissions(lockStatePath_, QFile::ReadOwner | QFile::WriteOwner);
}

bool AuthService::clearLockState(const QString &userId) {
    if (userId.isEmpty()) return false;
    storeLock(userId, LockState{});
    return true;
}

bool AuthService::terminalRateLimited(qint64 now) const {
    // 语义是「距上次认证**结束**不足 1 秒」。只看开始时间的话，
    // PBKDF2 本身要 760ms，紧接着的第二次调用总会被判为超时后放行。
    return lastAttemptMs_ != 0 && now - lastAttemptMs_ < PinPolicy::kTerminalMinIntervalMs;
}

bool AuthService::beginVerify(const QString &userId, const QString &pin, KdfParams *params, Result *early) {
    const qint64 start = nowMs();
    if (terminalRateLimited(start)) {
        *early = {AuthResult::RateLimited, PinPolicy::kTerminalMinIntervalMs, {}, {}, false};
        return false;
    }
    UserRecord record;
    const bool found = users_.lookup(userId, &record);
    LockState state = found ? lockFor(userId) : LockState{};
    if (found && state.lockedUntilMs > start) {
        lastAttemptMs_ = qMax(start, nowMs());
        *early = {AuthResult::RateLimited, static_cast<int>(state.lockedUntilMs - start), {}, {}, false};
        return false;
    }
    // 账号不存在与 PIN 错误返回同一个 code，不泄漏存在性。
    if (!found || record.disabled || !PinPolicy::validPin(pin)) {
        if (found) {
            ++state.failures;
            if (state.failures >= PinPolicy::kMaxAccountFailures)
                state.lockedUntilMs = nowMs() + PinPolicy::kAccountLockMs;
            storeLock(userId, state);
        }
        lastAttemptMs_ = qMax(start, nowMs());
        *early = {AuthResult::AuthFailed, 0, {}, {}, false};
        return false;
    }
    params->salt = record.salt;
    params->iterations = PinPolicy::effectiveIterations(record.iterations);
    lastAttemptMs_ = qMax(start, nowMs());
    return true;
}

AuthService::Result AuthService::finishVerify(const QString &userId, const QByteArray &kek) {
    UserRecord record;
    if (!users_.lookup(userId, &record) || record.disabled || kek.size() != 32)
        return {AuthResult::AuthFailed, 0, {}, {}, false};

    LockState state = lockFor(userId);
    if (!PinPolicy::verifyMatches(record.verifier, kek)) {
        ++state.failures;
        if (state.failures >= PinPolicy::kMaxAccountFailures)
            state.lockedUntilMs = nowMs() + PinPolicy::kAccountLockMs;
        storeLock(userId, state);
        return {AuthResult::AuthFailed, 0, {}, {}, false};
    }
    const QByteArray dbKey = KeyWrap::open(kek, record.wrappedDbKey, record.dbKeyNonce);
    if (dbKey.isEmpty()) return {AuthResult::AuthFailed, 0, {}, {}, false};
    storeLock(userId, {});
    return {AuthResult::Ok, 0, dbKey, record.userId, record.admin};
}

AuthService::Result AuthService::verifyPin(const QString &userId, const QString &pin) {
    const qint64 start = nowMs();
    // 终端级限速：未知账号也走这里，所以不能用它判断账号是否存在。
    if (terminalRateLimited(start)) {
        return {AuthResult::RateLimited, PinPolicy::kTerminalMinIntervalMs, {}, {}, false};
    }

    const auto finish = [this, start]() {
        // 记录结束时间，而不是开始时间。
        lastAttemptMs_ = qMax(start, nowMs());
    };

    UserRecord record;
    const bool found = users_.lookup(userId, &record);
    LockState state = found ? lockFor(userId) : LockState{};
    if (found && state.lockedUntilMs > start) {
        finish();
        return {AuthResult::RateLimited, static_cast<int>(state.lockedUntilMs - start), {}, {}, false};
    }

    // 账号不存在与 PIN 错误返回同一个 code，不泄漏存在性。
    if (!found || record.disabled || !PinPolicy::validPin(pin)) {
        if (found) {
            ++state.failures;
            if (state.failures >= PinPolicy::kMaxAccountFailures)
                state.lockedUntilMs = nowMs() + PinPolicy::kAccountLockMs;
            storeLock(userId, state);
        }
        finish();
        return {AuthResult::AuthFailed, 0, {}, {}, false};
    }

    const QByteArray kek = PinPolicy::deriveKek(pin, record.salt, PinPolicy::effectiveIterations(record.iterations));
    if (!PinPolicy::verifyMatches(record.verifier, kek)) {
        ++state.failures;
        if (state.failures >= PinPolicy::kMaxAccountFailures)
            state.lockedUntilMs = nowMs() + PinPolicy::kAccountLockMs;
        storeLock(userId, state);
        finish();
        return {AuthResult::AuthFailed, 0, {}, {}, false};
    }

    const QByteArray dbKey = KeyWrap::open(kek, record.wrappedDbKey, record.dbKeyNonce);
    if (dbKey.isEmpty()) {
        finish();
        return {AuthResult::AuthFailed, 0, {}, {}, false};
    }

    storeLock(userId, {});   // 正确认证才清除该账号失败计数
    finish();
    return {AuthResult::Ok, 0, dbKey, record.userId, record.admin};
}

AuthService::Result AuthService::verifyAdminReauth(const QString &userId, const QString &pin) {
    const qint64 start = nowMs();
    if (terminalRateLimited(start))
        return {AuthResult::RateLimited, PinPolicy::kTerminalMinIntervalMs, {}, {}, false};
    const auto finish = [this, start]() { lastAttemptMs_ = qMax(start, nowMs()); };

    UserRecord record;
    const bool found = users_.lookup(userId, &record);
    if (!found || !record.admin || record.disabled) {
        finish();
        return {AuthResult::NotAuthorized, 0, {}, {}, false};
    }
    LockState state = lockFor(userId);
    if (state.lockedUntilMs > start) {
        finish();
        return {AuthResult::RateLimited,
                static_cast<int>(state.lockedUntilMs - start), {}, {}, false};
    }
    if (!PinPolicy::validPin(pin)) {
        ++state.failures;
        if (state.failures >= PinPolicy::kMaxAccountFailures)
            state.lockedUntilMs = nowMs() + PinPolicy::kAccountLockMs;
        storeLock(userId, state);
        finish();
        return {AuthResult::AuthFailed, 0, {}, {}, false};
    }
    const QByteArray kek = PinPolicy::deriveKek(
        pin, record.salt, PinPolicy::effectiveIterations(record.iterations));
    if (!PinPolicy::verifyMatches(record.verifier, kek)) {
        ++state.failures;
        if (state.failures >= PinPolicy::kMaxAccountFailures)
            state.lockedUntilMs = nowMs() + PinPolicy::kAccountLockMs;
        storeLock(userId, state);
        finish();
        return {AuthResult::AuthFailed, 0, {}, {}, false};
    }
    storeLock(userId, {});
    finish();
    return {AuthResult::Ok, 0, {}, record.userId, true};
}

bool AuthService::verifyAdminPin(const QString &userId, const QString &pin) {
    UserRecord record;
    if (!users_.lookup(userId, &record) || !record.admin || record.disabled) return false;
    if (!PinPolicy::validPin(pin)) return false;
    return PinPolicy::verifyMatches(record.verifier,
                                    PinPolicy::deriveKek(pin, record.salt, PinPolicy::effectiveIterations(record.iterations)));
}

bool AuthService::verifyOwnPin(const QString &userId, const QString &pin) {
    UserRecord record;
    if (!users_.lookup(userId, &record) || record.disabled) return false;
    if (!PinPolicy::validPin(pin)) return false;
    return PinPolicy::verifyMatches(record.verifier,
                                    PinPolicy::deriveKek(pin, record.salt, PinPolicy::effectiveIterations(record.iterations)));
}

bool AuthService::changePin(const QString &userId, const QString &oldPin, const QString &newPin) {
    UserRecord record;
    if (!users_.lookup(userId, &record) || record.disabled) return false;
    if (!PinPolicy::validPin(newPin)) return false;

    const QByteArray oldKek = PinPolicy::deriveKek(oldPin, record.salt, PinPolicy::effectiveIterations(record.iterations));
    if (!PinPolicy::verifyMatches(record.verifier, oldKek)) return false;

    // 改 PIN 只重封装 DB key，不重加密整库（f-day1 §5）。
    const QByteArray dbKey = KeyWrap::open(oldKek, record.wrappedDbKey, record.dbKeyNonce);
    if (dbKey.isEmpty()) return false;

    UserRecord updated = record;
    updated.salt = PinPolicy::salt16();
    const QByteArray newKek = PinPolicy::deriveKek(
        newPin, updated.salt, PinPolicy::effectiveIterations(updated.iterations));
    if (newKek.isEmpty()) return false;
    updated.verifier = PinPolicy::verifyValue(newKek);
    updated.wrappedDbKey = KeyWrap::seal(newKek, dbKey, &updated.dbKeyNonce);
    if (updated.wrappedDbKey.isEmpty()) return false;

    // 失败时保留旧封装（文档要求"失败保留可用旧封装"）。
    return users_.replaceRecord(updated);
}

AuthService::Result AuthService::verifyRecoveryCode(const QString &userId,
                                                    const QString &recoveryCode) {
    const qint64 start = nowMs();
    if (terminalRateLimited(start))
        return {AuthResult::RateLimited, PinPolicy::kTerminalMinIntervalMs, {}, {}, false};

    const auto finish = [this, start]() { lastAttemptMs_ = qMax(start, nowMs()); };
    UserRecord record;
    const bool found = users_.lookup(userId, &record);
    LockState state = found ? lockFor(userId) : LockState{};
    if (found && state.recoveryLockedUntilMs > start) {
        finish();
        return {AuthResult::RateLimited,
                static_cast<int>(state.recoveryLockedUntilMs - start), {}, {}, false};
    }
    QByteArray dbKey;
    const bool ok = found && !record.disabled && !recoveryCode.isEmpty()
        && users_.openWithRecoveryCode(userId, recoveryCode, &dbKey)
        && dbKey.size() == 32;
    if (!ok) {
        if (found) {
            ++state.recoveryFailures;
            if (state.recoveryFailures >= PinPolicy::kMaxAccountFailures)
                state.recoveryLockedUntilMs = nowMs() + PinPolicy::kAccountLockMs;
            storeLock(userId, state);
        }
        finish();
        return {AuthResult::AuthFailed, 0, {}, {}, false};
    }
    // 成功恢复清掉两套计数与 PIN 锁定：用户接下来要设新 PIN。
    storeLock(userId, {});
    finish();
    return {AuthResult::Ok, 0, dbKey, record.userId, record.admin};
}

bool AuthService::resetPinWithDbKey(const QString &userId, const QByteArray &dbKey,
                                    const QString &newPin) {
    if (dbKey.size() != 32 || !PinPolicy::validPin(newPin)) return false;
    UserRecord record;
    if (!users_.lookup(userId, &record) || record.disabled) return false;
    UserRecord updated = record;
    updated.salt = PinPolicy::salt16();
    const QByteArray kek = PinPolicy::deriveKek(
        newPin, updated.salt, PinPolicy::effectiveIterations(updated.iterations));
    if (kek.isEmpty()) return false;
    updated.verifier = PinPolicy::verifyValue(kek);
    updated.wrappedDbKey = KeyWrap::seal(kek, dbKey, &updated.dbKeyNonce);
    if (updated.wrappedDbKey.isEmpty()) return false;
    if (!users_.replaceRecord(updated)) return false;
    storeLock(userId, {});
    return true;
}

}  // namespace security
