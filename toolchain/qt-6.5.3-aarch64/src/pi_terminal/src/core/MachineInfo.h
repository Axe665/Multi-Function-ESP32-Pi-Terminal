#pragma once

#include <QObject>
#include <QVariantMap>
#include <QString>

// 「关于本机」的只读系统信息。
//
// 边界（与作者约定一致）：
// - 只读：不改 /etc/hostname、不改程序内部名称（applicationName / productName）、
//   不改登录页与托盘里作者写死的产品名。本机名称的编辑只落在应用设置里（QML 侧）。
// - 值是运行时从 /proc、/sys、statvfs 读到的真实数据；读不到就给空字符串，
//   由界面显示「未知」，不编造。
// - 每次打开页面调用 snapshot() 重新读，不缓存（内存/存储会变）。
class MachineInfo : public QObject
{
    Q_OBJECT

public:
    explicit MachineInfo(QObject *parent = nullptr);

    // cpuModel / cpuCores / cpuArch / gpuName / gpuDriver / gpuPciId /
    // nics[] / memTotalBytes / memAvailableBytes / diskTotalBytes /
    // diskAvailableBytes / kernelType / kernelVersion / buildDate
    Q_INVOKABLE QVariantMap snapshot() const;
};
