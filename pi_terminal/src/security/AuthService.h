#pragma once
#include <QByteArray>
#include <QString>

namespace security {


class UserService;

// 认证结果。错误提示不区分「账号不存在」与「PIN 错误」（f-day1 §2）。
namespace AuthResult {
constexpr auto Ok = "OK";
constexpr auto AuthFailed = "AUTH_FAILED";
constexpr auto RateLimited = "RATE_LIMITED";
constexpr auto NotAuthorized = "NOT_AUTHORIZED";
// 锁屏期间服务端拒绝数据 API；恢复码登录后、改 PIN 前拒绝数据 API。
constexpr auto SessionLocked = "SESSION_LOCKED";
constexpr auto PinChangeRequired = "SESSION_PIN_CHANGE_REQUIRED";
}  // namespace AuthResult

// 认证与限速。锁定状态落盘，重启不清除（§2 要求）。
class AuthService {
public:
    struct Result {
        QString code;
        int retryAfterMs = 0;      // 仅 RATE_LIMITED 时非零，可公开的剩余等待时间
        QByteArray dbKey;          // 仅 Ok 时非空；只在可信侧短期持有
        QString userId;
        bool admin = false;
    };

    explicit AuthService(UserService &users, QString lockStatePath = {});

    // 未知账号同样计入终端级 1 次/秒上限，避免用它探测账号是否存在。
    Result verifyPin(const QString &userId, const QString &pin);

    // 供 KDF 子进程使用的两段式入口：先把"这一 PIN 该用什么盐/迭代"拿出来，
    // KDF 在别处算完后，用 finishVerify 完成比较、解封与锁定状态更新。
    // 这样安全判定仍然完整走一遍，只是把那一步耗时计算挪出了主线程。
    struct KdfParams {
        QByteArray salt;
        int iterations = 0;
    };
    // 返回 false 表示不必算 KDF（账号不存在/已锁定/PIN 格式非法），early 已填好错误码。
    bool beginVerify(const QString &userId, const QString &pin, KdfParams *params, Result *early);
    // 用外部算好的 KEK 继续：失败计数/锁定/解封 DB key 全部照旧。
    Result finishVerify(const QString &userId, const QByteArray &kek);

    // 成功后清除该账号失败计数；失败按连错累计。
    bool changePin(const QString &userId, const QString &oldPin, const QString &newPin);
    // 恢复码验证：独立失败计数/锁定，不占用 PIN 的失败计数。
    Result verifyRecoveryCode(const QString &userId, const QString &recoveryCode);
    // 恢复码登录后的强制改 PIN：已经有 dbKey，不需要旧 PIN。
    bool resetPinWithDbKey(const QString &userId, const QByteArray &dbKey,
                           const QString &newPin);

    // 仅测试/管理员重验用：不消耗一次尝试。
    bool verifyAdminPin(const QString &userId, const QString &pin);

    // 管理员高风险操作重验：与登录共用终端 1 次/秒与 5 次锁定，
    // 但不解封 DB key、不重建会话。只接受未禁用的管理员账号。
    Result verifyAdminReauth(const QString &userId, const QString &pin);

    // 只验“当前用户自己的 PIN”，不要求管理员、不消耗尝试次数。
    // 用于本人删号等自助高风险操作。
    bool verifyOwnPin(const QString &userId, const QString &pin);

    // 账户删除后清掉该账号的失败计数/锁定记录（没有记录也视为成功）。
    bool clearLockState(const QString &userId);

private:
    struct LockState {
        int failures = 0;
        qint64 lockedUntilMs = 0;   // 单调时钟不可跨重启，故用 epoch 毫秒
        int recoveryFailures = 0;
        qint64 recoveryLockedUntilMs = 0;
    };
    LockState lockFor(const QString &userId) const;
    void storeLock(const QString &userId, const LockState &state);
    bool terminalRateLimited(qint64 nowMs) const;

    UserService &users_;
    QString lockStatePath_;
    mutable qint64 lastAttemptMs_ = 0;
};

}  // namespace security
