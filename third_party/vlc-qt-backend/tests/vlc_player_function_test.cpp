#include <vlc-qt-backend/VlcPlayer.h>

#include <QtTest>
#include <QSignalSpy>

// Functional coverage for the vlc-qt-backend wrapper. Runs in stub mode as
// well (no libVLC runtime): stub behavior is verified explicitly, and the
// real playback lifecycle is exercised when VLC_TEST_MEDIA points at a local
// media file on a machine with libVLC installed.
class VlcPlayerFunctionTest : public QObject {
    Q_OBJECT
private slots:
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

    void volumeMuteRoundTrip() {
        VlcPlayer player;
        player.setVolume(0.45);
        QCOMPARE(player.volume(), 0.45);
        player.setVolume(3.0); // clamped
        QCOMPARE(player.volume(), 1.25);
        player.setMuted(true);
        QVERIFY(player.muted());
        player.setMuted(false);
        QVERIFY(!player.muted());
    }

    void positionSetter() {
        VlcPlayer player;
        player.setPosition(4200);
        QCOMPARE(player.position(), qint64(4200));
    }

    void stopResetsPosition() {
        VlcPlayer player;
        player.setPosition(500);
        player.stop();
        QCOMPARE(player.position(), qint64(0));
    }

    void missingMediaReportsError() {
        VlcPlayer player;
        QSignalSpy errorSpy(&player, &VlcPlayer::errorOccurred);
        player.setSource(QUrl::fromLocalFile(QStringLiteral("/definitely/missing/video.mp4")));
        player.play();
        if (VlcPlayer::runtimeAvailable()) {
            QTRY_VERIFY_WITH_TIMEOUT(!player.errorString().isEmpty(), 8000);
        } else {
            // Stub build: the error is reported synchronously on setSource.
            QVERIFY(!player.errorString().isEmpty());
            QCOMPARE(errorSpy.count(), 1);
        }
    }

    void loadingStateWithoutRuntime() {
        if (VlcPlayer::runtimeAvailable()) QSKIP("Stub-only assertion");
        VlcPlayer player;
        QVERIFY(!player.loading());
        player.setSource(QUrl::fromLocalFile(QStringLiteral("/tmp/x.mp4")));
        QVERIFY(!player.loading()); // error already reported -> not "loading"
        player.stop();
        QVERIFY(!player.playing());
    }

    void realPlaybackLifecycle() {
        const QString media = qEnvironmentVariable("VLC_TEST_MEDIA");
        if (media.isEmpty()) QSKIP("Set VLC_TEST_MEDIA to a local media file to exercise real playback");
        if (!VlcPlayer::runtimeAvailable()) QSKIP("libVLC runtime not installed");
        VlcPlayer player;
        QSignalSpy playingSpy(&player, &VlcPlayer::playingChanged);
        player.setSource(QUrl::fromLocalFile(media));
        player.play();
        QTRY_VERIFY_WITH_TIMEOUT(player.playing(), 15000);
        QVERIFY2(player.errorString().isEmpty(), qPrintable(player.errorString()));
        player.pause();
        QTRY_VERIFY_WITH_TIMEOUT(!player.playing(), 5000);
        player.play();
        QTRY_VERIFY_WITH_TIMEOUT(player.playing(), 5000);
        player.stop();
        QTRY_VERIFY_WITH_TIMEOUT(!player.playing(), 5000);
        QVERIFY(playingSpy.count() >= 3);
    }
};

QTEST_MAIN(VlcPlayerFunctionTest)
#include "vlc_player_function_test.moc"
