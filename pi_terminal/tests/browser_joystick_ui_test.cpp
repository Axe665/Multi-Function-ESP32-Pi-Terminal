#include <QtTest>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QScopedPointer>
#include "ui/TerminalUi.h"
#include "JoystickTestSupport.h"

// UI-layer coverage for the scroll-only BrowserJoystick: visibility states,
// stick thumb geometry (follows stickX/stickY), elderly-friendly touch target
// sizes and in-bounds placement of the floating cluster.
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

        QVERIFY(!joystick->property("expanded").toBool());
        auto *badge = joystick->findChild<QQuickItem *>(QStringLiteral("joystickBadge"));
        auto *cluster = joystick->findChild<QQuickItem *>(QStringLiteral("joystickCluster"));
        QVERIFY(badge && cluster);
        QVERIFY(badge->isVisible());
        QVERIFY(!cluster->isVisible());

        QMetaObject::invokeMethod(joystick.data(), "open");
        QVERIFY(joystick->property("expanded").toBool());
        QVERIFY(!badge->isVisible());
        QVERIFY(cluster->isVisible());
    }

    void stickThumbTracksDeflection() {
        FakeWebView fake;
        fake.setSize(QSize(400, 300));
        JoystickTools tools;
        QQmlEngine engine;
        QString error;
        QScopedPointer<QQuickItem> joystick(makeJoystick(engine, tools, fake, QSize(800, 600), &error));
        QVERIFY2(joystick, qPrintable(error));
        QMetaObject::invokeMethod(joystick.data(), "open");
        auto *base = joystick->findChild<QQuickItem *>(QStringLiteral("joystickStick"));
        auto *thumb = joystick->findChild<QQuickItem *>(QStringLiteral("joystickStickThumb"));
        QVERIFY(base && thumb);

        QVERIFY(QMetaObject::invokeMethod(joystick.data(), "setStick",
            Q_ARG(QVariant, QVariant(0.5)), Q_ARG(QVariant, QVariant(-1.0))));
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(thumb->x() - (base->width() / 2 - thumb->width() / 2
                                                   + 0.5 * (base->width() - thumb->width()) / 2)) < 2.0, 500);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(thumb->y() - (base->height() / 2 - thumb->height() / 2
                                                   - 1.0 * (base->height() - thumb->height()) / 2)) < 2.0, 500);
    }

    void touchTargets() {
        FakeWebView fake;
        fake.setSize(QSize(400, 300));
        JoystickTools tools;
        QQmlEngine engine;
        QString error;
        QScopedPointer<QQuickItem> joystick(makeJoystick(engine, tools, fake, QSize(800, 600), &error));
        QVERIFY2(joystick, qPrintable(error));
        QMetaObject::invokeMethod(joystick.data(), "open");

        auto *stick = joystick->findChild<QQuickItem *>(QStringLiteral("joystickStick"));
        auto *hideButton = joystick->findChild<QQuickItem *>(QStringLiteral("joystickHideButton"));
        QVERIFY(stick && hideButton);
        // Elderly-friendly targets: stick and buttons must be at least 48 px.
        QVERIFY2(stick->width() >= 120.0 && stick->height() >= 120.0, "stick surface too small");
        QVERIFY2(hideButton->width() >= 48.0 && hideButton->height() >= 48.0, "hide button below 48 px");
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
};

QTEST_MAIN(BrowserJoystickUiTest)
#include "browser_joystick_ui_test.moc"
