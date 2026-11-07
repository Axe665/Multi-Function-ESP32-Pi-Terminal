// 诊断探针：SQLCipher 的 open+key+首次读，在有/无 QtWebEngine 初始化时差多少。
//
// 背景：真实应用里登录时打开每用户库会"卡死"，于是把浏览器 WebEngineView 改成
// 懒加载绕开。但懒加载本身带来了 ui_responsive_touch 回归。要先确认卡死的真因：
//   A. 真·死锁（WebEngine 与 SQLCipher 争某个全局锁）
//   B. 只是慢（PBKDF2 600k + Chromium 抢占 CPU），被肉眼判成死锁
//
// 用法：
//   ./db_webengine_probe         # 不开 WebEngine
//   ./db_webengine_probe --web   # 先初始化 WebEngine
//
// 每次跑 20 轮，打印每轮耗时与总耗时；超过 30 秒整进程超时（外部 timeout 兜底）。
#include <QApplication>
#include <QElapsedTimer>
#include <QtConcurrent>
#include <openssl/evp.h>
#include <QFile>
#include <QtWebEngineQuick>

#include <sqlite3.h>

#include <cstdio>

int main(int argc, char **argv)
{
    bool withWebEngine = false;
    bool workerKdf = false;
    bool warmUp = false;
    for (int i = 1; i < argc; ++i) {
        if (QByteArray(argv[i]) == "--web") withWebEngine = true;
        // 对照实验：让 PBKDF2 在 QtConcurrent 工作线程里跑完，再回主线程开库。
        // 复现「KDF 后台 + 开库主线程」这个组合是否会把 SQLite 初始化搞坏。
        if (QByteArray(argv[i]) == "--worker-kdf") workerKdf = true;
        if (QByteArray(argv[i]) == "--warmup") warmUp = true;
    }

    if (withWebEngine) {
        // 与产品相同的初始化顺序：必须在 QApplication 之前。
        QCoreApplication::setAttribute(Qt::AA_ShareOpenGLContexts);
        QtWebEngineQuick::initialize();
    }
    QApplication app(argc, argv);

    if (warmUp) {
        printf("phase: warmUp sqlite3_initialize on main thread\n");
        fflush(stdout);
        sqlite3_initialize();
        printf("phase: warmUp returned\n");
        fflush(stdout);
    }

    if (workerKdf) {
        printf("phase: worker-thread KDF\n");
        fflush(stdout);
        QByteArray pin(6, '2');
        QByteArray salt(16, 's');
        QtConcurrent::run([pin, salt] {
            std::vector<unsigned char> out(32);
            const bool ok = PKCS5_PBKDF2_HMAC(pin.constData(), pin.size(),
                reinterpret_cast<const unsigned char *>(salt.constData()), salt.size(),
                200000, EVP_sha256(), 32, out.data()) == 1;
            printf("worker KDF done ok=%d\n", int(ok));
            fflush(stdout);
        }).waitForFinished();
        printf("phase: main thread will open db now\n");
        fflush(stdout);
    }

    const QString path = QStringLiteral("/tmp/db-probe.sqlite");
    QFile::remove(path);
    const QByteArray key(32, 'k');

    printf("mode=%s\n", withWebEngine ? "webengine" : "plain");
    fflush(stdout);

    qint64 worst = 0;
    QElapsedTimer total;
    total.start();
    for (int round = 0; round < 20; ++round) {
        QElapsedTimer one;
        one.start();

        sqlite3 *db = nullptr;
        if (sqlite3_open(path.toUtf8().constData(), &db) != SQLITE_OK) {
            printf("open failed\n");
            return 1;
        }
        sqlite3_key(db, key.constData(), key.size());
        // 必须真读一页才知道 key 对不对；这一步才是解密的实际发生点。
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS t(x)", nullptr, nullptr, nullptr);
        sqlite3_exec(db, "INSERT INTO t VALUES(1)", nullptr, nullptr, nullptr);
        sqlite3_stmt *stmt = nullptr;
        sqlite3_prepare_v2(db, "SELECT count(*) FROM t", -1, &stmt, nullptr);
        if (stmt) {
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }
        sqlite3_close(db);

        const qint64 ms = one.elapsed();
        if (ms > worst) worst = ms;
        printf("round %2d: %lld ms\n", round + 1, static_cast<long long>(ms));
        fflush(stdout);
    }
    printf("total=%lld ms worst=%lld ms\n", static_cast<long long>(total.elapsed()),
           static_cast<long long>(worst));
    return 0;
}
