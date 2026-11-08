#include "core/DeveloperProbe.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QStandardPaths>
#include <QSysInfo>

DeveloperProbe::DeveloperProbe(QObject *parent) : QObject(parent) {}

QString DeveloperProbe::runtimeJson() const
{
    QJsonObject obj;
    obj.insert(QStringLiteral("appVersion"), QCoreApplication::applicationVersion());
    obj.insert(QStringLiteral("appName"), QCoreApplication::applicationName());
    obj.insert(QStringLiteral("organization"), QCoreApplication::organizationName());
    obj.insert(QStringLiteral("qtRuntime"), QString::fromLatin1(qVersion()));
    obj.insert(QStringLiteral("qtCompiled"), QString::fromLatin1(QT_VERSION_STR));
    obj.insert(QStringLiteral("cpuArchitecture"), QSysInfo::currentCpuArchitecture());
    obj.insert(QStringLiteral("kernelType"), QSysInfo::kernelType());
    obj.insert(QStringLiteral("kernelVersion"), QSysInfo::kernelVersion());
    obj.insert(QStringLiteral("productType"), QSysInfo::productType());
    obj.insert(QStringLiteral("productVersion"), QSysInfo::productVersion());
    obj.insert(QStringLiteral("prettyProductName"), QSysInfo::prettyProductName());
    obj.insert(QStringLiteral("platform"), QGuiApplication::platformName());
    obj.insert(QStringLiteral("locale"), QLocale::system().name());
    obj.insert(QStringLiteral("pid"), QString::number(QCoreApplication::applicationPid()));
    return QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Indented));
}

QVariantList DeveloperProbe::moduleCache(const QString &root) const
{
    QVariantList list;
    QDir dir(root);
    if (!dir.exists()) return list;
    const QFileInfoList entries = dir.entryInfoList(
        QDir::Dirs | QDir::Files | QDir::NoDotAndDotDot, QDir::Time);
    for (const QFileInfo &info : entries) {
        QVariantMap item;
        item.insert(QStringLiteral("name"), info.fileName());
        item.insert(QStringLiteral("kind"), info.isDir() ? QStringLiteral("dir") : QStringLiteral("file"));
        item.insert(QStringLiteral("size"), info.size());
        item.insert(QStringLiteral("modified"), info.lastModified().toString(Qt::ISODate));
        item.insert(QStringLiteral("path"), info.absoluteFilePath());
        list.append(item);
    }
    return list;
}

bool DeveloperProbe::copyText(const QString &text) const
{
    if (!QGuiApplication::clipboard()) return false;
    QGuiApplication::clipboard()->setText(text);
    return true;
}

QString DeveloperProbe::exportText(const QString &content) const
{
    QString dir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    if (dir.isEmpty()) dir = QStandardPaths::writableLocation(QStandardPaths::HomeLocation);
    if (dir.isEmpty()) return QStringLiteral("ERROR: no writable location");
    QDir().mkpath(dir);
    const QString name = QStringLiteral("developer-snapshot-%1.txt")
                             .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss")));
    const QString path = QDir(dir).filePath(name);
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        return QStringLiteral("ERROR: ") + file.errorString();
    }
    file.write(content.toUtf8());
    file.close();
    return path;
}
