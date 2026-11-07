// D 写：设备配对授权页的渲染回归。
//
// 背景：AdminPairingPage.qml 的「已配对桥板 / 已绑定卡片」两个 Repeater 用的是
// ListModel，但 delegate 声明了 `required property var modelData`。ListModel
// 只提供具名 role（bridgeId / fingerprint / label），不提供 modelData，于是
// delegate 初始化失败，整行渲染不出来。运行时表现是：
//     AdminPairingPage.qml:95: QML Component: Cannot create delegate
//     AdminPairingPage.qml:96: Required property modelData was not initialized
// 症状：信任库里明明有桥板，界面却是空白（"还没有配对任何桥板"也被 count>0 隐藏）。
//
// 本用例断言"信任库里有记录，页面就必须出现该桥板"，因此**在缺陷修好前会失败**。
// 修复方向二选一：delegate 改用 `required property string bridgeId` 等具名 role，
// 或者把模型换成 JS 数组（QVariantList）保留 modelData。
//
// 归属：测试由 D 写；AdminPairingPage.qml 属 Z 侧文件，本测试不改它。

#include <QtTest>
#include <QDateTime>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QVariantList>
#include <QVariantMap>

#include "ui/TerminalUi.h"

namespace {

// 最小 securityService 桩：只实现页面用到的只读接口。
class StubSecurityService : public QObject {
    Q_OBJECT
public:
    QVariantList bridges;
    Q_INVOKABLE QVariantList trustedBridges() const { return bridges; }
    Q_INVOKABLE QVariantList boundCards() const { return {}; }
    Q_INVOKABLE QVariantList recentAudit(int) const { return {}; }
    Q_INVOKABLE bool healthy() const { return true; }
    Q_INVOKABLE bool revokeBridge(const QString &) { return true; }
    Q_INVOKABLE bool revokeCard(const QString &) { return true; }
    Q_INVOKABLE int revokeAllCards() { return 0; }

    // 数据与读数（UserSecurityPage 新增区块）。
    QVariantList readingList;
    Q_INVOKABLE QVariantList readings(int) const { return readingList; }
    Q_INVOKABLE bool addManualReading(double value, const QString &unit, const QString &)
    {
        QVariantMap row;
        row.insert("receivedAtMs", QDateTime::currentMSecsSinceEpoch());
        row.insert("value", value);
        row.insert("unit", unit);
        row.insert("hasValue", true);
        row.insert("source", QStringLiteral("user.entry"));
        readingList.prepend(row);
        return true;
    }
    Q_INVOKABLE bool createBackup(const QString &, const QString &) { return true; }
    Q_INVOKABLE bool restoreBackup(const QString &, const QString &) { return true; }
    Q_INVOKABLE bool purgeOwnData() { return true; }
    Q_INVOKABLE bool exportEncrypted(const QString &, const QString &) { return true; }
    Q_PROPERTY(QString lastMessage READ lastMessage CONSTANT)
    QString lastMessage() const { return {}; }
signals:
    void changed();
};

// SecurityStatus 桩：只提供 UserSecurityPage 用到的只读字段。
class StubSecurityStatus : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList trustRecords READ trustRecords NOTIFY trustChanged)
    Q_PROPERTY(bool trustStoreHealthy READ trustStoreHealthy NOTIFY trustChanged)
    Q_PROPERTY(QString trustStorePath READ trustStorePath CONSTANT)
    Q_PROPERTY(QString identityFingerprint READ identityFingerprint NOTIFY identityChanged)
    Q_PROPERTY(QString identityState READ identityState NOTIFY identityChanged)
    Q_PROPERTY(bool uidKeyReady READ uidKeyReady NOTIFY uidKeyChanged)
public:
    QVariantList records;
    QVariantList trustRecords() const { return records; }
    bool trustStoreHealthy() const { return true; }
    QString trustStorePath() const { return QStringLiteral("/tmp/trust.json"); }
    QString identityFingerprint() const { return QStringLiteral("0123456789abcdef"); }
    QString identityState() const { return QStringLiteral("ready"); }
    bool uidKeyReady() const { return true; }
    Q_INVOKABLE QVariantList slotSnapshot() const
    {
        QVariantMap bound;
        bound.insert("slot", 0);
        bound.insert("bound", true);
        bound.insert("deviceId", QStringLiteral("dev-a"));
        bound.insert("generation", QStringLiteral("gen1"));
        QVariantMap free;
        free.insert("slot", 1);
        free.insert("bound", false);
        QVariantList out;
        out.append(bound);
        out.append(free);
        return out;
    }
    Q_INVOKABLE QVariantMap slotStats() const
    {
        QVariantMap m;
        m.insert("accepted", 3);
        m.insert("rejected", 1);
        m.insert("lastRejection", QStringLiteral("StaleGeneration"));
        return m;
    }
    Q_INVOKABLE void refresh() {}
signals:
    void trustChanged();
    void identityChanged();
    void uidKeyChanged();
};

class StubSessionManager : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool isAdmin READ isAdmin CONSTANT)
    Q_PROPERTY(bool loggedIn READ loggedIn CONSTANT)
    Q_PROPERTY(QString activeUserId READ activeUserId CONSTANT)
    Q_PROPERTY(QVariantList users READ users CONSTANT)
    Q_PROPERTY(QString message READ message CONSTANT)
public:
    QVariantList userList;
    QString createResult = QStringLiteral("recovery-code-1");
    bool createOk = true;
    bool admin = true;
    bool isAdmin() const { return admin; }
    bool loggedIn() const { return true; }
    QString activeUserId() const { return QStringLiteral("u-1"); }
    QVariantList users() const { return userList; }
    QString message() const { return {}; }
    Q_INVOKABLE QVariantMap createUser(const QString &name, const QString &, bool isAdmin)
    {
        if (!createOk) return {};
        QVariantMap out;
        out.insert("userId", QStringLiteral("u-new"));
        out.insert("recoveryCode", createResult);
        userList.append(QVariantMap{{"userId", "u-new"}, {"displayName", name}, {"admin", isAdmin}});
        emit usersChanged();
        return out;
    }
    Q_INVOKABLE bool changeOwnPin(const QString &, const QString &) { return true; }
    Q_INVOKABLE bool verifyPin(const QString &) { return true; }
signals:
    void usersChanged();
    void changed();
};

// 模块认证面板用的桩：connectionManager + 能力接口。
class StubConnectionManager : public QObject {
    Q_OBJECT
    // 与真实 ConnectionManager 一致：cards 必须带 NOTIFY，否则 QML 会把它
    // 当常量缓存，绑定拿不到新值。
    Q_PROPERTY(QVariantList cards READ cards NOTIFY cardsChanged)
public:
    QVariantList cardList;
    QVariantList cards() const { return cardList; }
signals:
    void cardsChanged();
};

class StubCapabilityService : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString lastMessage READ lastMessage CONSTANT)
public:
    QVariantList requested;
    Q_INVOKABLE QVariantList requestedCapabilities(int) { return requested; }
    Q_INVOKABLE bool grantCapability(const QString &, int, const QString &) { return true; }
    Q_INVOKABLE bool revokeCapability(const QString &, int, const QString &) { return true; }
    QString lastMessage() const { return {}; }
signals:
    void changed();
};

QString I18nLike(const QString &text) { return text; }

QQuickItem *findItemByObjectName(QQuickItem *root, const QString &name)
{
    if (!root) return nullptr;
    if (root->objectName() == name) return root;
    for (QQuickItem *child : root->childItems())
        if (QQuickItem *found = findItemByObjectName(child, name)) return found;
    return nullptr;
}

void collectTexts(QQuickItem *root, QStringList *out)
{
    if (!root) return;
    const QVariant text = root->property("text");
    if (text.isValid() && !text.toString().isEmpty()) out->append(text.toString());
    for (QQuickItem *child : root->childItems()) collectTexts(child, out);
}

} // namespace

class PairingUiTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase()
    {
        QQuickStyle::setStyle(QStringLiteral("Material"));
        initializeTerminalUi();
    }

    void trustedBridgeRendersWhenStoreHasRecord()
    {
        StubSecurityService service;
        QVariantMap bridge;
        bridge.insert(QStringLiteral("bridgeId"), QStringLiteral("bridge-01"));
        bridge.insert(QStringLiteral("fingerprint"), QStringLiteral("bf1c990de882b0e3"));
        service.bridges.append(bridge);

        StubSessionManager session;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("securityService"), &service);
        engine.rootContext()->setContextProperty(QStringLiteral("sessionManager"), &session);

        QQmlComponent component(&engine,
                                QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/AdminPairingPage.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{QStringLiteral("width"), 1024}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);

        QQuickWindow window;
        window.resize(1024, 800);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        window.show();
        QTest::qWait(200);

        QStringList texts;
        collectTexts(page, &texts);
        QVERIFY2(texts.join(QStringLiteral(" | ")).contains(QStringLiteral("bridge-01")),
                 qPrintable(QStringLiteral("已配对桥板没有渲染出来，当前文本：") +
                            texts.join(QStringLiteral(" | "))));
    }

    void userPageShowsUsersAndRecoveryCode()
    {
        StubSessionManager session;
        session.userList.append(QVariantMap{{"userId", "u-1"}, {"displayName", QStringLiteral("验收员")}, {"admin", true}});

        QQmlEngine engine;
        engine.rootContext()->setContextProperty("sessionManager", &session);
        QQmlComponent component(&engine,
                                QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/UserSecurityPage.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.createWithInitialProperties({{QStringLiteral("width"), 1024}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);

        QQuickWindow window;
        window.resize(1024, 700);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        window.show();
        QTest::qWait(200);

        QStringList texts;
        collectTexts(page, &texts);
        const QString joined = texts.join(QStringLiteral(" | "));
        QVERIFY2(joined.contains(QStringLiteral("验收员")), qPrintable(joined));
        // 2026-11-01 改版：入口改成「添加用户」按钮，表单默认收起。
        QVERIFY2(joined.contains(I18nLike(QStringLiteral("添加用户"))), qPrintable(joined));
        // 新入口：管理员账户管理 + 危险区删号。
        QVERIFY2(joined.contains(I18nLike(QStringLiteral("账户管理"))), qPrintable(joined));
        QVERIFY2(joined.contains(I18nLike(QStringLiteral("删除我的账户"))), qPrintable(joined));
        auto *managerButton = findItemByObjectName(page, QStringLiteral("accountManagerButton"));
        QVERIFY(managerButton && managerButton->isVisible());
        auto *deleteButton = findItemByObjectName(page, QStringLiteral("deleteOwnAccountButton"));
        QVERIFY(deleteButton);
        // 2026-11-01 起最后一名管理员也能自删：按钮保持可用，删完回首次开机向导。
        QVERIFY(deleteButton->property("enabled").toBool());
        QVERIFY2(joined.contains(QStringLiteral("最后一名管理员")), qPrintable(joined));

        // 恢复码弹窗：创建后必须出现且只显示一次。先填显示名，否则会被校验挡住。
        if (auto *nameField = findItemByObjectName(page, QStringLiteral("newUserName")))
            nameField->setProperty("text", QStringLiteral("新同事"));
        QVERIFY(QMetaObject::invokeMethod(page, "createUser"));
        QTest::qWait(150);
        // Popup 的内容不在 childItems 里，按页面属性 + 弹窗可见性断言。
        QCOMPARE(page->property("recoveryCode").toString(), QStringLiteral("recovery-code-1"));
        auto *dialog = page->findChild<QObject *>(QStringLiteral("recoveryCodeDialog"));
        QVERIFY2(dialog && dialog->property("visible").toBool(), "recovery dialog should be visible");
        window.grabWindow().save(QStringLiteral("/tmp/ui-user-security.png"));
    }

    // 用户与权限的输入框：点击才请求键盘；焦点自动回到输入框不能触发。
    // 背景：原来用 onActiveFocusChanged 请求键盘，键盘收起时 Qt 会把焦点
    // 还给输入框，焦点变化又请求弹出，表现为"键盘关不上、循环开启"。
    void userPageFieldRequestsKeyboardOnTapOnly()
    {
        StubSessionManager session;
        session.userList.append(QVariantMap{{"userId", "u-1"},
                                            {"displayName", QStringLiteral("验收员")},
                                            {"admin", true}});

        QQmlEngine engine;
        engine.rootContext()->setContextProperty("sessionManager", &session);
        QQmlComponent component(&engine,
                                QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/UserSecurityPage.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{QStringLiteral("width"), 1024}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);

        QQuickWindow window;
        // 页面默认不分区（section=-1）时五组一起排，窗口开高一点让字段都在视口内。
        window.resize(1024, 4000);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        window.show();
        QTest::qWait(200);

        QSignalSpy keySpy(page, SIGNAL(keyboardRequested()));
        // 添加用户表单默认收起，先展开再点输入框。
        page->setProperty("addUserOpen", true);
        QTest::qWait(150);
        auto *field = findItemByObjectName(page, QStringLiteral("newUserName"));
        QVERIFY2(field, "newUserName field missing");
        QVERIFY(field->isVisible());

        const QPoint center =
            field->mapToScene(QPointF(field->width() / 2, field->height() / 2)).toPoint();
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, center);
        QTRY_COMPARE_WITH_TIMEOUT(keySpy.count(), 1, 2000);

        // 模拟键盘收起后焦点回到输入框：不能再发一次 keyboardRequested。
        auto *other = findItemByObjectName(page, QStringLiteral("newUserPin"));
        QVERIFY(other);
        other->forceActiveFocus();
        QTest::qWait(80);
        field->forceActiveFocus();
        QTest::qWait(120);
        QCOMPARE(keySpy.count(), 1);
    }

    void moduleAuthPanelShowsEmptyState()
    {
        StubConnectionManager connection;
        StubCapabilityService caps;
        StubSessionManager session;

        QQmlEngine engine;
        engine.rootContext()->setContextProperty("connectionManager", &connection);
        engine.rootContext()->setContextProperty("securityService", &caps);
        engine.rootContext()->setContextProperty("sessionManager", &session);
        QQmlComponent component(&engine,
                                QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/ModuleAuthPanel.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.createWithInitialProperties({{QStringLiteral("width"), 1024}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *panel = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(panel);

        QQuickWindow window;
        window.resize(1024, 500);
        panel->setParentItem(window.contentItem());
        panel->setWidth(1024);
        window.show();
        QTest::qWait(200);

        QStringList texts;
        collectTexts(panel, &texts);
        const QString joined = texts.join(QStringLiteral(" | "));
        // 无模块时必须常驻一句"无连接 · 未认证"，而不是空白。
        QVERIFY2(joined.contains(QStringLiteral("未认证")), qPrintable(joined));
        window.grabWindow().save(QStringLiteral("/tmp/ui-module-auth.png"));

        // 有模块时列出能力与授予状态。
        connection.cardList.append(QVariantMap{{"title", QStringLiteral("啸天红外围界")},
                                               {"moduleId", 82}, {"state", "ready"}, {"ready", true}});
        caps.requested.append(QVariantMap{{"capability", "sensor.read"}, {"requested", true}, {"granted", false}});
        emit connection.cardsChanged();
        emit caps.changed();
        QTest::qWait(200);
        QVERIFY2(panel->property("revision").toInt() > 0, "revision should bump on cardsChanged");
        QVERIFY(panel->property("rowCount").toInt() >= 2);   // 模块行 + 能力行
        QStringList withCard;
        collectTexts(panel, &withCard);
        const QString cardText = withCard.join(QStringLiteral(" | "));
        QVERIFY2(cardText.contains(QStringLiteral("啸天红外围界")), qPrintable(cardText));
        QVERIFY2(cardText.contains(QStringLiteral("sensor.read")), qPrintable(cardText));
        window.grabWindow().save(QStringLiteral("/tmp/ui-module-auth-cards.png"));
    }

    // D 写：数据导出的界面契约（路径/密码/按钮都在且可见，校验先于后端调用）。
    void userPageShowsExportSection()
    {
        StubSessionManager session;
        session.userList.append(QVariantMap{{"userId", "u-1"}, {"displayName", QStringLiteral("验收员")}, {"admin", true}});

        QQmlEngine engine;
        engine.rootContext()->setContextProperty("sessionManager", &session);
        QQmlComponent component(&engine,
                                QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/UserSecurityPage.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.createWithInitialProperties({{QStringLiteral("width"), 1024}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);

        QQuickWindow window;
        window.resize(1024, 700);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        window.show();
        QTest::qWait(200);

        // 2026-11-01 起地址输入换成 U 盘选择器：用户不再填路径。
        auto *picker = findItemByObjectName(page, QStringLiteral("exportDevicePicker"));
        auto *password = findItemByObjectName(page, QStringLiteral("exportPassword"));
        auto *button = findItemByObjectName(page, QStringLiteral("exportDatabaseButton"));
        QVERIFY2(picker && password && button, "导出节控件缺失：U 盘选择 / 密码 / 按钮");
        QVERIFY(picker->isVisible());
        QVERIFY(password->isVisible());
        QVERIFY(button->isVisible());
        // 没有插 U 盘时按钮必须是禁用的，不能让人点了个空路径。
        QVERIFY(!button->property("enabled").toBool());

        // 空密码点导出：必须被界面校验挡住，此时不应触碰 securityService。
        QVERIFY(QMetaObject::invokeMethod(page, "exportDatabase"));
        QCOMPARE(page->property("message").toString(), I18nLike(QStringLiteral("导出密码至少 8 位")));
        window.grabWindow().save(QStringLiteral("/tmp/ui-export-section.png"));
    }

    // 数据备份 / 读数 / 安全状态三块必须在页面上真实渲染，且校验先于后端调用。
    void userPageShowsBackupReadingsAndSecurity()
    {
        StubSecurityService service;
        StubSecurityStatus status;
        StubSessionManager session;
        session.userList.append(QVariantMap{{"userId", "u-1"}, {"displayName", QStringLiteral("验收员")}, {"admin", true}});
        QVariantMap record;
        record.insert("bridgeId", QStringLiteral("bridge-01"));
        record.insert("fingerprintHex", QStringLiteral("bf1c990de882b0e3"));
        status.records.append(record);

        QQmlEngine engine;
        engine.rootContext()->setContextProperty("securityService", &service);
        engine.rootContext()->setContextProperty("securityStatus", &status);
        engine.rootContext()->setContextProperty("sessionManager", &session);
        QQmlComponent component(&engine,
                                QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/UserSecurityPage.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.createWithInitialProperties({{QStringLiteral("width"), 1024}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);

        QQuickWindow window;
        window.resize(1024, 1400);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        window.show();
        QTest::qWait(250);

        for (const char *name : {"backupDevicePicker", "backupPassword", "createBackupButton",
                                 "restoreDevicePicker", "restoreBackupButton",
                                 "purgePin", "purgeDataButton",
                                 "refreshSecurityStatusButton"}) {
            auto *item = findItemByObjectName(page, QString::fromLatin1(name));
            QVERIFY2(item, name);
            QVERIFY2(item->isVisible(), name);
        }

        // 血压计（手工读数）暂时不做：界面元素必须**还在**（代码保留在项目内），
        // 但不可见。等恢复时把 UserSecurityPage 里那个 ColumnLayout 的 visible 改回 true，
        // 并把下面这段改回"可见"断言即可。
        for (const char *name : {"readingValue", "addReadingButton", "refreshReadingsButton"}) {
            auto *item = findItemByObjectName(page, QString::fromLatin1(name));
            QVERIFY2(item, name);
            QVERIFY2(!item->isVisible(), "health readings must stay hidden for now");
        }

        QStringList texts;
        collectTexts(page, &texts);
        const QString joined = texts.join(QStringLiteral(" | "));
        // 2026-11-01 改版：页内不再重复「数据与备份」标题，主标题已经是「数据」。
        QVERIFY2(joined.contains(I18nLike(QStringLiteral("导出数据库"))), qPrintable(joined));
        // 标题随区块一起收起，不再断言它出现在可见文本里。
        QVERIFY2(joined.contains(I18nLike(QStringLiteral("安全状态"))), qPrintable(joined));
        QVERIFY2(joined.contains(QStringLiteral("bridge-01")), qPrintable(joined));
        QVERIFY2(joined.contains(QStringLiteral("0123456789abcdef")), qPrintable(joined));

        // 空密码备份：界面先拦，不能触碰后端。
        QVERIFY(QMetaObject::invokeMethod(page, "createBackup"));
        QCOMPARE(page->property("message").toString(), I18nLike(QStringLiteral("备份密码至少 8 位")));

        // 手工读数：填 128 → 保存 → 列表出现一条 user.entry。
        if (auto *value = findItemByObjectName(page, QStringLiteral("readingValue")))
            value->setProperty("text", QStringLiteral("128"));
        QVERIFY(QMetaObject::invokeMethod(page, "addReading"));
        QCOMPARE(page->property("message").toString(), QStringLiteral("已记录 128 mmHg"));
        QCOMPARE(page->property("readingRows").toList().size(), 1);

        // 清空：空 PIN 先被界面拦住；填 PIN 后确认才调用后端。
        QVERIFY(QMetaObject::invokeMethod(page, "requestPurge"));
        QCOMPARE(page->property("message").toString(), I18nLike(QStringLiteral("请输入当前 PIN")));
        if (auto *pin = findItemByObjectName(page, QStringLiteral("purgePin")))
            pin->setProperty("text", QStringLiteral("135790"));
        QVERIFY(QMetaObject::invokeMethod(page, "requestPurge"));
        QVERIFY(QMetaObject::invokeMethod(page, "confirmPurge"));
        QCOMPARE(page->property("message").toString(), I18nLike(QStringLiteral("已清空本用户数据")));

        window.grabWindow().save(QStringLiteral("/tmp/ui-user-data-security.png"));
    }

    // 非管理员：清空入口必须不可见（后端 verifyPin 只认管理员）。
    void nonAdminCannotSeePurge()
    {
        StubSecurityService service;
        StubSecurityStatus status;
        StubSessionManager session;
        session.admin = false;

        QQmlEngine engine;
        engine.rootContext()->setContextProperty("securityService", &service);
        engine.rootContext()->setContextProperty("securityStatus", &status);
        engine.rootContext()->setContextProperty("sessionManager", &session);
        QQmlComponent component(&engine,
                                QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/UserSecurityPage.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.createWithInitialProperties({{QStringLiteral("width"), 1024}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);

        QQuickWindow window;
        window.resize(1024, 1200);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        window.show();
        QTest::qWait(200);

        auto *purge = findItemByObjectName(page, QStringLiteral("purgeDataButton"));
        QVERIFY(purge);
        QVERIFY2(!purge->isVisible(), "non-admin must not see the purge entry");
    }

    // 任务收尾弹窗必须提供「取消（标记未完成）」，不能只有完成。
    void taskFinishDialogOffersCancel()
    {
        QQmlEngine engine;
        QQmlComponent component(&engine,
                                QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/TaskFinishDialog.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QVariantList tasks;
        tasks.append(QVariantMap{{"taskId", "t1"}, {"label", QStringLiteral("任务 t1")}});
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{QStringLiteral("width"), 640}, {QStringLiteral("tasks"), tasks}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *dialog = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(dialog);

        QQuickWindow window;
        window.resize(640, 480);
        dialog->setParentItem(window.contentItem());
        dialog->setWidth(640);
        window.show();
        QTest::qWait(200);

        QVERIFY2(object->metaObject()->indexOfSignal("cancelTask(QString)") >= 0,
                 "TaskFinishDialog must expose cancelTask(taskId)");
        QStringList texts;
        collectTexts(dialog, &texts);
        const QString joined = texts.join(QStringLiteral(" | "));
        QVERIFY2(joined.contains(I18nLike(QStringLiteral("取消（标记未完成）"))), qPrintable(joined));
        QVERIFY2(joined.contains(I18nLike(QStringLiteral("全部完成"))), qPrintable(joined));
        window.grabWindow().save(QStringLiteral("/tmp/ui-task-finish.png"));
    }
};

QTEST_MAIN(PairingUiTest)
#include "pairing_ui_test.moc"
