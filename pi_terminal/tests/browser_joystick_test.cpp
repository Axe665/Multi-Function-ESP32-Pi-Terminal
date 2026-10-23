#include <QtTest>
#include <QQmlEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickStyle>
#include <QJSValue>
#include <QScopedPointer>
#include "ui/TerminalUi.h"
#include "JoystickTestSupport.h"

class BrowserJoystickTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        QQuickStyle::setStyle(QStringLiteral("Material"));
        initializeTerminalUi();
    }

    void cursorScrollClickAndNavigation() {
        FakeWebView fake;
        fake.setSize(QSize(400, 400));
        JoystickTools tools;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &tools);
        engine.rootContext()->setContextProperty("vlcBackendAvailable", false);
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/BrowserJoystick.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> created(component.create());
        QVERIFY2(created, qPrintable(component.errorString()));
        auto *joystick = qobject_cast<QQuickItem *>(created.data());
        QVERIFY(joystick);
        joystick->setSize(QSize(800, 600));

        joystick->setProperty("targetView", QVariant::fromValue(static_cast<QQuickItem *>(&fake)));
        joystick->setProperty("expanded", true);
        QTest::qWait(50);
        QCOMPARE(joystick->property("cursorX").toReal(), 0.5);

        // Drive the stick right until the cursor reaches the edge zone; the
        // edge detector must then inject window.scrollBy calls.
        QVERIFY(QMetaObject::invokeMethod(joystick, "setStick",
            Q_ARG(QVariant, QVariant(1.0)), Q_ARG(QVariant, QVariant(0.0))));
        QTRY_VERIFY_WITH_TIMEOUT(joystick->property("cursorX").toReal() > 0.9, 3000);
        QTRY_VERIFY_WITH_TIMEOUT([&] {
            for (const auto &call : fake.jsCalls)
                if (call.contains(QStringLiteral("window.scrollBy"))) return true;
            return false;
        }(), 3000);
        QVERIFY(QMetaObject::invokeMethod(joystick, "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(0.0))));
        QTest::qWait(120);

        // Click injection resolves the element under the cursor.
        joystick->setProperty("cursorX", 0.5);
        joystick->setProperty("cursorY", 0.5);
        const int beforeClick = fake.jsCalls.size();
        QVERIFY(QMetaObject::invokeMethod(joystick, "injectClick"));
        QTRY_VERIFY(fake.jsCalls.size() > beforeClick);
        QVERIFY(fake.jsCalls.last().contains(QStringLiteral("elementFromPoint")));

        // Navigation helpers reach the target view.
        QVERIFY(QMetaObject::invokeMethod(joystick, "goBack"));
        QCOMPARE(fake.backCalls, 1);
        QVERIFY(QMetaObject::invokeMethod(joystick, "reload"));
        QCOMPARE(fake.reloadCalls, 1);

        // Toggle collapses the cluster and stops the cursor overlay.
        QVERIFY(QMetaObject::invokeMethod(joystick, "toggle"));
        QCOMPARE(joystick->property("expanded").toBool(), false);
    }
};

QTEST_MAIN(BrowserJoystickTest)
#include "browser_joystick_test.moc"
