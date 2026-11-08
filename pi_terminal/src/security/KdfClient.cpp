#include "security/KdfClient.h"

#include <QDebug>
#include <QTimer>

namespace security {

namespace {
// 600k 次在 Pi 上约 1 秒，给 15 秒余量；超时说明子进程已经不正常了。
constexpr int kDeriveTimeoutMs = 15000;
constexpr int kStartTimeoutMs = 3000;
}  // namespace

KdfClient::KdfClient(QObject *parent) : QObject(parent)
{
    // 走管道而不是 socket：子进程由主进程直接拉起，不需要额外端口与鉴权。
    process_.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&process_, &QProcess::readyReadStandardOutput, this, &KdfClient::onReadyRead);
    connect(&process_, &QProcess::finished, this,
            [this](int exitCode, QProcess::ExitStatus) { onFinished(exitCode); });
    connect(&process_, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        available_ = false;
        lastError_ = process_.errorString();
        failPending(QStringLiteral("worker-error"));
    });
}

KdfClient::~KdfClient()
{
    // 先让子进程自己退出，避免退出时被 SIGKILL（日志里会出现 "Process crashed"）。
    if (process_.state() == QProcess::Running) {
        process_.write("quit\n");
        process_.waitForBytesWritten(200);
        process_.closeWriteChannel();
        if (!process_.waitForFinished(800)) process_.kill();
    }
}

bool KdfClient::start(const QString &workerPath)
{
    lastError_.clear();
    process_.setProgram(workerPath);
    process_.setArguments({});
    process_.start();
    if (!process_.waitForStarted(kStartTimeoutMs)) {
        available_ = false;
        lastError_ = process_.errorString();
        qWarning() << "kdf-worker: failed to start" << workerPath << lastError_;
        return false;
    }
    available_ = true;
    qInfo("kdf-worker: ready (pid %lld) program=%s", static_cast<long long>(process_.processId()),
          qPrintable(process_.program()));
    return true;
}

bool KdfClient::derive(const QString &pin, const QByteArray &salt, int iterations, Callback done)
{
    if (!available_ || process_.state() != QProcess::Running) return false;
    if (busy_) return false;   // 登录是串行的，重复请求视为调用方 bug

    const QByteArray pinBytes = pin.toUtf8();
    const QByteArray line = QByteArrayLiteral("kdf ") + QByteArray::number(iterations) + ' '
                          + salt.toHex() + ' ' + pinBytes.toHex() + '\n';
    busy_ = true;
    pending_ = std::move(done);
    rxBuffer_.clear();

    const qint64 written = process_.write(line);
    qInfo("kdf-client: sending %lld bytes (iter=%d)", static_cast<long long>(written), iterations);
    if (!process_.waitForBytesWritten(2000)) {
        qWarning("kdf-client: waitForBytesWritten failed");
        busy_ = false;
        pending_ = nullptr;
        return false;
    }

    // 超时兜底：子进程若卡死，必须回调失败让上层回退，不能把登录永远挂住。
    QTimer::singleShot(kDeriveTimeoutMs, this, [this] {
        if (!busy_) return;
        lastError_ = QStringLiteral("timeout");
        available_ = false;
        process_.kill();
        failPending(QStringLiteral("timeout"));
    });
    return true;
}

void KdfClient::onReadyRead()
{
    const QByteArray chunk = process_.readAllStandardOutput();
    qInfo("kdf-client: stdout chunk %d bytes: %s", int(chunk.size()), chunk.trimmed().constData());
    rxBuffer_ += chunk;
    while (true) {
        const int nl = rxBuffer_.indexOf('\n');
        if (nl < 0) return;
        const QByteArray line = rxBuffer_.left(nl).trimmed();
        rxBuffer_.remove(0, nl + 1);
        if (line.isEmpty()) continue;
        if (!busy_ || !pending_) continue;   // 没有等待者：丢弃（例如上一次超时后的迟到响应）

        if (line.startsWith("ok ")) {
            const QByteArray kek = QByteArray::fromHex(line.mid(3));
            auto callback = std::move(pending_);
            pending_ = nullptr;
            busy_ = false;
            callback(kek.size() == 32, kek);
            return;
        }
        // err <reason>：参数问题，回调失败让上层回退/报错。
        lastError_ = QString::fromUtf8(line.mid(4));
        failPending(lastError_);
        return;
    }
}

void KdfClient::onFinished(int exitCode)
{
    available_ = false;
    if (lastError_.isEmpty())
        lastError_ = QStringLiteral("worker exited with code %1").arg(exitCode);
    qWarning() << "kdf-worker: exited" << exitCode << lastError_;
    failPending(QStringLiteral("worker-exited"));
}

void KdfClient::failPending(const QString &reason)
{
    if (!pending_) return;
    auto callback = std::move(pending_);
    pending_ = nullptr;
    busy_ = false;
    qWarning() << "kdf-worker: request failed:" << reason;
    callback(false, {});
}

}  // namespace security
