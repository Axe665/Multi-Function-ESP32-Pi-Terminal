#pragma once
#include <QByteArray>
#include <QObject>
#include <QProcess>
#include <QString>

#include <functional>

namespace security {

// KDF 子进程的客户端：把一次 600k 次 PBKDF2 交给常驻子进程算，主线程只等管道。
//
// 为什么要进程而不是线程：SQLite/OpenSSL 的进程级全局状态跨线程会自锁
// （实测登录永久卡死）。进程隔离没有这个共享状态，主线程全程不阻塞，
// 解锁动画能保持流畅。
//
// 失败语义：任何失败（起不来、中途死、超时、协议错）都只把这一次请求回调成
// 失败，由调用方回退到主线程同步算——登录功能不会因为一个辅助进程而不可用。
class KdfClient : public QObject
{
    Q_OBJECT
public:
    using Callback = std::function<void(bool ok, const QByteArray &kek)>;

    explicit KdfClient(QObject *parent = nullptr);

    // 拉起常驻子进程；失败返回 false（调用方之后会一直走同步回退）。
    bool start(const QString &workerPath);
    bool available() const { return available_; }
    QString lastError() const { return lastError_; }

    // 异步派生。返回 false 表示这次请求根本没发出去（调用方应立即回退同步）。
    // 成功发出的请求一定会回调一次（成功、失败或超时），永不悬挂。
    bool derive(const QString &pin, const QByteArray &salt, int iterations, Callback done);

private:
    void onReadyRead();
    void onFinished(int exitCode);
    void failPending(const QString &reason);

    QProcess process_;
    bool available_ = false;
    QString lastError_;
    bool busy_ = false;
    Callback pending_;
    QByteArray rxBuffer_;
};

}  // namespace security
