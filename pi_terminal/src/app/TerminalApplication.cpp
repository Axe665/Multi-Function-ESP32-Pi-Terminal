#include "TerminalApplication.h"
#include <QTimer>
#include <QElapsedTimer>

#include <QCommandLineParser>
#include <QDir>
#include <QHostAddress>
#include <QTcpSocket>
#include <QCoreApplication>
#include <QFileInfo>
#include <QSaveFile>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkProxy>
#include <QProcess>
#include <QQmlContext>
#include <QQmlNetworkAccessManagerFactory>
#include <QStandardPaths>
#include <QSysInfo>
#include <QTimer>

#include "net/NetChannels.h"
#include "net/NetPolicy.h"
#include "net/NetworkPolicyController.h"
#include "security/SqlCipherStore.h"
#include "security/uid_index_key.h"

namespace {

// 新机器 / 新用户：注册表为空却留着上一次的鉴权与用户数据，
// 会让启动直接落到锁屏或半初始化状态（列表里有账户但库打不开）。
// 只清「肯定属于旧用户」的部分：登录锁定、UID 索引、各用户库、
// 语音包与浏览器缓存；日志保留，方便排查。
void purgeStaleProfile() {
    const QString configDir = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
    const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    const QStringList targets{
        configDir + QStringLiteral("/auth_locks.json"),
        configDir + QStringLiteral("/uid_index.key"),
        configDir + QStringLiteral("/users"),
        dataDir + QStringLiteral("/arkpets"),
        dataDir + QStringLiteral("/voice-packs"),
        dataDir + QStringLiteral("/music-api"),
        dataDir + QStringLiteral("/music-covers"),
        dataDir + QStringLiteral("/viper-browser"),
        dataDir + QStringLiteral("/QtWebEngine"),
    };
    QStringList removed;
    for (const QString &path : targets) {
        const QFileInfo info(path);
        if (!info.exists()) continue;
        const bool ok = info.isDir() ? QDir(path).removeRecursively() : QFile::remove(path);
        if (ok) removed << path;
    }
    if (!removed.isEmpty())
        qInfo().noquote() << "profile: cleared stale data from a previous run:" << removed.join(QLatin1String(", "));
}

} // namespace

namespace {

// QML 里的 XMLHttpRequest 走 Qt Network；给它一个默认就带代理的 NAM，
// 这样天气、校时以及任何新写的 QML 请求都自动经过 qml 通道。
class ProxiedNamFactory final : public QQmlNetworkAccessManagerFactory {
public:
    QNetworkAccessManager *create(QObject *parent) override
    {
        auto *manager = new QNetworkAccessManager(parent);
        manager->setProxy(QNetworkProxy(QNetworkProxy::HttpProxy,
                                        QStringLiteral("127.0.0.1"), NetChannels::QmlPort));
        return manager;
    }
};

}  // namespace

// 策略文件：谁允许出网。只写"通道 → 布尔"，代理负责执行。
// 先写文件再拉进程——代理读不到文件时会全拒（fail-closed）。
void TerminalApplication::writeNetPolicy()
{
    if (proxyPolicyPath_.isEmpty()) {
        // 代理跑在独立 systemd 单元里（独立 UID），读不到本用户 0700 的
        // XDG_RUNTIME_DIR。所以策略放公共运行目录：目录由单元的
        // RuntimeDirectory=orpi-net-proxy 创建（0777），文件默认 0644，
        // 宿主可写、代理可读。目录不在时（开发环境没装单元）退回本用户运行目录。
        const QString shared = QStringLiteral("/run/orpi-net-proxy");
        if (QFileInfo(shared).isDir())
            proxyPolicyPath_ = shared + QStringLiteral("/policy.json");
        else {
            QString dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
            if (dir.isEmpty()) dir = QDir::tempPath();
            proxyPolicyPath_ = QDir(dir).filePath(QStringLiteral("orange-pi-net-policy.json"));
        }
    }
    const QJsonObject root = NetPolicy::build(networkGate_, &networkPolicy_.policy());
    const QByteArray payload = QJsonDocument(root).toJson(QJsonDocument::Compact);

    // 先按“临时文件 + rename”的原子方式写；代理和本进程会同时看这个文件，
    // 半截 JSON 会让代理解析失败并 fail-closed 到全拒。
    QSaveFile file(proxyPolicyPath_);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(payload);
        if (file.commit()) return;
        qWarning("net-proxy: policy commit failed %s: %s", qPrintable(proxyPolicyPath_),
                 qPrintable(file.errorString()));
    } else {
        qWarning("net-proxy: policy open failed %s: %s", qPrintable(proxyPolicyPath_),
                 qPrintable(file.errorString()));
    }

    // 回退：QSaveFile 在 DynamicUser 属主的文件上 open 就会失败
    // （"Existing file ... is not writable"）。文件属主是代理的
    // DynamicUser，宿主写不了；但运行时目录是 0777，删除只需要目录权限，
    // 所以先删再建。代理 watcher 会短暂读到 missing 并 fail-closed
    // （百毫秒级），随后读到新策略恢复。
    if (QFileInfo::exists(proxyPolicyPath_) && !QFileInfo(proxyPolicyPath_).isWritable()) {
        if (!QFile::remove(proxyPolicyPath_))
            qWarning("net-proxy: cannot remove unwritable policy %s", qPrintable(proxyPolicyPath_));
    }
    QFile direct(proxyPolicyPath_);
    if (!direct.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning("net-proxy: cannot write policy %s: %s", qPrintable(proxyPolicyPath_),
                 qPrintable(direct.errorString()));
        return;
    }
    if (direct.write(payload) != payload.size())
        qWarning("net-proxy: short write policy %s", qPrintable(proxyPolicyPath_));
    direct.close();
    qInfo("net-proxy: policy written directly %s (QSaveFile unavailable)",
          qPrintable(proxyPolicyPath_));
}

void TerminalApplication::startNetworkProxy()
{
    if (proxyProcess_.state() != QProcess::NotRunning) return;
    writeNetPolicy();

    // 已有代理解在跑（例如由 systemd 独立拉起、跑在另一个 cgroup 里）：
    // 不要再用 QProcess 起一个——端口会冲突，而且系统级规则要求代理与主进程
    // 属于不同 cgroup，主进程自己起的子进程做不到这一点。
    {
        QTcpSocket probe;
        probe.connectToHost(QHostAddress::LocalHost, NetChannels::BrowserPort);
        if (probe.waitForConnected(200)) {
            qInfo("net-proxy: already running on port %u, not spawning another", NetChannels::BrowserPort);
            probe.abort();
            return;
        }
        probe.abort();
    }

    // 与主程序同目录（安装后也是同一前缀）。
    const QString exe = QCoreApplication::applicationDirPath() + QStringLiteral("/network_proxy");
    if (!QFileInfo::exists(exe)) {
        // 代理不在 = 四条栈全指向一个没人监听的端口 = 全部失败。
        // 这正是 fail-closed 想要的结果，但要在日志里说清楚。
        qWarning("net-proxy: %s missing, every outbound request will fail", qPrintable(exe));
        return;
    }
    proxyProcess_.setProgram(exe);
    proxyProcess_.setArguments({ QStringLiteral("--policy"), proxyPolicyPath_ });
    proxyProcess_.setProcessChannelMode(QProcess::MergedChannels);
    QObject::connect(&proxyProcess_, &QProcess::readyRead, &proxyProcess_, [this] {
        const QByteArray out = proxyProcess_.readAll();
        if (!out.isEmpty()) qInfo("net-proxy: %s", out.trimmed().constData());
    });
    // 看护：崩了自动重拉（退避），期间没有代理 = 全部失败，不会偷偷直连。
    QObject::connect(&proxyProcess_, &QProcess::finished, &proxyProcess_,
                     [this](int code, QProcess::ExitStatus) {
        if (proxyStopping_) return;   // 正常退出，不是崩溃
        if (proxyRestarts_ >= 5) {
            qWarning("net-proxy: gave up after 5 restarts (last exit %d)", code);
            return;
        }
        const int delay = 500 * (++proxyRestarts_);
        qWarning("net-proxy: exited %d, restarting in %d ms", code, delay);
        QTimer::singleShot(delay, &proxyProcess_, [this] { startNetworkProxy(); });
    });
    // 退出时必须收掉子进程：QProcess 析构时若子进程仍在跑，Qt 只会打一行
    // "Destroyed while process is still running"，代理会变成孤儿继续监听端口。
    QObject::connect(qApp, &QCoreApplication::aboutToQuit, &proxyProcess_, [this] {
        proxyStopping_ = true;
        if (proxyProcess_.state() == QProcess::NotRunning) return;
        proxyProcess_.terminate();
        if (!proxyProcess_.waitForFinished(1500)) proxyProcess_.kill();
    });
    proxyProcess_.start();
    if (!proxyProcess_.waitForStarted(3000))
        qWarning("net-proxy: did not start: %s", qPrintable(proxyProcess_.errorString()));
}

int TerminalApplication::initialize(const QCommandLineParser &options) {
    if (options.isSet("paint-test")) {
        QObject::connect(&connection_, &ConnectionManager::trustRequired, &connection_,
            [this](const QString &instance, const QString &, const QStringList &) {
                connection_.trust(instance, false);
            });
    }
    QObject::connect(&connection_, &ConnectionManager::announcement,
                     &systemTools_, &SystemTools::speak);
    QObject::connect(&connection_, &ConnectionManager::announcement,
                     &systemTools_, &SystemTools::log);
    if (options.isSet("demo") || options.isSet("ui-test")) {
        // The desktop integration fixture uses loopback TCP, not a real AP.
        // Inject its virtual hotspot readiness instead of changing NetworkManager.
        QObject::connect(&connection_, &ConnectionManager::hotspotLeaseRequested,
                         &connection_, [this](const QString &instance) {
            QTimer::singleShot(0, &connection_, [this, instance] {
                connection_.hotspotLeaseReady(instance, true);
            });
        });
    } else {
        QObject::connect(&connection_, &ConnectionManager::hotspotLeaseRequested,
                         &systemTools_, &SystemTools::acquireHotspotLease);
    }
    QObject::connect(&systemTools_, &SystemTools::hotspotLeaseReady,
                     &connection_, &ConnectionManager::hotspotLeaseReady);
    if (!options.isSet("demo"))
        QObject::connect(&connection_, &ConnectionManager::hotspotLeaseReleased,
                         &systemTools_, &SystemTools::releaseHotspotLease);

    if (options.isSet("config") && !connection_.configure(options.value("config"))) {
        qCritical().noquote() << connection_.status();
        return 2;
    }
    // 首次绑卡/刷卡前必须有整机 UID 索引密钥；缺失时 bindCard 会失败。
    if (!ensureUidIndexKey())
        qWarning() << "uid index key could not be created";
    const QString device = qEnvironmentVariable("ORANGE_PI_CONTROL_DEVICE");
    // PBR 握手宿主能力：Pi 身份 + TrustStore 候选 + 签名/验签。
    // 必须在 start() 之前注入；串口一打开就会自动发起握手。
    if (!device.isEmpty() && securityStatus_.ensureIdentity()) {
        PogoControlTransport::HandshakeContext handshake;
        handshake.candidates = [this](quint8 keyId) {
            QVector<QPair<QString, QByteArray>> out;
            for (const auto &candidate : securityService_.bridgeHandshakeCandidates(keyId))
                out.append(candidate);
            return out;
        };
        handshake.piPublicKey = [this] { return securityStatus_.identityPublicKey(); };
        handshake.piKeyId = [this] { return securityStatus_.identityKeyIdByte(); };
        handshake.verify = [](const QByteArray &pub, const QByteArray &hash,
                              const QByteArray &sig) {
            return SecurityStatus::verifyIdentity(pub, hash, sig);
        };
        handshake.sign = [this](const QByteArray &hash, QByteArray *signature) {
            return securityStatus_.signIdentity(hash, signature);
        };
        connection_.setPogoHandshakeContext(handshake);
    }
    if (!device.isEmpty())
        connection_.start(device);

    engine_.rootContext()->setContextProperty("connectionManager", &connection_);
    engine_.rootContext()->setContextProperty("securityStatus", &securityStatus_);
    // 安全服务门面：QML 只能通过它做信任/绑卡/授权/审计/导出。
    securityService_.setSessionManager(&session_);
    engine_.rootContext()->setContextProperty("securityService", &securityService_);
    // §9.3 联网权限：root 策略是唯一来源，应用默认全拒绝；不再继承 QSettings。
    // 策略变化：只改文件，代理自己热载。这个连接必须在 startNetworkProxy()
    // 之前建立——否则探测到 systemd 代理已存在时 startNetworkProxy() 提前
    // return，运行期改开关就再也不会重写策略（生产形态的实际 bug）。
    QObject::connect(&networkGate_, &NetworkGate::settingChanged, &networkGate_,
                     [this] { writeNetPolicy(); });
    networkPolicy_.setSessionManager(&session_);
    networkPolicy_.setGate(&networkGate_);
    connection_.setNetworkGate(&networkGate_);
    modulePageHost_.setNetworkGate(&networkGate_);
    QObject::connect(&networkPolicy_, &NetworkPolicyController::policyApplied,
                     &networkPolicy_, [this] { writeNetPolicy(); });

    // QML 的网络栈：必须在加载 QML 之前装好工厂，否则首帧页面拿到的还是默认 NAM。
    engine_.setNetworkAccessManagerFactory(new ProxiedNamFactory());

    // 六条网络栈接进本地代理：浏览器走 Chromium 参数（main.cpp 里设），
    // 音乐、QML、校时在这里设，电视在 GstVideoItem 的 pipeline 里设；
    // 更新下载是预留的 updates 通道。
    musicService_.setNetworkProxy(QNetworkProxy(QNetworkProxy::HttpProxy,
                                                QStringLiteral("127.0.0.1"), NetChannels::MusicPort));
    startNetworkProxy();

    QObject::connect(&securityService_, &SecurityService::bridgeRevoked,
                     &connection_, [this](const QString &bridgeId) {
        connection_.abortBridge(bridgeId);
    });

    // 保留期：登录开库时清一次，之后每日定时；锁屏期间不跑。
    QObject::connect(&session_, &security::SessionManager::databaseChanged, &session_,
                     [this](security::UserDatabase *database) {
        if (database && session_.loggedIn() && !session_.locked())
            session_.applyRetention(systemTools_.retentionDays());
    });
    retentionTimer_.setInterval(24 * 60 * 60 * 1000);
    QObject::connect(&retentionTimer_, &QTimer::timeout, &retentionTimer_, [this] {
        if (session_.loggedIn() && !session_.locked())
            session_.applyRetention(systemTools_.retentionDays());
    });
    retentionTimer_.start();

    QObject::connect(&session_, &security::SessionManager::changed, &session_, [this] {
        const bool guest = session_.isGuest();
        browserController_.setGuestProfile(guest, guest ? session_.activeUserId() : QString());
    });

    // KDF 子进程：PBKDF2 600k 在 Pi 上约 6 s，放主线程会让整个界面卡住。
    // 子进程只做派生，PIN 走管道、不落盘；不可用时 SessionManager 自动退回同步路径。
    if (kdfClient_.start(QCoreApplication::applicationDirPath()
                         + QStringLiteral("/terminal_kdf_worker"))) {
        session_.setKdfClient(&kdfClient_);
    } else {
        qWarning() << "kdf-worker: unavailable, login will block on the main thread";
    }

    // 音乐服务与浏览器控制器自己不知道设置从哪来，宿主把门控指针交给它们。
    // 浏览器这一路由 Viper 的 RequestInterceptor 兜底：关闭后**所有**请求都被取消，
    // 包括开关关闭前就已经打开、还在跑 XHR 的页面。
    musicService_.setNetworkGate(&networkGate_);
    browserController_.setNetworkGate(&networkGate_);
    engine_.rootContext()->setContextProperty("networkGate", &networkGate_);
    engine_.rootContext()->setContextProperty("networkPolicy", &networkPolicy_);
    // §13 供电状态：P0 无数据源，保持 unknown，界面据此显示"状态未知"。
    engine_.rootContext()->setContextProperty("powerStatus", &powerStatus_);
    engine_.rootContext()->setContextProperty("systemTools", &systemTools_);
    engine_.rootContext()->setContextProperty("timeSyncClient", &timeSyncClient_);
    engine_.rootContext()->setContextProperty("developerProbe", &developerProbe_);
    engine_.rootContext()->setContextProperty("testRunner", &testRunner_);
    engine_.rootContext()->setContextProperty("machineInfo", &machineInfo_);
    engine_.rootContext()->setContextProperty("musicService", &musicService_);
    engine_.rootContext()->setContextProperty("viperBrowser", &browserController_);
    engine_.rootContext()->setContextProperty("desktopShell", &desktopShell_);
    engine_.rootContext()->setContextProperty("desktopDebug", options.isSet("demo"));
    // 登录/锁屏：QML 只调这些方法，服务端再做会话与权限校验。
    engine_.rootContext()->setContextProperty("sessionManager", &session_);
    // 首次开机向导：只在“注册表里没有任何用户”时接管启动。
    // 调试豁免与门禁的 sessionGateBypassed 保持同一组 flag，
    // 否则 --ui-test / --no-login 会被向导挡住。
    const bool onboardingBypassed = options.isSet("skip-onboarding")
                                    || options.isSet("ui-test") || options.isSet("no-login");
    // 判定标准是「没有可用的管理员」，而不是「没有任何用户」：
    // 最后一名管理员被删掉后，哪怕还留着普通用户，也必须能重新初始化，
    // 否则这台终端永远没人能管理。
    const bool onboardingRequired = !onboardingBypassed && !userService_.hasAdminUser();
    // 只有「完全没有任何用户」时才清理旧数据；只剩普通用户时必须原样保留。
    if (onboardingRequired && !userService_.hasAnyUser() && !options.isSet("keep-stale-data"))
        purgeStaleProfile();
    onboarding_.setStartupRequirement(onboardingRequired);
    if (onboardingBypassed && !userService_.hasAdminUser())
        qInfo().noquote() << "onboarding: bypassed by debug flag, no administrator";
    else if (onboardingRequired) {
        if (userService_.hasAnyUser())
            qInfo().noquote() << "onboarding: no administrator left, offering re-initialisation (regular users kept)";
        else
            qInfo().noquote() << "onboarding: no users, starting first-run setup";
    }
    engine_.rootContext()->setContextProperty("onboarding", &onboarding_);
    // §0.8.5：业务数据必须挂在当前登录用户上。会话变化时同步给连接管理器，
    // 否则 lane 门控拿不到用户，所有业务数据都会被拒。
    QObject::connect(&session_, &security::SessionManager::changed, &connection_, [this] {
        connection_.setActiveUserId(session_.activeUserId());
    });
    // 报告 §6.1：模块观测写进当前用户的加密库，模块侧不再写明文 JSON。
    connection_.observationSink = [this](const QString &, double value) {
        return session_.recordObservation(QStringLiteral("module"), value);
    };
    // T-08：刷卡事件接到安全服务，只解析出"该跳到哪个用户的 PIN 页"。
    // raw UID 不进 QML、不落盘；派生在 C++ 内部完成。
    QObject::connect(&connection_, &ConnectionManager::cardPresented,
                     &securityService_, [this](const QString &uidHex, int) {
        // 绑卡窗口内刷卡 = 绑定到当前用户（D8b），不参与"选用户"。
        if (securityService_.cardBindingWindowOpen()) {
            securityService_.bindCard(uidHex);
            securityService_.closeCardBindingWindow();
            return;
        }
        const QVariantMap result = securityService_.resolveCard(uidHex);
        if (result.value(QStringLiteral("matched")).toBool()) {
            const QString matchedUser = result.value(QStringLiteral("userId")).toString();
            emit securityService_.cardUserSelected(matchedUser);
        }
    });
    QObject::connect(&connection_, &ConnectionManager::bridgeAvailabilityChanged,
                     &securityService_, [this](bool available) {
        securityService_.setBridgeAvailable(available);
    });
    // start(device) 在上述 connect 之前执行，首次 connected 的可用性信号会丢；
    // 这里补一次当前状态，否则 resolveCard 永远 POSITION_UNKNOWN。
    securityService_.setBridgeAvailable(connection_.bridgeConnected());

    // 模块页的数据接口（§6.1）：每次加载页面按当前会话新建一个，
    // 作用域是 moduleId + instance + 当前登录用户。
    connection_.moduleDataApiFactory = [this](int moduleId, const QString &instance) -> QObject * {
        delete moduleDataApi_;
        // TerminalApplication 不是 QObject，父对象挂在 modulePageHost_ 上。
        moduleDataApi_ = new ModuleDataApi(moduleId, instance, &modulePageHost_);
        moduleDataApi_->setSessionManager(&session_);
        moduleDataApi_->setDatabase(session_.database());
        modulePageHost_.setModuleDataApi(moduleDataApi_);
        return moduleDataApi_;
    };

    // manifest 的 permissions 只记录为"请求"，授予仍须用户/管理员操作。
    connection_.requestedCapabilitiesSink = [this](int moduleId, const QStringList &capabilities) {
        securityService_.noteRequestedCapabilities(moduleId, capabilities);
    };
    // 账户删除：卡索引/权限矩阵不在加密库里，由宿主在同一事件循环内清理。
    QObject::connect(&session_, &security::SessionManager::userDeleted,
                     &securityService_, [this](const QString &userId) {
        securityService_.forgetUser(userId);
    });
    // 最后一名管理员被删掉后把首次开机向导重新拉起来，用户不用重启就能重建管理员。
    // 判定必须是「没有管理员」而不是「没有用户」：删掉管理员但还留着普通用户时，
    // 注册表非空，旧条件不会触发，界面会直接落到锁屏（实测）。
    QObject::connect(&session_, &security::SessionManager::userDeleted,
                     &onboarding_, [this](const QString &) {
        if (!userService_.hasAdminUser()) onboarding_.rearm();
    });
    // 当前用户加密库的指针必须跟着登录/退出/删号走：
    // SecurityService 的 bindCard/备份/审计都以 database_->isOpen() 为前提，
    // 只传一次 nullptr 会让这些入口永远 NOT_AUTHORIZED。
    QObject::connect(&session_, &security::SessionManager::databaseChanged,
                     &securityService_, [this](security::UserDatabase *database) {
        securityService_.setUserDatabase(database);
        if (moduleDataApi_) moduleDataApi_->setDatabase(database);
    });
    securityService_.setUserDatabase(session_.database());
    // 调试/演示：ORANGE_PI_AUTO_LOGIN=<pin> 用第一个用户自动登录（见
    // docs/devdocs/09-debug-hooks.md）。PIN 只从环境读一次，不写日志、不落盘。
    const QString autoLoginPin = qEnvironmentVariable("ORANGE_PI_AUTO_LOGIN");
    if (!autoLoginPin.isEmpty() && session_.hasUsers()) {
        const QVariantList users = session_.users();
        if (!users.isEmpty()) {
            const QString userId =
                users.first().toMap().value(QStringLiteral("userId")).toString();
            // ORANGE_PI_LOGIN_ASYNC=1 走 KDF 子进程的异步路径（默认同步，
            // 保持历史行为便于对照）。异步时用 loginFinished 收尾。
            if (qEnvironmentVariable("ORANGE_PI_LOGIN_ASYNC") == QLatin1String("1")) {
                auto handled = std::make_shared<bool>(false);
                QObject::connect(&session_, &security::SessionManager::loginFinished, &session_,
                                 [this, handled](const QString &code) {
                    if (*handled) return;
                    *handled = true;
                    qInfo().noquote() << "auto-login(async):" << (code.isEmpty() ? "ok" : code);
                    connection_.setActiveUserId(session_.activeUserId());
                });
                // 等事件循环稳定后再发起：自动登录发生在初始化阶段，主线程正忙于
                // QML/WebEngine 初始化，此时发请求会把“回调延迟”算进登录耗时。
                // TerminalApplication 不是 QObject：定时器与连接上下文挂到 session_ 上。
                auto *asyncLoginDelay = new QTimer(&session_);
                asyncLoginDelay->setSingleShot(true);
                QObject::connect(asyncLoginDelay, &QTimer::timeout, &session_,
                                 [this, userId, autoLoginPin] {
                    const bool sent = session_.loginWithWorker(userId, autoLoginPin);
                    qInfo().noquote() << "auto-login(async):" << (sent ? "sent" : "fallback");
                });
                asyncLoginDelay->start(3000);
            } else {
                const QString code = session_.login(userId, autoLoginPin);
                qInfo().noquote() << "auto-login:" << (code.isEmpty() ? "ok" : code);
            }
        }
    }
    connection_.setActiveUserId(session_.activeUserId());
    // 自动化审计（--ui-test）以无用户配置启动，门控会拒绝业务数据；
    // 仅测试路径注入一个占位用户，让审计能走完既有业务断言。
    if (options.isSet("ui-test"))
        connection_.setActiveUserId(QStringLiteral("ui-test-user"));
    // 人工测试同样不能卡在门禁上：--no-login 跳过门禁，但不跑自动点按脚本。
    // 已经有真实会话（ORANGE_PI_AUTO_LOGIN）时不要覆盖它。
    else if (options.isSet("no-login") && session_.activeUserId().isEmpty())
        connection_.setActiveUserId(QStringLiteral("test-user"));
    // 自动化审计（--ui-test）以全新配置启动、从不登录；门禁若照常生效，
    // 审计脚本点不到桌面会被误判为产品回归。仅测试路径关闭门禁。
    engine_.rootContext()->setContextProperty(
        "sessionGateBypassed", options.isSet("ui-test") || options.isSet("no-login"));
    // §0.7：模块页用独立引擎，宿主对象不在它的 context 里。
    engine_.rootContext()->setContextProperty("modulePageHost", &modulePageHost_);
    // QML binds directly to the persisted setting; never freeze it at startup.
    engine_.rootContext()->setContextProperty("efficientRendering", systemTools().energySaving());
    engine_.load(QUrl("qrc:/qt/qml/OrangePiTerminal/Main.qml"));
    return engine_.rootObjects().isEmpty() ? 1 : 0;
}
