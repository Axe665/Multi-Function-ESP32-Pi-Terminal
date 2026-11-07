#pragma once

#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMessageAuthenticationCode>
#include <QtEndian>

// 外置文件 daemon 的 IPC：u32le 长度 + JSON。
// schema=orpi-file-v1；所有请求带同一会话 token。
namespace FileProtocol {

constexpr auto Schema = "orpi-file-v1";
constexpr int kMaxFrameBytes = 24 * 1024 * 1024;
constexpr int kMaxChunkBytes = 1024 * 1024;

// 能力令牌的规范化载荷。字段顺序固定，避免 JSON 对象顺序造成签名不一致。
inline QByteArray capabilityPayload(const QJsonObject &capability)
{
    return (capability.value(QStringLiteral("appId")).toString() + QLatin1Char('\n')
            + capability.value(QStringLiteral("appRoot")).toString() + QLatin1Char('\n')
            + capability.value(QStringLiteral("readRoot")).toString() + QLatin1Char('\n')
            + capability.value(QStringLiteral("writeRoot")).toString() + QLatin1Char('\n')
            + QString::number(capability.value(QStringLiteral("expires")).toInteger()))
        .toUtf8();
}

inline QByteArray signCapability(const QString &sessionToken, const QJsonObject &capability)
{
    return QMessageAuthenticationCode::hash(capabilityPayload(capability),
                                            sessionToken.toUtf8(),
                                            QCryptographicHash::Sha256)
        .toHex();
}

inline QByteArray encode(const QJsonObject &message)
{
    const QByteArray payload = QJsonDocument(message).toJson(QJsonDocument::Compact);
    QByteArray frame(4, Qt::Uninitialized);
    qToLittleEndian<quint32>(static_cast<quint32>(payload.size()), frame.data());
    frame.append(payload);
    return frame;
}

inline QJsonObject decode(const QByteArray &frame)
{
    if (frame.size() < 4 || frame.size() > kMaxFrameBytes + 4) return {};
    const quint32 declared = qFromLittleEndian<quint32>(frame.constData());
    if (static_cast<int>(declared) != frame.size() - 4) return {};
    QJsonParseError error{};
    const QJsonDocument document = QJsonDocument::fromJson(frame.mid(4), &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) return {};
    QJsonObject object = document.object();
    if (object.value(QStringLiteral("schema")).toString() != QLatin1String(Schema)) return {};
    return object;
}

inline QJsonObject request(quint64 id, const QString &op, const QJsonObject &body = {})
{
    QJsonObject object{{QStringLiteral("schema"), QLatin1String(Schema)},
                       {QStringLiteral("request_id"), static_cast<double>(id)},
                       {QStringLiteral("op"), op}};
    for (auto it = body.begin(); it != body.end(); ++it) object.insert(it.key(), it.value());
    return object;
}

inline QJsonObject response(quint64 id, bool ok, const QJsonObject &body = {},
                            const QString &error = {})
{
    QJsonObject object{{QStringLiteral("schema"), QLatin1String(Schema)},
                       {QStringLiteral("request_id"), static_cast<double>(id)},
                       {QStringLiteral("ok"), ok}};
    if (!error.isEmpty()) object.insert(QStringLiteral("error"), error);
    for (auto it = body.begin(); it != body.end(); ++it) object.insert(it.key(), it.value());
    return object;
}

}  // namespace FileProtocol
