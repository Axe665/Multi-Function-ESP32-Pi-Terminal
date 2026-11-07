#pragma once

#include <QHash>
#include <QObject>
#include <QProcess>
#include <QStringList>
#include <QVariantList>

// 测试模式后端：发现 pi_terminal 的测试（ctest / python / node），按组分类，
// 单并发执行并实时回传输出。只做白名单内、由 discover() 生成的任务，
// 不接受任意命令/路径。
class TestRunner : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(QString currentTest READ currentTest NOTIFY runningChanged)
    Q_PROPERTY(QString discoveryError READ discoveryError NOTIFY discoveryErrorChanged)
public:
    explicit TestRunner(QObject *parent = nullptr);
    ~TestRunner() override;

    bool running() const { return process_ != nullptr; }
    QString currentTest() const { return currentId_; }
    QString discoveryError() const { return discoveryError_; }

    // 返回 [{id,group,label,kind,heavy,available,reason}, ...]。
    Q_INVOKABLE QVariantList discover();
    Q_INVOKABLE bool run(const QString &id);
    Q_INVOKABLE void cancel();

signals:
    void runningChanged();
    void discoveryErrorChanged();
    void started(QString id, QString label);
    void output(QString chunk);
    void finished(bool ok, QString summary);

private:
    struct Entry {
        QString id, group, label, kind, reason;
        QString program;
        QStringList args;
        QString workDir;
        bool heavy = false;
        bool available = false;
    };
    void finish(bool ok, const QString &summary);

    QHash<QString, Entry> entries_;
    QProcess *process_ = nullptr;
    QString currentId_;
    QString discoveryError_;
    bool timedOut_ = false;
};
