#include "core/TestRunner.h"

#include <QCoreApplication>
#include <algorithm>
#include <QDir>
#include <QFileInfo>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTimer>
#include <QVariantMap>

namespace {

QString findTestsDir(const QString &root)
{
    const QString preferred = QDir(root).filePath(QStringLiteral("pi_terminal/tests"));
    if (QFileInfo(preferred).isDir()) return preferred;
    const QString direct = QDir(root).filePath(QStringLiteral("tests"));
    if (QFileInfo(direct).isDir()) return direct;
    return {};
}

QString findBuildDir(const QString &appDir)
{
    const QStringList candidates = {
        qEnvironmentVariable("ORANGE_PI_TEST_BUILD"),
        qEnvironmentVariable("BUILD_DIR"),
        appDir,
        QDir(appDir).filePath(QStringLiteral("..")),
    };
    for (const QString &candidate : candidates) {
        if (candidate.isEmpty()) continue;
        if (QFileInfo(QDir(candidate).filePath(QStringLiteral("CTestTestfile.cmake"))).isFile())
            return QDir(candidate).canonicalPath();
    }
    return {};
}

int groupOrder(const QString &group)
{
    static const QStringList order = {
        QStringLiteral("Protocol"), QStringLiteral("Security"),
        QStringLiteral("Connection / Worker"), QStringLiteral("Network"),
        QStringLiteral("Media"), QStringLiteral("UI"),
        QStringLiteral("Runtime"), QStringLiteral("Python"), QStringLiteral("Node"),
    };
    const int index = order.indexOf(group);
    return index < 0 ? order.size() : index;
}

QString classify(const QString &name)
{
    if (name.startsWith(QLatin1String("pbr_")) || name == QLatin1String("pibridge_protocol"))
        return QStringLiteral("Protocol");
    static const QRegularExpression security(
        QStringLiteral("trust|auth|user|session_gate|card|permission|recovery|backup|uid|host_identity|sqlcipher|business_data_security"));
    if (security.match(name).hasMatch()) return QStringLiteral("Security");
    static const QRegularExpression worker(QStringLiteral("worker|module_|lane_gate|slot_router"));
    if (worker.match(name).hasMatch()) return QStringLiteral("Connection / Worker");
    if (name.contains(QLatin1String("network"))
        || name.startsWith(QLatin1String("net_policy")))
        return QStringLiteral("Network");
    static const QRegularExpression media(QStringLiteral("music|video|tv_|weather_math"));
    if (media.match(name).hasMatch()) return QStringLiteral("Media");
    static const QRegularExpression ui(
        QStringLiteral("ui_|arkpets|pet_|startup|text_|time_tools|weather_tools|login|pairing|plugin_scale"));
    if (ui.match(name).hasMatch()) return QStringLiteral("UI");
    return QStringLiteral("Runtime");
}

bool heavyCtest(const QString &name)
{
    return name == QLatin1String("ui_responsive_touch") || name == QLatin1String("ui_highdpi_touch");
}

} // namespace

TestRunner::TestRunner(QObject *parent) : QObject(parent) {}

TestRunner::~TestRunner()
{
    if (process_) {
        process_->disconnect(this);
        process_->kill();
        process_->waitForFinished(1000);
    }
}

QVariantList TestRunner::discover()
{
    entries_.clear();
    discoveryError_.clear();

    const QString appDir = QCoreApplication::applicationDirPath();
    QString sourceRoot = qEnvironmentVariable("ORANGE_PI_TEST_ROOT");
    if (sourceRoot.isEmpty() || findTestsDir(sourceRoot).isEmpty()) {
        const QStringList candidates = {
            qEnvironmentVariable("ORANGE_PI_TEST_ROOT"),
            QDir(appDir).filePath(QStringLiteral("..")),
            QDir(appDir).filePath(QStringLiteral("../..")),
            QDir::currentPath(),
        };
        sourceRoot.clear();
        for (const QString &candidate : candidates) {
            if (candidate.isEmpty()) continue;
            if (!findTestsDir(candidate).isEmpty()) {
                sourceRoot = QDir(candidate).canonicalPath();
                break;
            }
        }
    }
    const QString testsDir = sourceRoot.isEmpty() ? QString() : findTestsDir(sourceRoot);
    const QString buildDir = findBuildDir(appDir);

    // ---- ctest ----
    const QString ctest = QStandardPaths::findExecutable(QStringLiteral("ctest"));
    if (!testsDir.isEmpty() && !buildDir.isEmpty() && !ctest.isEmpty()) {
        QProcess probe;
        probe.start(ctest, {QStringLiteral("--test-dir"), buildDir, QStringLiteral("-N")});
        if (probe.waitForFinished(5000) && probe.exitCode() == 0) {
            const QString text = QString::fromLocal8Bit(probe.readAllStandardOutput());
            static const QRegularExpression line(
                QStringLiteral("^\\s*Test\\s+#\\d+:\\s+(\\S+)\\s*$"),
                QRegularExpression::MultilineOption);
            auto it = line.globalMatch(text);
            while (it.hasNext()) {
                const QString name = it.next().captured(1);
                if (name.isEmpty()) continue;
                Entry entry;
                entry.id = QStringLiteral("ctest:") + name;
                entry.group = classify(name);
                entry.label = name;
                entry.kind = QStringLiteral("ctest");
                entry.heavy = heavyCtest(name);
                entry.program = ctest;
                entry.args = {QStringLiteral("--test-dir"), buildDir,
                              QStringLiteral("-R"), QStringLiteral("^") + name + QStringLiteral("$"),
                              QStringLiteral("--output-on-failure")};
                entry.workDir = buildDir;
                entry.available = true;
                entries_.insert(entry.id, entry);
            }
        }
    }

    // ---- python ----
    const QString python = QStandardPaths::findExecutable(QStringLiteral("python3"));
    const QStringList pythonScripts = {
        QStringLiteral("run_integration.py"),
        QStringLiteral("run_media_browser_tests.py"),
        QStringLiteral("screenshot_regression.py"),
        QStringLiteral("shared_runtime_install.py"),
        QStringLiteral("character_worker_test.py"),
        QStringLiteral("pack_sprites_test.py"),
    };
    for (const QString &script : pythonScripts) {
        Entry entry;
        entry.id = QStringLiteral("py:") + script;
        entry.group = QStringLiteral("Python");
        entry.label = script;
        entry.kind = QStringLiteral("python");
        entry.heavy = (script == QLatin1String("screenshot_regression.py")
                       || script == QLatin1String("run_media_browser_tests.py")
                       || script == QLatin1String("run_integration.py"));
        entry.workDir = testsDir;
        entry.program = python;
        const QString path = QDir(testsDir).filePath(script);
        entry.args = {path};
        entry.available = !testsDir.isEmpty() && QFileInfo(path).isFile() && !python.isEmpty();
        entry.reason = entry.available ? QString()
                       : (testsDir.isEmpty() ? QStringLiteral("tests directory not found")
                                             : QStringLiteral("python3 or script not available"));
        entries_.insert(entry.id, entry);
    }

    // ---- node ----
    const QString node = QStandardPaths::findExecutable(QStringLiteral("node"));
    const QStringList nodeScripts = {
        QStringLiteral("music_queue_test.cjs"),
        QStringLiteral("time_math_test.cjs"),
        QStringLiteral("weather_math_test.cjs"),
    };
    for (const QString &script : nodeScripts) {
        Entry entry;
        entry.id = QStringLiteral("node:") + script;
        entry.group = QStringLiteral("Node");
        entry.label = script;
        entry.kind = QStringLiteral("node");
        entry.workDir = testsDir;
        entry.program = node;
        const QString path = QDir(testsDir).filePath(script);
        entry.args = {path};
        entry.available = !testsDir.isEmpty() && QFileInfo(path).isFile() && !node.isEmpty();
        entry.reason = entry.available ? QString()
                       : (testsDir.isEmpty() ? QStringLiteral("tests directory not found")
                                             : QStringLiteral("node or script not available"));
        entries_.insert(entry.id, entry);
    }

    if (entries_.isEmpty() && discoveryError_.isEmpty()) {
        discoveryError_ = testsDir.isEmpty()
            ? QStringLiteral("tests directory not found (set ORANGE_PI_TEST_ROOT)")
            : QStringLiteral("no runnable tests found (need ctest build tree or python3/node)");
        emit discoveryErrorChanged();
    }

    QList<Entry> sorted = entries_.values();
    std::sort(sorted.begin(), sorted.end(), [](const Entry &a, const Entry &b) {
        const int ga = groupOrder(a.group), gb = groupOrder(b.group);
        if (ga != gb) return ga < gb;
        return a.label < b.label;
    });

    QVariantList list;
    for (const Entry &entry : sorted) {
        QVariantMap item;
        item.insert(QStringLiteral("id"), entry.id);
        item.insert(QStringLiteral("group"), entry.group);
        item.insert(QStringLiteral("label"), entry.label);
        item.insert(QStringLiteral("kind"), entry.kind);
        item.insert(QStringLiteral("heavy"), entry.heavy);
        item.insert(QStringLiteral("available"), entry.available);
        item.insert(QStringLiteral("reason"), entry.reason);
        list.append(item);
    }
    return list;
}

bool TestRunner::run(const QString &id)
{
    if (process_) return false;
    const auto it = entries_.constFind(id);
    if (it == entries_.constEnd() || !it->available) return false;
    const Entry entry = it.value();

    currentId_ = id;
    timedOut_ = false;
    process_ = new QProcess(this);
    process_->setProgram(entry.program);
    process_->setArguments(entry.args);
    process_->setWorkingDirectory(entry.workDir);
    process_->setProcessChannelMode(QProcess::MergedChannels);

    connect(process_, &QProcess::readyReadStandardOutput, this, [this] {
        if (!process_) return;
        emit output(QString::fromLocal8Bit(process_->readAllStandardOutput()));
    });
    connect(process_, &QProcess::finished, this, [this](int code, QProcess::ExitStatus) {
        finish(code == 0 && !timedOut_,
               timedOut_ ? QStringLiteral("TIMEOUT (600s)")
                         : QStringLiteral("exit %1").arg(code));
    });
    connect(process_, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (!process_) return;
        finish(false, QStringLiteral("process error %1").arg(int(error)));
    });

    emit runningChanged();
    emit started(id, entry.label);
    process_->start();
    QTimer::singleShot(600000, this, [this] {
        if (!process_) return;
        timedOut_ = true;
        process_->kill();
    });
    return true;
}

void TestRunner::cancel()
{
    if (!process_) return;
    process_->kill();
}

void TestRunner::finish(bool ok, const QString &summary)
{
    if (!process_) return;
    QProcess *process = process_;
    process_ = nullptr;
    process->disconnect(this);
    process->deleteLater();
    currentId_.clear();
    emit runningChanged();
    emit finished(ok, summary);
}
