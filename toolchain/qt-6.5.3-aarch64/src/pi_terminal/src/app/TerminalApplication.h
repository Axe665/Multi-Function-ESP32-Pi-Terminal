#pragma once

#include <QProcess>
#include <QTimer>

#include <QQmlApplicationEngine>

#include "core/ConnectionManager.h"
#include "core/DeveloperProbe.h"
#include "core/MachineInfo.h"
#include "core/TestRunner.h"
#include "app/OnboardingController.h"
#include "core/ModulePageHost.h"
#include "core/ModuleDataApi.h"
#include "core/NetworkGate.h"
#include "net/NetChannels.h"
#include "net/NetworkPolicyController.h"
#include "core/PowerStatus.h"
#include "core/SecurityService.h"
#include "core/SecurityStatus.h"
#include "security/AuthService.h"
#include "security/KdfClient.h"
#include "security/SessionManager.h"
#include "security/UserService.h"
#include "ui/DesktopShell.h"
#include "ui/MusicService.h"
#include "ui/SystemTools.h"
#include "ui/TimeSyncClient.h"
#include "ui/ViperBrowserController.h"

class QCommandLineParser;

class TerminalApplication final {
public:
    int initialize(const QCommandLineParser &options);

    ConnectionManager &connection() { return connection_; }
    SystemTools &systemTools() { return systemTools_; }
    DesktopShell &desktopShell() { return desktopShell_; }
    security::SessionManager &session() { return session_; }
    ModulePageHost &modulePageHost() { return modulePageHost_; }
    QQmlApplicationEngine &engine() { return engine_; }

private:
    // Reverse destruction order: QML pages/engine, shell, connection sessions
    // (which release hotspot leases), then SystemTools and its helper processes.
    SystemTools systemTools_;
    DeveloperProbe developerProbe_;
    TestRunner testRunner_;
    MachineInfo machineInfo_;
    ConnectionManager connection_;
    SecurityStatus securityStatus_{&connection_};
    SecurityService securityService_;
    NetworkGate networkGate_;
    NetworkPolicyController networkPolicy_;
    // 校时 HTTP 走独立 C++ QNAM + 34005 通道，避免与天气共用 qml 通道。
    TimeSyncClient timeSyncClient_{&networkGate_, NetChannels::TimeSyncPort};

    // 本地出站代理：策略文件由这里写，代理进程由这里拉起并看护。
    void writeNetPolicy();
    void startNetworkProxy();
    QProcess proxyProcess_;
    QTimer retentionTimer_;
    QString proxyPolicyPath_;
    int proxyRestarts_ = 0;
    // 正常退出时置位：避免 terminate 触发重启逻辑又拉起一个代理。
    bool proxyStopping_ = false;
    Power::PowerStatus powerStatus_;
    DesktopShell desktopShell_;
    MusicService musicService_;
    ViperBrowserController browserController_;

    // 安全层：注册表与认证是 SessionManager 的依赖，必须先于它构造。
    // 放在 security 命名空间里：Viper-Browser 有一个同名的全局 SessionManager，
    // 不隔离会 ODR 冲突并导致析构时 SIGSEGV（已实测）。
    security::UserService userService_;
    security::AuthService authService_{userService_};
    security::SessionManager session_{&userService_, &authService_};
    // KDF 子进程：把 600k 次 PBKDF2 挪出主线程，登录期间界面不冻结。
    security::KdfClient kdfClient_;

    // 首次开机向导（OOBE）：注册表为空时由 initialize() 打开。
    // 依赖 userService_ 与 session_，必须声明在它们之后。
    OnboardingController onboarding_{userService_, &session_, false};

    // 模块页沙箱（§0.7）：独立 QQmlEngine，宿主对象不可见。
    ModulePageHost modulePageHost_;
    // 当前模块页的数据接口（每实例一个，随会话重建）。
    ModuleDataApi *moduleDataApi_ = nullptr;

    QQmlApplicationEngine engine_;
};
