#include <QtTest>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QScopedPointer>
#include "ui/TerminalUi.h"
#include "JoystickTestSupport.h"

// UI-layer coverage for BrowserJoystick: visibility states, cursor overlay
// geometry, touch target sizes, button enablement and in-bounds placement of
// the floating cluster (elderly-friendly 48px+ controls).
class BrowserJoystickUiTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        QQuickStyle::setStyle(QStringLiteral("Material"));
        initializeTerminalUi();
    }

    void collapsedAndExpandedStates() {
        FakeWebView fake;
        fake.setSize(QSize(400, 300));
        JoystickTools tools;
        QQmlEngine engine;
        QString error;
        QScopedPointer<QQuickItem> joystick(makeJoystick(engine, tools, fake, QSize(800, 600), &error));
        QVERIFY2(joystick, qPrintable(error));

        QVERIFY(joystick->property("expanded").toBool() == false);
        auto *badge = joystick->findChild<QQuickItem *>(QStringLiteral("joystickBadge"));
        auto *cluster = joystick->findChild<QQuickItem *>(QStringLiteral("joystickCluster"));
        auto *cursor = joystick->findChild<QQuickItem *>(QStringLiteral("joystickCursor"));
        QVERIFY(badge && cluster && cursor);
        QVERIFY(badge->isVisible());
        QVERIFY(!cluster->isVisible());
        QVERIFY(!cursor->isVisible());

        QMetaObject::invokeMethod(joystick.data(), "open");
        QVERIFY(joystick->property("expanded").toBool());
        QVERIFY(!badge->isVisible());
        QVERIFY(cluster->isVisible());
        QVERIFY(cursor->isVisible());
    }

    void cursorGeometryFollowsPosition() {
        FakeWebView fake;
        fake.setSize(QSize(400, 300));
        fake.setPosition(QPointF(0, 0));
        JoystickTools tools;
        QQmlEngine engine;
        QString error;
        QScopedPointer<QQuickItem> joystick(makeJoystick(engine, tools, fake, QSize(800, 600), &error));
        QVERIFY2(joystick, qPrintable(error));
        QMetaObject::invokeMethod(joystick.data(), "open");
        auto *cursor = joystick->findChild<QQuickItem *>(QStringLiteral("joystickCursor"));
        QVERIFY(cursor);

        joystick->setProperty("cursorX", 0.25);
        joystick->setProperty("cursorY", 0.5);
        QCoreApplication::processEvents();
        const qreal expectX = 0.25 * fake.width() - cursor->width() / 2.0;
        const qreal expectY = 0.5 * fake.height() - cursor->height() / 2.0;
        QVERIFY2(qAbs(cursor->x() - expectX) < 2.0, "cursor X does not track cursorX");
        QVERIFY2(qAbs(cursor->y() - expectY) < 2.0, "cursor Y does not track cursorY");
    }

    void touchTargetsAndButtonStates() {
        FakeWebView fake;
        fake.setSize(QSize(400, 300));
        JoystickTools tools;
        QQmlEngine engine;
        QString error;
        QScopedPointer<QQuickItem> joystick(makeJoystick(engine, tools, fake, QSize(800, 600), &error));
        QVERIFY2(joystick, qPrintable(error));
        QMetaObject::invokeMethod(joystick.data(), "open");

        auto *clickButton = joystick->findChild<QQuickItem *>(QStringLiteral("joystickClickButton"));
        auto *backButton = joystick->findChild<QQuickItem *>(QStringLiteral("joystickBackButton"));
        auto *reloadButton = joystick->findChild<QQuickItem *>(QStringLiteral("joystickReloadButton"));
        QVERIFY(clickButton && backButton && reloadButton);
        // Elderly-friendly targets: every control must be at least 48 px.
        for (auto *button : {clickButton, backButton, reloadButton})
            QVERIFY2(button->width() >= 48.0 && button->height() >= 48.0,
                     "joystick button smaller than 48 px");

        fake.setCanGoBack(true);
        QCoreApplication::processEvents();
        QVERIFY(backButton->property("enabled").toBool());
        fake.setCanGoBack(false);
        QCoreApplication::processEvents();
        QVERIFY(!backButton->property("enabled").toBool());
    }

    void clusterStaysInsideBounds() {
        for (const QSize size : {QSize(800, 600), QSize(360, 480)}) {
            FakeWebView fake;
            fake.setSize(QSize(200, 200));
            JoystickTools tools;
            QQmlEngine engine;
            QString error;
            QScopedPointer<QQuickItem> joystick(makeJoystick(engine, tools, fake, size, &error));
            QVERIFY2(joystick, qPrintable(error));
            auto *cluster = joystick->findChild<QQuickItem *>(QStringLiteral("joystickCluster"));
            QVERIFY(cluster);
            QVERIFY2(cluster->x() >= 8.0, "cluster left edge offscreen");
            QVERIFY2(cluster->y() >= 8.0, "cluster top edge offscreen");
            QVERIFY2(cluster->x() + cluster->width() <= size.width() - 8.0,
                     "cluster right edge offscreen");
            QVERIFY2(cluster->y() + cluster->height() <= size.height() - 8.0,
                     "cluster bottom edge offscreen");
        }
    }

    void navigationReachesTargetView() {
        FakeWebView fake;
        fake.setSize(QSize(400, 300));
        JoystickTools tools;
        QQmlEngine engine;
        QString error;
        QScopedPointer<QQuickItem> joystick(makeJoystick(engine, tools, fake, QSize(800, 600), &error));
        QVERIFY2(joystick, qPrintable(error));
        QMetaObject::invokeMethod(joystick.data(), "open");
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "goBack"));
        QCOMPARE(fake.backCalls, 1);
        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "reload"));
        QCOMPARE(fake.reloadCalls, 1);
    }
};

QTEST_MAIN(BrowserJoystickUiTest)
#include "browser_joystick_ui_test.moc"
