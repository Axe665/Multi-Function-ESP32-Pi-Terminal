#include "net/NetPolicy.h"

#include "core/NetworkGate.h"
#include "net/NetChannels.h"

namespace {
QJsonObject channel(const NetworkGate &gate, NetworkGate::Purpose purpose) {
    return QJsonObject{{QStringLiteral("enabled"), gate.permits(purpose)}};
}
}  // namespace

namespace NetPolicy {

QJsonObject build(const NetworkGate &gate, const NetworkPolicy::Policy * /*policy*/)
{
    QJsonObject channels;
    channels.insert(QString::fromLatin1(NetChannels::Browser),
                    channel(gate, NetworkGate::Purpose::Browser));
    channels.insert(QString::fromLatin1(NetChannels::Music),
                    channel(gate, NetworkGate::Purpose::Music));
    channels.insert(QString::fromLatin1(NetChannels::Tv),
                    channel(gate, NetworkGate::Purpose::Tv));
    channels.insert(QString::fromLatin1(NetChannels::Qml),
                    channel(gate, NetworkGate::Purpose::Weather));
    channels.insert(QString::fromLatin1(NetChannels::TimeSync),
                    channel(gate, NetworkGate::Purpose::TimeSync));
    channels.insert(QString::fromLatin1(NetChannels::Updates),
                    channel(gate, NetworkGate::Purpose::Updates));
    return QJsonObject{{QStringLiteral("version"), NetChannels::PolicyVersion},
                       {QStringLiteral("channels"), channels}};
}

}  // namespace NetPolicy
