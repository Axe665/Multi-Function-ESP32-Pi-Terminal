// Weather page regression: the real WeatherTools.qml against a stub host object.
// No network: the page is fed a synthetic normalized model, so the test covers
// layout, unit formatting, place switching and the dialog, not the data sources.
// (The provider parsers live in WeatherMath.js and are covered by Node.)
#include <QtTest>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QElapsedTimer>
#include <QVariantMap>
#include "core/NetworkGate.h"
#include "ui/TerminalUi.h"

namespace {

class WeatherToolsHost : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString uiLanguage MEMBER language NOTIFY languageChanged)
public:
    QString language = QStringLiteral("zh");
    QHash<QString, QString> settings;
    Q_INVOKABLE QString monochromeIcon(const QString &name, bool) {
        return QStringLiteral("qrc:/icons/material/light/") + name + QStringLiteral(".svg");
    }
    // Mirrors SystemTools: only "time/" and "weather/" keys are writable from a page.
    Q_INVOKABLE QString settingsRead(const QString &key, const QString &fallback = QString()) const {
        return settings.value(key, fallback);
    }
    Q_INVOKABLE bool settingsWrite(const QString &key, const QString &value) {
        const bool allowed = key.startsWith(QStringLiteral("time/")) ||
                             key.startsWith(QStringLiteral("weather/"));
        if (!allowed || key.size() > 96 || value.toUtf8().size() > 16384) return false;
        settings.insert(key, value);
        return true;
    }
signals:
    void languageChanged();
};

QQuickItem *findItemByObjectName(QQuickItem *root, const QString &name) {
    if (!root) return nullptr;
    if (root->objectName() == name) return root;
    for (QQuickItem *child : root->childItems()) {
        if (QQuickItem *found = findItemByObjectName(child, name)) return found;
    }
    return nullptr;
}

QVariantMap sampleModel()
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    QVariantMap current;
    current.insert("t", now);
    current.insert("temp", 26.4);
    current.insert("apparent", 27.1);
    current.insert("code", 2);
    current.insert("wind", 12.4);
    current.insert("windDir", 135);
    current.insert("humidity", 78);
    current.insert("isDay", true);
    current.insert("pop", 40);

    QVariantList hourly;
    for (int i = 0; i < 24; ++i) {
        QVariantMap row;
        row.insert("t", now + i * 3600 * 1000);
        row.insert("temp", 26.4 - i * 0.2);
        row.insert("code", i == 6 ? 61 : 2);
        row.insert("pop", i * 3);
        row.insert("precip", 0.0);
        row.insert("wind", 12.0);
        hourly.append(row);
    }
    QVariantList daily;
    for (int i = 0; i < 7; ++i) {
        QVariantMap row;
        row.insert("t", now + i * 86400 * 1000);
        row.insert("code", i % 2 == 0 ? 2 : 61);
        row.insert("max", 28.4 - i * 0.4);
        row.insert("min", 22.9 - i * 0.3);
        row.insert("pop", 35);
        daily.append(row);
    }

    QVariantMap model;
    model.insert("source", QStringLiteral("open-meteo"));
    model.insert("fetchedAt", now);
    model.insert("utcOffsetSeconds", 28800);
    model.insert("offsetApproximate", false);
    model.insert("current", current);
    model.insert("hourly", hourly);
    model.insert("daily", daily);
    return model;
}

} // namespace

class WeatherToolsTests : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        QQuickStyle::setStyle(QStringLiteral("Material"));
        initializeTerminalUi();
    }

    void pageStructure() {
        WeatherToolsHost host;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &host);
        QQmlComponent engineComponent(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherEngine.qml")));
        QVERIFY2(engineComponent.isReady(), qPrintable(engineComponent.errorString()));
        QScopedPointer<QObject> weatherEngine(engineComponent.create());
        QVERIFY(weatherEngine);

        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherTools.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{"width", 1024}, {"height", 600}, {"uiScale", 1.0}, {"active", true},
             {"weatherEngine", QVariant::fromValue(weatherEngine.data())}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);

        // 布局需要在真实窗口的 polish 循环里跑；offscreen 平台也要 show()。
        QQuickWindow window;
        window.resize(1024, 600);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        page->setHeight(600);
        window.show();
        QTest::qWait(150);

        // 默认地点是需求指定的珠海；双栏在 1024 宽下生效。
        QVERIFY(weatherEngine->property("place").toMap().value("name").toString() == QStringLiteral("珠海"));
        QVERIFY(page->property("twoPane").toBool());
        QVERIFY(page->property("hasData").toBool() == false);
        QVERIFY(findItemByObjectName(page, QStringLiteral("weatherRefresh")));
        QVERIFY(findItemByObjectName(page, QStringLiteral("weatherCurrentPane")));
        QVERIFY(findItemByObjectName(page, QStringLiteral("weatherForecastPane")));

        // 注入归一化结果后，温度/实况/逐小时立刻有内容，且单位可切换。
        weatherEngine->setProperty("model", sampleModel());
        QVERIFY(page->property("hasData").toBool());
        QTest::qWait(50);
        auto *temperature = findItemByObjectName(page, QStringLiteral("weatherTemperature"));
        QVERIFY(temperature);
        QCOMPARE(temperature->property("text").toString(), QStringLiteral("26"));
        auto *strip = findItemByObjectName(page, QStringLiteral("weatherHourlyStrip"));
        QVERIFY(strip);
        QVERIFY(strip->property("contentWidth").toDouble() > strip->width());

        weatherEngine->setProperty("units", QStringLiteral("imperial"));
        QTRY_COMPARE(temperature->property("text").toString(), QStringLiteral("80"));

        // 双栏在窄页退回单栏；卡片仍留在页面内。
        page->setWidth(700);
        QTRY_VERIFY(!page->property("twoPane").toBool());
    }

    void announcementText() {
        WeatherToolsHost host;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &host);
        QQmlComponent engineComponent(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherEngine.qml")));
        QScopedPointer<QObject> weatherEngine(engineComponent.create());
        QVERIFY(weatherEngine);
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherTools.qml")));
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{"width", 1024}, {"height", 600}, {"uiScale", 1.0},
             {"weatherEngine", QVariant::fromValue(weatherEngine.data())}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);
        weatherEngine->setProperty("model", sampleModel());
        QSignalSpy announced(page, SIGNAL(announceRequested(QString)));
        QMetaObject::invokeMethod(page, "announceWeather");
        QCOMPARE(announced.count(), 1);
        const QString text = announced.takeFirst().at(0).toString();
        QVERIFY(text.contains(QStringLiteral("珠海")));
        QVERIFY(text.contains(QStringLiteral("26")));
        QVERIFY(text.contains(QStringLiteral("摄氏度")));
    }

    void placeDialogOpensAndCloses() {
        WeatherToolsHost host;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &host);
        QQmlComponent engineComponent(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherEngine.qml")));
        QScopedPointer<QObject> weatherEngine(engineComponent.create());
        QVERIFY(weatherEngine);
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherTools.qml")));
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{"width", 1024}, {"height", 600}, {"uiScale", 1.0},
             {"weatherEngine", QVariant::fromValue(weatherEngine.data())}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);
        QQuickWindow window;
        window.resize(1024, 600);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        page->setHeight(600);
        window.show();
        QTest::qWait(120);

        auto *dialog = findItemByObjectName(page, QStringLiteral("weatherPlaceDialog"));
        QVERIFY(dialog);
        QVERIFY(!dialog->isVisible());
        QMetaObject::invokeMethod(page, "openPlaceDialog");
        QTRY_VERIFY(dialog->isVisible());
        QMetaObject::invokeMethod(page, "closePlaceDialog");
        QTRY_VERIFY(!dialog->isVisible());
    }

    void failureKeepsLastResultAndReportsError() {
        WeatherToolsHost host;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &host);
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherEngine.qml")));
        QScopedPointer<QObject> object(component.create());
        QVERIFY2(object, qPrintable(component.errorString()));

        // 只留一个必然连不上的源：刷新应失败，但不能把已有结果清空，也不能伪造数据。
        object->setProperty("model", sampleModel());
        object->setProperty("customUrl", QStringLiteral("http://127.0.0.1:1/now?lat={lat}"));
        QVariantList sources;
        QVariantMap custom;
        custom.insert("id", QStringLiteral("custom"));
        custom.insert("enabled", true);
        sources.append(custom);
        object->setProperty("sources", sources);

        QMetaObject::invokeMethod(object.data(), "refresh");
        QTRY_VERIFY_WITH_TIMEOUT(!object->property("loading").toBool(), 5000);
        QVERIFY(!object->property("error").toString().isEmpty());
        QVERIFY(object->property("stale").toBool());
        QVERIFY(object->property("model").toMap().value("current").toMap().contains("temp"));
    }

    void settingsPersistThroughHost() {
        WeatherToolsHost host;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &host);
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherEngine.qml")));
        QScopedPointer<QObject> object(component.create());
        QVERIFY2(object, qPrintable(component.errorString()));

        QMetaObject::invokeMethod(object.data(), "setUnits", Q_ARG(QVariant, QStringLiteral("imperial")));
        QCOMPARE(host.settings.value(QStringLiteral("weather/units")), QStringLiteral("imperial"));
        QMetaObject::invokeMethod(object.data(), "setRefreshMinutes", Q_ARG(QVariant, 30));
        QCOMPARE(host.settings.value(QStringLiteral("weather/refreshMinutes")), QStringLiteral("30"));
        QMetaObject::invokeMethod(object.data(), "setSourceEnabled",
                                  Q_ARG(QVariant, QStringLiteral("openweather")), Q_ARG(QVariant, true));
        QVERIFY(host.settings.value(QStringLiteral("weather/sources")).contains(QStringLiteral("openweather")));
    }

    // 自定义源：模板里写 {key} 却没填 Key 时按"未配置"跳过（与 OpenWeather 同待遇），
    // 填上 Key 之后立刻恢复可用。两条都走真实的 WeatherEngine.qml。
    void customSourceRequiresKeyWhenTemplateAsksForIt() {
        WeatherToolsHost host;
        host.settings.insert(QStringLiteral("weather/custom.url"),
                             QStringLiteral("https://example.test/w?lat={lat}&key={key}"));
        host.settings.insert(QStringLiteral("weather/sources"),
                             QStringLiteral("[{\"id\":\"open-meteo\",\"enabled\":false},"
                                            "{\"id\":\"met-no\",\"enabled\":false},"
                                            "{\"id\":\"openweather\",\"enabled\":false},"
                                            "{\"id\":\"custom\",\"enabled\":true}]"));
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &host);
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherEngine.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.create());
        QVERIFY2(object, qPrintable(component.errorString()));

        QCOMPARE(object->property("customUrl").toString(),
                 QStringLiteral("https://example.test/w?lat={lat}&key={key}"));
        // 只有 custom 启用、而它缺 Key：整条链没有可用源。
        QCOMPARE(object->property("hasUsableSource").toBool(), false);

        QVERIFY(QMetaObject::invokeMethod(object.data(), "setCustomKey",
                                          Q_ARG(QVariant, QStringLiteral("secret"))));
        QCOMPARE(object->property("customKey").toString(), QStringLiteral("secret"));
        QCOMPARE(host.settings.value(QStringLiteral("weather/custom.key")), QStringLiteral("secret"));
        QCOMPARE(object->property("hasUsableSource").toBool(), true);
    }

    // 联网总开关关闭时：一次请求都不发，直接如实写「联网已关闭」。
    // 判定"没发请求"的方式是耗时为 0——真发的话至少会等到 15 s 超时。
    void networkOffStopsRequests() {
        WeatherToolsHost host;
        NetworkGate gate;
        gate.setEnabled(false);
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &host);
        engine.rootContext()->setContextProperty("networkGate", &gate);
        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherEngine.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.create());
        QVERIFY2(object, qPrintable(component.errorString()));

        QElapsedTimer timer;
        timer.start();
        QVERIFY(QMetaObject::invokeMethod(object.data(), "refresh"));
        QVERIFY2(timer.elapsed() < 1000, "refresh must not wait on a network request when the gate is closed");

        QCOMPARE(object->property("loading").toBool(), false);
        QCOMPARE(object->property("error").toString(), QStringLiteral("联网已关闭"));

        // 只关「天气联网」也一样拦（总开关仍开着）。
        gate.setEnabled(true);
        gate.setFeatureEnabledFromUi(QStringLiteral("weather"), false);
        QMetaObject::invokeMethod(object.data(), "refresh");
        QCOMPARE(object->property("error").toString(), QStringLiteral("联网已关闭"));
    }

    // 缓存超过 6 小时只换标签，不丢数据：「缓存 HH:MM」→「缓存已过期 HH:MM」。
    void expiredCacheKeepsDataAndChangesLabel() {
        WeatherToolsHost host;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &host);
        QQmlComponent engineComponent(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherEngine.qml")));
        QVERIFY2(engineComponent.isReady(), qPrintable(engineComponent.errorString()));
        QScopedPointer<QObject> weatherEngine(engineComponent.create());
        QVERIFY(weatherEngine);

        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        QVariantMap fresh = sampleModel();
        fresh.insert("fetchedAt", now);
        weatherEngine->setProperty("model", fresh);
        weatherEngine->setProperty("stale", true);

        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherTools.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        // active=false：不触发自动刷新，也就不会真的发网络请求。
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{"width", 1024}, {"height", 600}, {"uiScale", 1.0}, {"active", false},
             {"weatherEngine", QVariant::fromValue(weatherEngine.data())}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);

        QQuickWindow window;
        window.resize(1024, 600);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        page->setHeight(600);
        window.show();
        QTest::qWait(150);

        auto labelText = [&]() {
            QStringList texts;
            collectTexts(page, &texts);
            return texts.join(QStringLiteral("\n"));
        };

        // 新鲜、只来自缓存：标「缓存」但不说过期。
        const QString freshText = labelText();
        QVERIFY2(freshText.contains(QStringLiteral("缓存 ")), qPrintable(freshText));
        QVERIFY2(!freshText.contains(QStringLiteral("缓存已过期")), qPrintable(freshText));

        // 7 小时前的缓存：标签变「缓存已过期」，温度照常显示（数据没被清掉）。
        QVariantMap aged = sampleModel();
        aged.insert("fetchedAt", now - 7 * 60 * 60 * 1000);
        weatherEngine->setProperty("model", aged);
        QTest::qWait(80);
        const QString agedText = labelText();
        QVERIFY2(agedText.contains(QStringLiteral("缓存已过期 ")), qPrintable(agedText));
        QVERIFY2(agedText.contains(QStringLiteral("26")), qPrintable(agedText));

        // 重新拿到新鲜数据：回到「更新于」。
        QVariantMap renewed = sampleModel();
        renewed.insert("fetchedAt", QDateTime::currentMSecsSinceEpoch());
        weatherEngine->setProperty("model", renewed);
        weatherEngine->setProperty("stale", false);
        QTest::qWait(80);
        const QString renewedText = labelText();
        QVERIFY2(renewedText.contains(QStringLiteral("更新于 ")), qPrintable(renewedText));
    }

    // D 写：设置从设置页搬进天气页右上角，齿轮打开/返回关闭。
    void settingsGearOpensPageSettings() {
        WeatherToolsHost host;
        QQmlEngine engine;
        engine.rootContext()->setContextProperty("systemTools", &host);
        QQmlComponent engineComponent(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherEngine.qml")));
        QVERIFY2(engineComponent.isReady(), qPrintable(engineComponent.errorString()));
        QScopedPointer<QObject> weatherEngine(engineComponent.create());
        QVERIFY(weatherEngine);

        QQmlComponent component(&engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/WeatherTools.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{"width", 1024}, {"height", 600}, {"uiScale", 1.0}, {"active", true},
             {"weatherEngine", QVariant::fromValue(weatherEngine.data())}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);

        QQuickWindow window;
        window.resize(1024, 600);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        page->setHeight(600);
        window.show();
        QTest::qWait(150);

        // 齿轮常驻，位于工具栏最右。
        auto *gear = findItemByObjectName(page, QStringLiteral("weatherSettingsGear"));
        QVERIFY(gear);
        auto *layer = findItemByObjectName(page, QStringLiteral("weatherSettingsLayer"));
        QVERIFY(layer);

        QVERIFY(!page->property("settingsOpen").toBool());
        QVERIFY(layer->x() >= 1024 - 1);          // 收起时停在右侧画外

        QVERIFY(QMetaObject::invokeMethod(page, "openSettings"));
        QTest::qWait(350);                        // 240ms 过渡
        QVERIFY(page->property("settingsOpen").toBool());
        QVERIFY(layer->x() < 1);                  // 滑入到位
        // 设置内容确实在层里：应该能看到数据源/刷新这类文案。
        QStringList texts;
        collectTexts(layer, &texts);
        QVERIFY2(!texts.isEmpty(), "settings layer should render WeatherSettings content");
        // 设置页现在是「分类卡片 + 滑入二级页」：自定义 API 在第二页，先切过去。
        auto *panel = findItemByObjectName(layer, QStringLiteral("weatherSettingsPanel"));
        QVERIFY2(panel, "weather settings panel missing");
        panel->setProperty("section", 2);
        QTest::qWait(350);

        // 自定义 API 的 Key 输入框必须在设置层里真实存在，而且是可见、有宽度的
        // （只声明不渲染的控件也能被 findChild 找到，所以这里连几何一起断言）。
        auto *customKey = findItemByObjectName(layer, QStringLiteral("weatherCustomKey"));
        QVERIFY2(customKey, "custom API key field should be present in the weather settings layer");
        QVERIFY2(customKey->isVisible(), "custom API key field should be visible");
        QVERIFY2(customKey->width() > 0, "custom API key field should be laid out");

        QVERIFY(QMetaObject::invokeMethod(page, "closeSettings"));
        QTest::qWait(350);
        QVERIFY(!page->property("settingsOpen").toBool());
        QVERIFY(layer->x() >= 1024 - 1);
    }

    // 从设置层里找一段可读文案，确认搬过来的是真组件而不是空壳。
    void collectTexts(QQuickItem *item, QStringList *out) {
        if (!item) return;
        const QVariant text = item->property("text");
        if (text.isValid() && !text.toString().isEmpty()) out->append(text.toString());
        for (QQuickItem *child : item->childItems()) collectTexts(child, out);
    }
};

QTEST_MAIN(WeatherToolsTests)
#include "weather_tools_test.moc"
