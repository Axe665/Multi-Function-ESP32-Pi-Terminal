#pragma once

#include "net/NetworkPolicy.h"

#include <QJsonObject>

class NetworkGate;

// 运行期代理策略的唯一构造点：宿主写盘与测试都走这里。
// v4 只保留应用级通道开关；域名 allowlist 已删除，公网-only 由代理按目的地执行。
namespace NetPolicy {
QJsonObject build(const NetworkGate &gate,
                  const NetworkPolicy::Policy *policy = nullptr);
}
