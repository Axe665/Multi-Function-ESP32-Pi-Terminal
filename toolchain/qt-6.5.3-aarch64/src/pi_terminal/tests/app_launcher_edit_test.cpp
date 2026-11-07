// 应用卡片编辑模式的逻辑回归：排序、持久化、取消恢复、恢复默认。
//
// 只测模型与状态机，不模拟真实指针拖拽（拖拽手感由人工验收）；
// 这样即使将来把 DragHandler 换成别的交互，排序语义仍被锁住。

#include <QtTest>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>

#include "ui/TerminalUi.h"

namespace {

// 只实现 AppLauncher 用到的系统接口；layout/apps 落在这个内存表里。
class StubTools : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool energySaving READ energySaving CONSTANT)
    Q_PROPERTY(double launcherOpacity READ launcherOpacity CONSTANT)
public:
    QHash<QString, QString> store;
    bool energySaving() const { return true; }
    double launcherOpacity() const { return 0.65; }
    Q_INVOKABLE bool settingsWrite(const QString &key, const QString &value)
    {
        store.insert(key, value);
        return true;
    }
    Q_INVOKABLE QString settingsRead(const QString &key, const QString &fallback) const
    {
        return store.value(key, fallback);
    }
    Q_INVOKABLE QString monochromeIcon(const QString &, bool) const { return {}; }
};

QByteArray sixAppModel()
{
    return QByteArrayLiteral(
        "import QtQuick\n"
        "ListModel {\n"
        "    ListElement { entryId:\"a\"; title:\"A\"; description:\"\"; iconName:\"apps\"; accentColor:\"#ffffff\"; route:2; instance:\"\"; ready:true }\n"
        "    ListElement { entryId:\"b\"; title:\"B\"; description:\"\"; iconName:\"apps\"; accentColor:\"#ffffff\"; route:3; instance:\"\"; ready:true }\n"
        "    ListElement { entryId:\"c\"; title:\"C\"; description:\"\"; iconName:\"apps\"; accentColor:\"#ffffff\"; route:1; instance:\"\"; ready:true }\n"
        "    ListElement { entryId:\"d\"; title:\"D\"; description:\"\"; iconName:\"apps\"; accentColor:\"#ffffff\"; route:4; instance:\"\"; ready:true }\n"
        "    ListElement { entryId:\"e\"; title:\"E\"; description:\"\"; iconName:\"apps\"; accentColor:\"#ffffff\"; route:6; instance:\"\"; ready:true }\n"
        "    ListElement { entryId:\"f\"; title:\"F\"; description:\"\"; iconName:\"apps\"; accentColor:\"#ffffff\"; route:7; instance:\"\"; ready:true }\n"
        "}\n");
}

QByteArray moduleThenAppsModel()
{
    return QByteArrayLiteral(
        "import QtQuick\n"
        "ListModel {\n"
        "    ListElement { entryId:\"m1\"; title:\"M\"; description:\"\"; iconName:\"apps\"; accentColor:\"#ffffff\"; route:5; instance:\"m1\"; ready:true }\n"
        "    ListElement { entryId:\"a\"; title:\"A\"; description:\"\"; iconName:\"apps\"; accentColor:\"#ffffff\"; route:2; instance:\"\"; ready:true }\n"
        "    ListElement { entryId:\"b\"; title:\"B\"; description:\"\"; iconName:\"apps\"; accentColor:\"#ffffff\"; route:3; instance:\"\"; ready:true }\n"
        "}\n");
}

QVariantList orderOf(QObject *launcher)
{
    QVariant value;
    if (!QMetaObject::invokeMethod(launcher, "snapshotOrder", Q_RETURN_ARG(QVariant, value)))
        qWarning("snapshotOrder() invocation failed");
    return value.toList();
}

QQuickItem *makeLauncher(QQmlEngine *engine, QObject *model, const QVariantList &defaults)
{
    QQmlComponent component(engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/AppLauncher.qml")));
    if (!component.isReady()) {
        qWarning("%s", qPrintable(component.errorString()));
        return nullptr;
    }
    QObject *object = component.createWithInitialProperties(
        {{QStringLiteral("width"), 1024.0}, {QStringLiteral("height"), 560.0},
         {QStringLiteral("model"), QVariant::fromValue(model)},
         {QStringLiteral("defaultOrder"), defaults}});
    return qobject_cast<QQuickItem *>(object);
}

} // namespace

class AppLauncherEditTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase()
    {
        QQuickStyle::setStyle(QStringLiteral("Material"));
        initializeTerminalUi();
    }

    void reorderFinishCancelAndReset()
    {
        StubTools tools;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &tools);

        QQmlComponent modelComponent(&engine);
        modelComponent.setData(sixAppModel(), QUrl());
        QVERIFY2(modelComponent.isReady(), qPrintable(modelComponent.errorString()));
        QScopedPointer<QObject> model(modelComponent.create());
        QVERIFY(model);
        QCOMPARE(model->property("count").toInt(), 6);

        const QVariantList defaults{QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c"),
                                    QStringLiteral("d"), QStringLiteral("e"), QStringLiteral("f")};
        QScopedPointer<QQuickItem> launcher(makeLauncher(&engine, model.data(), defaults));
        QVERIFY(launcher);
        QQuickWindow window;
        window.resize(1024, 600);
        launcher->setParentItem(window.contentItem());
        window.show();
        QTest::qWait(120);

        QCOMPARE(orderOf(launcher.data()),
                 (QVariantList{"a", "b", "c", "d", "e", "f"}));

        // 进入编辑 → 把第 0 项拖到第 2 项 → 顺序变化。
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "enterEdit"));
        QVERIFY(launcher->property("editMode").toBool());
        launcher->setProperty("dragIndex", 0);
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "moveDragTo", Q_ARG(QVariant, 2)));
        QCOMPARE(orderOf(launcher.data()),
                 (QVariantList{"b", "c", "a", "d", "e", "f"}));

        // 完成：写 layout/apps，退出编辑。
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "finishEdit"));
        QVERIFY(!launcher->property("editMode").toBool());
        QVERIFY(tools.store.contains(QStringLiteral("layout/apps")));
        const QJsonArray saved =
            QJsonDocument::fromJson(tools.store.value(QStringLiteral("layout/apps")).toUtf8()).array();
        QCOMPARE(saved.size(), 6);
        QCOMPARE(saved.at(0).toString(), QStringLiteral("b"));

        // 取消：恢复进入编辑前的顺序。
        const QVariantList before = orderOf(launcher.data());
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "enterEdit"));
        launcher->setProperty("dragIndex", 0);
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "moveDragTo", Q_ARG(QVariant, 3)));
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "cancelEdit"));
        QCOMPARE(orderOf(launcher.data()), before);
        QVERIFY(!launcher->property("editMode").toBool());

        // 恢复默认：回到 Main 传入的 defaultOrder。
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "enterEdit"));
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "resetOrder"));
        QCOMPARE(orderOf(launcher.data()), defaults);
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "cancelEdit"));
    }

    // 模块卡片（route=5）固定在页首：编辑时不能被拖到内置应用后面。
    void moduleCardsStayFirst()
    {
        StubTools tools;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &tools);

        QQmlComponent modelComponent(&engine);
        modelComponent.setData(moduleThenAppsModel(), QUrl());
        QVERIFY2(modelComponent.isReady(), qPrintable(modelComponent.errorString()));
        QScopedPointer<QObject> model(modelComponent.create());
        QVERIFY(model);
        QCOMPARE(model->property("count").toInt(), 3);

        QScopedPointer<QQuickItem> launcher(makeLauncher(&engine, model.data(), {}));
        QVERIFY(launcher);
        QQuickWindow window;
        window.resize(1024, 600);
        launcher->setParentItem(window.contentItem());
        window.show();
        QTest::qWait(120);

        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "enterEdit"));
        launcher->setProperty("dragIndex", 1);
        // 目标 0 会被夹到第一个内置应用位置（索引 1），模块仍在最前。
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "moveDragTo", Q_ARG(QVariant, 0)));
        QCOMPARE(orderOf(launcher.data()), (QVariantList{"m1", "a", "b"}));
        QVERIFY(QMetaObject::invokeMethod(launcher.data(), "cancelEdit"));
    }
};

QTEST_MAIN(AppLauncherEditTest)
#include "app_launcher_edit_test.moc"
