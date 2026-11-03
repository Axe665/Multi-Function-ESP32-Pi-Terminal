#pragma once

#include <QFileSystemWatcher>
#include <QHash>
#include <QList>
#include <QObject>
#include <QString>

class QTcpServer;
class QTcpSocket;

// 本地出站代理（C/S 里的 Server 侧）。
//
// 为什么需要它：主程序里有五条互不相通的网络栈（Qt Network / QML XHR /
// Chromium / GStreamer / 校时 C++ QNAM），没有一个公共的“请求出口”可以在应用层
// 拦住它们。HTTP 代理是这些栈唯一的共同语言，所以把“谁能出网”做成一个有明确
// 边界的服务端点：每条栈按功能指向不同端口，代理按“哪个端口收到连接”判定通道。
//
// 边界：
// - CONNECT 只看得到 host:port，看不到 URL 路径（HTTPS 加密，不做 MITM）；
// - 非 CONNECT 的明文 HTTP 会改写成 origin-form 再转发，代理能看到 path；
// - 不防同一登录用户下的恶意进程（同 UID）；系统级兜底是 nftables。
//
// 策略不在这里判定“该不该”——那是宿主 NetworkGate 的职责。这里只执行：
// 策略文件说该通道允许就放行，不允许就回 403。
class ProxyServer : public QObject {
    Q_OBJECT
public:
    struct Channel {
        QString name;
        quint16 port;
    };
    struct ChannelPolicy {
        bool enabled = false;
    };

    ProxyServer(const QList<Channel> &channels, QString policyPath,
                QObject *parent = nullptr, bool allowLoopbackForTests = false);

    // 绑定全部通道端口并开始监听；任何一个绑不上都算启动失败。
    // port=0 时由内核分配（测试用），实际端口用 portFor() 查询。
    bool start();

    // 立即重读策略文件（构造后与文件变化时都会调用）。
    void reloadPolicy();

    QStringList listeningPorts() const;
    quint16 portFor(const QString &channel) const;
    bool channelAllowed(const QString &channel) const;
    bool targetAllowed(const QString &channel, const QString &host, quint16 port,
                       bool tunneling) const;

private:
    // 一条连接的全部状态都在 cpp 里的 Session（收头/判通道/连上游/双向转发）。

    QList<Channel> channels_;
    QHash<QString, QTcpServer *> servers_;
    QHash<QString, ChannelPolicy> policy_;
    QString policyPath_;
    QFileSystemWatcher watcher_;
    // 仅测试：允许本机 origin 验证 HTTP 改写/隧道。生产构造保持 false。
    bool allowLoopbackForTests_ = false;
};
