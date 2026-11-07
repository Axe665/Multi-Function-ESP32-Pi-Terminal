#pragma once

#include "TransportBase.h"
#include "protocol/pbr_aead.h"
#include "protocol/pbr_session.h"

#include <QElapsedTimer>
#include <QHash>
#include <QPair>
#include <QSerialPort>
#include <QTimer>
#include <QVector>

#include <functional>

class PogoControlTransport : public TransportBase {
    Q_OBJECT
public:
    explicit PogoControlTransport(QObject *parent = nullptr);
    bool open(const QString &device, qint32 baud = 115200);
    bool sendControl(const QJsonObject &event) override { return sendCommand(event); }
    void close() override;
    bool sendCommand(const QJsonObject &command, quint32 *sequenceOut = nullptr);
    bool sendRawControl(quint8 command, const QByteArray &payload);

    // 认证密钥（握手完成后由会话注入）。未设置时只接受明文 hello，
    // 收到 AEAD 信封一律拒绝 —— 而不是当作 JSON 扫描后静默丢弃。
    // §6.1：未认证期不接受业务/诊断帧。
    void setSessionKeys(const QByteArray &bridgeToPiKey32,
                        const QByteArray &piToBridgeKey32,
                        const QByteArray &noncePrefix4,
                        const QByteArray &piKeyId);
    // 已认证状态。只有握手成功后才会置 true。
    bool authenticated() const { return authenticated_; }
    void setAuthenticated(bool value) { authenticated_ = value; }

    // PBR 握手所需的宿主能力。用回调注入，避免传输层依赖 terminal_security
    // 的 mbedtls / TrustStore 具体类型。
    struct HandshakeContext {
        // 按线上 1 字节 key_id 取候选桥板： (bridgeId, 65B publicKey)。
        std::function<QVector<QPair<QString, QByteArray>>(quint8)> candidates;
        std::function<QByteArray()> piPublicKey;      // 65B
        std::function<quint8()> piKeyId;
        // 用完整公钥验 SHA-256(T2/T3) 的 r‖s 签名。
        std::function<bool(const QByteArray &pub, const QByteArray &hash,
                           const QByteArray &sig)> verify;
        // 对 SHA-256(T3) 签名；输出 64B r‖s。
        std::function<bool(const QByteArray &hash, QByteArray *sig)> sign;
    };
    void setHandshakeContext(const HandshakeContext &context);
    bool handshakeActive() const { return hsActive_; }
    // 管理员撤销某个桥板身份后，宿主调用这里立即断开匹配会话并清密钥。
    void abortBridge(const QString &bridgeId);
private slots:
    void readAvailable();
    void handshakeTimeout();
private:
    bool sendCommandInternal(const QJsonObject &command, quint32 *sequenceOut,
                             bool handshakeMessage);
    void startHandshake();
    void restartHandshake();
    void sendHandshake(const QJsonObject &message);
    void handleHandshake(const QJsonObject &event);
    void failHandshake(const QString &reason);

    QSerialPort serial_;
    QByteArray buffer_;
    quint32 sequence_ = 1;
    quint32 lastReceiveSequence_ = 0;
    bool haveReceiveSequence_ = false;
    QTimer reconnect_, frameTimeout_;
    QString device_;
    qint32 baud_ = 115200;
    bool enabled_ = false;

    // §5 / §6.2：按方向维护的接收序号；只在 tag 通过后推进。
    QByteArray bridgeToPiKey_;
    QByteArray piToBridgeKey_;
    QByteArray noncePrefix_;
    quint8 piKeyId_ = 0;
    quint64 piAuthSeq_ = 1;
    // 事件 TTL 的对端时钟基准（只从 hello_ok.uptime_ms 设一次）。
    QElapsedTimer pbrClock_;
    qint64 ttlOffsetMs_ = 0;
    bool ttlOffsetValid_ = false;
    bool authenticated_ = false;
    ReplayGuard replay_;
    EventDedup dedup_;

    // PBR 握手状态机（§3.1–§3.7）。临时私钥只在一次握手中有效。
    HandshakeContext hsContext_;
    bool hsActive_ = false;
    int hsStage_ = 0;          // 1=等 hello_resp，2=等 hello_ok
    int hsRetries_ = 0;
    QByteArray hsPriv_;
    QByteArray hsMsg1_;
    QByteArray hsMsg2_;
    QByteArray hsT2_;
    QByteArray hsT3_;
    QByteArray hsHandshakeKey_;
    QJsonObject hsLastMessage_;
    QByteArray hsPiPub_;
    quint8 hsPiKeyId_ = 0;
    quint8 hsBridgeKeyId_ = 0;
    // 握手验签通过时从 TrustStore 候选里记下的 bridge_id（§6.4 逐字节比对的依据）。
    QString hsBridgeId_;
    QByteArray hsBridgePubEph_;
    QByteArray hsBridgeToPi_;
    QByteArray hsPiToBridge_;
    QByteArray hsSessionId_;
    QByteArray hsNoncePrefix_;
    QByteArray hsBridgeBootId4_;
    QByteArray bridgeBootIdHex_;
    QTimer hsTimer_;
};
