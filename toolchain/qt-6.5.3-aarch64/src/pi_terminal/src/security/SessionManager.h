#pragma once
#include <QByteArray>
#include <QHash>
#include <QMutex>
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

#include "security/AuthService.h"
#include "security/TaskCapability.h"
// 信号参数是 UserDatabase*，Qt 6.4 的 metatype 要求指针指向完整类型。
#include "security/UserDatabase.h"

namespace security {


class AuthService;
class KdfClient;
class UserService;
class CardIndex;

// 单一 activeUserId；切用户/退出立即销毁旧会话能力（服务端执行，不只是隐藏 UI）。
//
// 前台能力与任务能力分开（f-day1 §5）：
//   - 锁屏撤销前台读写，但已启动任务仍可向原用户追加样本
//   - 切用户前必须所有任务收尾，否则拒绝
//   - 迟到事件凭代次拒绝，不得挂到新用户
//
// QML 通过本对象的 Q_INVOKABLE 方法调用，不持有 PIN/KEK/DB key。
// 所有操作在服务端再次校验，不依赖 UI 隐藏控件。
class SessionManager : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString activeUserId READ activeUserId NOTIFY changed)
    Q_PROPERTY(QString activeDisplayName READ activeDisplayName NOTIFY changed)
    Q_PROPERTY(bool locked READ locked NOTIFY changed)
    Q_PROPERTY(bool loggedIn READ loggedIn NOTIFY changed)
    Q_PROPERTY(bool isAdmin READ isAdmin NOTIFY changed)
    Q_PROPERTY(bool hasUsers READ hasUsers NOTIFY changed)
    Q_PROPERTY(QVariantList users READ users NOTIFY usersChanged)
    Q_PROPERTY(QString ownAvatarSource READ ownAvatarSource NOTIFY usersChanged)
    Q_PROPERTY(QString message READ message NOTIFY messageChanged)
    Q_PROPERTY(int retryAfterMs READ retryAfterMs NOTIFY messageChanged)
    // 无操作自动锁屏：0 表示永不；未设置时默认 5 分钟。按当前登录用户取值。
    Q_PROPERTY(int autoLockSeconds READ autoLockSeconds NOTIFY changed)
    Q_PROPERTY(int ownLockTimeoutMinutes READ ownLockTimeoutMinutes NOTIFY changed)
    // 异步登录/解锁：KDF（PBKDF2 600k）与开库都在后台线程，UI 显示「正在解锁」。
    Q_PROPERTY(bool unlocking READ unlocking NOTIFY unlockingChanged)
    // 临时会话：无密码进入、每次会话独立目录、退出即删。QML 用它决定隐藏哪些入口。
    Q_PROPERTY(bool guestSession READ isGuest NOTIFY changed)
    // 恢复码登录后必须改 PIN 才能读写数据；服务端据此拒绝数据 API。
    Q_PROPERTY(bool mustChangePin READ mustChangePin NOTIFY changed)
    // 解锁进度阶段："verifying"（KDF/验签）→ "opening"（打开加密库）→ ""（结束）。
    // QML 据此画进度条，不是假动画：两个阶段各自代表真实的一段耗时。
    Q_PROPERTY(QString authStage READ authStage NOTIFY authStageChanged)

public:
    SessionManager(UserService *users, AuthService *auth, QObject *parent = nullptr);
    ~SessionManager() override;

    // 认证成功后建立唯一会话。已有会话会先被撤销。
    QString begin(const QString &userId, const QByteArray &dbKey, bool admin);

    void lock();
    void logout();

    // ---- QML 入口：全部经过服务端校验 ----

    // 低敏用户列表（只有 userId/displayName/admin/disabled）。
    Q_INVOKABLE void refreshUsers();
    // KDF 子进程客户端（可空）。设了就走异步登录：主线程不阻塞，动画不卡；
    // 子进程不可用时自动回退到同步 login()。
    void setKdfClient(KdfClient *client) { kdfClient_ = client; }

    // 用 PIN 登录。成功返回空，失败返回错误码（QML 只显示本地化提示）。
    Q_INVOKABLE QString login(const QString &userId, const QString &pin);
    // 用恢复码登录。成功后 mustChangePin=true，数据 API 直到 setRecoveryPin 成功才放行。
    Q_INVOKABLE QString loginWithRecoveryCode(const QString &userId,
                                               const QString &recoveryCode);
    // 恢复码登录后的强制改 PIN（不需要旧 PIN，DB key 已在会话内）。
    Q_INVOKABLE bool setRecoveryPin(const QString &newPin);
    // 两段式轮换恢复码：先展示新码，用户确认已保存后再 commit。
    Q_INVOKABLE QString beginRecoveryRotation();
    Q_INVOKABLE bool commitRecoveryRotation();
    Q_INVOKABLE void cancelRecoveryRotation();

    // 开一个临时会话：随机库密钥、独立目录、无 PIN 校验。
    // 返回空串表示成功；失败返回错误码。已有会话时先要求收尾。
    Q_INVOKABLE QString startGuestSession();
    // 结束临时会话并删除它的全部数据。非临时会话调用时什么都不做。
    Q_INVOKABLE void endGuestSession();
    bool isGuest() const { return guestSession_; }
    // 异步登录：KDF 在子进程算，主线程只画进度条。结果经 loginFinished 回传。
    Q_INVOKABLE bool loginWithWorker(const QString &userId, const QString &pin);
    Q_INVOKABLE bool unlockWithWorker(const QString &pin);
    bool unlocking() const { return unlocking_; }
    QString authStage() const { return authStage_; }
    // 锁屏后解锁：必须重输 PIN，不得刷卡解锁。
    Q_INVOKABLE QString unlockWithPin(const QString &pin);
    Q_INVOKABLE void lockNow();
    Q_INVOKABLE void signOut();

    // ---- 用户管理（D 写：设置页入口；服务端复核管理员身份）----
    // 新建用户并生成一次性恢复码。返回 {userId, recoveryCode}；失败返回空 map。
    Q_INVOKABLE QVariantMap createUser(const QString &displayName, const QString &pin, bool admin);
    // 登录页用：没有当前会话，由界面先验过管理员 PIN，再把该管理员当 actor。
    Q_INVOKABLE QVariantMap createUserAs(const QString &actorUserId, const QString &displayName,
                                         const QString &pin, bool admin);
    // 改自己的 PIN：必须给旧 PIN；成功后旧 PIN 立即失效。
    Q_INVOKABLE bool changeOwnPin(const QString &oldPin, const QString &newPin);
    // 已登录状态下用恢复码重设自己的 PIN（不需要旧 PIN）。
    // 恢复码由 AuthService 验证并解出 DB key，必须与当前会话的 dbKey 逐字节一致；
    // 成功后恢复码不轮换（它封装的是同一个 DB key）。
    Q_INVOKABLE bool changeOwnPinWithRecoveryCode(const QString &recoveryCode,
                                                  const QString &newPin);
    // 只校验 PIN、不改会话状态也不消耗尝试次数（绑卡前的重验用）。
    Q_INVOKABLE bool verifyPin(const QString &pin);
    // 登录页没有当前用户时用这个：按指定账户验证 PIN，且只接受未停用的管理员。
    Q_INVOKABLE bool verifyAdminPinFor(const QString &userId, const QString &pin);
    // 改网络策略前重验管理员 PIN：返回 {ok, code, retryAfterMs}。
    Q_INVOKABLE QVariantMap verifyAdminPinForPolicy(const QString &pin);

    // 保存当前用户自己的自动锁屏时长；只影响该账户。
    // 允许 0（永不）/1/2/5/10/15/30 分钟；其它值拒绝。
    Q_INVOKABLE bool setOwnLockTimeout(int minutes);

    // ---- 账户删除（硬删除；服务端再次校验权限/最后管理员/任务）----
    // 成功返回空；失败返回错误码：
    // AUTH_FAILED / BUSY / LAST_ADMIN / NOT_AUTHORIZED /
    // NOT_FOUND / NAME_MISMATCH / STORAGE_UNAVAILABLE。
    // 本人删号：当前 PIN；成功后会话立即失效并回到登录页。
    // 改自己的显示名：2..24 字符，不碰 PIN、恢复码与加密库。
    // 成功返回空，失败返回 NAME_INVALID / NOT_AUTHORIZED / STORAGE_UNAVAILABLE。
    Q_INVOKABLE QString changeOwnDisplayName(const QString &name);

    Q_INVOKABLE QString deleteOwnAccount(const QString &pin);
    // 管理员删他人：管理员 PIN + 目标显示名精确匹配；目标不能是自己。
    Q_INVOKABLE QString deleteUser(const QString &adminPin, const QString &targetUserId,
                                   const QString &targetDisplayName);

    // ---- 头像（只能改自己的）----
    // 读 sourcePath，居中裁成正方形、缩到 256px 并做圆形 alpha 蒙版，
    // 原子写入 users.json 同目录下的 avatars/<userId>.png，再登记文件名。
    // 成功返回空；失败返回错误码（INVALID_IMAGE / STORAGE_UNAVAILABLE / NOT_AUTHORIZED）。
    Q_INVOKABLE QString setOwnAvatar(const QString &sourcePath);
    Q_INVOKABLE bool removeOwnAvatar();
    // 当前用户头像的 file:// URL；没有头像或文件缺失时为空。
    QString ownAvatarSource() const;

    // 任务能力：由可信侧在 measurement 开始时创建，绑定当前用户与设备。
    QString startTask(const QString &deviceId);
    // ---- 重启恢复（报告 §5.3）----
    // 只记录"上次解锁的用户"，**不记录** PIN、KEK、DB key。
    // 重启后流程：先回到该用户的锁屏（需重输 PIN），再恢复其任务归属。
    // 不是"重启即登录"——那会绕过 PIN。
    QString lastUserHint() const;
    // 由 TerminalApplication 在成功登录后调用。
    void rememberUserHint(const QString &userId);
    void clearUserHint();
    // 是否有可恢复的上次用户（用于显示"上次是 X"）。
    bool hasUserHint() const;

    // 报告 §5.3：无法确认测量是否完成时，显式取消并标记"不完整"。
    // 与 finishTask 的区别：finishTask 是正常收尾，本方法是异常收尾。
    Q_INVOKABLE bool cancelTaskAsIncomplete(const QString &taskId);
    // 任务是否被标记为不完整。
    Q_INVOKABLE bool taskIsIncomplete(const QString &taskId) const;

    // QML 只读摘要：{taskId, deviceId}，不含 TaskCapability* 指针。
    Q_INVOKABLE QVariantList pendingTaskSummaries() const;
    // QML 用：结束某个任务。服务端校验归属。
    Q_INVOKABLE bool finishTask(const QString &taskId);
    bool hasUnfinishedTasks() const;
    QVector<TaskCapability *> unfinishedTasks() const;

    // 追加样本：同时校验任务归属、设备与代次。
    bool appendTaskSample(const QString &taskId, const QString &deviceId, qint64 generation);

    // 模块观测入可信存储（报告 §6.1）：QML/模块都拿不到 DB，只有这里能写。
    // 观察值缺失或库未打开时返回 false，不静默吞掉。
    Q_INVOKABLE bool recordObservation(const QString &deviceId, double value);

    // 报告 §6.4：按保留期限清理本用户历史。0 表示永久保留（直接返回 true）。
    Q_INVOKABLE bool applyRetention(int retentionDays);

    QString activeUserId() const { return activeUserId_; }
    QString activeDisplayName() const { return activeDisplayName_; }
    bool locked() const { return locked_; }
    bool loggedIn() const { return !activeUserId_.isEmpty(); }
    bool hasUsers() const { return !users_.isEmpty(); }
    QVariantList users() const { return users_; }
    QString message() const { return message_; }
    int retryAfterMs() const { return retryAfterMs_; }
    int autoLockSeconds() const;
    int ownLockTimeoutMinutes() const;

    // 只有当前 token 能通过；旧 token 一律拒绝。
    bool validate(const QString &token) const;
    bool isAdmin() const { return admin_; }
    bool mustChangePin() const { return mustChangePin_; }

    // 可信侧短期持有；不暴露给 QML。
    QByteArray dbKey() const;

    // 当前打开的用户库（未登录/锁屏前为 nullptr）。
    // 只给 SecurityService 这类可信宿主组件用；不得经 contextProperty 暴露。
    UserDatabase *database() const { return database_; }
    // 打开/关闭用户库。登录后由 TerminalApplication 调用一次。
    bool openDatabase();

signals:
    void changed();
    void usersChanged();
    void messageChanged();
    // 切用户/退出/撤权：D 侧据此断开传输并销毁派生会话密钥。
    void sessionInvalidated();
    // 账户已从注册表移除：宿主据此清理卡索引/权限矩阵等非库内状态。
    void userDeleted(const QString &userId);
    // 当前用户的加密库被打开/关闭（含切用户、退出、删号）。
    // SecurityService、ModuleDataApi 等持有者必须换指针；否则库关闭后仍用
    // 旧指针，或者一直拿不到库而误报 NOT_AUTHORIZED。
    void databaseChanged(security::UserDatabase *database);
    // 锁屏/解锁状态变化，QML 用它切换遮罩层。
    void lockStateChanged();
    void unlockingChanged();
    void authStageChanged();
    void loginFinished(const QString &error);
    void unlockFinished(const QString &error);
    // 当前用户的自动锁屏时长被修改：SessionGate 重置空闲计时。
    void lockTimeoutChanged();

private:
    // 只能在 unlockWithPin() 成功之后内部调用：本函数不验 PIN。
    // 公开它会成为锁屏旁路，因此不导出。
    void unlock(const QString &wantUserId);
    void clear();
    void setMessage(const QString &code, int retryAfterMs = 0);

    // 头像目录与注册表同目录，测试里随临时 users.json 自动隔离。
    QString avatarDirectory() const;
    QString avatarSourceFor(const QString &userId, const QString &fileName) const;

    // 硬删除账号数据（注册表、库目录、头像、卡/锁/上次用户由信号与清理完成）。
    // 注册表移除是提交点：先移除记录，再删文件；返回 false 表示记录未删。
    bool deleteAccountData(const QString &userId);
    int enabledAdminCount() const;
    void auditAccountDeletion(const QString &targetUserId, const QString &result);

    UserService *usersService_ = nullptr;
    AuthService *authService_ = nullptr;

    QString activeUserId_;
    QString activeDisplayName_;
    QString tokenHex_;   // 与 begin() 返回值同一形态，避免调用侧还去做编码转换
    QByteArray dbKey_;
    // 上次解锁的用户（仅 userId，不含任何密钥材料）。
    QString lastUserHintPath_;
    // 可信存储句柄：只在 SessionManager 内部持有，QML 与模块都拿不到。
    UserDatabase *database_ = nullptr;
    bool locked_ = false;
    bool admin_ = false;
    bool mustChangePin_ = false;
    QString pendingRecoveryCode_;
    QString pendingRecoveryUserId_;
    QString message_;
    int retryAfterMs_ = 0;
    QVariantList users_;
    QHash<QString, TaskCapability *> tasks_;
    QHash<QString, qint64> taskGenerations_;
    bool unlocking_ = false;
    // 临时会话状态。库密钥只存内存（随机生成，不落盘），退出即随对象销毁。
    bool guestSession_ = false;
    QString guestUserId_;
    // 完成一次"KDF 已算好"之后的收尾：比较 verifier、解封、开库、发信号。
    void completeLogin(const QString &userId, const AuthService::Result &result);
    void completeUnlock(const AuthService::Result &result);
    KdfClient *kdfClient_ = nullptr;
    // 失败回退时需要重算一次，用完立刻清掉（不在内存里长期留存 PIN）。
    QString loginFallbackPin_;
    // AuthService 有内部状态、会写账户锁定文件：所有入口串行调用它。
    QMutex authMutex_;
    QString authStage_;
};

}  // namespace security
