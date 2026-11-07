// 登入门禁端到端：无用户 / 有用户未登录 / 登录成功 / 锁屏 / 解锁 / 退出。
// 走真实 SessionManager + UserService + AuthService，不 mock 认证。
#include "security/AuditLog.h"
#include "security/AuthService.h"
#include "security/SessionManager.h"
#include "security/UserService.h"
#include "security/UserDatabase.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QStandardPaths>
#include <QElapsedTimer>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

using namespace security;

class SessionGateTest : public QObject {
    Q_OBJECT

private:
    QTemporaryDir dir_;
    QString registry_() const { return dir_.filePath("users.json"); }
    QString locks_() const { return dir_.filePath("locks.json"); }

private slots:
    void init() {
        QFile::remove(registry_());
        QFile::remove(locks_());
    }

    void noUsersMeansCannotLogin() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);

        // 空注册表：hasUsers 必须为 false，QML 据此显示"请先创建管理员"。
        QVERIFY(!session.hasUsers());
        QVERIFY(session.users().isEmpty());
        QVERIFY(!session.loggedIn());
        // 没有用户时任何登录尝试都失败，且不泄漏原因。
        QCOMPARE(session.login(QStringLiteral("nobody"), QStringLiteral("246810")),
                 QString(AuthResult::AuthFailed));
    }

    // 临时会话：无密码进入、库真的打开、锁屏固定 5 分钟、退出后数据目录被删。
    void guestSessionLivesAndDiesCleanly() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        users.createInitialAdmin(QStringLiteral("Owner"), QStringLiteral("246810"));
        session.refreshUsers();

        // 走的是无 PIN 路径，注册表里没有 guest 这个用户。
        QCOMPARE(session.startGuestSession(), QString());
        QVERIFY(session.isGuest());
        QVERIFY(session.loggedIn());
        QVERIFY(!session.isAdmin());
        QVERIFY(session.database() != nullptr);

        // 固定 5 分钟，且访客改不了。
        QCOMPARE(session.ownLockTimeoutMinutes(), 5);
        QVERIFY(!session.setOwnLockTimeout(30));
        QCOMPARE(session.ownLockTimeoutMinutes(), 5);

        // 按具体 id 断言，而不是数目录个数（别的测试可能留下 guest* 目录）。
        const QString dataRoot = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation)
                                 + QStringLiteral("/users");
        const QString guestId = session.activeUserId();
        QVERIFY2(guestId.startsWith(QStringLiteral("guest")), qPrintable(guestId));
        const QString guestDir = dataRoot + QLatin1Char('/') + guestId;
        QVERIFY2(QDir(guestDir).exists(), qPrintable(guestDir));

        session.endGuestSession();
        QVERIFY(!session.isGuest());
        QVERIFY(!session.loggedIn());
        QVERIFY(session.database() == nullptr);
        QVERIFY2(!QDir(guestDir).exists(), "guest data must be deleted on exit");
    }

    void loginGateBlocksUntilAuthenticated() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString id = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        session.refreshUsers();
        QVERIFY(session.hasUsers());
        // 未登录：QML 的 needLogin 依赖这两个状态。
        QVERIFY(!session.loggedIn());
        QVERIFY(!session.locked());

        // 错误 PIN：仍然未登录。
        QCOMPARE(session.login(id, QStringLiteral("000000")), QString(AuthResult::AuthFailed));
        QVERIFY(!session.loggedIn());
        QVERIFY(!session.message().isEmpty());   // QML 用它显示错误

        // 正确 PIN：建立会话，门禁放开。
        QTest::qWait(1100);   // 终端级 1 次/秒
        QCOMPARE(session.login(id, QStringLiteral("246810")), QString());
        QVERIFY(session.loggedIn());
        QCOMPARE(session.activeUserId(), id);
        QVERIFY(session.message().isEmpty());
    }

    void loginOpensUserDatabase() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString id = users.createInitialAdmin(QStringLiteral("DB"), QStringLiteral("246810"));
        session.refreshUsers();

        QSignalSpy dbSpy(&session, &SessionManager::databaseChanged);
        QTest::qWait(1100);
        QCOMPARE(session.login(id, QStringLiteral("246810")), QString());
        // SecurityService 的绑定卡片/备份/审计都以库已打开为前提；
        // 登录后必须已经打开，且通过信号把指针交给宿主组件。
        QVERIFY(session.database());
        QVERIFY(session.database()->isOpen());
        QCOMPARE(dbSpy.count(), 1);

        session.logout();
        QVERIFY(!session.database());
        QCOMPARE(dbSpy.count(), 2);   // 退出时通知宿主清空指针
    }

    void lockRequiresPinNotCard() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString id = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        session.refreshUsers();
        QCOMPARE(session.login(id, QStringLiteral("246810")), QString());

        QSignalSpy lockSpy(&session, &SessionManager::lockStateChanged);
        session.lockNow();
        QVERIFY(session.locked());
        QVERIFY(session.loggedIn());       // 会话还在，只是锁住
        QVERIFY(session.dbKey().isEmpty()); // 前台拿不到 DB key
        QCOMPARE(lockSpy.count(), 1);

        // 解锁必须输 PIN，且错误 PIN 不解锁。
        QTest::qWait(1100);
        QCOMPARE(session.unlockWithPin(QStringLiteral("000000")), QString(AuthResult::AuthFailed));
        QVERIFY(session.locked());

        QTest::qWait(1100);
        QCOMPARE(session.unlockWithPin(QStringLiteral("246810")), QString());
        QVERIFY(!session.locked());
        QVERIFY(!session.dbKey().isEmpty());
    }

    void signOutReturnsToLogin() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString id = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        session.refreshUsers();
        QCOMPARE(session.login(id, QStringLiteral("246810")), QString());

        QSignalSpy invalidated(&session, &SessionManager::sessionInvalidated);
        session.signOut();
        QVERIFY(!session.loggedIn());
        QVERIFY(!session.locked());
        QVERIFY(session.activeUserId().isEmpty());
        QCOMPARE(invalidated.count(), 1);
        // 退出后用户列表还在（可以重新登录），但会话没了。
        QVERIFY(session.hasUsers());
        QVERIFY(!session.users().isEmpty());
    }

    void loginRefusedWhileTasksUnfinished() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString id = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        session.refreshUsers();
        QCOMPARE(session.login(id, QStringLiteral("246810")), QString());

        const QString task = session.startTask(QStringLiteral("planter-1"));
        QVERIFY(!task.isEmpty());
        // 有未完成任务时不能切用户/重新登录（f-day1 §2）。
        QTest::qWait(1100);
        QCOMPARE(session.login(id, QStringLiteral("246810")), QString("BUSY"));
        QVERIFY(session.finishTask(task));
    }

    void userListIsLowSensitivity() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        session.refreshUsers();

        QCOMPARE(session.users().size(), 1);
        const QVariantMap user = session.users().first().toMap();
        // 只允许显示名与不透明 ID；不能泄漏 salt/verifier/DB key。
        QVERIFY(user.contains("displayName"));
        QVERIFY(user.contains("userId"));
        QVERIFY(!user.contains("salt"));
        QVERIFY(!user.contains("verifier"));
        QVERIFY(!user.contains("wrappedDbKey"));
        QVERIFY(!user.contains("pin"));
    }

    void disabledUserIsHiddenFromList() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString admin = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        const QString member = users.createUser(admin, QStringLiteral("M"), QStringLiteral("111222"));
        QVERIFY(!member.isEmpty());
        session.refreshUsers();
        QCOMPARE(session.users().size(), 2);

        QVERIFY(users.disableUser(admin, member));
        session.refreshUsers();
        // 停用用户不出现在登录选择列表里。
        QCOMPARE(session.users().size(), 1);
        QCOMPARE(session.users().first().toMap().value("displayName").toString(), QStringLiteral("Z"));
    }

    void avatarIsInstalledAndRemoved() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString id = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        session.refreshUsers();
        QCOMPARE(session.login(id, QStringLiteral("246810")), QString());
        QVERIFY(session.ownAvatarSource().isEmpty());

        const QString source = dir_.filePath("portrait.png");
        QImage image(120, 80, QImage::Format_ARGB32_Premultiplied);
        image.fill(QColor(200, 30, 40));
        QVERIFY(image.save(source));

        QCOMPARE(session.setOwnAvatar(source), QString());
        QVERIFY(session.ownAvatarSource().startsWith(QStringLiteral("file://")));

        // users.json 只存文件名，不落绝对路径；文件名带版本后缀，换头像时 URL 变化。
        UserRecord record;
        QVERIFY(users.lookup(id, &record));
        QVERIFY(record.avatar.startsWith(id + QStringLiteral("-")));
        QVERIFY(record.avatar.endsWith(QStringLiteral(".png")));
        const QString firstAvatar = dir_.filePath("avatars/" + record.avatar);
        QVERIFY(QFileInfo::exists(firstAvatar));
        // 用户列表也要带上可显示的头像地址（登录页直接绑定）。
        QCOMPARE(session.users().first().toMap().value("avatarSource").toString(),
                 session.ownAvatarSource());
        QCOMPARE(session.users().first().toMap().value("avatar").toString(), record.avatar);
        QFile registry(registry_());
        QVERIFY(registry.open(QIODevice::ReadOnly));
        const QString registryText = QString::fromUtf8(registry.readAll());
        QVERIFY(!registryText.contains(firstAvatar));
        // 注册表不接受带路径的头像名（防目录穿越）。
        QVERIFY(!users.setAvatar(id, QStringLiteral("../evil.png")));
        QVERIFY(!users.setAvatar(id, QStringLiteral("sub/evil.png")));

        // 非图片不能装成头像。
        const QString notImage = dir_.filePath("not-image.txt");
        QFile text(notImage);
        QVERIFY(text.open(QIODevice::WriteOnly));
        text.write("not an image");
        text.close();
        QCOMPARE(session.setOwnAvatar(notImage), QStringLiteral("INVALID_IMAGE"));
        QCOMPARE(session.setOwnAvatar(dir_.filePath("missing.png")), QStringLiteral("INVALID_IMAGE"));

        // 再换一张：文件名必须变化（QML Image 以 URL 为缓存键），旧文件被清掉。
        QImage second(64, 64, QImage::Format_ARGB32_Premultiplied);
        second.fill(QColor(20, 120, 200));
        QVERIFY(second.save(source));
        const QString firstSource = session.ownAvatarSource();
        QCOMPARE(session.setOwnAvatar(source), QString());
        QVERIFY(session.ownAvatarSource() != firstSource);   // URL 变化才会刷新 QML 图片缓存
        QVERIFY(users.lookup(id, &record));
        QVERIFY(record.avatar.startsWith(id + QStringLiteral("-")));
        QVERIFY(record.avatar.endsWith(QStringLiteral(".png")));
        const QString secondAvatar = dir_.filePath("avatars/" + record.avatar);
        QVERIFY(QFileInfo::exists(secondAvatar));
        if (secondAvatar != firstAvatar) QVERIFY(!QFileInfo::exists(firstAvatar));

        QVERIFY(session.removeOwnAvatar());
        QVERIFY(!QFileInfo::exists(secondAvatar));
        QVERIFY(session.ownAvatarSource().isEmpty());
        QVERIFY(users.lookup(id, &record));
        QVERIFY(record.avatar.isEmpty());
    }

    QString databasePath_(const QString &userId) const {
        return QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation)
               + QStringLiteral("/users/") + userId + QStringLiteral("/data.db");
    }

    // 改自己的显示名：只动注册表字段，不动 PIN/恢复码/加密库。
    void changeOwnDisplayNameUpdatesRegistry() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString admin = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        session.refreshUsers();
        QCOMPARE(session.login(admin, QStringLiteral("246810")), QString());

        QCOMPARE(session.changeOwnDisplayName(QStringLiteral("新 名字")), QString());
        QCOMPARE(session.activeDisplayName(), QStringLiteral("新 名字"));
        UserRecord record;
        QVERIFY(users.lookup(admin, &record));
        QCOMPARE(record.displayName, QStringLiteral("新 名字"));
        // 改名不影响登录：同一个 PIN 仍然可用（终端级限速 1 次/秒，等过窗口）。
        session.logout();
        QTest::qWait(1200);
        QCOMPARE(session.login(admin, QStringLiteral("246810")), QString());

        // 太短/太长的名字被拒绝，名字保持不变。
        QCOMPARE(session.changeOwnDisplayName(QStringLiteral("x")), QStringLiteral("NAME_INVALID"));
        QCOMPARE(session.changeOwnDisplayName(QString(30, QChar('A'))), QStringLiteral("NAME_INVALID"));
        QCOMPARE(session.activeDisplayName(), QStringLiteral("新 名字"));

        session.logout();
        QCOMPARE(session.changeOwnDisplayName(QStringLiteral("未登录")),
                 QStringLiteral("NOT_AUTHORIZED"));
    }

    void deleteOwnAccountRequiresPinAndRemovesEverything() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString admin = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        const QString member = users.createUser(admin, QStringLiteral("M"), QStringLiteral("111222"));
        QVERIFY(!member.isEmpty());
        session.refreshUsers();
        QCOMPARE(session.login(member, QStringLiteral("111222")), QString());
        QVERIFY(session.openDatabase());

        // 头像：新旧两种文件名都要清掉。
        const QString avatarDir = dir_.filePath("avatars");
        QVERIFY(QDir().mkpath(avatarDir));
        const QString avatarOld = avatarDir + "/" + member + ".png";
        const QString avatarNew = avatarDir + "/" + member + "-deadbeef.png";
        for (const QString &path : {avatarOld, avatarNew}) {
            QFile file(path);
            QVERIFY(file.open(QIODevice::WriteOnly));
            file.write("x");
        }
        QVERIFY(QFileInfo::exists(databasePath_(member)));

        QCOMPARE(session.deleteOwnAccount(QStringLiteral("000000")),
                 QStringLiteral("AUTH_FAILED"));
        QVERIFY(session.loggedIn());
        UserRecord stillThere;
        QVERIFY(users.lookup(member, &stillThere));   // 仍在，只是 PIN 错

        QSignalSpy deleted(&session, &SessionManager::userDeleted);
        QSignalSpy invalidated(&session, &SessionManager::sessionInvalidated);
        QCOMPARE(session.deleteOwnAccount(QStringLiteral("111222")), QString());
        QVERIFY(!session.loggedIn());
        QCOMPARE(session.message(), QStringLiteral("ACCOUNT_DELETED"));
        QCOMPARE(deleted.count(), 1);
        QCOMPARE(invalidated.count(), 1);

        UserRecord record;
        QVERIFY(!users.lookup(member, &record));
        QVERIFY(users.lookup(admin, &record));
        QCOMPARE(session.users().size(), 1);
        QVERIFY(!QFileInfo::exists(databasePath_(member)));
        QVERIFY(!QFileInfo::exists(avatarOld));
        QVERIFY(!QFileInfo::exists(avatarNew));

        QTest::qWait(1100);
        QCOMPARE(session.login(admin, QStringLiteral("246810")), QString());
    }

    // 用户要求（2026-11-01）：最后一名管理员也能删除自己。删完注册表为空，
    // 宿主（TerminalApplication）把首次开机向导重新拉起来重建管理员。
    void lastAdminCanDeleteSelfAndLeavesRegistryEmpty() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString admin = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        session.refreshUsers();
        QCOMPARE(session.login(admin, QStringLiteral("246810")), QString());
        QCOMPARE(session.deleteOwnAccount(QStringLiteral("246810")), QString());
        QVERIFY(!session.loggedIn());
        QVERIFY(!users.hasAnyUser());
        UserRecord gone;
        QVERIFY(!users.lookup(admin, &gone));
    }

    void deleteOwnAccountRefusedWhileTasksUnfinished() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString admin = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        const QString member = users.createUser(admin, QStringLiteral("M"), QStringLiteral("111222"));
        session.refreshUsers();
        QCOMPARE(session.login(member, QStringLiteral("111222")), QString());
        const QString task = session.startTask(QStringLiteral("planter-1"));
        QVERIFY(!task.isEmpty());
        QCOMPARE(session.deleteOwnAccount(QStringLiteral("111222")), QStringLiteral("BUSY"));
        QVERIFY(session.loggedIn());
        QVERIFY(session.finishTask(task));
        QCOMPARE(session.deleteOwnAccount(QStringLiteral("111222")), QString());
        QVERIFY(!session.loggedIn());
    }

    void adminDeletesUserAndAudits() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString admin = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        const QString member = users.createUser(admin, QStringLiteral("M"), QStringLiteral("111222"));
        session.refreshUsers();
        QCOMPARE(session.login(admin, QStringLiteral("246810")), QString());
        QVERIFY(session.openDatabase());

        // 目标库目录：内容不重要，删除必须整目录消失。
        const QString memberDir = QFileInfo(databasePath_(member)).absolutePath();
        QVERIFY(QDir().mkpath(memberDir));
        QFile dummy(databasePath_(member));
        QVERIFY(dummy.open(QIODevice::WriteOnly));
        dummy.write("not-a-real-db");
        dummy.close();

        QCOMPARE(session.deleteUser(QStringLiteral("246810"), admin, QStringLiteral("Z")),
                 QStringLiteral("NOT_AUTHORIZED"));
        QCOMPARE(session.deleteUser(QStringLiteral("000000"), member, QStringLiteral("M")),
                 QStringLiteral("AUTH_FAILED"));
        QCOMPARE(session.deleteUser(QStringLiteral("246810"), member, QStringLiteral("wrong")),
                 QStringLiteral("NAME_MISMATCH"));
        QCOMPARE(session.deleteUser(QStringLiteral("246810"), QStringLiteral("nope"), QStringLiteral("M")),
                 QStringLiteral("NOT_FOUND"));
        QVERIFY(session.loggedIn());

        QSignalSpy deleted(&session, &SessionManager::userDeleted);
        QCOMPARE(session.deleteUser(QStringLiteral("246810"), member, QStringLiteral("M")), QString());
        QCOMPARE(deleted.count(), 1);
        QVERIFY(!QFileInfo::exists(memberDir));
        UserRecord record;
        QVERIFY(!users.lookup(member, &record));
        QVERIFY(session.loggedIn());
        QCOMPARE(session.users().size(), 1);

        // 审计落在管理员自己的库里，actor 是管理员，target 是被删用户。
        QVERIFY(session.database() != nullptr);
        auto *log = session.database()->audit();
        QVERIFY(log);
        bool foundOk = false;
        for (const auto &entry : log->recent(20)) {
            if (entry.action == QLatin1String("user.delete")
                && entry.target == member
                && entry.result == QLatin1String("ok"))
                foundOk = true;
        }
        QVERIFY2(foundOk, "deleting a user must write a user.delete audit entry");
    }

    void twoAdminsHaveIndependentLockTimeouts() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString first = users.createInitialAdmin(QStringLiteral("A"), QStringLiteral("246810"));
        const QString second = users.createUser(first, QStringLiteral("B"), QStringLiteral("135790"), true);
        QVERIFY(!second.isEmpty());
        session.refreshUsers();

        QCOMPARE(session.login(first, QStringLiteral("246810")), QString());
        QCOMPARE(session.autoLockSeconds(), 300);
        QVERIFY(session.setOwnLockTimeout(0));   // A: 永不
        QCOMPARE(session.autoLockSeconds(), 0);

        // 另一个管理员登录：默认 5 分钟，不会被 A 的“永不”影响。
        QTest::qWait(1100);
        QCOMPARE(session.login(second, QStringLiteral("135790")), QString());
        QCOMPARE(session.autoLockSeconds(), 300);
        QVERIFY(session.setOwnLockTimeout(30));
        QCOMPARE(session.autoLockSeconds(), 1800);

        // 切回 A：仍是永不；两个管理员各存各的。
        QTest::qWait(1100);
        QCOMPARE(session.login(first, QStringLiteral("246810")), QString());
        QCOMPARE(session.autoLockSeconds(), 0);
        UserRecord a;
        UserRecord b;
        QVERIFY(users.lookup(first, &a));
        QVERIFY(users.lookup(second, &b));
        QCOMPARE(a.lockTimeoutMinutes, 0);
        QCOMPARE(b.lockTimeoutMinutes, 30);
    }

    void lockTimeoutIsPerUserAndPersisted() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        const QString admin = users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        const QString member = users.createUser(admin, QStringLiteral("M"), QStringLiteral("111222"));
        session.refreshUsers();
        QCOMPARE(session.login(admin, QStringLiteral("246810")), QString());

        // 未设置时默认 5 分钟；-1 表示没有个人值。
        QCOMPARE(session.ownLockTimeoutMinutes(), -1);
        QCOMPARE(session.autoLockSeconds(), 300);
        QVERIFY(session.setOwnLockTimeout(0));
        QCOMPARE(session.ownLockTimeoutMinutes(), 0);
        QCOMPARE(session.autoLockSeconds(), 0);
        QVERIFY(!session.setOwnLockTimeout(7));   // 非允许值
        QVERIFY(session.setOwnLockTimeout(15));
        QCOMPARE(session.autoLockSeconds(), 900);

        // 重新建 SessionManager：偏好从 users.json 读回。
        SessionManager reopened(&users, &auth);
        reopened.refreshUsers();
        QTest::qWait(1100);
        QCOMPARE(reopened.login(admin, QStringLiteral("246810")), QString());
        QCOMPARE(reopened.ownLockTimeoutMinutes(), 15);
        QCOMPARE(reopened.autoLockSeconds(), 900);

        // 另一个用户有自己的默认值和独立设置。
        QTest::qWait(1100);
        QCOMPARE(reopened.login(member, QStringLiteral("111222")), QString());
        QCOMPARE(reopened.ownLockTimeoutMinutes(), -1);
        QCOMPARE(reopened.autoLockSeconds(), 300);
        QVERIFY(reopened.setOwnLockTimeout(2));
        QCOMPARE(reopened.autoLockSeconds(), 120);
        UserRecord memberRecord;
        QVERIFY(users.lookup(member, &memberRecord));
        QCOMPARE(memberRecord.lockTimeoutMinutes, 2);
        UserRecord adminRecord;
        QVERIFY(users.lookup(admin, &adminRecord));
        QCOMPARE(adminRecord.lockTimeoutMinutes, 15);
    }

    void avatarRequiresSession() {
        UserService users(registry_());
        AuthService auth(users, locks_());
        SessionManager session(&users, &auth);
        users.createInitialAdmin(QStringLiteral("Z"), QStringLiteral("246810"));
        session.refreshUsers();
        QCOMPARE(session.setOwnAvatar(dir_.filePath("portrait.png")),
                 QStringLiteral("NOT_AUTHORIZED"));
        QVERIFY(!session.removeOwnAvatar());
    }
};

QTEST_GUILESS_MAIN(SessionGateTest)
#include "session_gate_test.moc"

