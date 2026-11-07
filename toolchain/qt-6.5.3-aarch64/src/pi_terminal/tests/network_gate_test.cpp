// 报告 §9.3 / §3.2：联网总开关与分功能开关。
//
// 2026-11-01 变更：联网权限改为 root 策略驱动、默认拒绝。总开关仍是紧急总闸，
// 但任何应用（包括天气/音乐/校时）都必须先由管理员在策略里逐项开启。
#include "core/NetworkGate.h"

#include <QSignalSpy>
#include <QtTest>

class NetworkGateTest : public QObject {
    Q_OBJECT

private slots:
    // 默认拒绝：策略缺失时所有应用都不可联网。
    void defaultIsDeny()
    {
        NetworkGate gate;
        QVERIFY(gate.enabled());
        for (const char *feature : {"browser", "music", "tv", "weather", "timesync", "updates"})
            QVERIFY2(!gate.featureEnabled(QString::fromLatin1(feature)), feature);
        QVERIFY(!gate.allow(QStringLiteral("weather")));
        QVERIFY(gate.reason().contains(QStringLiteral("weather")));
    }

    // 关闭时拒绝必须给出可读原因，且含调用方标识。
    void denialExplainsWhy()
    {
        NetworkGate gate;
        gate.setEnabled(false);
        QVERIFY(!gate.allow(QStringLiteral("timesync")));
        QVERIFY2(gate.reason().contains(QStringLiteral("timesync")), qPrintable(gate.reason()));
        QVERIFY(gate.reason().startsWith(QStringLiteral("network disabled")));
    }

    // 重新打开后放行，且清掉拒绝原因。
    void enablingAllowsAndClearsReason()
    {
        NetworkGate gate;
        gate.setFeatureEnabledFromUi(QStringLiteral("music"), true);
        gate.setEnabled(false);
        QVERIFY(!gate.allow(QStringLiteral("music")));
        QVERIFY(!gate.reason().isEmpty());

        gate.setEnabled(true);
        QVERIFY(gate.allow(QStringLiteral("music")));
        QVERIFY(gate.reason().isEmpty());
    }

    // 关闭后立即生效（不必等重启）。
    void disablingTakesEffectImmediately()
    {
        NetworkGate gate;
        gate.setFeatureEnabledFromUi(QStringLiteral("weather"), true);
        QVERIFY(gate.allow(QStringLiteral("weather")));
        gate.setEnabled(false);
        QVERIFY(!gate.allow(QStringLiteral("weather")));
        QVERIFY(!gate.reason().isEmpty());
    }

    // 重复设置同一状态不重复发信号（避免界面抖动与多余写盘）。
    void settingSameValueIsIdempotent()
    {
        NetworkGate gate;
        QSignalSpy changed(&gate, &NetworkGate::changed);
        gate.setEnabled(true);           // 已经是 true
        QCOMPARE(changed.count(), 0);
        gate.setEnabled(false);
        QCOMPARE(changed.count(), 1);
        gate.setEnabled(false);
        QCOMPARE(changed.count(), 1);
    }

    // 六个子开关各自独立，互不影响。
    void perFeatureSwitchesAreIndependent()
    {
        NetworkGate gate;
        const QStringList features{QStringLiteral("browser"), QStringLiteral("music"),
                                   QStringLiteral("tv"), QStringLiteral("weather"),
                                   QStringLiteral("timesync"), QStringLiteral("updates")};
        for (const QString &feature : features) {
            gate.setFeatureEnabledFromUi(feature, true);
            QVERIFY2(gate.featureEnabled(feature), qPrintable(feature));
        }
        // 只关天气，其余照旧。
        QVERIFY(gate.setFeatureEnabledFromUi(QStringLiteral("weather"), false));
        QVERIFY(!gate.allow(QStringLiteral("weather")));
        QVERIFY(gate.reason().contains(QStringLiteral("weather")));
        QVERIFY(gate.allow(QStringLiteral("music")));
        QVERIFY(gate.allow(QStringLiteral("tv")));
        QVERIFY(gate.allow(QStringLiteral("browser")));
    }

    // 总开关关闭时子开关状态保留：重新打开即恢复，不需要用户再逐个开。
    void featureSwitchesSurviveMasterToggle()
    {
        NetworkGate gate;
        gate.setFeatureEnabledFromUi(QStringLiteral("music"), false);
        gate.setFeatureEnabledFromUi(QStringLiteral("weather"), false);
        gate.setFeatureEnabledFromUi(QStringLiteral("timesync"), true);
        gate.setEnabled(false);
        QVERIFY(gate.featureEnabled(QStringLiteral("music")) == false);  // 保留的是"关"
        gate.setEnabled(true);
        QVERIFY(!gate.allow(QStringLiteral("music")));
        QVERIFY(!gate.allow(QStringLiteral("weather")));
        QVERIFY(gate.allow(QStringLiteral("timesync")));
    }

    // 未知用途按 Other 处理；带后缀的老写法仍映射到对应功能。
    void purposeStringsUsePrefixes()
    {
        NetworkGate gate;
        gate.setFeatureEnabledFromUi(QStringLiteral("music"), false);
        QVERIFY(!gate.allow(QStringLiteral("music.api")));
        QVERIFY2(gate.reason().contains(QStringLiteral("music")), qPrintable(gate.reason()));
        gate.setFeatureEnabledFromUi(QStringLiteral("weather"), false);
        QVERIFY(!gate.allow(QStringLiteral("weather.geocoding")));
        // Other 永远放行（总开关开着时）。
        QVERIFY(gate.allow(QStringLiteral("something.else")));
        // 未知的子开关名直接拒绝，不会静默当成成功。
        QVERIFY(!gate.setFeatureEnabledFromUi(QStringLiteral("nope"), true));
    }

    // 只有用户改开关才发 settingChanged；allow() 被拒不该触发写盘。
    void settingChangedOnlyOnUserAction()
    {
        NetworkGate gate;
        QSignalSpy setting(&gate, &NetworkGate::settingChanged);
        gate.allow(QStringLiteral("weather"));
        gate.setEnabled(false);
        gate.allow(QStringLiteral("weather"));   // 拒绝，但仍不该写盘
        QCOMPARE(setting.count(), 1);
        gate.setFeatureEnabledFromUi(QStringLiteral("tv"), true);
        QCOMPARE(setting.count(), 2);
        gate.setFeatureEnabledFromUi(QStringLiteral("tv"), false);
        QCOMPARE(setting.count(), 3);
        gate.setFeatureEnabledFromUi(QStringLiteral("tv"), false);   // 幂等
        QCOMPARE(setting.count(), 3);
    }

    // snapshot / restore：宿主持久化的往返。
    void snapshotRoundTrips()
    {
        NetworkGate source;
        source.setEnabled(false);
        source.setFeatureEnabledFromUi(QStringLiteral("tv"), true);
        source.setFeatureEnabledFromUi(QStringLiteral("updates"), true);
        const QVariantMap saved = source.snapshot();

        NetworkGate restored;
        restored.restore(saved);
        QCOMPARE(restored.enabled(), false);
        QCOMPARE(restored.tvAllowed(), true);
        QCOMPARE(restored.updatesAllowed(), true);
        QCOMPARE(restored.musicAllowed(), false);

        // 缺键时按默认值：总闸开、应用全关。
        NetworkGate fresh;
        fresh.restore(QVariantMap{});
        QVERIFY(fresh.enabled());
        QVERIFY(!fresh.weatherAllowed());
    }

    // permits() 是给"信号回调里判断"用的：不许改 reason、不许发信号，
    // 否则 allow() -> changed -> 回调 -> allow() 会无限递归。
    void permitsHasNoSideEffects()
    {
        NetworkGate gate;
        gate.setFeatureEnabledFromUi(QStringLiteral("music"), true);
        QSignalSpy changed(&gate, &NetworkGate::changed);
        QVERIFY(!gate.permits(QStringLiteral("browser")));
        QCOMPARE(changed.count(), 0);
        QVERIFY2(gate.reason().isEmpty(), "permits() must not write the reason");

        // 与 allow() 的判定保持一致（同一状态、同一条字符串）。
        QVERIFY(!gate.allow(QStringLiteral("browser")));
        QVERIFY(!gate.permits(QStringLiteral("browser")));
        QVERIFY(gate.permits(QStringLiteral("music")));
        QVERIFY(gate.allow(QStringLiteral("music")));

        gate.setEnabled(false);
        QVERIFY(!gate.permits(NetworkGate::Purpose::Music));
        QVERIFY(gate.permits(NetworkGate::Purpose::Other) == false);
        gate.setEnabled(true);
        QVERIFY(gate.permits(NetworkGate::Purpose::Other));
    }

    // §9.3 第 3 条：三态互不推导。接口有 IP 不代表互联网可达。
    void interfaceReadyDoesNotImplyInternet()
    {
        NetworkGate gate;
        gate.setInterfaceReady(true);
        QVERIFY(gate.interfaceReady());
        QVERIFY2(!gate.internetReachable(), "interface up must not imply internet");
        gate.setModuleLinkReady(true);
        QVERIFY(gate.moduleLinkReady());
        QVERIFY(!gate.internetReachable());
        gate.setInternetReachable(true);
        QVERIFY(gate.internetReachable());
    }

    // §9.3 第 6 条：更新下载默认关闭，避免网络恢复即自动拉大包。
    void updateDownloadsDefaultOff()
    {
        NetworkGate gate;
        QVERIFY2(!gate.updatesAllowed(), "update downloads must default to off");
        QVERIFY(!gate.allow(NetworkGate::Purpose::Updates));
        QVERIFY(gate.reason().contains(QStringLiteral("updates")));
    }

    // 关总开关不再清空在途计数：一次性请求允许跑完，由调用方自己收尾。
    void disablingKeepsInFlightCounter()
    {
        NetworkGate gate;
        gate.beginRequest();
        gate.beginRequest();
        QCOMPARE(gate.inFlight(), 2);
        gate.setEnabled(false);
        QCOMPARE(gate.inFlight(), 2);
        gate.endRequest();
        QCOMPARE(gate.inFlight(), 1);
    }

    // 请求计数不得为负（重复 end 不能把计数打穿）。
    void requestCounterNeverGoesNegative()
    {
        NetworkGate gate;
        gate.endRequest();
        QCOMPARE(gate.inFlight(), 0);
        gate.beginRequest();
        QCOMPARE(gate.inFlight(), 1);
        gate.endRequest();
        gate.endRequest();
        QCOMPARE(gate.inFlight(), 0);
    }

    // 校时被拒也只是拿到 false：调用方保留内置时区，不抛错、不阻塞。
    void timeSyncDenialIsGraceful()
    {
        NetworkGate gate;
        gate.setFeatureEnabledFromUi(QStringLiteral("timesync"), true);
        gate.setEnabled(false);
        QVERIFY(!gate.allow(NetworkGate::Purpose::TimeSync));
        QVERIFY(gate.reason().contains(QStringLiteral("timesync")));
        gate.setEnabled(true);
        QVERIFY(gate.allow(NetworkGate::Purpose::TimeSync));
    }
};

QTEST_GUILESS_MAIN(NetworkGateTest)
#include "network_gate_test.moc"
