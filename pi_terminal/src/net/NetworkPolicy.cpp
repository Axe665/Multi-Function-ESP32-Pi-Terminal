#include "net/NetworkPolicy.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>

namespace NetworkPolicy {
namespace {

const QStringList kApps{
    QStringLiteral("browser"), QStringLiteral("tv"), QStringLiteral("weather"),
    QStringLiteral("time"), QStringLiteral("music"), QStringLiteral("updates")};

bool hasOnlyKnownApps(const QJsonObject &apps, QString *error) {
    for (auto it = apps.begin(); it != apps.end(); ++it) {
        if (!kApps.contains(it.key())) {
            if (error) *error = QStringLiteral("unknown app: %1").arg(it.key());
            return false;
        }
    }
    return true;
}

bool parseEntry(const QJsonObject &entry, const QString &id, bool v2, bool *enabled,
                QString *error) {
    const QJsonValue enabledValue = entry.value(QStringLiteral("enabled"));
    if (enabledValue.isUndefined() || !enabledValue.isBool()) {
        if (error) *error = QStringLiteral("%1.enabled must be bool").arg(id);
        return false;
    }
    if (v2 && entry.contains(QStringLiteral("hosts"))) {
        if (error) *error = QStringLiteral("%1.hosts is not supported by policy v2").arg(id);
        return false;
    }
    *enabled = enabledValue.toBool();
    return true;
}

bool validModuleId(const QString &id) {
    static const QRegularExpression ok(
        QStringLiteral("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"));
    return ok.match(id).hasMatch();
}

}  // namespace

QStringList appIds() { return kApps; }

QString displayName(const QString &app) {
    if (app == QStringLiteral("browser")) return QStringLiteral("浏览器");
    if (app == QStringLiteral("tv")) return QStringLiteral("网络电视");
    if (app == QStringLiteral("weather")) return QStringLiteral("天气");
    if (app == QStringLiteral("time")) return QStringLiteral("网络校时");
    if (app == QStringLiteral("music")) return QStringLiteral("音乐");
    if (app == QStringLiteral("updates")) return QStringLiteral("更新下载");
    return app;
}

QString channelForApp(const QString &app) {
    if (app == QStringLiteral("weather")) return QStringLiteral("qml");
    if (app == QStringLiteral("time")) return QStringLiteral("timesync");
    return app;
}

QString purposeForApp(const QString &app) {
    if (app == QStringLiteral("time")) return QStringLiteral("timesync");
    return app;
}

Policy defaults() {
    Policy policy;
    for (const QString &id : kApps) policy.apps.append(AppPolicy{id, false});
    return policy;
}

bool parse(const QJsonObject &root, Policy *out, QString *error) {
    if (!out) return false;
    const QString schema = root.value(QStringLiteral("schema")).toString();
    const int version = root.value(QStringLiteral("version")).toInt(-1);
    const bool v2 = schema == QLatin1String(Schema) && version == Version;
    const bool v1 = schema == QLatin1String(LegacySchema) && version == LegacyVersion;
    if (!v2 && !v1) {
        if (error) *error = QStringLiteral("unsupported policy schema/version");
        return false;
    }

    const QJsonObject apps = root.value(QStringLiteral("apps")).toObject();
    if (apps.isEmpty()) {
        if (error) *error = QStringLiteral("apps object missing");
        return false;
    }
    if (!hasOnlyKnownApps(apps, error)) return false;

    Policy policy = defaults();
    for (AppPolicy &app : policy.apps) {
        if (!apps.contains(app.id)) continue;
        if (!apps.value(app.id).isObject()) {
            if (error) *error = QStringLiteral("%1 must be an object").arg(app.id);
            return false;
        }
        bool enabled = false;
        if (!parseEntry(apps.value(app.id).toObject(), app.id, v2, &enabled, error))
            return false;
        app.enabled = enabled;
    }

    if (v2 && root.contains(QStringLiteral("modules"))) {
        const QJsonValue modulesValue = root.value(QStringLiteral("modules"));
        if (!modulesValue.isObject()) {
            if (error) *error = QStringLiteral("modules must be an object");
            return false;
        }
        const QJsonObject modules = modulesValue.toObject();
        for (auto it = modules.begin(); it != modules.end(); ++it) {
            if (!validModuleId(it.key())) {
                if (error) *error = QStringLiteral("invalid module id: %1").arg(it.key());
                return false;
            }
            if (!it.value().isObject()) {
                if (error) *error = QStringLiteral("%1 must be an object").arg(it.key());
                return false;
            }
            const QJsonObject entry = it.value().toObject();
            policy.modules.append(ModulePolicy{
                it.key(),
                entry.value(QStringLiteral("network")).toBool(false),
                entry.value(QStringLiteral("file")).toBool(false)});
        }
    }
    *out = policy;
    return true;
}

QJsonObject toJson(const Policy &policy) {
    QJsonObject apps;
    for (const AppPolicy &app : policy.apps)
        apps.insert(app.id, QJsonObject{{QStringLiteral("enabled"), app.enabled}});
    QJsonObject modules;
    for (const ModulePolicy &module : policy.modules)
        modules.insert(module.id, QJsonObject{{QStringLiteral("network"), module.network},
                                              {QStringLiteral("file"), module.file}});
    return QJsonObject{{QStringLiteral("schema"), QLatin1String(Schema)},
                       {QStringLiteral("version"), Version},
                       {QStringLiteral("apps"), apps},
                       {QStringLiteral("modules"), modules}};
}

Policy loadFile(const QString &path, QString *error) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        if (error) *error = QStringLiteral("cannot read %1").arg(path);
        return defaults();
    }
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        if (error) *error = QStringLiteral("bad JSON: %1").arg(parseError.errorString());
        return defaults();
    }
    Policy policy;
    QString why;
    if (!parse(document.object(), &policy, &why)) {
        if (error) *error = why;
        return defaults();
    }
    if (error) error->clear();
    return policy;
}

bool writeFile(const QString &path, const QJsonObject &root, QString *error) {
    Policy policy;
    if (!parse(root, &policy, error)) return false;
    const QString directory = QFileInfo(path).absolutePath();
    if (!QDir().mkpath(directory)) {
        if (error) *error = QStringLiteral("cannot create %1").arg(directory);
        return false;
    }
    QSaveFile out(path);
    if (!out.open(QIODevice::WriteOnly)) {
        if (error) *error = QStringLiteral("cannot write %1").arg(path);
        return false;
    }
    out.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ReadGroup | QFile::ReadOther);
    const QByteArray bytes = QJsonDocument(root).toJson(QJsonDocument::Indented);
    if (out.write(bytes) != bytes.size()) {
        out.cancelWriting();
        if (error) *error = QStringLiteral("short write");
        return false;
    }
    if (!out.commit()) {
        if (error) *error = QStringLiteral("commit failed");
        return false;
    }
    QFile::setPermissions(path, QFile::ReadOwner | QFile::WriteOwner
                                | QFile::ReadGroup | QFile::ReadOther);
    return true;
}

}  // namespace NetworkPolicy
