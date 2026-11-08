// 特权策略写入器：由 Polkit/pkexec 以 root 调用，只接受标准输入上的完整策略。
// 不接受任意路径（测试用 --policy 除外），避免变成任意文件写。
#include "net/NetworkPolicy.h"

#include <QCoreApplication>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTextStream>

#include <cstdio>

namespace {
constexpr auto kSystemPath = "/etc/orange-pi-terminal/network-policy.json";
}

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    bool check = false;
    QString path = QString::fromLatin1(kSystemPath);
    const QStringList args = app.arguments();
    for (int i = 1; i < args.size(); ++i) {
        if (args.at(i) == QStringLiteral("--check")) check = true;
        else if (args.at(i) == QStringLiteral("--policy") && i + 1 < args.size())
            path = args.at(++i);
        else {
            QTextStream(stderr) << "usage: net-policy-helper [--check] [--policy PATH]\n";
            return 2;
        }
    }

    QFile input;
    if (!input.open(stdin, QIODevice::ReadOnly)) {
        QTextStream(stderr) << "cannot read stdin\n";
        return 2;
    }
    const QByteArray bytes = input.readAll();
    if (bytes.size() > 64 * 1024) {
        QTextStream(stderr) << "policy too large\n";
        return 2;
    }
    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(bytes, &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
        QTextStream(stderr) << "bad JSON: " << parseError.errorString() << "\n";
        return 2;
    }
    NetworkPolicy::Policy policy;
    QString error;
    if (!NetworkPolicy::parse(doc.object(), &policy, &error)) {
        QTextStream(stderr) << "invalid policy: " << error << "\n";
        return 2;
    }
    if (check) {
        QTextStream(stdout) << "OK\n";
        return 0;
    }
    if (!NetworkPolicy::writeFile(path, doc.object(), &error)) {
        QTextStream(stderr) << "write failed: " << error << "\n";
        return 1;
    }
    QTextStream(stdout) << "OK\n";
    return 0;
}
