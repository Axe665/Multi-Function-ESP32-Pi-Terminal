// 文件 daemon 边界：token、家目录只读、app 数据根可写、敏感路径拒绝。
#include <QtTest>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QProcess>
#include <QTemporaryDir>

#include "core/FileApiBroker.h"
#include "files/FileProtocol.h"
#include <QLocalSocket>

class FileDaemonTest : public QObject {
    Q_OBJECT
private:
    QTemporaryDir dir_;
    QProcess daemon_;

    QString socketPath() const { return dir_.filePath("file.sock"); }
    QString tokenPath() const { return dir_.filePath("file.token"); }

private slots:
    void initTestCase()
    {
        QVERIFY(dir_.isValid());
        QDir().mkpath(dir_.filePath("home/.ssh"));
        QDir().mkpath(dir_.filePath("home/.local/share"));
        QDir().mkpath(dir_.filePath("run"));
        QFile token(tokenPath());
        QVERIFY(token.open(QIODevice::WriteOnly));
        token.setPermissions(QFile::ReadOwner | QFile::WriteOwner);
        token.write("test-token");
        token.close();
        QFile homeFile(dir_.filePath("home/readme.txt"));
        QVERIFY(homeFile.open(QIODevice::WriteOnly));
        homeFile.write("home-read-ok");
        homeFile.close();
        QFile sensitive(dir_.filePath("home/.ssh/id_test"));
        QVERIFY(sensitive.open(QIODevice::WriteOnly));
        sensitive.write("secret");
        sensitive.close();

        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert("HOME", dir_.filePath("home"));
        env.insert("XDG_RUNTIME_DIR", dir_.filePath("run"));
        env.insert("XDG_DATA_HOME", dir_.filePath("home/.local/share"));
        daemon_.setProcessEnvironment(env);
        daemon_.setProgram(QStringLiteral(FILE_DAEMON_BINARY));
        daemon_.setArguments({QStringLiteral("--socket"), socketPath(),
                              QStringLiteral("--token-file"), tokenPath()});
        daemon_.setProcessChannelMode(QProcess::MergedChannels);
        daemon_.start();
        QVERIFY2(daemon_.waitForStarted(3000), qPrintable(daemon_.errorString()));
        QByteArray ready;
        QTRY_VERIFY_WITH_TIMEOUT((ready += daemon_.readAllStandardOutput()).contains("ready"), 3000);

        qputenv("ORANGE_PI_FILE_SOCKET", socketPath().toUtf8());
        qputenv("ORANGE_PI_FILE_TOKEN", tokenPath().toUtf8());
        qputenv("XDG_DATA_HOME", dir_.filePath("home/.local/share").toUtf8());
        qputenv("HOME", dir_.filePath("home").toUtf8());
    }

    void cleanupTestCase()
    {
        if (daemon_.state() != QProcess::NotRunning) {
            daemon_.terminate();
            daemon_.waitForFinished(2000);
        }
    }

    void appDataIsWritableAndHomeIsReadable()
    {
        FileApiBroker broker;
        const QString appRoot = broker.appDataRoot(QStringLiteral("example.device"));
        QVERIFY(!appRoot.isEmpty());
        const QString path = appRoot + QStringLiteral("/note.txt");
        const QByteArray payload = QByteArrayLiteral("hello-file-api");
        QJsonObject write = broker.requestSync(
            QStringLiteral("write"),
            {{QStringLiteral("path"), path},
             {QStringLiteral("appRoot"), appRoot},
             {QStringLiteral("writeRoot"), appRoot},
             {QStringLiteral("offset"), 0},
             {QStringLiteral("dataBase64"), QString::fromLatin1(payload.toBase64())}});
        QVERIFY2(write.value(QStringLiteral("ok")).toBool(),
                 qPrintable(write.value(QStringLiteral("error")).toString()));

        QJsonObject read = broker.requestSync(
            QStringLiteral("read"),
            {{QStringLiteral("path"), path}, {QStringLiteral("appRoot"), appRoot}});
        QVERIFY2(read.value(QStringLiteral("ok")).toBool(),
                 qPrintable(read.value(QStringLiteral("error")).toString()));
        QCOMPARE(QByteArray::fromBase64(read.value(QStringLiteral("dataBase64")).toString().toLatin1()),
                 payload);

        QJsonObject listing = broker.requestSync(
            QStringLiteral("list"),
            {{QStringLiteral("path"), appRoot}, {QStringLiteral("appRoot"), appRoot}});
        QVERIFY2(listing.value(QStringLiteral("ok")).toBool(),
                 qPrintable(listing.value(QStringLiteral("error")).toString()));
        QVERIFY(listing.value(QStringLiteral("entries")).toArray().size() >= 1);
    }

    void homeReadAllowedButSensitiveDenied()
    {
        FileApiBroker broker;
        const QString appRoot = broker.appDataRoot(QStringLiteral("example.device"));
        const QString readme = dir_.filePath("home/readme.txt");
        QJsonObject read = broker.requestSync(
            QStringLiteral("read"),
            {{QStringLiteral("path"), readme}, {QStringLiteral("appRoot"), appRoot}});
        QVERIFY2(read.value(QStringLiteral("ok")).toBool(),
                 qPrintable(read.value(QStringLiteral("error")).toString()));
        QCOMPARE(QByteArray::fromBase64(read.value(QStringLiteral("dataBase64")).toString().toLatin1()),
                 QByteArrayLiteral("home-read-ok"));

        QJsonObject secret = broker.requestSync(
            QStringLiteral("read"),
            {{QStringLiteral("path"), dir_.filePath("home/.ssh/id_test")},
             {QStringLiteral("appRoot"), appRoot}});
        QCOMPARE(secret.value(QStringLiteral("ok")).toBool(), false);
        QVERIFY(secret.value(QStringLiteral("error")).toString().contains(QStringLiteral("sensitive")));
    }

    void writeOutsideAppRootDenied()
    {
        FileApiBroker broker;
        const QString appRoot = broker.appDataRoot(QStringLiteral("example.device"));
        const QString outside = dir_.filePath("home/not-allowed.txt");
        QJsonObject write = broker.requestSync(
            QStringLiteral("write"),
            {{QStringLiteral("path"), outside},
             {QStringLiteral("appRoot"), appRoot},
             {QStringLiteral("writeRoot"), appRoot},
             {QStringLiteral("dataBase64"),
              QString::fromLatin1(QByteArrayLiteral("nope").toBase64())}});
        QCOMPARE(write.value(QStringLiteral("ok")).toBool(), false);
        QVERIFY(!QFile::exists(outside));
    }

    void userSelectedDirectoryUsesSessionGrant()
    {
        FileApiBroker broker;
        const QString selected = dir_.filePath("selected");
        QVERIFY(QDir().mkpath(selected));
        const QString path = selected + QStringLiteral("/granted.txt");
        const QString token = broker.grantWrite(QStringLiteral("example.device"), selected);
        QVERIFY(!token.isEmpty());
        const QByteArray payload = QByteArrayLiteral("selected-write");
        QJsonObject write = broker.requestSync(
            QStringLiteral("write"),
            {{QStringLiteral("path"), path},
             {QStringLiteral("appId"), QStringLiteral("example.device")},
             {QStringLiteral("writeToken"), token},
             {QStringLiteral("dataBase64"), QString::fromLatin1(payload.toBase64())}});
        QVERIFY2(write.value(QStringLiteral("ok")).toBool(),
                 qPrintable(write.value(QStringLiteral("error")).toString()));
        QFile file(path);
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(file.readAll(), payload);

        QJsonObject wrong = broker.requestSync(
            QStringLiteral("write"),
            {{QStringLiteral("path"), path},
             {QStringLiteral("appId"), QStringLiteral("other.app")},
             {QStringLiteral("writeToken"), token},
             {QStringLiteral("dataBase64"), QString::fromLatin1(payload.toBase64())}});
        QCOMPARE(wrong.value(QStringLiteral("ok")).toBool(), false);
    }


    void forgedCapabilityIsRejected()
    {
        QLocalSocket socket;
        socket.connectToServer(socketPath());
        QVERIFY(socket.waitForConnected(2000));
        const QJsonObject capability{
            {QStringLiteral("appId"), QStringLiteral("forged.app")},
            {QStringLiteral("appRoot"), QDir::homePath()},
            {QStringLiteral("readRoot"), QDir::homePath()},
            {QStringLiteral("writeRoot"), QDir::homePath()},
            {QStringLiteral("expires"), QDateTime::currentSecsSinceEpoch() + 60}};
        const QJsonObject body{
            {QStringLiteral("schema"), QString::fromLatin1(FileProtocol::Schema)},
            {QStringLiteral("request_id"), 1},
            {QStringLiteral("op"), QStringLiteral("stat")},
            {QStringLiteral("token"), QStringLiteral("test-token")},
            {QStringLiteral("path"), dir_.filePath("home/readme.txt")},
            {QStringLiteral("capability"), capability},
            {QStringLiteral("capability_sig"), QStringLiteral("deadbeef")}};
        socket.write(FileProtocol::encode(body));
        QVERIFY(socket.waitForBytesWritten(2000));
        QTRY_VERIFY_WITH_TIMEOUT(socket.bytesAvailable() >= 4, 2000);
        const QByteArray header = socket.read(4);
        const quint32 length = quint32(quint8(header[0])) | (quint32(quint8(header[1])) << 8)
            | (quint32(quint8(header[2])) << 16) | (quint32(quint8(header[3])) << 24);
        QByteArray frame = header;
        QTRY_VERIFY_WITH_TIMEOUT(socket.bytesAvailable() >= int(length), 2000);
        frame += socket.read(int(length));
        const QJsonObject response = FileProtocol::decode(frame);
        QCOMPARE(response.value(QStringLiteral("ok")).toBool(), false);
        QVERIFY(response.value(QStringLiteral("error")).toString().contains(QStringLiteral("signature")));
    }

    void singleFileGrantOnlyAllowsThatFile()
    {
        FileApiBroker broker;
        const QString selected = dir_.filePath("single.txt");
        QFile file(selected);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("old");
        file.close();
        const QString token = broker.grantWrite(QStringLiteral("single.app"), selected);
        QVERIFY(!token.isEmpty());
        QJsonObject write = broker.requestSync(
            QStringLiteral("write"),
            {{QStringLiteral("path"), selected},
             {QStringLiteral("appId"), QStringLiteral("single.app")},
             {QStringLiteral("writeToken"), token},
             {QStringLiteral("offset"), 0},
             {QStringLiteral("truncate"), true},
             {QStringLiteral("dataBase64"),
              QString::fromLatin1(QByteArrayLiteral("new").toBase64())}});
        QVERIFY2(write.value(QStringLiteral("ok")).toBool(),
                 qPrintable(write.value(QStringLiteral("error")).toString()));
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(file.readAll(), QByteArrayLiteral("new"));
        file.close();

        const QString sibling = dir_.filePath("sibling.txt");
        QJsonObject denied = broker.requestSync(
            QStringLiteral("write"),
            {{QStringLiteral("path"), sibling},
             {QStringLiteral("appId"), QStringLiteral("single.app")},
             {QStringLiteral("writeToken"), token},
             {QStringLiteral("dataBase64"),
              QString::fromLatin1(QByteArrayLiteral("nope").toBase64())}});
        QCOMPARE(denied.value(QStringLiteral("ok")).toBool(), false);
    }

    void grantExpiryAndCrossSessionRestore()
    {
        FileApiBroker broker;
        const QString selected = dir_.filePath("expiring.txt");
        QFile file(selected);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("seed");
        file.close();
        QVERIFY(!broker.grantWrite(QStringLiteral("expiry.app"), selected, 1).isEmpty());
        QTest::qWait(1200);
        const QString expired = broker.restoreWrite(QStringLiteral("expiry.app"));
        QVERIFY(expired.isEmpty());

        const QString token = broker.grantWrite(QStringLiteral("restore.app"), selected, 60);
        QVERIFY(!token.isEmpty());
        FileApiBroker restoredBroker;
        const QString restored = restoredBroker.restoreWrite(QStringLiteral("restore.app"));
        QVERIFY(!restored.isEmpty());
        QJsonObject write = restoredBroker.requestSync(
            QStringLiteral("write"),
            {{QStringLiteral("path"), selected},
             {QStringLiteral("appId"), QStringLiteral("restore.app")},
             {QStringLiteral("writeToken"), restored},
             {QStringLiteral("dataBase64"),
              QString::fromLatin1(QByteArrayLiteral("restored").toBase64())}});
        QVERIFY2(write.value(QStringLiteral("ok")).toBool(),
                 qPrintable(write.value(QStringLiteral("error")).toString()));
    }
};

QTEST_GUILESS_MAIN(FileDaemonTest)
#include "file_daemon_test.moc"
