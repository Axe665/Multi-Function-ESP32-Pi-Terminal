#include "PogoControlTransport.h"
#include "../protocol/pibridge_protocol.h"
#include "../protocol/control_event.h"
#include "../protocol/pbr_handshake.h"
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QRandomGenerator>

PogoControlTransport::PogoControlTransport(QObject *parent) : TransportBase(parent) {
    pbrClock_.start();
    reconnect_.setInterval(1000);
    connect(&reconnect_, &QTimer::timeout, this, [this] { if (enabled_ && !serial_.isOpen()) open(device_, baud_); });
    frameTimeout_.setInterval(1000); frameTimeout_.setSingleShot(true);
    connect(&frameTimeout_, &QTimer::timeout, this, [this] { buffer_.clear(); emit error("PBR1 partial-frame timeout"); });
    hsTimer_.setSingleShot(true);
    hsTimer_.setInterval(500);
    connect(&hsTimer_, &QTimer::timeout, this, &PogoControlTransport::handshakeTimeout);
    connect(&serial_, &QSerialPort::readyRead, this, &PogoControlTransport::readAvailable);
    connect(&serial_, &QSerialPort::errorOccurred, this, [this](QSerialPort::SerialPortError e) {
        if (e != QSerialPort::NoError) {
            emit error(serial_.errorString());
            if (e == QSerialPort::ResourceError || e == QSerialPort::DeviceNotFoundError || e == QSerialPort::ReadError) {
                // Qt can emit errorOccurred synchronously from open(). Closing
                // inside that callback corrupts the ongoing open attempt.
                QTimer::singleShot(0, this, [this] {
                    if (serial_.isOpen()) serial_.close();
                    frameTimeout_.stop(); buffer_.clear();
                    emit disconnected("control bridge lost");
                });
            }
        }
    });
}

bool PogoControlTransport::open(const QString &device, qint32 baud) {
    device_ = device; baud_ = baud; enabled_ = true; reconnect_.start();
    if (serial_.isOpen()) serial_.close();
    // Drop a previous failed-open error before configuring/reopening; do not
    // synchronously close the port from Qt's open() error callbacks.
    serial_.clearError(); frameTimeout_.stop();
    buffer_.clear(); haveReceiveSequence_ = false; lastReceiveSequence_ = 0; serial_.setReadBufferSize(8192);
    serial_.setPortName(device);
    serial_.setBaudRate(baud);
    serial_.setDataBits(QSerialPort::Data8);
    serial_.setParity(QSerialPort::NoParity);
    serial_.setStopBits(QSerialPort::OneStop);
    serial_.setFlowControl(QSerialPort::NoFlowControl);
    if (!serial_.open(QIODevice::ReadWrite)) {
        qWarning().noquote() << "PBR1 serial open failed:" << device << serial_.errorString();
        emit error(serial_.errorString()); return false;
    }
    // CH343 的 DTR/RTS 常被板子接到 EN/GPIO0（自动下载电路）。Qt 打开串口
    // 时默认拉起这两根线，会把 ESP32 按在复位/下载态，表现为"串口能开但
    // 一个字节都不回"。显式释放，让桥板正常跑固件。
    serial_.setDataTerminalReady(false);
    serial_.setRequestToSend(false);
    emit connected();
    // 串口一打开就发起 PBR 握手（§3.7）；没有宿主上下文时保持旧行为。
    startHandshake();
    return true;
}

void PogoControlTransport::close() {
    enabled_ = false; reconnect_.stop(); frameTimeout_.stop(); buffer_.clear();
    hsTimer_.stop(); hsActive_ = false; hsStage_ = 0; hsRetries_ = 0;
    hsBridgeId_.clear(); bridgeBootIdHex_.clear();
    hsBridgeToPi_.fill('\0'); hsBridgeToPi_.clear();
    hsPiToBridge_.fill('\0'); hsPiToBridge_.clear();
    hsBridgeBootId4_.clear();
    if (!hsPriv_.isEmpty()) { hsPriv_.fill('\0'); hsPriv_.clear(); }
    hsHandshakeKey_.fill('\0'); hsHandshakeKey_.clear();
    authenticated_ = false;
    bridgeToPiKey_.fill('\0'); bridgeToPiKey_.clear();
    piToBridgeKey_.fill('\0'); piToBridgeKey_.clear();
    noncePrefix_.clear();
    piAuthSeq_ = 1;
    ttlOffsetValid_ = false; ttlOffsetMs_ = 0;
    bridgeBootIdHex_.clear();
    if (serial_.isOpen()) serial_.close();
    emit disconnected(QStringLiteral("serial closed"));
}

bool PogoControlTransport::sendCommand(const QJsonObject &command, quint32 *sequenceOut) {
    return sendCommandInternal(command, sequenceOut, false);
}

bool PogoControlTransport::sendCommandInternal(const QJsonObject &command,
                                                quint32 *sequenceOut, bool handshakeMessage) {
    if (!serial_.isOpen()) return false;
    if (!handshakeMessage) {
        if (hsActive_) {
            emit error(QStringLiteral("SESSION_REHANDSHAKING"));
            return false;
        }
        if (!authenticated_) {
            emit error(QStringLiteral("SESSION_UNAUTHENTICATED"));
            return false;
        }
        if (piToBridgeKey_.size() != 32) return false;
        // 禁止 Pi→桥计数器环绕：余量不足时先重新握手，命令明确失败而不是回绕。
        if (piAuthSeq_ >= (0xffffffffffffffffULL - (1ULL << 20))) {
            restartHandshake();
            emit error(QStringLiteral("SESSION_REHANDSHAKING"));
            return false;
        }
    }
    QByteArray payload = QJsonDocument(command).toJson(QJsonDocument::Compact);
    if (authenticated_ && !handshakeMessage) {
        PbrAead::Result result = PbrAead::Result::Malformed;
        payload = PbrAead::seal(payload, piToBridgeKey_, noncePrefix_, piAuthSeq_,
                                piKeyId_, quint8(PiBridge::ControlCommand), 0, &result);
        if (payload.isEmpty() || result != PbrAead::Result::Ok) {
            qWarning() << "PBR command: AEAD seal failed" << int(result);
            return false;
        }
    }
    const quint32 sequence = sequence_++;
    const auto wire = PiBridge::encode(0, PiBridge::ControlCommand, sequence, payload);
    const bool sent = !wire.isEmpty() && serial_.bytesToWrite() < 8192 && serial_.write(wire) == wire.size();
    if (sent) {
        if (sequenceOut) *sequenceOut = sequence;
        if (authenticated_ && !handshakeMessage) ++piAuthSeq_;
    }
    return sent;
}

bool PogoControlTransport::sendRawControl(quint8 command, const QByteArray &payload) {
    QJsonObject object{{"command", int(command)}, {"payload_hex", QString::fromLatin1(payload.toHex())}};
    return sendCommand(object);
}

void PogoControlTransport::setSessionKeys(const QByteArray &bridgeToPiKey32,
                                          const QByteArray &piToBridgeKey32,
                                          const QByteArray &noncePrefix4,
                                          const QByteArray &piKeyId) {
    bridgeToPiKey_ = bridgeToPiKey32;
    piToBridgeKey_ = piToBridgeKey32;
    noncePrefix_ = noncePrefix4;
    piKeyId_ = piKeyId.isEmpty() ? 0 : quint8(piKeyId.at(0));
    piAuthSeq_ = 1;
    replay_.reset();
    dedup_.clear();
}

void PogoControlTransport::readAvailable() {
    buffer_.append(serial_.readAll());
    if (buffer_.size() > 16384) { buffer_.clear(); emit error("PBR1 receive limit"); return; }
    quint8 direction = 0; PiBridge::Kind kind{}; quint32 sequence = 0; QByteArray payload;
    while (PiBridge::decode(buffer_, direction, kind, sequence, payload)) {
        if (direction != 1) continue;
        if (haveReceiveSequence_) {
            const quint32 distance = sequence - lastReceiveSequence_;
            if (distance == 0 || distance >= 0x80000000u) continue;
        }
        lastReceiveSequence_ = sequence; haveReceiveSequence_ = true;
        if (kind == PiBridge::ControlEvent) {
            // 握手期：hello_resp/hello_finish 是明文 JSON，hello_ok 是
            // k_handshake 加密的信封；都必须在 authenticated_ 之前处理。
            if (hsActive_ && !authenticated_) {
                if (hsStage_ == 2) {
                    PbrAead::Envelope envelope;
                    PbrAead::Aad aad;
                    PbrAead::Result aeadResult = PbrAead::Result::Malformed;
                    if (PbrAead::parseEnvelope(payload, &envelope, nullptr, &aad, &aeadResult)
                        && envelope.keyId == hsBridgeKeyId_) {
                        aad.kind = quint8(kind);
                        aad.dir = quint8(direction);
                        const QByteArray opened = PbrAead::open(payload, hsHandshakeKey_, aad, &aeadResult);
                        if (aeadResult == PbrAead::Result::Ok) {
                            handleHandshake(PiBridge::event(opened));
                            // hello_ok 是握手最后一条；不要再用会话密钥把它当业务帧处理。
                            if (authenticated_) continue;
                        }
                    }
                }
                const QJsonObject handshakeEvent = PiBridge::event(payload);
                if (handshakeEvent.value(QStringLiteral("schema")).toString()
                    == QStringLiteral("pbr-handshake-v1")) {
                    handleHandshake(handshakeEvent);
                    continue;
                }
            }
            // §6.2 的拒绝顺序在这里落地：
            //   1. 帧头合法性     — PiBridge::decode 已完成
            //   2. CRC16          — PiBridge::decode 已完成
            //   3. env_ver/key_id — parseEnvelope
            //   4. tag            — **先验**，通过后序号才可信
            //   5. auth_seq 单调性
            //   6. JSON + schema 校验
            //   7. event_id 去重 + TTL
            // 顺序不能调换：先查序号会让未认证的伪造帧推高窗口（DoS）。
            QByteArray plaintext = payload;

            if (authenticated_) {
                if (bridgeToPiKey_.size() != 32) continue;

                PbrAead::Envelope envelope;
                PbrAead::Aad aad;
                PbrAead::Result aeadResult = PbrAead::Result::Malformed;
                if (!PbrAead::parseEnvelope(payload, &envelope, nullptr, &aad, &aeadResult)) {
                    // 第 3 步失败：整帧丢弃、不回应（不给攻击者 oracle）。
                    qWarning() << "PBR event: bad envelope" << int(aeadResult);
                    continue;
                }
                aad.kind = quint8(kind);
                aad.dir = quint8(direction);
                // 第 4 步：tag 必须先验，且用信封自己声明的 auth_seq。
                plaintext = PbrAead::open(payload, bridgeToPiKey_, aad, &aeadResult);
                if (aeadResult != PbrAead::Result::Ok) {
                    qWarning() << "PBR event: AEAD failed" << int(aeadResult);
                    continue;
                }

                // 第 5 步：tag 通过后序号才可信。
                const auto seqVerdict = replay_.check(envelope.authSeq);
                if (seqVerdict != ReplayGuard::Verdict::Accepted) {
                    // 已认证对端才回 REPLAY；未认证期不回。
                    emit controlEvent(QJsonObject{{"event", "replay"},
                                                  {"auth_seq", double(envelope.authSeq)}});
                    continue;
                }
                replay_.advance(envelope.authSeq);
                if (replay_.needsRehandshake()) {
                    qWarning() << "PBR auth_seq nearing wrap; restarting handshake";
                    restartHandshake();
                    continue;
                }
            }
            // 未认证期（authenticated_ == false）只允许握手帧；业务事件
            // 一律不解析、不分派，避免留一条未认证的业务入口（§6.1）。

            // 未认证期业务/诊断帧一律丢弃；握手帧已在上面单独处理。
            if (!authenticated_) continue;

            // 第 6 步：认证通过后才解析 JSON。
            if (!PbrControl::payloadAcceptable(plaintext)) continue;
            auto event = PiBridge::event(plaintext);
            if (event.isEmpty()) continue;

            // §3.5：hello_resp 里的 boot_id4 必须与事件 boot_id 的前 8 个 hex 相等。
            const QString bootId = event.value(QStringLiteral("boot_id")).toString();
            if (bootId.size() < 8
                || bootId.left(8) != QString::fromLatin1(bridgeBootIdHex_)) {
                qWarning().noquote() << "PBR event: boot_id does not match handshake";
                continue;
            }
            // §6.4：ACK 没有 ttl/event_id；其余事件必须按对端单调时钟判龄。
            const QString eventName = event.value(QStringLiteral("event")).toString();
            if (eventName != QLatin1String("ack")) {
                const auto ttlVerdict = EventTtl::evaluateWithOffset(
                    qint64(event.value(QStringLiteral("ttl_ms")).toDouble()),
                    qint64(event.value(QStringLiteral("uptime_ms")).toDouble()),
                    pbrClock_.elapsed(), ttlOffsetMs_, ttlOffsetValid_);
                if (ttlVerdict != EventTtl::Verdict::Ok) {
                    const qint64 senderMs = qint64(event.value(QStringLiteral("uptime_ms")).toDouble());
                    const qint64 ageMs = senderMs - (pbrClock_.elapsed() + ttlOffsetMs_);
                    // 诊断：把三个时钟原样打出来，避免"过期"只剩一个数字。
                    qWarning().noquote() << "PBR event: EVENT_EXPIRED verdict" << int(ttlVerdict)
                                         << "event=" << eventName
                                         << "ttl_ms=" << qint64(event.value(QStringLiteral("ttl_ms")).toDouble())
                                         << "sender_ms=" << senderMs
                                         << "receiver_ms=" << pbrClock_.elapsed()
                                         << "offset_ms=" << ttlOffsetMs_
                                         << "age_ms=" << ageMs;
                    // 对端重启：boot_id 变了说明是新会话，旧密钥下的所有事件都会
                    // 判过期，静默丢弃会让模块永远接不进来。这里主动重握手。
                    const QString bootId = event.value(QStringLiteral("boot_id")).toString();
                    if (!bootId.isEmpty() && !bridgeBootIdHex_.isEmpty()
                        && bootId.left(8) != QString::fromLatin1(bridgeBootIdHex_)) {
                        qWarning().noquote() << "PBR event: boot_id changed, restarting handshake";
                        restartHandshake();
                        return;
                    }
                    continue;
                }
            }

            // §6.4：bridge_id 必须与已认证身份逐字节相等。
            // 放在 schema 校验之后、去重之前：先确认字段形状，再确认身份归属。
            if (!PbrControl::bridgeIdMatches(hsBridgeId_, event.value("bridge_id").toString())) {
                qWarning().noquote() << "PBR event: bridge_id does not match authenticated identity";
                continue;
            }

            // 第 7 步：event_id 去重（键含 bridge/boot/session/event）。
            const QString dedupKey = QStringLiteral("%1|%2|%3|%4")
                .arg(event.value("bridge_id").toString(),
                     event.value("boot_id").toString(),
                     event.value("session_id").toString(),
                     QString::number(event.value("event_id").toDouble(), 'g', 20));
            if (!event.value("event_id").isUndefined()) {
                const auto verdict = dedup_.check(dedupKey);
                if (verdict == EventDedup::Verdict::Duplicate) {
                    // 重复事件：回 duplicate，不重复分派。
                    emit controlEvent(QJsonObject{{"event", "ack"},
                                                  {"ack_event_id", event.value("event_id")},
                                                  {"result", "duplicate"}});
                    continue;
                }
                if (verdict == EventDedup::Verdict::TableFull) {
                    emit error(QStringLiteral("event dedup table full; session must be re-established"));
                    continue;
                }
            }

            event["_bridge_sequence"] = double(sequence);
            emit controlEvent(event);
        }
        else if (kind == PiBridge::Error) emit error(QStringLiteral("PBR1 bridge error: ") + QString::fromUtf8(payload).left(512));
    }
    if (buffer_.isEmpty()) frameTimeout_.stop(); else frameTimeout_.start();
}

void PogoControlTransport::restartHandshake() {
    if (hsActive_) return;
    // 主动重握手：销毁旧会话密钥，handshake 消息仍走明文；握手期间
    // sendCommand() 会明确返回 SESSION_REHANDSHAKING，不回退到明文命令。
    authenticated_ = false;
    bridgeToPiKey_.fill('\0'); bridgeToPiKey_.clear();
    piToBridgeKey_.fill('\0'); piToBridgeKey_.clear();
    noncePrefix_.clear();
    piAuthSeq_ = 1;
    replay_.reset();
    dedup_.clear();
    ttlOffsetValid_ = false;
    ttlOffsetMs_ = 0;
    hsBridgeId_.clear();
    bridgeBootIdHex_.clear();
    hsStage_ = 0;
    hsRetries_ = 0;
    startHandshake();
}

void PogoControlTransport::abortBridge(const QString &bridgeId) {
    if (bridgeId.isEmpty()) return;
    // 还没从 hello_resp 绑定身份时无法判断是哪块桥板，不误伤其它会话。
    if (hsBridgeId_.isEmpty() || hsBridgeId_ != bridgeId) return;
    qWarning().noquote() << "PBR bridge revoked:" << bridgeId;
    if (hsActive_) {
        failHandshake(QStringLiteral("BRIDGE_REVOKED"));
        return;
    }
    if (!authenticated_) return;
    authenticated_ = false;
    bridgeToPiKey_.fill('\0'); bridgeToPiKey_.clear();
    piToBridgeKey_.fill('\0'); piToBridgeKey_.clear();
    noncePrefix_.clear();
    piAuthSeq_ = 1;
    replay_.reset();
    dedup_.clear();
    ttlOffsetValid_ = false;
    hsBridgeId_.clear();
    bridgeBootIdHex_.clear();
    if (serial_.isOpen()) serial_.close();
    emit error(QStringLiteral("PBR bridge revoked"));
    emit disconnected(QStringLiteral("PBR bridge revoked"));
}

void PogoControlTransport::setHandshakeContext(const HandshakeContext &context) {
    hsContext_ = context;
}

void PogoControlTransport::sendHandshake(const QJsonObject &message) {
    hsLastMessage_ = message;
    sendCommandInternal(message, nullptr, true);
}

void PogoControlTransport::startHandshake() {
    if (authenticated_ || hsActive_) return;
    if (!hsContext_.candidates || !hsContext_.verify || !hsContext_.sign
        || !hsContext_.piPublicKey || !hsContext_.piKeyId)
        return;

    hsPriv_ = PbrHandshake::generatePrivateKey();
    if (hsPriv_.size() != PbrHandshake::kKeyBytes) {
        emit error(QStringLiteral("PBR handshake: cannot generate X25519 key"));
        return;
    }
    hsPiPub_ = hsContext_.piPublicKey();
    if (hsPiPub_.size() != 65) {
        emit error(QStringLiteral("PBR handshake: host identity unavailable"));
        return;
    }
    hsPiKeyId_ = hsContext_.piKeyId();

    QByteArray nonce(16, '\0');
    for (int i = 0; i < nonce.size(); ++i)
        nonce[i] = char(QRandomGenerator::system()->bounded(256));

    hsMsg1_.clear();
    hsMsg1_.append(char(1));   // proto_ver
    hsMsg1_.append(char(1));   // suite_id
    hsMsg1_.append(PbrHandshake::publicKeyOf(hsPriv_));
    hsMsg1_.append(nonce);
    if (hsMsg1_.size() != 50) {
        emit error(QStringLiteral("PBR handshake: bad hello_req length"));
        return;
    }

    hsT2_.clear(); hsT3_.clear(); hsHandshakeKey_.clear();
    hsBridgeToPi_.clear(); hsPiToBridge_.clear(); hsNoncePrefix_.clear();
    hsBridgePubEph_.clear(); hsBridgeBootId4_.clear(); bridgeBootIdHex_.clear();
    ttlOffsetValid_ = false; ttlOffsetMs_ = 0;
    hsStage_ = 1; hsRetries_ = 0; hsActive_ = true;
    hsLastMessage_ = QJsonObject{
        {QStringLiteral("schema"), QStringLiteral("pbr-handshake-v1")},
        {QStringLiteral("msg"), QStringLiteral("hello_req")},
        {QStringLiteral("body"), QString::fromLatin1(hsMsg1_.toHex())}};
    sendHandshake(hsLastMessage_);
    hsTimer_.start();
}

void PogoControlTransport::handshakeTimeout() {
    if (!hsActive_) return;
    if (hsStage_ == 2 && hsLastMessage_.value(QStringLiteral("msg")).toString()
                              == QStringLiteral("hello_ok")) {
        failHandshake(QStringLiteral("hello_ok timeout"));
        return;
    }
    if (++hsRetries_ > 5) {
        failHandshake(QStringLiteral("timeout"));
        return;
    }
    sendHandshake(hsLastMessage_);
    hsTimer_.start();
}

void PogoControlTransport::handleHandshake(const QJsonObject &event) {
    if (!hsActive_) return;
    const QString msg = event.value(QStringLiteral("msg")).toString();
    const QByteArray body = QByteArray::fromHex(event.value(QStringLiteral("body")).toString().toLatin1());

    if (msg == QLatin1String("hello_resp") && hsStage_ == 1) {
        const QByteArray signature = QByteArray::fromHex(
            event.value(QStringLiteral("sig")).toString().toLatin1());
        if (body.size() != 55 || signature.size() != 64) {
            failHandshake(QStringLiteral("malformed hello_resp"));
            return;
        }
        if (quint8(body.at(0)) != 1 || quint8(body.at(1)) != 1) {
            failHandshake(QStringLiteral("UNSUPPORTED_VERSION"));
            return;
        }
        hsMsg2_ = body;
        hsBridgePubEph_ = body.mid(2, 32);
        hsBridgeBootId4_ = body.mid(50, 4);
        bridgeBootIdHex_ = hsBridgeBootId4_.toHex();
        hsBridgeKeyId_ = quint8(body.at(54));

        hsT2_ = PbrHandshake::element(QByteArrayLiteral("pbr_hello_req"), hsMsg1_)
              + PbrHandshake::element(QByteArrayLiteral("pbr_hello_resp"), hsMsg2_);
        if (hsT2_.size() != 140) {
            failHandshake(QStringLiteral("bad T2 length"));
            return;
        }
        const QByteArray t2Hash = QCryptographicHash::hash(hsT2_, QCryptographicHash::Sha256);
        bool trusted = false;
        for (const auto &candidate : hsContext_.candidates(hsBridgeKeyId_)) {
            if (candidate.second.size() == 65
                && hsContext_.verify(candidate.second, t2Hash, signature)) {
                trusted = true;
                // 身份已证：记下这条记录绑定的 bridge_id，之后每个事件都要对得上。
                hsBridgeId_ = candidate.first;
                break;
            }
        }
        if (!trusted) {
            failHandshake(QStringLiteral("IDENTITY_REJECTED"));
            return;
        }

        const QByteArray shared = PbrHandshake::sharedSecret(hsPriv_, hsBridgePubEph_);
        if (shared.size() != PbrHandshake::kKeyBytes || !PbrAead::sharedIsUsable(shared)) {
            failHandshake(QStringLiteral("bad X25519 shared secret"));
            return;
        }
        const QByteArray msg3 = QByteArray(1, char(hsPiKeyId_)) + hsPiPub_;
        hsT3_ = hsT2_ + PbrHandshake::element(QByteArrayLiteral("pbr_hello_finish"), msg3);
        if (hsT3_.size() != 226) {
            failHandshake(QStringLiteral("bad T3 length"));
            return;
        }
        const PbrHandshake::Keys keys = PbrHandshake::deriveKeys(shared, hsT3_);
        if (keys.handshake.size() != 32 || keys.bridgeToPi.size() != 32
            || keys.noncePrefix.size() != 4) {
            failHandshake(QStringLiteral("HKDF failed"));
            return;
        }
        QByteArray piSignature;
        if (!hsContext_.sign(QCryptographicHash::hash(hsT3_, QCryptographicHash::Sha256),
                             &piSignature)
            || piSignature.size() != 64) {
            failHandshake(QStringLiteral("host signature failed"));
            return;
        }
        hsHandshakeKey_ = keys.handshake;
        hsBridgeToPi_ = keys.bridgeToPi;
        hsPiToBridge_ = keys.piToBridge;
        hsNoncePrefix_ = keys.noncePrefix;
        hsSessionId_ = keys.sessionId;
        hsLastMessage_ = QJsonObject{
            {QStringLiteral("schema"), QStringLiteral("pbr-handshake-v1")},
            {QStringLiteral("msg"), QStringLiteral("hello_finish")},
            {QStringLiteral("body"), QString::fromLatin1(msg3.toHex())},
            {QStringLiteral("sig"), QString::fromLatin1(piSignature.toHex())}};
        hsStage_ = 2; hsRetries_ = 0;
        sendHandshake(hsLastMessage_);
        hsTimer_.start();
        return;
    }

    if (msg == QLatin1String("hello_ok") && hsStage_ == 2) {
        if (hsBridgeToPi_.size() != 32 || hsPiToBridge_.size() != 32
            || hsNoncePrefix_.size() != 4) {
            failHandshake(QStringLiteral("hello_ok before keys"));
            return;
        }
        const QJsonValue uptimeValue = event.value(QStringLiteral("uptime_ms"));
        if (!uptimeValue.isDouble() || uptimeValue.toDouble() < 0
            || uptimeValue.toDouble() > 9e15) {
            failHandshake(QStringLiteral("hello_ok missing uptime_ms"));
            return;
        }
        ttlOffsetMs_ = qint64(uptimeValue.toDouble()) - pbrClock_.elapsed();
        ttlOffsetValid_ = true;
        qInfo().noquote() << "PBR hello_ok: bridge_uptime_ms=" << qint64(uptimeValue.toDouble())
                          << "pi_elapsed_ms=" << pbrClock_.elapsed()
                          << "offset_ms=" << ttlOffsetMs_;
        setSessionKeys(hsBridgeToPi_, hsPiToBridge_, hsNoncePrefix_,
                       QByteArray(1, char(hsPiKeyId_)));
        authenticated_ = true;
        hsActive_ = false;
        hsStage_ = 0;
        hsTimer_.stop();
        hsPriv_.fill('\0'); hsPriv_.clear();
        hsHandshakeKey_.fill('\0'); hsHandshakeKey_.clear();
        qInfo().noquote() << "PBR handshake ok, session" << QString::fromLatin1(hsSessionId_.toHex());
    }
}

void PogoControlTransport::failHandshake(const QString &reason) {
    hsTimer_.stop();
    hsActive_ = false;
    hsStage_ = 0;
    hsBridgeId_.clear();
    hsBridgeToPi_.fill('\0'); hsBridgeToPi_.clear();
    hsPiToBridge_.fill('\0'); hsPiToBridge_.clear();
    hsBridgeBootId4_.clear();
    hsPriv_.fill('\0'); hsPriv_.clear();
    hsHandshakeKey_.fill('\0'); hsHandshakeKey_.clear();
    authenticated_ = false;
    bridgeToPiKey_.clear();
    piToBridgeKey_.clear();
    noncePrefix_.clear();
    piAuthSeq_ = 1;
    ttlOffsetValid_ = false; ttlOffsetMs_ = 0;
    bridgeBootIdHex_.clear();
    qWarning().noquote() << "PBR handshake failed:" << reason;
    emit error(QStringLiteral("PBR handshake failed: ") + reason);
    if (serial_.isOpen()) serial_.close();
    emit disconnected(QStringLiteral("PBR handshake failed"));
}
