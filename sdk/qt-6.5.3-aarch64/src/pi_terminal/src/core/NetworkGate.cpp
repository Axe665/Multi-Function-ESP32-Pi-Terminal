#include "core/NetworkGate.h"

#include <QVariantMap>

namespace {

// 与 Purpose 的声明顺序严格对应，allow() 用下标取名字。
const char *const kPurposeNames[] = {"browser", "music", "tv", "weather",
                                     "timesync", "updates", "other"};

}  // namespace

QString NetworkGate::purposeName(Purpose purpose) {
    return QLatin1String(kPurposeNames[int(purpose)]);
}

void NetworkGate::clearReason() {
    if (reason_.isEmpty()) return;
    reason_.clear();
    emit changed();
}

void NetworkGate::setEnabled(bool enabled) {
    if (enabled_ == enabled) return;
    enabled_ = enabled;
    reason_.clear();
    // 关闭总开关不再丢弃在途请求：调用方按用途自己收尾（持续连接立即停，
    // 一次性请求让它跑完）。这里只如实反映"不再放行新请求"。
    emit changed();
    emit settingChanged();
}

void NetworkGate::setBrowserAllowed(bool allowed) {
    if (browserAllowed_ == allowed) return;
    browserAllowed_ = allowed;
    emit changed();
    emit settingChanged();
}

void NetworkGate::setMusicAllowed(bool allowed) {
    if (musicAllowed_ == allowed) return;
    musicAllowed_ = allowed;
    emit changed();
    emit settingChanged();
}

void NetworkGate::setTvAllowed(bool allowed) {
    if (tvAllowed_ == allowed) return;
    tvAllowed_ = allowed;
    emit changed();
    emit settingChanged();
}

void NetworkGate::setWeatherAllowed(bool allowed) {
    if (weatherAllowed_ == allowed) return;
    weatherAllowed_ = allowed;
    emit changed();
    emit settingChanged();
}

void NetworkGate::setTimeSyncAllowed(bool allowed) {
    if (timeSyncAllowed_ == allowed) return;
    timeSyncAllowed_ = allowed;
    emit changed();
    emit settingChanged();
}

void NetworkGate::setUpdatesAllowed(bool allowed) {
    if (updatesAllowed_ == allowed) return;
    updatesAllowed_ = allowed;
    emit changed();
    emit settingChanged();
}

bool NetworkGate::setFeatureEnabledFromUi(const QString &feature, bool enabled) {
    const QString key = feature.trimmed().toLower();
    if (key == QLatin1String("browser")) setBrowserAllowed(enabled);
    else if (key == QLatin1String("music")) setMusicAllowed(enabled);
    else if (key == QLatin1String("tv")) setTvAllowed(enabled);
    else if (key == QLatin1String("weather")) setWeatherAllowed(enabled);
    else if (key == QLatin1String("timesync")) setTimeSyncAllowed(enabled);
    else if (key == QLatin1String("updates")) setUpdatesAllowed(enabled);
    else return false;
    return true;
}

bool NetworkGate::featureEnabled(const QString &feature) const {
    const QString key = feature.trimmed().toLower();
    if (key == QLatin1String("browser")) return browserAllowed_;
    if (key == QLatin1String("music")) return musicAllowed_;
    if (key == QLatin1String("tv")) return tvAllowed_;
    if (key == QLatin1String("weather")) return weatherAllowed_;
    if (key == QLatin1String("timesync")) return timeSyncAllowed_;
    if (key == QLatin1String("updates")) return updatesAllowed_;
    return false;
}

bool NetworkGate::moduleNetworkAllowed(const QString &instance) const {
    return enabled_ && moduleAllowed_.value(instance, false);
}

bool NetworkGate::setModuleNetworkAllowed(const QString &instance, bool allowed) {
    if (instance.isEmpty()) return false;
    const bool current = moduleAllowed_.value(instance, false);
    if (current == allowed) return true;
    moduleAllowed_.insert(instance, allowed);
    emit moduleNetworkChanged(instance);
    return true;
}

bool NetworkGate::moduleFileAllowed(const QString &instance) const {
    return moduleFileAllowed_.value(instance, false);
}

bool NetworkGate::setModuleFileAllowed(const QString &instance, bool allowed) {
    if (instance.isEmpty()) return false;
    if (moduleFileAllowed_.value(instance, false) == allowed) return true;
    moduleFileAllowed_.insert(instance, allowed);
    emit moduleFileChanged(instance);
    return true;
}

void NetworkGate::setInterfaceReady(bool ready) {
    if (interfaceReady_ == ready) return;
    interfaceReady_ = ready;
    emit stateChanged();
}

void NetworkGate::setModuleLinkReady(bool ready) {
    if (moduleLinkReady_ == ready) return;
    moduleLinkReady_ = ready;
    emit stateChanged();
}

void NetworkGate::setInternetReachable(bool reachable) {
    if (internetReachable_ == reachable) return;
    internetReachable_ = reachable;
    emit stateChanged();
}

bool NetworkGate::permits(Purpose purpose) const {
    if (!enabled_) return false;
    switch (purpose) {
    case Purpose::Browser: return browserAllowed_;
    case Purpose::Music: return musicAllowed_;
    case Purpose::Tv: return tvAllowed_;
    case Purpose::Weather: return weatherAllowed_;
    case Purpose::TimeSync: return timeSyncAllowed_;
    case Purpose::Updates: return updatesAllowed_;
    case Purpose::Other: return true;
    }
    return true;
}

bool NetworkGate::permits(const QString &purpose) const {
    const QString key = purpose.trimmed().toLower();
    const auto startsWith = [&key](const char *prefix) {
        return key == QLatin1String(prefix) || key.startsWith(QLatin1String(prefix) + QLatin1Char('.'));
    };
    if (startsWith("browser")) return permits(Purpose::Browser);
    if (startsWith("music")) return permits(Purpose::Music);
    if (startsWith("tv")) return permits(Purpose::Tv);
    if (startsWith("weather")) return permits(Purpose::Weather);
    if (startsWith("timesync")) return permits(Purpose::TimeSync);
    if (startsWith("updates")) return permits(Purpose::Updates);
    return permits(Purpose::Other);
}

bool NetworkGate::allow(Purpose purpose) {
    // 总开关关闭：一律拒绝，不分用途。
    if (!enabled_) {
        reason_ = QStringLiteral("network disabled: ") + purposeName(purpose);
        emit changed();
        return false;
    }
    // 总开关打开后按分功能开关判定。
    const bool allowed = permits(purpose);
    if (!allowed) {
        reason_ = QStringLiteral("feature disabled: ") + purposeName(purpose);
        emit changed();
        return false;
    }
    clearReason();
    return true;
}

bool NetworkGate::allow(const QString &purpose) {
    // 字符串入口：旧调用方与 QML 用。未知用途按 Other 处理。
    // "music.api" 这类带后缀的老写法仍然算到对应功能上。
    const QString key = purpose.trimmed().toLower();
    const auto startsWith = [&key](const char *prefix) {
        return key == QLatin1String(prefix) || key.startsWith(QLatin1String(prefix) + QLatin1Char('.'));
    };
    if (startsWith("browser")) return allow(Purpose::Browser);
    if (startsWith("music")) return allow(Purpose::Music);
    if (startsWith("tv")) return allow(Purpose::Tv);
    if (startsWith("weather")) return allow(Purpose::Weather);
    if (startsWith("timesync")) return allow(Purpose::TimeSync);
    if (startsWith("updates")) return allow(Purpose::Updates);
    return allow(Purpose::Other);
}

void NetworkGate::beginRequest() {
    ++inFlight_;
    emit changed();
}

void NetworkGate::endRequest() {
    if (inFlight_ > 0) --inFlight_;
    emit changed();
}

QVariantMap NetworkGate::snapshot() const {
    QVariantMap out;
    out.insert(QStringLiteral("enabled"), enabled_);
    out.insert(QStringLiteral("browser"), browserAllowed_);
    out.insert(QStringLiteral("music"), musicAllowed_);
    out.insert(QStringLiteral("tv"), tvAllowed_);
    out.insert(QStringLiteral("weather"), weatherAllowed_);
    out.insert(QStringLiteral("timesync"), timeSyncAllowed_);
    out.insert(QStringLiteral("updates"), updatesAllowed_);
    return out;
}

void NetworkGate::restore(const QVariantMap &values) {
    if (values.contains(QStringLiteral("enabled")))
        setEnabled(values.value(QStringLiteral("enabled")).toBool());
    if (values.contains(QStringLiteral("browser")))
        setBrowserAllowed(values.value(QStringLiteral("browser")).toBool());
    if (values.contains(QStringLiteral("music")))
        setMusicAllowed(values.value(QStringLiteral("music")).toBool());
    if (values.contains(QStringLiteral("tv")))
        setTvAllowed(values.value(QStringLiteral("tv")).toBool());
    if (values.contains(QStringLiteral("weather")))
        setWeatherAllowed(values.value(QStringLiteral("weather")).toBool());
    if (values.contains(QStringLiteral("timesync")))
        setTimeSyncAllowed(values.value(QStringLiteral("timesync")).toBool());
    if (values.contains(QStringLiteral("updates")))
        setUpdatesAllowed(values.value(QStringLiteral("updates")).toBool());
}
