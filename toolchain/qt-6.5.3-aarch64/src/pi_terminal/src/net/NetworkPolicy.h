#pragma once

#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QVector>

// 系统级联网策略（root 拥有）。与运行期 proxy 策略分开：
//   - 本文件是管理员意图，落 /etc/orange-pi-terminal/network-policy.json；
//   - NetPolicy 是宿主按当前 gate 生成的 /run 代理策略。
//
// v2 语义：只有应用级开关，没有域名白名单。代理按通道放行，
// 但所有通道都只允许公网目的地；本机 Node 的 127.0.0.1:3000 是音乐专属例外。
// 默认拒绝：文件缺失/损坏/版本不识别时，所有应用都不可联网。
namespace NetworkPolicy {

constexpr auto Schema = "orpi-net-policy-v2";
constexpr auto LegacySchema = "orpi-net-policy-v1";
constexpr int Version = 2;
constexpr int LegacyVersion = 1;

struct AppPolicy {
    QString id;
    bool enabled = false;
};

// 第三方模块按 manifest id 授权；与固定六个内置应用分开。
struct ModulePolicy {
    QString id;
    bool network = false;
    bool file = false;
};

struct Policy {
    QVector<AppPolicy> apps;
    QVector<ModulePolicy> modules;
};

// 固定顺序，QML/审计都依赖它。
QStringList appIds();
QString displayName(const QString &app);       // 中文名，仅日志/测试
QString channelForApp(const QString &app);     // proxy 通道名
QString purposeForApp(const QString &app);     // NetworkGate feature 名

Policy defaults();
// 接受 v2，以及 v1 迁移（v1 的 hosts 字段直接丢弃，启用状态保留）。
bool parse(const QJsonObject &root, Policy *out, QString *error);
QJsonObject toJson(const Policy &policy);
Policy loadFile(const QString &path, QString *error);
bool writeFile(const QString &path, const QJsonObject &root, QString *error);

}  // namespace NetworkPolicy
