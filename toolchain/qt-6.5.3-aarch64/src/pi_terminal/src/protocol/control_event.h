#pragma once
#include <QByteArray>
#include <QJsonObject>
#include <QString>

// Validates a decrypted PBR control event against docs/devdocs/04-dev-tasks-f-day1.md §4.2.
// "p0-control-v1" is the only trusted schema. Schema-less attach/detach is the
// pre-P0 bridge frame and is now rejected: PBR command AEAD made the old firmware
// incompatible anyway, so the temporary legacy branch is gone (T-07).
namespace PbrControl {
enum class Verdict { Rejected, Trusted };
struct Result {
    Verdict verdict = Verdict::Rejected;
    QString reason; // f-day1 §7 error code
};
Result validate(const QJsonObject &event);

// §6.4：事件里的 bridge_id 必须与**已认证身份**逐字节相等（不是"格式合法"）。
// expected 为空表示当前会话没有绑定身份（未认证期/未配对），此时不做比对。
// 单独抽出来是为了能单测——它是一条安全判定，不该只存在于串口状态机里。
bool bridgeIdMatches(const QString &expected, const QString &actual);

// f-day1 §4.2 requires rejecting duplicate JSON keys and nesting deeper than 8,
// but Qt's parser silently keeps the last duplicate and accepts any depth. This
// scans the raw bytes before parsing; validate() cannot see what was dropped.
bool payloadAcceptable(const QByteArray &payload);
}
