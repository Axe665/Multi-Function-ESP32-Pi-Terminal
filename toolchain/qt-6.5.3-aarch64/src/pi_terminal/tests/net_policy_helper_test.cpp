// 策略 helper 的契约测试：stdin 收整份策略，校验通过后写文件。
//
// 覆盖：
// - 合法策略写入成功、落盘内容正确；
// - 非 JSON 输入被拒绝（退出码 2）；
// - schema 不对被拒绝；
// - 失败时不会留下策略文件。
//
// helper 路径由 CMake 以 NET_POLICY_HELPER 传入；测试用 --policy 指向
// 临时目录，因此本机不需要 root。

#include <QtTest>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QTemporaryDir>

namespace {

QByteArray validPolicy()
{
    QJsonObject browser;
    browser.insert(QStringLiteral("enabled"), true);
    QJsonObject apps;
    apps.insert(QStringLiteral("browser"), browser);
    QJsonObject root;
    root.insert(QStringLiteral("schema"), QStringLiteral("orpi-net-policy-v2"));
    root.insert(QStringLiteral("version"), 2);
    root.insert(QStringLiteral("apps"), apps);
    root.insert(QStringLiteral("modules"), QJsonObject());
    return QJsonDocument(root).toJson(QJsonDocument::Compact);
}

}  // namespace

class NetPolicyHelperTest : public QObject {
    Q_OBJECT

private slots:
    void writesValidPolicy()
    {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString target = dir.filePath(QStringLiteral("policy.json"));

        QProcess process;
        process.start(QStringLiteral(NET_POLICY_HELPER),
                      {QStringLiteral("--policy"), target});
        QVERIFY(process.waitForStarted(5000));
        process.write(validPolicy());
        process.closeWriteChannel();
        QVERIFY(process.waitForFinished(10000));
        QCOMPARE(process.exitCode(), 0);
        QVERIFY(process.readAllStandardOutput().contains("OK"));

        QFile file(target);
        QVERIFY(file.open(QIODevice::ReadOnly));
        const QJsonObject written = QJsonDocument::fromJson(file.readAll()).object();
        QCOMPARE(written.value(QStringLiteral("schema")).toString(),
                 QStringLiteral("orpi-net-policy-v2"));
        QCOMPARE(written.value(QStringLiteral("apps")).toObject()
                     .value(QStringLiteral("browser")).toObject()
                     .value(QStringLiteral("enabled")).toBool(),
                 true);
    }

    void rejectsInvalidJson()
    {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString target = dir.filePath(QStringLiteral("policy.json"));

        QProcess process;
        process.start(QStringLiteral(NET_POLICY_HELPER),
                      {QStringLiteral("--policy"), target});
        QVERIFY(process.waitForStarted(5000));
        process.write("this is not json");
        process.closeWriteChannel();
        QVERIFY(process.waitForFinished(10000));
        QCOMPARE(process.exitCode(), 2);
        QVERIFY2(!QFile::exists(target), "invalid input must not create the policy file");
    }

    void rejectsWrongSchema()
    {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString target = dir.filePath(QStringLiteral("policy.json"));

        QJsonObject root;
        root.insert(QStringLiteral("schema"), QStringLiteral("bogus"));
        root.insert(QStringLiteral("version"), 2);
        root.insert(QStringLiteral("apps"), QJsonObject());
        root.insert(QStringLiteral("modules"), QJsonObject());

        QProcess process;
        process.start(QStringLiteral(NET_POLICY_HELPER),
                      {QStringLiteral("--policy"), target});
        QVERIFY(process.waitForStarted(5000));
        process.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
        process.closeWriteChannel();
        QVERIFY(process.waitForFinished(10000));
        QCOMPARE(process.exitCode(), 2);
        QVERIFY2(!QFile::exists(target), "unknown schema must not be written");
    }
};

QTEST_GUILESS_MAIN(NetPolicyHelperTest)
#include "net_policy_helper_test.moc"
