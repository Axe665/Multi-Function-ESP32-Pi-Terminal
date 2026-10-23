#include <QtTest>
#include <QQmlEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickStyle>
#include <QScopedPointer>
#include <QCoreApplication>
#include "ui/TerminalUi.h"

// Minimal systemTools stand-in for the VideoPlayer page: I18n reads
// uiLanguage, the page binds announcementGain and calls files()/fileUrl() in
// refresh()/playFile().
class VlcUiTools : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString uiLanguage MEMBER language NOTIFY languageChanged)
    Q_PROPERTY(double mediaGain READ mediaGain CONSTANT)
public:
    QString language = QStringLiteral("zh");
    double mediaGain() const { return 1.0; }
    Q_INVOKABLE QVariantList files(const QString &) const { return {}; }
    Q_INVOKABLE QUrl fileUrl(const QString &) const { return QUrl(); }
signals:
    void languageChanged();
};

// Page-level UI coverage for the VLC backend integration: the backend
// component exposes its QML surface (video output + the videoAudioOutput
// mirror contract), and VideoPlayer.qml's Loader picks the VLC backend only
// when vlcBackendAvailable is true — otherwise the Qt Multimedia backend.
class VlcVideoUiTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        QQuickStyle::setStyle(QStringLiteral("Material"));
        initializeTerminalUi();
    }

    void vlcBackendComponentSurface() {
        VlcUiTools tools;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &tools);
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/VideoBackendVlc.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.create());
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *root = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(root);
        root->setSize(QSize(640, 360));

        QVERIFY2(root->findChild<QObject *>(QStringLiteral("vlcVideoOutput")),
                 "VlcVideoOutput surface missing");
        auto *mirror = root->findChild<QObject *>(QStringLiteral("videoAudioOutput"));
        QVERIFY2(mirror, "videoAudioOutput mirror missing (DiagnosticRunner contract)");

        // Page-driven bindings must propagate to the audio mirror.
        root->setProperty("muted", true);
        root->setProperty("volume", 0.33);
        QCOMPARE(mirror->property("muted").toBool(), true);
        QCOMPARE(mirror->property("volume").toReal(), 0.33);
    }

    void multimediaBackendComponentSurface() {
        VlcUiTools tools;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &tools);
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/VideoBackendMultimedia.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.create());
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *root = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(root);
        root->setSize(QSize(640, 360));
        QVERIFY(root->findChild<QObject *>(QStringLiteral("qtMultimediaVideoOutput")));
        QVERIFY(root->findChild<QObject *>(QStringLiteral("videoAudioOutput")));
    }

    void pageSelectsBackend_data() {
        QTest::addColumn<bool>("vlc");
        QTest::newRow("vlc-backend") << true;
        QTest::newRow("multimedia-fallback") << false;
    }

    void pageSelectsBackend() {
        QFETCH(bool, vlc);
        VlcUiTools tools;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &tools);
        engine.rootContext()->setContextProperty("vlcBackendAvailable", vlc);
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/VideoPlayer.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.create());
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);
        page->setSize(QSize(1024, 600));
        QCoreApplication::processEvents();

        if (vlc) {
            QVERIFY2(page->findChild<QObject *>(QStringLiteral("vlcVideoOutput")),
                     "Loader did not select the VLC backend surface");
            QVERIFY(!page->findChild<QObject *>(QStringLiteral("qtMultimediaVideoOutput")));
        } else {
            QVERIFY2(page->findChild<QObject *>(QStringLiteral("qtMultimediaVideoOutput")),
                     "Loader did not select the Qt Multimedia fallback surface");
            QVERIFY(!page->findChild<QObject *>(QStringLiteral("vlcVideoOutput")));
        }
        // Page contract used by Main.qml / DiagnosticRunner stays intact.
        QCOMPARE(page->property("hasMedia").toBool(), false);
        QCOMPARE(page->property("mediaPosition").toReal(), 0.0);
        QCOMPARE(page->property("mediaDuration").toReal(), 0.0);
        QVERIFY(page->findChild<QObject *>(QStringLiteral("videoFileList")));
    }
};

QTEST_MAIN(VlcVideoUiTest)
#include "vlc_video_ui_test.moc"
