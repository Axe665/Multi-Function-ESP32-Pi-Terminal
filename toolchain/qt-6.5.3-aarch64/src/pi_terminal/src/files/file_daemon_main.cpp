#include "files/FileDaemonServer.h"

#include <QCommandLineParser>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("orange-pi-file-daemon"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("Orange Pi Terminal per-user file daemon"));
    parser.addHelpOption();
    const QCommandLineOption socketOption(QStringLiteral("socket"), QStringLiteral("Unix socket path"),
                                          QStringLiteral("path"));
    const QCommandLineOption tokenOption(QStringLiteral("token-file"),
                                         QStringLiteral("0600 token file"), QStringLiteral("path"));
    parser.addOption(socketOption);
    parser.addOption(tokenOption);
    parser.process(app);

    QString socketPath = parser.value(socketOption);
    if (socketPath.isEmpty()) {
        QString runtime = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
        if (runtime.isEmpty()) runtime = QDir::tempPath();
        socketPath = runtime + QStringLiteral("/orange-pi-file.sock");
    }
    QString token;
    const QString tokenPath = parser.value(tokenOption);
    if (!tokenPath.isEmpty()) {
        QFile file(tokenPath);
        if (!file.open(QIODevice::ReadOnly)) {
            qWarning("file-daemon: cannot read token file");
            return 2;
        }
        token = QString::fromUtf8(file.readAll()).trimmed();
    }
    if (token.isEmpty()) {
        qWarning("file-daemon: --token-file is required");
        return 2;
    }
    QDir().mkpath(QFileInfo(socketPath).absolutePath());
    FileDaemonServer server(socketPath, token);
    if (!server.start()) {
        qWarning("file-daemon: %s", qPrintable(server.errorString()));
        return 3;
    }
    qInfo("file-daemon: ready %s", qPrintable(socketPath));
    return app.exec();
}
