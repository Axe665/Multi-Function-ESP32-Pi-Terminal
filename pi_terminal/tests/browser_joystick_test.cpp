#include <QtTest>
#include <QQmlEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickStyle>
#include <QScopedPointer>
#include "ui/TerminalUi.h"
#include "JoystickTestSupport.h"

// Functional coverage for the scroll-only BrowserJoystick: stick deflection
// maps to window.scrollBy injections (direction and magnitude), the dead zone
// suppresses resting-thumb jitter, releasing the stick stops scrolling, and
// toggle/open/close manage the panel state.
class BrowserJoystickTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        QQuickStyle::setStyle(QStringLiteral("Material"));
        initializeTerminalUi();
    }

    QQuickItem *openJoystick(FakeWebView &fake, QString *error) {
        JoystickTools tools;
        QQmlEngine engine;
        auto *joystick = makeJoystick(engine, tools, fake, QSize(800, 600), error);
        if (joystick) QMetaObject::invokeMethod(joystick, "open");
        return joystick;
    }

    static int scrollCallCount(const FakeWebView &fake) {
        int count = 0;
        for (const auto &call : fake.jsCalls)
            if (call.contains(QStringLiteral("window.scrollBy"))) ++count;
        return count;
    }

    void stickUpScrollsPageUp() {
        FakeWebView fake;
        fake.setSize(QSize(400, 400));
        QString error;
        QScopedPointer<QQuickItem> joystick(openJoystick(fake, &error));
        QVERIFY2(joystick, qPrintable(error));
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(-1.0))));
        QTRY_VERIFY_WITH_TIMEOUT(fake.jsCalls.contains(QStringLiteral("window.scrollBy(0,-36); true;")), 2000);
        QVERIFY(!fake.jsCalls.contains(QStringLiteral("window.scrollBy(0,36); true;")));
    }

    void stickRightScrollsPageRight() {
        FakeWebView fake;
        fake.setSize(QSize(400, 400));
        QString error;
        QScopedPointer<QQuickItem> joystick(openJoystick(fake, &error));
        QVERIFY2(joystick, qPrintable(error));
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(1.0)), Q_ARG(QVariant, QVariant(0.0))));
        QTRY_VERIFY_WITH_TIMEOUT(fake.jsCalls.contains(QStringLiteral("window.scrollBy(36,0); true;")), 2000);
    }

    void deadZoneSuppressesJitter() {
        FakeWebView fake;
        fake.setSize(QSize(400, 400));
        QString error;
        QScopedPointer<QQuickItem> joystick(openJoystick(fake, &error));
        QVERIFY2(joystick, qPrintable(error));
        const int before = scrollCallCount(fake);
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(-0.05))));
        QTest::qWait(400);
        QCOMPARE(scrollCallCount(fake), before); // resting inside the dead zone scrolls nothing
    }

    void releaseStopsScrolling() {
        FakeWebView fake;
        fake.setSize(QSize(400, 400));
        QString error;
        QScopedPointer<QQuickItem> joystick(openJoystick(fake, &error));
        QVERIFY2(joystick, qPrintable(error));
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(-1.0))));
        QTRY_VERIFY_WITH_TIMEOUT(scrollCallCount(fake) > 0, 2000);
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(0.0))));
        QTest::qWait(300); // let pending ticks settle
        const int settled = scrollCallCount(fake);
        QTest::qWait(300);
        QCOMPARE(scrollCallCount(fake), settled); // no further injections after release
    }

    void toggleManagesPanelState() {
        FakeWebView fake;
        fake.setSize(QSize(400, 400));
        QString error;
        QScopedPointer<QQuickItem> joystick(openJoystick(fake, &error));
        QVERIFY2(joystick, qPrintable(error));
        QVERIFY(joystick->property("expanded").toBool());
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "toggle"));
        QCOMPARE(joystick->property("expanded").toBool(), false);
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "toggle"));
        QVERIFY(joystick->property("expanded").toBool());
    }

    void inactiveWithoutTargetView() {
        FakeWebView fake;
        fake.setSize(QSize(400, 400));
        QString error;
        QScopedPointer<QQuickItem> joystick(openJoystick(fake, &error));
        QVERIFY2(joystick, qPrintable(error));
        joystick->setProperty("targetView", QVariant::fromValue(static_cast<QQuickItem *>(nullptr)));
        QTest::qWait(50);
        const int before = fake.jsCalls.size();
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(-1.0))));
        QTest::qWait(400);
        QCOMPARE(fake.jsCalls.size(), before); // no target view -> no injections
    }
};

QTEST_MAIN(BrowserJoystickTest)
#include "browser_joystick_test.moc"
