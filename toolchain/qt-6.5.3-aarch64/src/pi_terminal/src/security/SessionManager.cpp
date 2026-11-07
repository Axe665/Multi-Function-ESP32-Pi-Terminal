#include "security/SessionManager.h"
#include "security/PinPolicy.h"
#include <QCoreApplication>
#include <QEventLoop>
#include <QDateTime>
#include <QThread>
#include <QElapsedTimer>
#include <QDebug>
#include <QFutureWatcher>
#include <QtConcurrent>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QPainterPath>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUrl>
#include <QUuid>

#include "security/AuditLog.h"
#include "security/UserDatabase.h"

#include "security/AuthService.h"
#include "security/KdfClient.h"
#include "security/RecoveryCode.h"
#include "security/UserService.h"

#include <QRandomGenerator>

namespace security {


SessionManager::SessionManager(UserService *users, AuthService *auth, QObject *parent)
    : QObject(parent), usersService_(users), authService_(auth) {
    lastUserHintPath_ = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation)
        + QStringLiteral("/last_user.json");
    refreshUsers();
}

SessionManager::~SessionManager() {
    clear();
}

QString SessionManager::begin(const QString &userId, const QByteArray &dbKey, bool admin) {
    if (userId.isEmpty() || dbKey.isEmpty()) return {};
    // 切用户前必须收尾：有未完成任务时拒绝新会话。
    if (hasUnfinishedTasks()) return {};
    clear();
    activeUserId_ = userId;
    dbKey_ = dbKey;
    admin_ = admin;
    locked_ = false;
    mustChangePin_ = false;
    // 生成 32 字节随机 token，对外一律以 hex 字符串出现。
    QByteArray token(32, Qt::Uninitialized);
    for (int i = 0; i < token.size(); ++i) token[i] = static_cast<char>(QRandomGenerator::system()->bounded(256));
    tokenHex_ = QString::fromLatin1(token.toHex());
    token.fill('\0');
    emit changed();
    return tokenHex_;
}

void SessionManager::lock() {
    if (activeUserId_.isEmpty() || locked_) return;
    // 前台能力立即失效；任务能力保留（仍可向原用户追加）。
    locked_ = true;
    emit changed();
    emit lockStateChanged();
}

void SessionManager::unlock(const QString &wantUserId) {
    // 锁屏后必须重输 PIN；调用方只有在 verifyPin 成功后才应走到这里。
    if (!locked_ || wantUserId != activeUserId_) return;
    locked_ = false;
    setMessage(QString());
    emit changed();
    emit lockStateChanged();
}

void SessionManager::logout() {
    if (activeUserId_.isEmpty()) return;
    // 退出时所有任务一并撤销，迟到回调凭代次被拒。
    clear();
    emit sessionInvalidated();
    emit changed();
    emit lockStateChanged();
}

// ---- QML 入口 ----

QVariantMap SessionManager::createUserAs(const QString &actorUserId, const QString &displayName,
                                         const QString &pin, bool admin) {
    QVariantMap out;
    if (actorUserId.isEmpty() || !usersService_) {
        setMessage(QStringLiteral("NOT_AUTHORIZED"));
        return out;
    }
    // 调用方（登录页）已经用 verifyAdminPinFor 验过这个管理员，这里只复核身份标记。
    bool actorIsAdmin = false;
    for (const auto &entry : users_) {
        const auto map = entry.toMap();
        if (map.value("userId").toString() == actorUserId && map.value("admin").toBool()
                && !map.value("disabled").toBool()) { actorIsAdmin = true; break; }
    }
    if (!actorIsAdmin) {
        setMessage(QStringLiteral("NOT_AUTHORIZED"));
        return out;
    }
    const QString recovery = RecoveryCode::generate();
    const QString userId = usersService_->createUser(actorUserId, displayName, pin, admin, recovery);
    if (userId.isEmpty()) {
        setMessage(QStringLiteral("INVALID_MESSAGE"));
        return out;
    }
    out.insert(QStringLiteral("userId"), userId);
    out.insert(QStringLiteral("recoveryCode"), recovery);
    refreshUsers();
    setMessage(QString());
    return out;
}

QVariantMap SessionManager::createUser(const QString &displayName, const QString &pin, bool admin) {
    QVariantMap out;
    if (!loggedIn() || !admin_) {
        setMessage(QStringLiteral("NOT_AUTHORIZED"));
        return out;
    }
    if (!usersService_) {
        setMessage(QStringLiteral("STORAGE_UNAVAILABLE"));
        return out;
    }
    // 恢复码由服务端生成，只回传一次给界面显示；不写日志、不落盘。
    const QString recovery = RecoveryCode::generate();
    const QString userId = usersService_->createUser(activeUserId_, displayName, pin, admin, recovery);
    if (userId.isEmpty()) {
        setMessage(QStringLiteral("INVALID_MESSAGE"));
        return out;
    }
    out.insert(QStringLiteral("userId"), userId);
    out.insert(QStringLiteral("recoveryCode"), recovery);
    refreshUsers();
    setMessage(QString());
    return out;
}

bool SessionManager::changeOwnPin(const QString &oldPin, const QString &newPin) {
    if (!loggedIn() || !authService_) {
        setMessage(QStringLiteral("NOT_AUTHORIZED"));
        return false;
    }
    if (!authService_->changePin(activeUserId_, oldPin, newPin)) {
        setMessage(QStringLiteral("AUTH_FAILED"));
        return false;
    }
    mustChangePin_ = false;
    setMessage(QString());
    emit changed();
    return true;
}

bool SessionManager::changeOwnPinWithRecoveryCode(const QString &recoveryCode,
                                                  const QString &newPin) {
    if (!loggedIn() || guestSession_ || !authService_) {
        setMessage(QStringLiteral("NOT_AUTHORIZED"));
        return false;
    }
    if (!PinPolicy::validPin(newPin)) {
        setMessage(QStringLiteral("AUTH_FAILED"));
        return false;
    }
    // 恢复码验证会走终端限速与按账号的恢复码锁定（与登录路径共用计数）。
    const AuthService::Result result =
        authService_->verifyRecoveryCode(activeUserId_, recoveryCode);
    if (result.code != QLatin1String(AuthResult::Ok)) {
        setMessage(result.code, result.retryAfterMs);
        return false;
    }
    // 恢复码按 userId 验证，正常只会解出同一个 DB key；仍显式比对一次，
    // 防止将来多库/换库路径把别的 key 写进当前记录。
    if (result.dbKey.size() != 32 || result.dbKey != dbKey_) {
        setMessage(QStringLiteral("AUTH_FAILED"));
        return false;
    }
    if (!authService_->resetPinWithDbKey(activeUserId_, result.dbKey, newPin)) {
        setMessage(QStringLiteral("STORAGE_UNAVAILABLE"));
        return false;
    }
    mustChangePin_ = false;
    setMessage(QString());
    emit changed();
    return true;
}

QVariantMap SessionManager::verifyAdminPinForPolicy(const QString &pin) {
    QVariantMap out{{QStringLiteral("ok"), false},
                    {QStringLiteral("code"), QString::fromLatin1(AuthResult::NotAuthorized)},
                    {QStringLiteral("retryAfterMs"), 0}};
    if (!loggedIn() || !authService_ || !isAdmin()) return out;
    const auto result = authService_->verifyAdminReauth(activeUserId_, pin);
    out.insert(QStringLiteral("ok"), result.code == QLatin1String(AuthResult::Ok));
    out.insert(QStringLiteral("code"), result.code);
    out.insert(QStringLiteral("retryAfterMs"), result.retryAfterMs);
    return out;
}

bool SessionManager::verifyPin(const QString &pin) {
    if (!loggedIn() || !authService_) return false;
    // verifyAdminPin 不消耗尝试次数：这是重验，不是登录。
    return authService_->verifyAdminPin(activeUserId_, pin);
}

bool SessionManager::verifyAdminPinFor(const QString &userId, const QString &pin) {
    if (!authService_ || userId.isEmpty()) return false;
    bool admin = false;
    for (const auto &entry : users_) {
        const auto map = entry.toMap();
        if (map.value("userId").toString() == userId && map.value("admin").toBool()
                && !map.value("disabled").toBool()) { admin = true; break; }
    }
    if (!admin) return false;
    // 与 verifyPin 一样：这是重验，不消耗登录尝试次数。
    return authService_->verifyAdminPin(userId, pin);
}

int SessionManager::enabledAdminCount() const {
    if (!usersService_) return 0;
    int count = 0;
    for (const auto &user : usersService_->listUsers())
        if (user.admin && !user.disabled) ++count;
    return count;
}

void SessionManager::auditAccountDeletion(const QString &targetUserId, const QString &result) {
    if (!usersService_ || targetUserId.isEmpty()) return;
    // 审计必须落在操作者自己的库里。登录时已打开用户库；这里不做懒打开，
    // 避免在 WebEngine 同进程环境里从非预期路径触发首次 SQLCipher 初始化。
    // 库确实不可用时只跳过审计，不阻塞删除，但要留下明确日志。
    if (!database_ || !database_->isOpen()) {
        qWarning() << "account deletion audit skipped: user database is not open";
        return;
    }
    if (auto *log = database_->audit())
        log->record(activeUserId_, QString::fromLatin1(AuditAction::DeleteUser),
                    targetUserId, result);
}

bool SessionManager::deleteAccountData(const QString &userId) {
    if (userId.isEmpty() || !usersService_) return false;
    // 注册表移除是提交点：一旦成功，该账号就不能再登录；文件删除失败只会留下
    // 无法解密的孤儿目录，下次仍可由管理员/启动清理处理，不会出现"账户还在但库没了"。
    if (!usersService_->removeRecord(userId)) return false;

    if (userId == activeUserId_) {
        if (database_) {
            database_->close();
            delete database_;
            database_ = nullptr;
            emit databaseChanged(nullptr);
        }
    }

    UserDatabase cleanup;
    if (!cleanup.deleteUserData(userId))
        qWarning() << "account data directory could not be removed";

    const QString dirPath = avatarDirectory();
    if (!dirPath.isEmpty()) {
        const QDir dir(dirPath);
        for (const QFileInfo &info : dir.entryInfoList(QDir::Files)) {
            const QString name = info.fileName();
            if (name == userId + QStringLiteral(".png")
                || name.startsWith(userId + QStringLiteral("-")))
                QFile::remove(info.absoluteFilePath());
        }
    }

    if (authService_) authService_->clearLockState(userId);
    if (lastUserHint() == userId) clearUserHint();

    // 卡索引与权限矩阵不在加密库里，交给宿主清理。
    emit userDeleted(userId);
    return true;
}

QString SessionManager::changeOwnDisplayName(const QString &name) {
    if (!loggedIn() || !usersService_) return QStringLiteral("NOT_AUTHORIZED");
    const QString trimmed = name.trimmed();
    if (trimmed.size() < 2 || trimmed.size() > 24) return QStringLiteral("NAME_INVALID");
    if (!usersService_->setDisplayName(activeUserId_, trimmed))
        return QStringLiteral("STORAGE_UNAVAILABLE");
    activeDisplayName_ = trimmed;
    // 用户列表与 activeDisplayName 拿的是注册表快照，刷新后再发 changed，
    // 顶部摘要、其他用户列表与登录页的“上次登录”都会跟着更新。
    refreshUsers();
    emit changed();
    return QString();
}

QString SessionManager::deleteOwnAccount(const QString &pin) {
    if (!loggedIn() || !authService_) return QStringLiteral("NOT_AUTHORIZED");
    if (hasUnfinishedTasks()) return QStringLiteral("BUSY");
    if (!authService_->verifyOwnPin(activeUserId_, pin))
        return QStringLiteral("AUTH_FAILED");
    // 最后一个管理员也允许自删（用户要求）：删完注册表为空，宿主把首次开机
    // 向导重新拉起来（OnboardingController::rearm），用户在那里重建管理员。
    // 因此这里不再返回 LAST_ADMIN；deleteUser() 删别人时仍保留守卫。

    if (!deleteAccountData(activeUserId_)) return QStringLiteral("STORAGE_UNAVAILABLE");

    clear();
    emit sessionInvalidated();
    refreshUsers();
    emit lockStateChanged();
    // 登录页据此显示一次“账户已删除”。
    setMessage(QStringLiteral("ACCOUNT_DELETED"));
    return QString();
}

QString SessionManager::deleteUser(const QString &adminPin, const QString &targetUserId,
                                   const QString &targetDisplayName) {
    if (!loggedIn() || !usersService_ || !authService_ || !admin_)
        return QStringLiteral("NOT_AUTHORIZED");
    // 删自己必须走 deleteOwnAccount（需要自己的 PIN），不能从管理员列表绕过。
    if (targetUserId.isEmpty() || targetUserId == activeUserId_)
        return QStringLiteral("NOT_AUTHORIZED");
    if (!authService_->verifyAdminPin(activeUserId_, adminPin)) {
        auditAccountDeletion(targetUserId, QString::fromLatin1(AuditResult::Denied));
        return QStringLiteral("AUTH_FAILED");
    }

    UserRecord target;
    if (!usersService_->lookup(targetUserId, &target) || target.disabled) {
        auditAccountDeletion(targetUserId, QString::fromLatin1(AuditResult::Denied));
        return QStringLiteral("NOT_FOUND");
    }
    if (targetDisplayName.trimmed() != target.displayName) {
        auditAccountDeletion(targetUserId, QString::fromLatin1(AuditResult::Denied));
        return QStringLiteral("NAME_MISMATCH");
    }
    if (target.admin && enabledAdminCount() <= 1) {
        auditAccountDeletion(targetUserId, QString::fromLatin1(AuditResult::Denied));
        return QStringLiteral("LAST_ADMIN");
    }

    if (!deleteAccountData(targetUserId)) {
        auditAccountDeletion(targetUserId, QString::fromLatin1(AuditResult::Failed));
        return QStringLiteral("STORAGE_UNAVAILABLE");
    }
    auditAccountDeletion(targetUserId, QString::fromLatin1(AuditResult::Ok));
    setMessage(QString());
    refreshUsers();
    return QString();
}

void SessionManager::refreshUsers() {
    users_.clear();
    if (!usersService_) { emit usersChanged(); return; }
    // 只暴露低敏字段：不含 salt/verifier/wrapped key。
    for (const auto &user : usersService_->listUsers()) {
        if (user.disabled) continue;   // 停用用户不出现在选择列表
        users_.append(QVariantMap{{"userId", user.userId},
                                  {"displayName", user.displayName},
                                  {"admin", user.admin},
                                  {"avatar", user.avatar},
                                  {"lockTimeoutMinutes", user.lockTimeoutMinutes},
                                  {"avatarSource", avatarSourceFor(user.userId, user.avatar)}});
    }
    emit usersChanged();
    emit changed();   // hasUsers 依赖它
}

QString SessionManager::avatarDirectory() const {
    if (!usersService_) return {};
    return QFileInfo(usersService_->path()).absolutePath() + QStringLiteral("/avatars");
}

QString SessionManager::avatarSourceFor(const QString &userId, const QString &fileName) const {
    if (userId.isEmpty() || fileName.isEmpty()) return {};
    // 注册表可能被手改：只接受纯文件名，并且必须位于头像目录下。
    if (fileName != QFileInfo(fileName).fileName() || fileName.contains(QLatin1Char('/'))
        || fileName.contains(QLatin1Char('\\')))
        return {};
    const QString dir = avatarDirectory();
    if (dir.isEmpty()) return {};
    const QString path = QDir(dir).filePath(fileName);
    if (!QFileInfo::exists(path)) return {};
    return QUrl::fromLocalFile(path).toString();
}

QString SessionManager::ownAvatarSource() const {
    if (!loggedIn() || !usersService_) return {};
    for (const auto &user : usersService_->listUsers())
        if (user.userId == activeUserId_) return avatarSourceFor(user.userId, user.avatar);
    return {};
}

int SessionManager::autoLockSeconds() const {
    if (!loggedIn() || !usersService_) return 5 * 60;
    UserRecord record;
    if (!usersService_->lookup(activeUserId_, &record)) return 5 * 60;
    const int minutes = record.lockTimeoutMinutes >= 0 ? record.lockTimeoutMinutes : 5;
    return minutes == 0 ? 0 : minutes * 60;
}

int SessionManager::ownLockTimeoutMinutes() const {
    // 临时会话固定 5 分钟：没有用户记录可读，也不该让访客改这个值。
    if (guestSession_) return 5;
    if (!loggedIn() || !usersService_) return -1;
    UserRecord record;
    if (!usersService_->lookup(activeUserId_, &record)) return -1;
    return record.lockTimeoutMinutes;
}

bool SessionManager::setOwnLockTimeout(int minutes) {
    // 访客不能改锁屏时长（固定 5 分钟）。
    if (guestSession_) return false;
    if (!loggedIn() || !usersService_) return false;
    if (!usersService_->setLockTimeout(activeUserId_, minutes)) {
        setMessage(QStringLiteral("STORAGE_UNAVAILABLE"));
        return false;
    }
    setMessage(QString());
    refreshUsers();
    emit changed();
    emit lockTimeoutChanged();
    return true;
}

QString SessionManager::setOwnAvatar(const QString &sourcePath) {
    if (!loggedIn() || !usersService_) {
        setMessage(QStringLiteral("NOT_AUTHORIZED"));
        return QStringLiteral("NOT_AUTHORIZED");
    }
    const QFileInfo source(sourcePath);
    if (!source.isFile() || !source.isReadable() || source.size() <= 0
        || source.size() > 16 * 1024 * 1024)
        return QStringLiteral("INVALID_IMAGE");

    // 先看清尺寸再解码，避免一张超大图把内存打满。
    QImageReader reader(source.absoluteFilePath());
    reader.setAutoTransform(true);
    const QSize declared = reader.size();
    if (declared.isValid()
        && (qint64(declared.width()) * declared.height() > 40'000'000LL))
        return QStringLiteral("INVALID_IMAGE");
    const QImage image = reader.read();
    if (image.isNull() || image.width() < 1 || image.height() < 1
        || qint64(image.width()) * image.height() > 40'000'000LL)
        return QStringLiteral("INVALID_IMAGE");

    // 居中裁正方形 + 缩到 256px + 圆形 alpha 蒙版：落地就是可直接显示的 PNG，
    // 登录页无需再做遮罩/特效（软件渲染下也能正确显示）。
    const int side = qMin(image.width(), image.height());
    const QImage square = image.copy((image.width() - side) / 2, (image.height() - side) / 2,
                                     side, side)
                              .scaled(256, 256, Qt::KeepAspectRatioByExpanding,
                                      Qt::SmoothTransformation);
    QImage avatar(256, 256, QImage::Format_ARGB32_Premultiplied);
    avatar.fill(Qt::transparent);
    {
        QPainter painter(&avatar);
        painter.setRenderHint(QPainter::Antialiasing, true);
        QPainterPath circle;
        circle.addEllipse(0, 0, 256, 256);
        painter.setClipPath(circle);
        painter.drawImage(0, 0, square);
    }

    const QString dir = avatarDirectory();
    if (dir.isEmpty() || !QDir().mkpath(dir)) return QStringLiteral("STORAGE_UNAVAILABLE");
    QFile::setPermissions(dir, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    // 文件名带版本后缀：QML Image 以 URL 为缓存键，覆盖同名文件不会刷新。
    const QString fileName = activeUserId_ + QStringLiteral("-")
        + QUuid::createUuid().toString(QUuid::WithoutBraces) + QStringLiteral(".png");
    const QString target = QDir(dir).filePath(fileName);

    QString previous;
    for (const auto &user : usersService_->listUsers())
        if (user.userId == activeUserId_) previous = user.avatar;

    QSaveFile file(target);
    if (!file.open(QIODevice::WriteOnly)) return QStringLiteral("STORAGE_UNAVAILABLE");
    if (!file.setPermissions(QFile::ReadOwner | QFile::WriteOwner)) return QStringLiteral("STORAGE_UNAVAILABLE");
    if (!avatar.save(&file, "PNG") || !file.commit()) return QStringLiteral("STORAGE_UNAVAILABLE");

    if (!usersService_->setAvatar(activeUserId_, fileName)) {
        QFile::remove(target);   // 注册失败就不留孤儿文件
        return QStringLiteral("STORAGE_UNAVAILABLE");
    }
    if (!previous.isEmpty() && previous != fileName)
        QFile::remove(QDir(dir).filePath(previous));

    setMessage(QString());
    refreshUsers();
    return QString();
}

bool SessionManager::removeOwnAvatar() {
    if (!loggedIn() || !usersService_) return false;
    QString previous;
    for (const auto &user : usersService_->listUsers())
        if (user.userId == activeUserId_) previous = user.avatar;
    if (!usersService_->setAvatar(activeUserId_, QString())) return false;
    if (!previous.isEmpty()) QFile::remove(QDir(avatarDirectory()).filePath(previous));
    refreshUsers();
    return true;
}

bool SessionManager::loginWithWorker(const QString &userId, const QString &pin) {
    if (unlocking_) return false;
    if (!authService_) {
        setMessage(QStringLiteral("STORAGE_UNAVAILABLE"));
        emit loginFinished(QStringLiteral("STORAGE_UNAVAILABLE"));
        return false;
    }
    if (hasUnfinishedTasks()) {
        setMessage(QStringLiteral("BUSY"));
        emit loginFinished(QStringLiteral("BUSY"));
        return false;
    }

    // 第一段：先把"这次该用什么盐/迭代"与前置校验（限速、存在性、锁定）做完，
    // 这一段不耗时，仍在主线程。
    AuthService::KdfParams params;
    AuthService::Result early;
    bool needKdf = false;
    {
        QMutexLocker locker(&authMutex_);
        needKdf = authService_->beginVerify(userId, pin, &params, &early);
    }
    if (!needKdf) {
        setMessage(early.code, early.retryAfterMs);
        emit loginFinished(early.code);
        return false;
    }

    unlocking_ = true;
    authStage_ = QStringLiteral("verifying");
    emit unlockingChanged();
    emit authStageChanged();

    // 第二段：KDF 交给常驻子进程。发不出去就直接走同步路径兜底。
    const bool sent = kdfClient_ && kdfClient_->derive(
        pin, params.salt, params.iterations,
        [this, userId](bool ok, const QByteArray &kek) {
            qInfo("session: kdf callback ok=%d kek=%d", int(ok), int(kek.size()));
            if (!ok) {
                // 子进程不可用：退回同步登录（界面会卡一下，但功能与安全强度不变）。
                qWarning() << "kdf-worker unavailable, falling back to synchronous login";
                authStage_.clear();
                unlocking_ = false;
                emit authStageChanged();
                emit unlockingChanged();
                const QString code = login(userId, loginFallbackPin_);
                loginFallbackPin_.clear();
                emit loginFinished(code);
                return;
            }
            AuthService::Result result;
            {
                QMutexLocker locker(&authMutex_);
                result = authService_->finishVerify(userId, kek);
            }
            completeLogin(userId, result);
        });
    if (!sent) {
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        const QString code = login(userId, pin);
        emit loginFinished(code);
        return code.isEmpty();
    }
    loginFallbackPin_ = pin;   // 仅供失败回退时重算（用完即清）
    return true;
}

bool SessionManager::unlockWithWorker(const QString &pin) {
    if (unlocking_) return false;
    if (!locked_) { emit unlockFinished(QString()); return true; }
    if (!authService_ || activeUserId_.isEmpty()) {
        setMessage(QStringLiteral("SESSION_EXPIRED"));
        emit unlockFinished(QStringLiteral("SESSION_EXPIRED"));
        return false;
    }
    const QString userId = activeUserId_;
    AuthService::KdfParams params;
    AuthService::Result early;
    bool needKdf = false;
    {
        QMutexLocker locker(&authMutex_);
        needKdf = authService_->beginVerify(userId, pin, &params, &early);
    }
    if (!needKdf) {
        setMessage(early.code, early.retryAfterMs);
        emit unlockFinished(early.code);
        return false;
    }
    unlocking_ = true;
    authStage_ = QStringLiteral("verifying");
    emit unlockingChanged();
    emit authStageChanged();

    const bool sent = kdfClient_ && kdfClient_->derive(
        pin, params.salt, params.iterations,
        [this, userId](bool ok, const QByteArray &kek) {
            if (!ok) {
                authStage_.clear();
                unlocking_ = false;
                emit authStageChanged();
                emit unlockingChanged();
                const QString code = unlockWithPin(loginFallbackPin_);
                loginFallbackPin_.clear();
                emit unlockFinished(code);
                return;
            }
            AuthService::Result result;
            {
                QMutexLocker locker(&authMutex_);
                result = authService_->finishVerify(userId, kek);
            }
            completeUnlock(result);
        });
    if (!sent) {
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        const QString code = unlockWithPin(pin);
        emit unlockFinished(code);
        return code.isEmpty();
    }
    loginFallbackPin_ = pin;
    return true;
}

void SessionManager::completeLogin(const QString &userId, const AuthService::Result &result) {
    qInfo("session: completeLogin code=%s", qPrintable(result.code));
    if (result.code != QLatin1String(AuthResult::Ok)) {
        loginFallbackPin_.clear();
        setMessage(result.code, result.retryAfterMs);
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        emit loginFinished(result.code);
        return;
    }
    if (begin(result.userId, result.dbKey, result.admin).isEmpty()) {
        loginFallbackPin_.clear();
        setMessage(QStringLiteral("BUSY"));
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        emit loginFinished(QStringLiteral("BUSY"));
        return;
    }
    loginFallbackPin_.clear();
    // 开库直接在回调栈里做：放进 QTimer::singleShot(0) 会在这个上下文里
    // 触发 SQLite 初始化自锁（实测卡片永远不消失）。
    authStage_ = QStringLiteral("opening");
    emit authStageChanged();
    if (!openDatabase())
        qWarning() << "user database could not be opened after login";
    for (const auto &user : usersService_ ? usersService_->listUsers()
                                          : QList<UserService::PublicUser>{}) {
        if (user.userId == userId) activeDisplayName_ = user.displayName;
    }
    setMessage(QString());
    authStage_.clear();
    unlocking_ = false;
    emit authStageChanged();
    emit unlockingChanged();
    emit changed();
    emit lockStateChanged();
    emit loginFinished(QString());
}

void SessionManager::completeUnlock(const AuthService::Result &result) {
    if (result.code != QLatin1String(AuthResult::Ok)) {
        loginFallbackPin_.clear();
        setMessage(result.code, result.retryAfterMs);
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        emit unlockFinished(result.code);
        return;
    }
    if (result.dbKey != dbKey_) {
        loginFallbackPin_.clear();
        setMessage(QStringLiteral("STORAGE_UNAVAILABLE"));
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        emit unlockFinished(QStringLiteral("STORAGE_UNAVAILABLE"));
        return;
    }
    loginFallbackPin_.clear();
    authStage_ = QStringLiteral("opening");
    emit authStageChanged();
    if (!openDatabase())
        qWarning() << "user database could not be opened after unlock";
    locked_ = false;
    setMessage(QString());
    authStage_.clear();
    unlocking_ = false;
    emit authStageChanged();
    emit unlockingChanged();
    emit changed();
    emit lockStateChanged();
    emit unlockFinished(QString());
}

QString SessionManager::startGuestSession() {
    if (hasUnfinishedTasks()) {
        setMessage(QStringLiteral("BUSY"));
        return QStringLiteral("BUSY");
    }
    // 已有正式会话时不覆盖：先退出再开访客。
    if (loggedIn() && !guestSession_) {
        setMessage(QStringLiteral("BUSY"));
        return QStringLiteral("BUSY");
    }
    clear();
    // 每次访客会话一个独立 id，避免上一轮的残留目录被复用。
    // 只含小写字母与数字：openForSession 与 discardSession 都按这个白名单查路径。
    guestUserId_ = QStringLiteral("guest") + QString::number(QDateTime::currentMSecsSinceEpoch(), 36);
    // 库密钥随机生成、只存内存：访客没有 PIN，也就不存在"用 PIN 派生"这回事。
    // 数据在会话期内仍加密落盘，退出时连同目录一起删。
    QByteArray dbKey(32, Qt::Uninitialized);
    for (int i = 0; i < dbKey.size(); ++i)
        dbKey[i] = static_cast<char>(QRandomGenerator::system()->bounded(256));

    const QString token = begin(guestUserId_, dbKey, false);
    dbKey.fill('\0');
    if (token.isEmpty()) {
        setMessage(QStringLiteral("STORAGE_UNAVAILABLE"));
        return QStringLiteral("STORAGE_UNAVAILABLE");
    }
    guestSession_ = true;
    if (!openDatabase()) {
        // 打不开也要把会话撤掉：留一个"已登录但没库"的访客态更糟。
        endGuestSession();
        setMessage(QStringLiteral("STORAGE_UNAVAILABLE"));
        return QStringLiteral("STORAGE_UNAVAILABLE");
    }
    setMessage(QString());
    emit changed();
    emit lockStateChanged();
    qInfo("guest session started: %s", qPrintable(guestUserId_));
    return QString();
}

void SessionManager::endGuestSession() {
    if (!guestSession_) return;
    const QString userId = guestUserId_;
    guestSession_ = false;
    guestUserId_.clear();
    if (database_) {
        // 先关库，再删目录：Windows 上打开的文件删不掉，Linux 也避免留 WAL。
        database_->discardSession(userId);
        delete database_;
        database_ = nullptr;
        emit databaseChanged(nullptr);
    }
    clear();
    setMessage(QString());
    emit changed();
    emit lockStateChanged();
    qInfo("guest session ended: %s", qPrintable(userId));
}

QString SessionManager::login(const QString &userId, const QString &pin) {
    // 计时：同步登录把 KDF 与开库都放在主线程，Pi 上这段是秒级。
    // 日志里留一条，便于在低性能设备上量"卡多久"，而不是靠肉眼估。
    QElapsedTimer loginClock;
    loginClock.start();
    if (!authService_) return QStringLiteral("STORAGE_UNAVAILABLE");
    // 已有会话时先要求收尾任务，再由调用方显式退出。
    if (hasUnfinishedTasks()) {
        setMessage(QStringLiteral("BUSY"));
        return QStringLiteral("BUSY");
    }

    // SQLCipher 的 sqlite3_initialize 不能跨线程（实测在工作线程触发会与
    // 主线程自锁，主线程永久卡在 openDatabase）。所以这条链路保持同步，
    // 只靠"先把进度条那一帧画出来"来遮盖耗时。
    unlocking_ = true;
    authStage_ = QStringLiteral("verifying");
    emit unlockingChanged();
    emit authStageChanged();
    QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents);

    // 测试口子：ORANGE_PI_LOGIN_DELAY_MS 让「正在解锁」多停一会儿。
    // KDF 一开跑主线程就冻结、遮罩不再刷新，本机上 150ms 一闪而过；
    // 设这个变量就能看清遮罩到底有没有先于计算出现。不设则完全不生效。
    {
        static const int holdMs = qEnvironmentVariableIntValue("ORANGE_PI_LOGIN_DELAY_MS");
        if (holdMs > 0) QThread::msleep(static_cast<unsigned long>(holdMs));
    }

    AuthService::Result result;
    {
        QMutexLocker locker(&authMutex_);
        result = authService_->verifyPin(userId, pin);
    }
    if (result.code != QLatin1String(AuthResult::Ok)) {
        // 只回传 code 与可公开的剩余等待时间，不回显账号是否存在。
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        setMessage(result.code, result.retryAfterMs);
        return result.code;
    }
    // 认证成功：建立唯一会话。
    if (begin(result.userId, result.dbKey, result.admin).isEmpty()) {
        setMessage(QStringLiteral("BUSY"));
        return QStringLiteral("BUSY");
    }
    // 进度条走到「打开数据」这一档，再让它画出来，然后才做会阻塞的开库。
    authStage_ = QStringLiteral("opening");
    emit authStageChanged();
    QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents);
    // 登录即打开当前用户的加密库：绑定卡片、备份/恢复、审计都依赖它。
    // 打不开不阻断登录（库损坏时仍可看到界面和错误），但必须留下日志，
    // 此时 SecurityService 会继续按 NOT_AUTHORIZED 拒绝写操作。
    if (!openDatabase())
        qWarning() << "user database could not be opened after login";
    authStage_.clear();
    unlocking_ = false;
    emit authStageChanged();
    emit unlockingChanged();
    for (const auto &user : usersService_ ? usersService_->listUsers()
                                          : QList<UserService::PublicUser>{}) {
        if (user.userId == result.userId) activeDisplayName_ = user.displayName;
    }
    setMessage(QString());
    emit changed();
    emit lockStateChanged();
    qInfo("auth: login completed in %lld ms", static_cast<long long>(loginClock.elapsed()));
    return QString();
}

QString SessionManager::loginWithRecoveryCode(const QString &userId,
                                              const QString &recoveryCode) {
    if (hasUnfinishedTasks()) {
        setMessage(QStringLiteral("BUSY"));
        return QStringLiteral("BUSY");
    }
    if (loggedIn() && !guestSession_) {
        setMessage(QStringLiteral("BUSY"));
        return QStringLiteral("BUSY");
    }
    if (guestSession_) {
        setMessage(QStringLiteral("BUSY"));
        return QStringLiteral("BUSY");
    }
    unlocking_ = true;
    authStage_ = QStringLiteral("verifying");
    emit unlockingChanged();
    emit authStageChanged();
    QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents);

    AuthService::Result result;
    {
        QMutexLocker locker(&authMutex_);
        result = authService_->verifyRecoveryCode(userId, recoveryCode);
    }
    if (result.code != QLatin1String(AuthResult::Ok)) {
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        setMessage(result.code, result.retryAfterMs);
        return result.code;
    }
    if (begin(result.userId, result.dbKey, result.admin).isEmpty()) {
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        setMessage(QStringLiteral("BUSY"));
        return QStringLiteral("BUSY");
    }
    mustChangePin_ = true;
    emit changed();
    authStage_ = QStringLiteral("opening");
    emit authStageChanged();
    QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents);
    if (!openDatabase()) {
        clear();
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        setMessage(QStringLiteral("STORAGE_UNAVAILABLE"));
        return QStringLiteral("STORAGE_UNAVAILABLE");
    }
    for (const auto &user : usersService_ ? usersService_->listUsers()
                                          : QList<UserService::PublicUser>{}) {
        if (user.userId == result.userId) activeDisplayName_ = user.displayName;
    }
    authStage_.clear();
    unlocking_ = false;
    emit authStageChanged();
    emit unlockingChanged();
    setMessage(QString());
    emit changed();
    emit lockStateChanged();
    return QString();
}

bool SessionManager::setRecoveryPin(const QString &newPin) {
    if (!loggedIn() || !mustChangePin_ || !authService_ || !usersService_) {
        setMessage(QStringLiteral("NOT_AUTHORIZED"));
        return false;
    }
    if (newPin.size() < 6) {
        setMessage(QStringLiteral("AUTH_FAILED"));
        return false;
    }
    if (!authService_->resetPinWithDbKey(activeUserId_, dbKey_, newPin)) {
        setMessage(QStringLiteral("STORAGE_UNAVAILABLE"));
        return false;
    }
    mustChangePin_ = false;
    setMessage(QString());
    emit changed();
    return true;
}

QString SessionManager::beginRecoveryRotation() {
    if (!loggedIn() || dbKey_.size() != 32 || !usersService_) return {};
    const QString code = RecoveryCode::generate();
    if (code.isEmpty()) return {};
    pendingRecoveryCode_ = code;
    pendingRecoveryUserId_ = activeUserId_;
    return code;
}

bool SessionManager::commitRecoveryRotation() {
    if (pendingRecoveryCode_.isEmpty() || pendingRecoveryUserId_ != activeUserId_
        || dbKey_.size() != 32 || !usersService_) {
        return false;
    }
    const bool ok = usersService_->setRecoveryCode(activeUserId_, dbKey_,
                                                   pendingRecoveryCode_);
    pendingRecoveryCode_.clear();
    pendingRecoveryUserId_.clear();
    return ok;
}

void SessionManager::cancelRecoveryRotation() {
    pendingRecoveryCode_.clear();
    pendingRecoveryUserId_.clear();
}

QString SessionManager::unlockWithPin(const QString &pin) {
    // 解锁成功后同样刷新"上次用户"，保证重启提示指向最近使用者。
    if (!locked_) return QString();
    if (!authService_ || activeUserId_.isEmpty()) return QStringLiteral("SESSION_EXPIRED");
    unlocking_ = true;
    authStage_ = QStringLiteral("verifying");
    emit unlockingChanged();
    emit authStageChanged();
    QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents);

    AuthService::Result result;
    {
        QMutexLocker locker(&authMutex_);
        result = authService_->verifyPin(activeUserId_, pin);
    }
    if (result.code != QLatin1String(AuthResult::Ok)) {
        setMessage(result.code, result.retryAfterMs);
        return result.code;
    }
    // DB key 必须重新解封成功才允许解锁：PIN 对了但库打不开说明状态异常。
    if (result.dbKey != dbKey_) {
        authStage_.clear();
        unlocking_ = false;
        emit authStageChanged();
        emit unlockingChanged();
        setMessage(QStringLiteral("STORAGE_UNAVAILABLE"));
        return QStringLiteral("STORAGE_UNAVAILABLE");
    }
    authStage_ = QStringLiteral("opening");
    emit authStageChanged();
    QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents);
    if (!openDatabase())
        qWarning() << "user database could not be opened after unlock";
    authStage_.clear();
    unlocking_ = false;
    emit authStageChanged();
    emit unlockingChanged();
    locked_ = false;
    setMessage(QString());
    emit changed();
    emit lockStateChanged();
    return QString();
}

void SessionManager::lockNow() {
    lock();
}

void SessionManager::signOut() {
    logout();
    refreshUsers();
}

void SessionManager::setMessage(const QString &code, int retryAfterMs) {
    message_ = code;
    retryAfterMs_ = retryAfterMs;
    emit messageChanged();
}

QString SessionManager::lastUserHint() const {
    QFile file(lastUserHintPath_);
    if (!file.open(QIODevice::ReadOnly)) return {};
    const QJsonObject object = QJsonDocument::fromJson(file.readAll()).object();
    // 只接受看起来像 userId 的不透明 ID；其他一律忽略。
    const QString userId = object.value(QStringLiteral("last_user_id")).toString();
    if (userId.isEmpty() || userId.size() > 64) return {};
    for (const QChar c : userId)
        if (!(c.isLetterOrNumber() || c == QLatin1Char('-') || c == QLatin1Char('_')))
            return {};
    return userId;
}

void SessionManager::rememberUserHint(const QString &userId) {
    if (userId.isEmpty()) return;
    QDir().mkpath(QFileInfo(lastUserHintPath_).absolutePath());
    QSaveFile file(lastUserHintPath_);
    if (!file.open(QIODevice::WriteOnly)) return;
    const QJsonObject object{{QStringLiteral("schema"), QStringLiteral("p0-session-hint-v1")},
                             {QStringLiteral("last_user_id"), userId}};
    if (file.write(QJsonDocument(object).toJson(QJsonDocument::Compact)) <= 0) {
        file.cancelWriting();
        return;
    }
    file.commit();
    // 0600：虽然不含密钥，但"谁在使用这台终端"本身是低敏隐私。
    QFile::setPermissions(lastUserHintPath_, QFile::ReadOwner | QFile::WriteOwner);
}

void SessionManager::clearUserHint() {
    QFile::remove(lastUserHintPath_);
}

bool SessionManager::hasUserHint() const {
    return !lastUserHint().isEmpty();
}

bool SessionManager::cancelTaskAsIncomplete(const QString &taskId) {
    TaskCapability *task = tasks_.take(taskId);
    if (!task) return false;
    // 显式取消：标记不完整后按正常收尾路径推进代次，
    // 保证此后任何迟到回调仍被拒绝。
    task->markIncomplete();
    task->revoke();
    taskGenerations_[taskId] = task->generation() + 1;
    delete task;
    emit changed();
    return true;
}

bool SessionManager::taskIsIncomplete(const QString &taskId) const {
    // 已收尾的任务不在表里；调用方按"已结束"处理即可。
    const TaskCapability *task = tasks_.value(taskId);
    return task && task->incomplete();
}

QString SessionManager::startTask(const QString &deviceId) {
    if (activeUserId_.isEmpty() || deviceId.isEmpty()) return {};
    QByteArray raw(8, Qt::Uninitialized);
    for (int i = 0; i < raw.size(); ++i) raw[i] = static_cast<char>(QRandomGenerator::system()->bounded(256));
    const QString taskId = QString::fromLatin1(raw.toHex());
    // 代次必须真正传给 TaskCapability：否则同一 taskId 重建时，
    // 旧代次的迟到回调会因为内部 generation_ 恒为 0 而被当成合法回调。
    const qint64 generation = taskGenerations_.value(taskId, 0);
    tasks_.insert(taskId,
                  new TaskCapability(TaskCapability::Kind::Task, activeUserId_, taskId,
                                     deviceId, generation));
    // 没有已推进的代次时保持 0；有则沿用，让 canAppend 能区分新旧代次。
    if (!taskGenerations_.contains(taskId)) taskGenerations_.insert(taskId, generation);
    return taskId;
}

bool SessionManager::finishTask(const QString &taskId) {
    TaskCapability *task = tasks_.take(taskId);
    if (!task) return false;
    task->revoke();
    // 推进代次：此后任何仍持有旧代次的迟到回调都不得写入。
    taskGenerations_[taskId] = task->generation() + 1;
    delete task;
    return true;
}

QVariantList SessionManager::pendingTaskSummaries() const {
    QVariantList list;
    for (TaskCapability *task : tasks_) {
        list.append(QVariantMap{{"taskId", task->taskId()}, {"deviceId", task->deviceId()}});
    }
    return list;
}

bool SessionManager::hasUnfinishedTasks() const { return !tasks_.isEmpty(); }

QVector<TaskCapability *> SessionManager::unfinishedTasks() const {
    QVector<TaskCapability *> result;
    for (TaskCapability *task : tasks_) result.append(task);
    return result;
}

bool SessionManager::appendTaskSample(const QString &taskId, const QString &deviceId,
                                       qint64 generation) {
    TaskCapability *task = tasks_.value(taskId);
    if (!task) return false;
    // 归属、设备、代次三者都要对上；锁屏不影响追加。
    return task->canAppend(deviceId, task->originUserId(), generation)
        && generation == taskGenerations_.value(taskId, 0);
}

void SessionManager::clear() {
    if (database_) {
        database_->close();
        delete database_;
        database_ = nullptr;
        emit databaseChanged(nullptr);
    }
    for (TaskCapability *task : tasks_) {
        task->revoke();
        delete task;
    }
    tasks_.clear();
    taskGenerations_.clear();
    activeUserId_.clear();
    activeDisplayName_.clear();
    admin_ = false;
    locked_ = false;
    mustChangePin_ = false;
    pendingRecoveryCode_.clear();
    pendingRecoveryUserId_.clear();
    tokenHex_.fill(QLatin1Char('\0'));
    tokenHex_.clear();
    dbKey_.fill('\0');   // 显式擦除，不只让容器失效
    dbKey_.clear();
}

bool SessionManager::validate(const QString &token) const {
    if (locked_ || tokenHex_.isEmpty() || token.size() != tokenHex_.size()) return false;
    // 常量时间比较，避免用比较耗时泄露前缀。
    unsigned char diff = 0;
    const QByteArray candidate = token.toLatin1();
    const QByteArray expected = tokenHex_.toLatin1();
    if (candidate.size() != expected.size()) return false;
    for (int i = 0; i < expected.size(); ++i) {
        diff |= static_cast<unsigned char>(candidate[i] ^ expected[i]);
    }
    return diff == 0;
}

bool SessionManager::openDatabase() {
    if (database_) return database_->isOpen();
    if (activeUserId_.isEmpty() || dbKey_.size() != 32) return false;
    auto *database = new UserDatabase();
    if (!database->openForSession(activeUserId_, dbKey_)) {
        delete database;
        return false;
    }
    database_ = database;
    // 登录后 SecurityService / ModuleDataApi 靠这条信号换到新库指针；
    // 不发就会一直拿着 nullptr，绑定卡片、备份、审计全部 NOT_AUTHORIZED。
    emit databaseChanged(database_);
    return true;
}

bool SessionManager::recordObservation(const QString &deviceId, double value) {
    // 锁屏不阻止任务追加（f-day1 §5），但拒绝写入时需要明确失败。
    if (activeUserId_.isEmpty() || deviceId.isEmpty()) return false;
    if (!openDatabase()) return false;
    return database_->addHistorySample(QDateTime::currentMSecsSinceEpoch(), value);
}

bool SessionManager::applyRetention(int retentionDays) {
    if (retentionDays < 0) return false;
    if (retentionDays == 0) return true;   // 0 = 永久保留，不需要清理
    if (activeUserId_.isEmpty() || locked_) return false;
    if (!openDatabase()) return false;

    const QDateTime now = QDateTime::currentDateTime();
    const int removed = database_->pruneHistory(now.toMSecsSinceEpoch(),
                                               qint64(retentionDays) * 24 * 60 * 60 * 1000);
    // pruneHistory 已在同一事务里清 audit；这里不再单独清一次。
    // 清理动作本身要留审计（不含条数以外的任何值）。
    if (AuditLog *log = database_->audit()) {
        log->record(activeUserId_, QStringLiteral("data.prune"),
                    QStringLiteral("history"), QStringLiteral("ok"));
    }
    if (removed > 0) emit changed();
    return true;
}

QByteArray SessionManager::dbKey() const { return locked_ ? QByteArray{} : dbKey_; }

}  // namespace security
