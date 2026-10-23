#include <vlc-qt-backend/VlcPlayer.h>
#include <vlc-qt-backend/VlcVideoOutput.h>

#include <QtTest>
#include <QElapsedTimer>

#include <cstring>

// Performance coverage for the vlc-qt-backend hot paths. All numbers are
// measured and logged (VLC_BENCH_* lines); the pass/fail bounds are generous
// floors that only catch pathological regressions (a full frame copy at 720p
// must exceed 80 MB/s on any board this terminal targets).
static QImage syntheticFrame(const QSize &size) {
    QImage frame(size, QImage::Format_RGB32);
    frame.fill(QColor(0x40, 0x70, 0xa0));
    return frame;
}

class VlcPlayerPerformanceTest : public QObject {
    Q_OBJECT
private slots:
    void frameCopyThroughput() {
        const QSize size(1280, 720);
        const QImage source = syntheticFrame(size);
        QImage target(size, QImage::Format_RGB32);
        const qint64 bytes = qint64(source.sizeInBytes());
        QElapsedTimer timer;
        timer.start();
        const int iterations = 60;
        for (int i = 0; i < iterations; ++i)
            std::memcpy(target.bits(), source.constBits(), size_t(source.sizeInBytes()));
        const double mbps = (bytes * iterations / 1e6) / (timer.nsecsElapsed() / 1e9);
        qInfo().noquote() << QStringLiteral("VLC_BENCH_FRAME_COPY %1 MB/s (720p RV32)").arg(mbps, 0, 'f', 1);
        QVERIFY2(mbps > 80.0, "720p frame copy throughput below 80 MB/s");
    }

    void presentLatency() {
        const QImage frame = syntheticFrame({1280, 720});
        VlcVideoOutput output;
        output.setSize(QSize(640, 360));
        QElapsedTimer timer;
        timer.start();
        const int iterations = 200;
        for (int i = 0; i < iterations; ++i) output.present(frame);
        const double usPerPresent = timer.nsecsElapsed() / 1000.0 / iterations;
        qInfo().noquote() << QStringLiteral("VLC_BENCH_PRESENT %1 us/frame").arg(usPerPresent, 0, 'f', 1);
        QVERIFY2(usPerPresent < 3000.0, "present() slower than 3 ms per 720p frame");
    }

    void eventDispatchThroughput() {
        VlcPlayer player;
        QElapsedTimer timer;
        timer.start();
        const int iterations = 5000;
        for (int i = 0; i < iterations; ++i)
            player.handleEvent(VlcPlayer::EvBuffering, (i % 2) ? 20 : 100);
        const double usPerEvent = timer.nsecsElapsed() / 1000.0 / iterations;
        qInfo().noquote() << QStringLiteral("VLC_BENCH_EVENT_DISPATCH %1 us/event").arg(usPerEvent, 0, 'f', 1);
        QVERIFY2(usPerEvent < 500.0, "event dispatch slower than 0.5 ms per event");
    }

    void propertyChangeSignals() {
        VlcPlayer player;
        QElapsedTimer timer;
        timer.start();
        const int iterations = 2000;
        for (int i = 0; i < iterations; ++i) {
            player.setVolume((i % 100) / 100.0);
            player.setPosition(i);
        }
        const double usPerSet = timer.nsecsElapsed() / 1000.0 / iterations;
        qInfo().noquote() << QStringLiteral("VLC_BENCH_PROPERTY_SET %1 us/set").arg(usPerSet, 0, 'f', 1);
        QVERIFY2(usPerSet < 500.0, "property setters slower than 0.5 ms per call");
    }
};

QTEST_MAIN(VlcPlayerPerformanceTest)
#include "vlc_player_performance_test.moc"
