#include "net/PublicNetwork.h"

#include <QHostInfo>

namespace PublicNetwork {

bool isPublicAddress(const QHostAddress &address)
{
    if (address.isNull() || address.isLoopback() || address.isLinkLocal()
        || address.isSiteLocal() || address.isUniqueLocalUnicast()
        || address.isMulticast() || address.isBroadcast())
        return false;
    if (address.protocol() == QAbstractSocket::IPv4Protocol) {
        const quint32 ip = address.toIPv4Address();
        if ((ip >> 24) == 0 || (ip >> 24) == 10 || (ip >> 24) == 127
            || (ip & 0xffc00000U) == 0x64400000U
            || (ip & 0xffff0000U) == 0xa9fe0000U
            || (ip & 0xfff00000U) == 0xac100000U
            || (ip & 0xffffff00U) == 0xc0000000U
            || (ip & 0xffffff00U) == 0xc0000200U
            || (ip & 0xffff0000U) == 0xc0a80000U
            || (ip & 0xfffe0000U) == 0xc6120000U
            || (ip & 0xffffff00U) == 0xc6336400U
            || (ip & 0xffffff00U) == 0xcb007100U
            || (ip & 0xf0000000U) == 0xe0000000U
            || (ip & 0xf0000000U) == 0xf0000000U)
            return false;
    }
    return true;
}

bool isPublicHost(const QString &host)
{
    const QString normalized = host.trimmed().toLower();
    if (normalized.isEmpty() || normalized == QLatin1String("localhost"))
        return false;
    QHostAddress literal;
    if (literal.setAddress(normalized))
        return isPublicAddress(literal);

    const QHostInfo info = QHostInfo::fromName(normalized);
    if (info.error() != QHostInfo::NoError || info.addresses().isEmpty())
        return false;
    for (const QHostAddress &address : info.addresses())
        if (!isPublicAddress(address)) return false;
    return true;
}

}  // namespace PublicNetwork
