#pragma once

#include <QtGlobal>

// 本地出站代理的通道定义：端口与通道名只在这里写一次。
//
// 约束：
// - 代理按“哪个端口收到连接”判通道，所以端口必须与 ProxyServer 的 Channel 列表一致；
// - 策略 JSON 的 channels 键必须与这里的 name 一致；
// - Chromium 的 --proxy-server、GStreamer souphttpsrc 的 proxy=、QML NAM 工厂、
//   TimeSyncClient 都从这里取，避免 34001..34005 在四处漂移。
namespace NetChannels {

inline constexpr quint16 BrowserPort = 34001;
inline constexpr quint16 MusicPort = 34002;
inline constexpr quint16 TvPort = 34003;
// 天气及其它 QML XHR 共用 qml 通道；校时已改为 C++ QNAM，独占 timesync 通道。
inline constexpr quint16 QmlPort = 34004;
inline constexpr quint16 TimeSyncPort = 34005;
inline constexpr quint16 UpdatesPort = 34006;

inline constexpr char Browser[] = "browser";
inline constexpr char Music[] = "music";
inline constexpr char Tv[] = "tv";
inline constexpr char Qml[] = "qml";
inline constexpr char TimeSync[] = "timesync";
inline constexpr char Updates[] = "updates";

// 策略文件版本：v1 只有 4 个通道；v2 增加 timesync；v3 增加 updates 并使用
// host allowlist；v4 删除域名 allowlist，只保留每个通道的 {enabled}。
inline constexpr int PolicyVersion = 4;

}  // namespace NetChannels
