// 策略页 QML 运行时冒烟：加载真实模块、填假策略、切换应用开关。
// 目的不是点按全流程，而是抓住属性名/绑定/Repeater 这类编译期看不到的错。
#include <QQuickItem>
#include <QQuickWindow>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QtTest>

class FakeNetworkPolicy : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList apps READ apps NOTIFY changed)
    Q_PROPERTY(bool loaded READ loaded NOTIFY changed)
    Q_PROPERTY(QString lastError READ lastError NOTIFY changed)
public:
    QVariantList apps() const { return apps_; }
    bool loaded() const { return true; }
    QString lastError() const { return {}; }
    Q_INVOKABLE void refresh() { ++refreshes; }
    Q_INVOKABLE QVariantList modules() const { return {}; }
    Q_INVOKABLE bool moduleNetworkEnabled(const QString &) const { return true; }
    Q_INVOKABLE bool moduleFileEnabled(const QString &) const { return false; }
    Q_INVOKABLE QVariantMap save(const QVariantList &apps, const QVariantList &modules,
                                 const QString &) {
        savedApps = apps;
        savedModules = modules;
        return {{QStringLiteral("ok"), true}, {QStringLiteral("code"), QStringLiteral("OK")}};
    }
    QVariantList apps_ = {
        QVariantMap{{QStringLiteral("id"), QStringLiteral("browser")},
                    {QStringLiteral("name"), QStringLiteral("浏览器")},
                    {QStringLiteral("enabled"), false}},
        QVariantMap{{QStringLiteral("id"), QStringLiteral("weather")},
                    {QStringLiteral("name"), QStringLiteral("天气")},
                    {QStringLiteral("enabled"), false}},
    };
    QVariantList savedApps;
    QVariantList savedModules;
    int refreshes = 0;
signals:
    void changed();
};

class FakeConnectionManager : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList cards READ cards NOTIFY cardsChanged)
public:
    QVariantList cards() const {
        return {QVariantMap{{QStringLiteral("instance"), QStringLiteral("inst-1")},
                            {QStringLiteral("packageId"), QStringLiteral("example.device")},
                            {QStringLiteral("title"), QStringLiteral("Example")},
                            {QStringLiteral("networkApi"), QStringLiteral("broker")},
                            {QStringLiteral("fileApi"), QStringLiteral("home-read")}}};
    }
signals:
    void cardsChanged();
};

class FakeSession : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool isAdmin READ isAdmin CONSTANT)
public:
    bool isAdmin() const { return true; }
};

class FakeTools : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString uiLanguage READ uiLanguage CONSTANT)
public:
    QString uiLanguage() const { return QStringLiteral("zh"); }
    Q_INVOKABLE QString monochromeIcon(const QString &, bool) const { return {}; }
};

static QQuickItem *findItem(QQuickItem *root, const QString &name) {
    if (!root) return nullptr;
    if (root->objectName() == name) return root;
    for (QQuickItem *child : root->childItems()) {
        if (QQuickItem *found = findItem(child, name)) return found;
    }
    return nullptr;
}

class NetworkPolicyQmlTest : public QObject {
    Q_OBJECT
private:
    QQmlEngine engine_;
    FakeNetworkPolicy policy_;
    FakeSession session_;
    FakeTools tools_;
    FakeConnectionManager connectionManager_;

private slots:
    void initTestCase() {
        engine_.addImportPath(QStringLiteral("qrc:/qt/qml"));
        engine_.rootContext()->setContextProperty("networkPolicy", &policy_);
        engine_.rootContext()->setContextProperty("sessionManager", &session_);
        engine_.rootContext()->setContextProperty("systemTools", &tools_);
        engine_.rootContext()->setContextProperty("connectionManager", &connectionManager_);
    }

    void pageLoadsAndDraftToggleRebuildsSwitch() {
        QQmlComponent component(&engine_,
            QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/NetworkPermissionsPage.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> page(component.create());
        QVERIFY2(page, qPrintable(component.errorString()));
        QQuickWindow window;
        if (auto *item = qobject_cast<QQuickItem *>(page.data())) {
            item->setParentItem(window.contentItem());
            item->setWidth(800);
            item->setHeight(600);
        }
        page->setProperty("open", true);
        QTRY_VERIFY(policy_.refreshes > 0);
        QQuickItem *root = qobject_cast<QQuickItem *>(page.data());
        QVERIFY(root);
        QTRY_VERIFY(findItem(root, QStringLiteral("netPolicyApp_weather")));
        QQuickItem *before = findItem(root, QStringLiteral("netPolicyApp_weather"));
        QVERIFY2(before, "weather switch missing");
        QCOMPARE(before->property("checked").toBool(), false);

        const bool invoked = QMetaObject::invokeMethod(
            page.data(), "updateApp", Q_ARG(QVariant, QStringLiteral("weather")),
            Q_ARG(QVariant, true));
        QVERIFY(invoked);
        QTRY_VERIFY(findItem(root, QStringLiteral("netPolicyApp_weather")));
        QQuickItem *after = findItem(root, QStringLiteral("netPolicyApp_weather"));
        QCOMPARE(after->property("checked").toBool(), true);

        QTRY_VERIFY(findItem(root, QStringLiteral("netPolicyModule_example.device")));
        QQuickItem *moduleSwitch = findItem(root, QStringLiteral("netPolicyModule_example.device"));
        QVERIFY(moduleSwitch);
        QCOMPARE(moduleSwitch->property("checked").toBool(), true);
        QQuickItem *fileSwitch = findItem(root, QStringLiteral("filePolicyModule_example.device"));
        QVERIFY(fileSwitch);
        QCOMPARE(fileSwitch->property("checked").toBool(), false);

        QVERIFY(QMetaObject::invokeMethod(page.data(), "updateModule",
                                          Q_ARG(QVariant, QStringLiteral("example.device")),
                                          Q_ARG(QVariant, QStringLiteral("file")),
                                          Q_ARG(QVariant, true)));
        QVERIFY(QMetaObject::invokeMethod(page.data(), "commit"));
        QCOMPARE(policy_.savedModules.size(), 1);
        const QVariantMap savedModule = policy_.savedModules.first().toMap();
        QCOMPARE(savedModule.value(QStringLiteral("packageId")).toString(),
                 QStringLiteral("example.device"));
        QVERIFY(savedModule.value(QStringLiteral("file")).toBool());
    }
};

QTEST_MAIN(NetworkPolicyQmlTest)
#include "network_policy_qml_test.moc"
