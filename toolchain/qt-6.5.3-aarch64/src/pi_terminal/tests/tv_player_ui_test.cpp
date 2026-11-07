#include "ui/TerminalUi.h"

#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QtTest>

// TvPlayer 的 UI 契约：电视音量必须和 MusicPlayer/VideoPlayer 一样叠加
// systemTools.mediaGain（播报降音）。这里用真实 QML 页面实例断言绑定，
// 不需要网络或 HLS 源：GstVideoItem 在无管线时也会保存 volume 属性。
class TvTools : public QObject {
    Q_OBJECT
    Q_PROPERTY(double mediaGain MEMBER gain NOTIFY gainChanged)
    Q_PROPERTY(QString uiLanguage MEMBER language CONSTANT)
public:
    double gain = 1.0;
    QString language = QStringLiteral("zh");
    Q_INVOKABLE QString tvTestUrl() { return {}; }
    Q_INVOKABLE QString tvChannelData() { return QStringLiteral("{\"categories\":[]}"); }
    Q_INVOKABLE QString tvChannelName() { return {}; }
    Q_INVOKABLE bool tvAutoplay() { return false; }
    Q_INVOKABLE bool tvForceFullscreen() { return false; }
    Q_INVOKABLE QString monochromeIcon(const QString &, bool) { return {}; }
signals:
    void gainChanged();
};

// 只实现 TvPlayer 会调用的 minimizeApp()，用来验证最小化按钮走宿主。
class FakeHost : public QObject {
    Q_OBJECT
public:
    int minimizeCalls = 0;
    Q_INVOKABLE void minimizeApp() { ++minimizeCalls; }
};

class TvPlayerUiTests : public QObject {
    Q_OBJECT
private slots:
    void volumeFollowsAnnouncementGain() {
        TvTools tools;
        QQuickWindow window;
        window.resize(1024, 600);
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &tools);
        QQmlComponent component(&engine, QUrl("qrc:/qt/qml/OrangePiTerminal/TvPlayer.qml"));
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{"width", 1024}, {"height", 600}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);
        page->setParentItem(window.contentItem());
        window.show();

        auto *backend = page->findChild<QQuickItem *>(QStringLiteral("tvVideoItem"));
        QVERIFY(backend);
        auto volume = [backend] { return backend->property("volume").toDouble(); };
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(volume() - 0.8) < 1e-6, 1000);

        // 用户把电视音量改成 50%，没有播报时应保持 0.5。
        page->setProperty("volume", 0.5);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(volume() - 0.5) < 1e-6, 1000);

        // 播报开始：mediaGain 0.5 → 管线音量 0.25（120ms 渐变，QTRY 等它走完）。
        tools.gain = 0.5;
        emit tools.gainChanged();
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(volume() - 0.25) < 0.01, 2000);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(page->property("announcementGain").toDouble() - 0.5) < 0.01, 2000);

        // 静音优先：muted 直接归零，不依赖增益。
        page->setProperty("muted", true);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(volume()) < 1e-6, 1000);

        // 取消静音后回到 0.25；播报结束媒体增益恢复 1.0，电视也回到 0.5。
        page->setProperty("muted", false);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(volume() - 0.25) < 0.01, 2000);
        tools.gain = 1.0;
        emit tools.gainChanged();
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(volume() - 0.5) < 0.01, 2000);

        // 播报期间用户改音量：增益是乘法，改完立即作用在新音量上，不写回旧值。
        tools.gain = 0.5;
        emit tools.gainChanged();
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(volume() - 0.25) < 0.01, 2000);
        page->setProperty("volume", 0.6);
        QTRY_VERIFY_WITH_TIMEOUT(qAbs(volume() - 0.3) < 0.01, 2000);
    }

    void minimizeKeepsPlaybackCloseReleases() {
        TvTools tools;
        FakeHost host;
        QQuickWindow window;
        window.resize(1024, 600);
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &tools);
        QQmlComponent component(&engine, QUrl("qrc:/qt/qml/OrangePiTerminal/TvPlayer.qml"));
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{"width", 1024}, {"height", 600},
             {"hostWindow", QVariant::fromValue(static_cast<QObject *>(&host))}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);
        page->setParentItem(window.contentItem());
        window.show();

        auto *backend = page->findChild<QQuickItem *>(QStringLiteral("tvVideoItem"));
        QVERIFY(backend);
        // 没有真实源时也能区分“保留管线”和“release”：releaseMedia 会清空 source。
        backend->setProperty("source", QStringLiteral("file:///nonexistent.m3u8"));
        page->setProperty("active", true);
        QTRY_VERIFY(!page->property("backgroundPlayback").toBool());

        // 最小化按钮：置后台标记并调用宿主 minimizeApp()。
        QVERIFY(QMetaObject::invokeMethod(page, "minimizeToBackground"));
        QVERIFY(page->property("backgroundPlayback").toBool());
        QCOMPARE(host.minimizeCalls, 1);

        // 页面 active 变 false 时不得释放管线。
        page->setProperty("active", false);
        QTest::qWait(50);
        QCOMPARE(backend->property("source").toString(), QStringLiteral("file:///nonexistent.m3u8"));

        // 恢复页面：清后台标记，仍保留管线。
        page->setProperty("active", true);
        QTRY_VERIFY(!page->property("backgroundPlayback").toBool());
        QCOMPARE(backend->property("source").toString(), QStringLiteral("file:///nonexistent.m3u8"));

        // 关闭路径：立即停播并清 source（Main.qml 的 closeApp 调的就是它）。
        QVERIFY(QMetaObject::invokeMethod(page, "stopPlayback"));
        QVERIFY(!page->property("backgroundPlayback").toBool());
        QCOMPARE(backend->property("source").toString(), QString());
    }
};

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    QQuickStyle::setStyle(QStringLiteral("Material"));
    initializeTerminalUi();
    TvPlayerUiTests tests;
    return QTest::qExec(&tests, argc, argv);
}

#include "tv_player_ui_test.moc"
