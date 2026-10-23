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

    // The QQmlEngine must stay alive for the whole test: QML functions are
    // invoked through it, and destroying the engine silently breaks every
    // QMetaObject::invokeMethod call on the created objects.
    struct Fixture {
        FakeWebView fake;
        JoystickTools tools;
        QQmlEngine engine;
        QScopedPointer<QQuickItem> joystick;
        QString error;
        bool open(const QSize &joystickSize = QSize(800, 600),
                  const QSize &viewSize = QSize(400, 400)) {
            fake.setSize(viewSize);
            joystick.reset(makeJoystick(engine, tools, fake, joystickSize, &error));
            if (!joystick) return false;
            return QMetaObject::invokeMethod(joystick.data(), "open");
        }
    };

private slots:
    void initTestCase() {
        QQuickStyle::setStyle(QStringLiteral("Material"));
        initializeTerminalUi();
    }

    static int scrollCallCount(const FakeWebView &fake) {
        int count = 0;
        for (const auto &call : fake.jsCalls)
            if (call.contains(QStringLiteral("window.scrollBy"))) ++count;
        return count;
    }

    void stickUpScrollsPageUp() {
        Fixture fixture;
        QVERIFY2(fixture.open(), qPrintable(fixture.error));
        QVERIFY(QMetaObject::invokeMethod(fixture.joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(-1.0))));
        QTRY_VERIFY_WITH_TIMEOUT(fixture.fake.jsCalls.contains(QStringLiteral("window.scrollBy(0,-36); true;")), 2000);
        QVERIFY(!fixture.fake.jsCalls.contains(QStringLiteral("window.scrollBy(0,36); true;")));
    }

    void stickRightScrollsPageRight() {
        Fixture fixture;
        QVERIFY2(fixture.open(), qPrintable(fixture.error));
        QVERIFY(QMetaObject::invokeMethod(fixture.joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(1.0)), Q_ARG(QVariant, QVariant(0.0))));
        QTRY_VERIFY_WITH_TIMEOUT(fixture.fake.jsCalls.contains(QStringLiteral("window.scrollBy(36,0); true;")), 2000);
    }

    void deadZoneSuppressesJitter() {
        Fixture fixture;
        QVERIFY2(fixture.open(), qPrintable(fixture.error));
        const int before = scrollCallCount(fixture.fake);
        QVERIFY(QMetaObject::invokeMethod(fixture.joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(-0.05))));
        QTest::qWait(400);
        QCOMPARE(scrollCallCount(fixture.fake), before); // resting inside the dead zone scrolls nothing
    }

    void releaseStopsScrolling() {
        Fixture fixture;
        QVERIFY2(fixture.open(), qPrintable(fixture.error));
        QVERIFY(QMetaObject::invokeMethod(fixture.joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(-1.0))));
        QTRY_VERIFY_WITH_TIMEOUT(scrollCallCount(fixture.fake) > 0, 2000);
        QVERIFY(QMetaObject::invokeMethod(fixture.joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(0.0))));
        QTest::qWait(300); // let pending ticks settle
        const int settled = scrollCallCount(fixture.fake);
        QTest::qWait(300);
        QCOMPARE(scrollCallCount(fixture.fake), settled); // no further injections after release
    }

    void toggleManagesPanelState() {
        Fixture fixture;
        QVERIFY2(fixture.open(), qPrintable(fixture.error));
        QVERIFY(fixture.joystick->property("expanded").toBool());
        QVERIFY(QMetaObject::invokeMethod(fixture.joystick.data(), "toggle"));
        QCOMPARE(fixture.joystick->property("expanded").toBool(), false);
        QVERIFY(QMetaObject::invokeMethod(fixture.joystick.data(), "toggle"));
        QVERIFY(fixture.joystick->property("expanded").toBool());
    }

    void inactiveWithoutTargetView() {
        Fixture fixture;
        QVERIFY2(fixture.open(), qPrintable(fixture.error));
        fixture.joystick->setProperty("targetView", QVariant::fromValue(static_cast<QQuickItem *>(nullptr)));
        QTest::qWait(50);
        const int before = fixture.fake.jsCalls.size();
        QVERIFY(QMetaObject::invokeMethod(fixture.joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(-1.0))));
        QTest::qWait(400);
        QCOMPARE(fixture.fake.jsCalls.size(), before); // no target view -> no injections
    }
};

QTEST_MAIN(BrowserJoystickTest)
#include "browser_joystick_test.moc"
