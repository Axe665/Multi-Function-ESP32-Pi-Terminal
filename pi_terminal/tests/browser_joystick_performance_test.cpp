#include <QtTest>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QElapsedTimer>
#include <QScopedPointer>
#include "ui/TerminalUi.h"
#include "JoystickTestSupport.h"

// Performance coverage for the scroll-only BrowserJoystick hot paths. Numbers
// are logged as JOYSTICK_BENCH_* lines; bounds are generous floors that only
// catch pathological regressions on the terminal's class of boards.
class BrowserJoystickPerformanceTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        QQuickStyle::setStyle(QStringLiteral("Material"));
        initializeTerminalUi();
    }

    void scrollInjectionRate() {
        FakeWebView fake;
        fake.setSize(QSize(400, 400));
        JoystickTools tools;
        QQmlEngine engine;
        QString error;
        QScopedPointer<QQuickItem> joystick(makeJoystick(engine, tools, fake, QSize(800, 600), &error));
        QVERIFY2(joystick, qPrintable(error));
        QMetaObject::invokeMethod(joystick.data(), "open");
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.0)), Q_ARG(QVariant, QVariant(-1.0))));
        const int before = fake.jsCalls.size();
        QTest::qWait(1000); // ~62 timer ticks, ~20 injection ticks at full deflection
        int scrollCalls = 0;
        for (const auto &call : fake.jsCalls)
            if (call.contains(QStringLiteral("window.scrollBy"))) ++scrollCalls;
        qInfo().noquote() << QStringLiteral("JOYSTICK_BENCH_SCROLL_RATE %1 scrolls/s")
            .arg(scrollCalls);
        // ~20 scrolls/s at full deflection; anything sane must stay in 5..40.
        QVERIFY2(scrollCalls >= 5, "scroll injection rate too low");
        QVERIFY2(scrollCalls <= 40, "scroll injection rate too high (runaway loop)");
    }

    void setStickInvokeThroughput() {
        FakeWebView fake;
        fake.setSize(QSize(400, 400));
        JoystickTools tools;
        QQmlEngine engine;
        QString error;
        QScopedPointer<QQuickItem> joystick(makeJoystick(engine, tools, fake, QSize(800, 600), &error));
        QVERIFY2(joystick, qPrintable(error));
        QElapsedTimer timer;
        timer.start();
        const int iterations = 1000;
        for (int i = 0; i < iterations; ++i)
            QMetaObject::invokeMethod(joystick.data(), "setStick",
                Q_ARG(QVariant, QVariant((i % 20) / 10.0 - 1.0)),
                Q_ARG(QVariant, QVariant((i % 7) / 3.0 - 1.0)));
        const double usPerCall = timer.nsecsElapsed() / 1000.0 / iterations;
        qInfo().noquote() << QStringLiteral("JOYSTICK_BENCH_SETSTICK %1 us/call").arg(usPerCall, 0, 'f', 1);
        QVERIFY2(usPerCall < 500.0, "setStick slower than 0.5 ms per call");
    }

    void zeroDeflectionInjectsNothing() {
        FakeWebView fake;
        fake.setSize(QSize(400, 400));
        JoystickTools tools;
        QQmlEngine engine;
        QString error;
        QScopedPointer<QQuickItem> joystick(makeJoystick(engine, tools, fake, QSize(800, 600), &error));
        QVERIFY2(joystick, qPrintable(error));
        QMetaObject::invokeMethod(joystick.data(), "open");
        QTest::qWait(500);
        QVERIFY(fake.jsCalls.isEmpty()); // idle panel must stay perfectly silent
    }
};

QTEST_MAIN(BrowserJoystickPerformanceTest)
#include "browser_joystick_performance_test.moc"
