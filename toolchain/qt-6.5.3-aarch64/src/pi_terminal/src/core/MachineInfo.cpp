#include "core/MachineInfo.h"

#include <QDir>
#include <QFile>
#include <QNetworkInterface>
#include <QRegularExpression>
#include <QSysInfo>
#include <QThread>

#include <sys/statvfs.h>

#include "build-info.h"

namespace {

// ARM 板子通常没有 /proc/cpuinfo 的 model name，设备树里的 model 更接近
// 使用者认知的「处理器/板卡型号」；两个位置各发行版不同，都试一遍。
QString deviceTreeModel()
{
    const QStringList candidates{QStringLiteral("/proc/device-tree/model"),
                                 QStringLiteral("/sys/firmware/devicetree/base/model")};
    for (const QString &path : candidates) {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) continue;
        QString text = QString::fromUtf8(file.readAll());
        text.remove(QChar('\0'));
        text = text.trimmed();
        if (!text.isEmpty()) return text;
    }
    return {};
}

QString cpuModel()
{
    QFile file(QStringLiteral("/proc/cpuinfo"));
    if (!file.open(QIODevice::ReadOnly)) return deviceTreeModel();
    const QString text = QString::fromUtf8(file.readAll());

    // x86 与部分 ARM 内核给 model name；老 ARM 内核给 Hardware / Processor。
    static const QRegularExpression modelName(
        QStringLiteral("^model name\\s*:\\s*(.+)$"),
        QRegularExpression::MultilineOption | QRegularExpression::CaseInsensitiveOption);
    QRegularExpressionMatch match = modelName.match(text);
    if (match.hasMatch()) return match.captured(1).trimmed();

    static const QRegularExpression fallback(
        QStringLiteral("^(?:Hardware|Processor|CPU model|Model)\\s*:\\s*(.+)$"),
        QRegularExpression::MultilineOption | QRegularExpression::CaseInsensitiveOption);
    match = fallback.match(text);
    if (match.hasMatch()) return match.captured(1).trimmed();

    return deviceTreeModel();
}

// /proc/meminfo 的单位是 kB（1024 字节），字段名后面可能跟空格。
qint64 meminfoKilobytes(const QString &text, const QString &field)
{
    const QRegularExpression pattern(
        QStringLiteral("^%1:\\s*(\\d+)\\s*kB").arg(QRegularExpression::escape(field)),
        QRegularExpression::MultilineOption);
    const QRegularExpressionMatch match = pattern.match(text);
    return match.hasMatch() ? match.captured(1).toLongLong() * 1024 : 0;
}

QPair<qint64, qint64> memoryBytes()
{
    QFile file(QStringLiteral("/proc/meminfo"));
    if (!file.open(QIODevice::ReadOnly)) return {0, 0};
    const QString text = QString::fromUtf8(file.readAll());
    return {meminfoKilobytes(text, QStringLiteral("MemTotal")),
            meminfoKilobytes(text, QStringLiteral("MemAvailable"))};
}

QPair<qint64, qint64> diskBytes(const QString &path)
{
    struct statvfs info {};
    if (::statvfs(path.toUtf8().constData(), &info) != 0) return {0, 0};
    const qint64 blockSize = static_cast<qint64>(info.f_frsize > 0 ? info.f_frsize : info.f_bsize);
    return {static_cast<qint64>(info.f_blocks) * blockSize,
            static_cast<qint64>(info.f_bavail) * blockSize};
}


// ---- GPU：/sys/class/drm/card*/device/uevent 给 DRIVER 与 PCI_ID；
// pci.ids 在多数桌面发行版上都有，用它把 1002:1900 解成厂商+型号。
QString pciIdsName(const QString &pciId)
{
    const QStringList parts = pciId.split(QLatin1Char(':'));
    if (parts.size() != 2) return {};
    bool vendorOk = false;
    bool deviceOk = false;
    const uint vendorId = parts.at(0).toUInt(&vendorOk, 16);
    const uint deviceId = parts.at(1).toUInt(&deviceOk, 16);
    if (!vendorOk || !deviceOk) return {};

    const QStringList candidates{QStringLiteral("/usr/share/misc/pci.ids"),
                                 QStringLiteral("/usr/share/hwdata/pci.ids"),
                                 QStringLiteral("/var/lib/pciutils/pci.ids")};
    QFile file;
    for (const QString &path : candidates) {
        file.setFileName(path);
        if (file.open(QIODevice::ReadOnly)) break;
    }
    if (!file.isOpen()) return {};

    uint currentVendor = 0xffffffffu;
    QString vendorName;
    QString deviceName;
    while (!file.atEnd()) {
        // 不能 trimmed()：设备行的判定依赖行首的制表符缩进。
        QString line = QString::fromUtf8(file.readLine());
        while (line.endsWith(QLatin1Char('\n')) || line.endsWith(QLatin1Char('\r')))
            line.chop(1);
        if (line.isEmpty() || line.startsWith(QLatin1Char('#'))) continue;
        // 顶层：4 位十六进制厂商号 + 两个空格 + 名称。
        if (!line.startsWith(QLatin1Char('\t'))) {
            if (line.size() < 6) continue;
            bool ok = false;
            currentVendor = line.left(4).toUInt(&ok, 16);
            vendorName = ok ? line.mid(6).trimmed() : QString();
            continue;
        }
        // 设备行是一层缩进；子系统行是两层，跳过。
        if (line.startsWith(QLatin1String("\t\t")) || line.size() < 7) continue;
        if (currentVendor != vendorId) continue;
        bool ok = false;
        const uint id = line.mid(1, 4).toUInt(&ok, 16);
        if (!ok || id != deviceId) continue;
        deviceName = line.mid(6).trimmed();
        break;
    }
    if (vendorName.isEmpty() && deviceName.isEmpty()) return {};
    return vendorName + (deviceName.isEmpty() ? QString() : QLatin1Char(' ') + deviceName);
}

QVariantMap gpuInfo()
{
    QVariantMap result;
    const QDir drm(QStringLiteral("/sys/class/drm"));
    const QRegularExpression cardPattern(QStringLiteral("^card\\d+$"));
    const QStringList cards = drm.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const QString &card : cards) {
        if (!cardPattern.match(card).hasMatch()) continue;
        const QString base = drm.filePath(card + QStringLiteral("/device/"));
        QFile uevent(base + QStringLiteral("uevent"));
        if (!uevent.open(QIODevice::ReadOnly)) continue;
        const QString text = QString::fromUtf8(uevent.readAll());
        QString driver;
        QString pciId;
        for (const QString &line : text.split(QLatin1Char('\n'))) {
            if (line.startsWith(QLatin1String("DRIVER="))) driver = line.mid(7).trimmed();
            else if (line.startsWith(QLatin1String("PCI_ID="))) pciId = line.mid(7).trimmed();
        }
        if (driver.isEmpty() && pciId.isEmpty()) continue;
        result.insert(QStringLiteral("gpuDriver"), driver);
        result.insert(QStringLiteral("gpuPciId"), pciId);
        result.insert(QStringLiteral("gpuName"), pciIdsName(pciId));
        break;
    }
    if (result.isEmpty()) {
        // ARM 板子通常没有 PCI：退到设备树里的 compatible / 驱动目录名。
        const QStringList compatCandidates{
            QStringLiteral("/sys/class/drm/card0/device/of_node/compatible"),
            QStringLiteral("/sys/firmware/devicetree/base/gpu/compatible")};
        for (const QString &path : compatCandidates) {
            QFile file(path);
            if (!file.open(QIODevice::ReadOnly)) continue;
            QString text = QString::fromUtf8(file.readAll());
            text.remove(QChar('\0'));
            text = text.trimmed();
            if (!text.isEmpty()) {
                result.insert(QStringLiteral("gpuName"), text);
                break;
            }
        }
    }
    return result;
}

// ---- 网卡：只留物理接口，过滤 lo / docker / veth / 网桥等虚拟设备。
bool isVirtualInterface(const QString &name, QNetworkInterface::InterfaceType type)
{
    if (type == QNetworkInterface::Loopback || type == QNetworkInterface::Virtual) return true;
    static const QStringList prefixes{QStringLiteral("docker"), QStringLiteral("veth"),
                                      QStringLiteral("br-"), QStringLiteral("virbr"),
                                      QStringLiteral("tun"), QStringLiteral("tap"),
                                      QStringLiteral("lo")};
    for (const QString &prefix : prefixes)
        if (name.startsWith(prefix)) return true;
    return false;
}

QVariantList networkInterfaces()
{
    QVariantList list;
    for (const QNetworkInterface &iface : QNetworkInterface::allInterfaces()) {
        if (isVirtualInterface(iface.name(), iface.type())) continue;
        QStringList ips;
        for (const QNetworkAddressEntry &entry : iface.addressEntries()) {
            if (entry.ip().protocol() == QAbstractSocket::IPv4Protocol)
                ips.append(entry.ip().toString());
        }
        QVariantMap item;
        item.insert(QStringLiteral("name"), iface.name());
        item.insert(QStringLiteral("kind"),
                    iface.type() == QNetworkInterface::Wifi ? QStringLiteral("wifi")
                                                            : QStringLiteral("ethernet"));
        item.insert(QStringLiteral("mac"), iface.hardwareAddress());
        item.insert(QStringLiteral("addresses"), ips);
        item.insert(QStringLiteral("up"), (iface.flags() & QNetworkInterface::IsUp) != 0);
        list.append(item);
    }
    return list;
}

} // namespace

MachineInfo::MachineInfo(QObject *parent) : QObject(parent) {}

QVariantMap MachineInfo::snapshot() const
{
    QVariantMap info;
    info.insert(QStringLiteral("cpuModel"), cpuModel());
    info.insert(QStringLiteral("cpuCores"), QThread::idealThreadCount());
    info.insert(QStringLiteral("cpuArch"), QSysInfo::currentCpuArchitecture());

    const QVariantMap gpu = gpuInfo();
    info.insert(QStringLiteral("gpuName"), gpu.value(QStringLiteral("gpuName")));
    info.insert(QStringLiteral("gpuDriver"), gpu.value(QStringLiteral("gpuDriver")));
    info.insert(QStringLiteral("gpuPciId"), gpu.value(QStringLiteral("gpuPciId")));

    info.insert(QStringLiteral("nics"), networkInterfaces());

    const auto memory = memoryBytes();
    info.insert(QStringLiteral("memTotalBytes"), memory.first);
    info.insert(QStringLiteral("memAvailableBytes"), memory.second);

    const auto disk = diskBytes(QStringLiteral("/"));
    info.insert(QStringLiteral("diskTotalBytes"), disk.first);
    info.insert(QStringLiteral("diskAvailableBytes"), disk.second);

    info.insert(QStringLiteral("kernelType"), QSysInfo::kernelType());
    info.insert(QStringLiteral("kernelVersion"), QSysInfo::kernelVersion());
    info.insert(QStringLiteral("buildDate"), QStringLiteral(ORANGE_PI_BUILD_DATE));
    return info;
}
