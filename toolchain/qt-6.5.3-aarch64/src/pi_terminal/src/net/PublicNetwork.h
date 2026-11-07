#pragma once

#include <QHostAddress>
#include <QString>

// 公网目的地判定：代理和模块网络 API 共用同一套边界。
// 拒绝 loopback、RFC1918、CGNAT、link-local、unique-local、multicast、
// broadcast、保留地址；域名必须解析成功且所有地址都是公网。
namespace PublicNetwork {
bool isPublicAddress(const QHostAddress &address);
bool isPublicHost(const QString &host);
}  // namespace PublicNetwork
