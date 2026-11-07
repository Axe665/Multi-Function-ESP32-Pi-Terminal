#include "net/NetChannels.h"
#include "net/ProxyServer.h"

#include <QCommandLineParser>
#include <QCoreApplication>
#include <QTimer>

// 本地出站代理（C/S 的 Server 侧）。
//
// 由主程序作为子进程拉起；五条网络栈按通道端口接进来：
//   34001 browser / 34002 music / 34003 tv / 34004 qml（天气 + 其余 QML 请求）
//   34005 timesync（C++ 校时 QNAM）
// 策略由宿主写文件、这里热载，只执行"该通道允许就放行，否则 403"。
int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("orange-pi-net-proxy"));
    QCoreApplication::setApplicationVersion(QStringLiteral("1.0"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("Orange Pi Terminal local egress proxy"));
    parser.addHelpOption();
    parser.addVersionOption();
    const QCommandLineOption policyOption(QStringLiteral("policy"), QStringLiteral("策略 JSON 路径"),
                                          QStringLiteral("path"));
    const QCommandLineOption basePortOption(QStringLiteral("base-port"),
                                            QStringLiteral("首个通道端口（默认 34001）"),
                                            QStringLiteral("port"), QStringLiteral("34001"));
    const QCommandLineOption onceOption(QStringLiteral("selftest"),
                                        QStringLiteral("绑定端口后立即退出（自检用）"));
    const QCommandLineOption loopbackTestOption(
        QStringLiteral("allow-loopback-for-tests"),
        QStringLiteral("仅测试：允许本机 origin，生产不要使用"));
    parser.addOption(policyOption);
    parser.addOption(basePortOption);
    parser.addOption(onceOption);
    parser.addOption(loopbackTestOption);
    parser.process(app);

    if (!parser.isSet(policyOption)) {
        qWarning("net-proxy: --policy is required");
        return 2;
    }
    bool ok = false;
    const uint base = parser.value(basePortOption).toUInt(&ok);
    if (!ok || base == 0 || base > 65000 - 5) {
        qWarning("net-proxy: bad --base-port");
        return 2;
    }

    const QList<ProxyServer::Channel> channels {
        { QString::fromLatin1(NetChannels::Browser), static_cast<quint16>(base + 0) },
        { QString::fromLatin1(NetChannels::Music), static_cast<quint16>(base + 1) },
        { QString::fromLatin1(NetChannels::Tv), static_cast<quint16>(base + 2) },
        { QString::fromLatin1(NetChannels::Qml), static_cast<quint16>(base + 3) },
        { QString::fromLatin1(NetChannels::TimeSync), static_cast<quint16>(base + 4) },
        { QString::fromLatin1(NetChannels::Updates), static_cast<quint16>(base + 5) },
    };

    ProxyServer server(channels, parser.value(policyOption), nullptr,
                       parser.isSet(loopbackTestOption));
    if (!server.start()) {
        qWarning("net-proxy: failed to listen, exiting");
        return 3;
    }
    qInfo("net-proxy: ready %s", qPrintable(server.listeningPorts().join(QLatin1Char(' '))));

    if (parser.isSet(onceOption)) {
        QTimer::singleShot(0, &app, &QCoreApplication::quit);
    }
    return app.exec();
}
