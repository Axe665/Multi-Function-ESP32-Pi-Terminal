#include <QGuiApplication>
#include <QQuickView>
#include <QQuickItem>
#include <QQmlEngine>
#include <QQmlContext>
#include <QQmlComponent>
#include <QTimer>
#include <QDateTime>
#include <QImage>
#include <cstdio>
#include <cmath>

// Explicit simulated fixture for repeatable layout checks; never installed
// as module history or published as physical sensor evidence.
//
// 建议数据同样是固定夹具：它只用来核对建议入口与建议页的排版，
// 不代表真实端侧推理结果，也不会写进任何用户库。
static QVariantList sampleAdvices(qint64 now)
{
    QVariantList out;
    out << QVariantMap{{"text", QStringLiteral("光照只有 1 lux，明显低于散射光下限。建议把花盆移到离窗更近的位置，或补一盏植物灯。")},
                       {"risk", "alert"}, {"confidence", 0.82}, {"generated_at", double(now - 120000)}};
    out << QVariantMap{{"text", QStringLiteral("空气湿度 53.6 %RH 偏低，可在托盘里加一点水提高局部湿度，避免叶尖干枯。")},
                       {"risk", "watch"}, {"confidence", 0.71}, {"generated_at", double(now - 300000)}};
    return out;
}

static QVariantList sampleHistory(qint64 now)
{
    QVariantList out;
    const struct { const char *text; const char *risk; double conf; qint64 agoMs; } kRows[] = {
        {"光照只有 1 lux，明显低于散射光下限。建议把花盆移到离窗更近的位置。", "alert", 0.82, 120000LL},
        {"空气湿度 53.6 %RH 偏低，可在托盘里加一点水提高局部湿度。", "watch", 0.71, 300000LL},
        {"上午温度 25.2 °C、湿度 56.1 %RH 都在舒适区间，保持当前摆放即可。", "normal", 0.88, 3600000LL},
        {"午后光照升到 720 lux，散射光充足；注意不要让叶片长时间直晒。", "normal", 0.79, 9000000LL},
        {"夜间温度降到 22.4 °C，昼夜温差 2.8 °C，属于健康范围。", "normal", 0.84, 43200000LL},
        {"电池 54 %，按当前上报频率预计还能工作约 3 天。", "watch", 0.66, 86400000LL},
        {"气压 1015 hPa 稳定，无剧烈变化。", "normal", 0.9, 129600000LL},
        {"连续两小时光照低于 5 lux，建议检查摆放位置或补光。", "alert", 0.77, 172800000LL},
    };
    for (const auto &row : kRows) {
        out << QVariantMap{{"text", QString::fromUtf8(row.text)},
                           {"risk", QString::fromLatin1(row.risk)},
                           {"confidence", row.conf},
                           {"generated_at", double(now - row.agoMs)}};
    }
    return out;
}

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    if (argc < 3) return 2;
    QQuickView view;
    bool warnings = false;
    QObject::connect(view.engine(), &QQmlEngine::warnings, [&](const QList<QQmlError> &errors) {
        warnings = true; for (const auto &e : errors) fprintf(stderr, "%s\n", qPrintable(e.toString()));
    });
    view.setResizeMode(QQuickView::SizeRootObjectToView);
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    QVariantList day, week;
    for (int i = 0; i < 96; ++i) {
        const double v = 22 + 3 * std::sin(i / 10.0);
        day.append(QVariantMap{{"t", double(now - (95-i)*900000LL)}, {"v", v}, {"min", v-.7}, {"max", v+.7}});
    }
    for (int i = 0; i < 84; ++i) {
        const double v = 23 + 2 * std::sin(i / 7.0);
        week.append(QVariantMap{{"t", double(now - (83-i)*7200000LL)}, {"v", v}, {"min", v-1.2}, {"max", v+1.2}});
    }
    QVariantMap data{{"temperature_C", 24.6}, {"humidity_RH", 61.2}, {"light_lux", 720},
        {"pressure_hPa", 1015.1}, {"battery_pct", 54}, {"battery_V", 3.85},
        {"power_source", "unknown"}, {"power_protection", "source_unknown_auto_sleep_inhibited"},
        {"received_at", double(now)}, {"history_day", day}, {"history_week", week}};
    // 宿主的 ModulePageHost 是把 sessionModel 作为 context property 注入的；
    // 页面里没有声明同名 property，所以 setProperty 不生效（首帧会读成
    // undefined，四张数据卡和曲线因此全空）。这里必须在 setSource 之前注。
    view.rootContext()->setContextProperty("sessionModel", QVariantMap{{"data", data}});
    // 生产环境里 appAdvice 由 ModulePageHost 注入。预览也要有一个，否则页面会
    // 落进"宿主未连接"分支，截出来的是降级态而不是成品态。用一个纯 QML 的
    // QtObject 冒充：只要 ready=true、信号齐全，页面的生产文案就会全部走通。
    QQmlComponent adviceComponent(view.engine());
    adviceComponent.setData(R"(
import QtQuick
QtObject {
    property bool ready: true
    property string lastError: ""
    property var history: []
    signal stateChanged()
    signal adviceReady(string requestId, var payload)
    signal adviceFailed(string requestId, string code)
    // history 属性自带的 historyChanged 已经满足页面监听，不要再显式声明。
    function request(options) {}
    function loadHistory() {}
}
)", QUrl());
    QObject *mockAdvice = adviceComponent.create();
    if (!mockAdvice) {
        fprintf(stderr, "%s\n", qPrintable(adviceComponent.errorString()));
        return 4;
    }
    view.rootContext()->setContextProperty("appAdvice", mockAdvice);
    view.setSource(QUrl::fromLocalFile(QString::fromLocal8Bit(argv[1])));
    if (view.status() != QQuickView::Ready) return 3;
    view.rootObject()->setProperty("adviceItems", sampleAdvices(now));
    view.rootObject()->setProperty("historyItems", sampleHistory(now));
    view.resize(840, 1120); view.show();
    QTimer::singleShot(1000, [&] {
        if (!view.grabWindow().save(QString::fromLocal8Bit(argv[2]) + "-day.png")) warnings = true;
        view.rootObject()->setProperty("weekView", true);
    });
    QTimer::singleShot(1600, [&] {
        if (!view.grabWindow().save(QString::fromLocal8Bit(argv[2]) + "-week.png")) warnings = true;
        view.resize(480, 1400);
    });
    QTimer::singleShot(2300, [&] {
        if (!view.grabWindow().save(QString::fromLocal8Bit(argv[2]) + "-narrow.png")) warnings = true;
        view.resize(840, 1010);
    });
    // 建议页：入口点击后切换到 showAdvice，给它一帧完成布局再抓。
    QTimer::singleShot(2900, [&] {
        view.rootObject()->setProperty("showAdvice", true);
    });
    // 滑入进行中抓一帧：240ms OutCubic 在 ~80ms 时约走完七成，
    // 能看出整幅色板是从右边缘推入而不是淡入/瞬切。
    QTimer::singleShot(2980, [&] {
        if (!view.grabWindow().save(QString::fromLocal8Bit(argv[2]) + "-slide.png")) warnings = true;
    });
    QTimer::singleShot(3500, [&] {
        if (!view.grabWindow().save(QString::fromLocal8Bit(argv[2]) + "-advice.png")) warnings = true;
        app.exit(warnings ? 1 : 0);
    });
    return app.exec();
}
