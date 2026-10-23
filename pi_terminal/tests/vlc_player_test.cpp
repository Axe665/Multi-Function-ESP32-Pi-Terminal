#include "ui/VlcPlayer.h"
#include "ui/TerminalUi.h"

#include <QtTest>
#include <QQmlEngine>
#include <QQmlComponent>
#include <QQuickItem>
#include <QScopedPointer>

// Smoke coverage for the libVLC backend. This test is only built when libvlc
// was found at configure time; it degrades gracefully when the runtime library
// is not installed on the test host.
class VlcPlayerTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() { initializeTerminalUi(); }

    void defaults() {
        VlcPlayer player;
        QCOMPARE(player.position(), qint64(0));
        QCOMPARE(player.duration(), qint64(0));
        QVERIFY(!player.playing());
        QVERIFY(!player.seekable());
        QVERIFY(player.source().isEmpty());
        QCOMPARE(player.volume(), 0.8);
        QVERIFY(!player.muted());
    }

    void missingMediaReportsError() {
        VlcPlayer player;
        player.setSource(QUrl::fromLocalFile(QStringLiteral("/definitely/missing/video.mp4")));
        player.play();
        if (VlcPlayer::runtimeAvailable()) {
            QTRY_VERIFY_WITH_TIMEOUT(!player.errorString().isEmpty(), 8000);
        } else {
            QVERIFY(!player.errorString().isEmpty());
        }
    }

    void qmlTypesRegistered() {
        QQmlEngine engine;
        QQmlComponent component(&engine);
        component.setData(
            "import QtQuick\n"
            "import Terminal.Native 1.0\n"
            "Item { VlcPlayer { id: player } VlcVideoOutput { id: output } "
            "property bool ready: player !== null && output !== null }",
            QUrl(QStringLiteral("qrc:/vlc-test.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.create());
        QVERIFY2(object, qPrintable(component.errorString()));
        QVERIFY(object->property("ready").toBool());
    }
};

QTEST_MAIN(VlcPlayerTest)
#include "vlc_player_test.moc"
