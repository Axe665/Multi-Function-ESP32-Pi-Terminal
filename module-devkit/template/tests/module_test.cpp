// 模块业务逻辑测试骨架：不需要真机、不需要装模块。
//
// 用法：
//   cmake -S . -B build -DMODULE_SDK_DIR=<devkit>/sdk -DMODULE_TESTING=ON
//   cmake --build build --parallel && ctest --test-dir build --output-on-failure
//
// 覆盖的是「模块自己的逻辑」，不是宿主：这里用一个假 host 把 emit_event 抓下来，
// 断言模块确实按 manifest 声明的 data_schema 发了记录。真机上出现「页面没数据」
// 时，先跑这个测试能区分是模块没发、还是宿主没接。
#include "pi_module_api.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QtTest>

namespace {
struct Captured {
    QString type;
    QJsonObject data;
};
QVector<Captured> g_events;

extern "C" void captureEvent(void *, const char *type, const char *json) {
    Captured captured;
    captured.type = QString::fromUtf8(type);
    captured.data = QJsonDocument::fromJson(QByteArray(json)).object();
    g_events.append(captured);
}
extern "C" int noopSend(void *, uint8_t, const uint8_t *, uint32_t) { return 0; }
extern "C" void noopAction(const char *, const char *) {}
extern "C" void noopPublish(const char *, const char *) {}
extern "C" const char *noopDir() { return "/tmp"; }
extern "C" void noopLog(int, const char *) {}
}  // namespace

// module.cpp 导出的 C ABI
extern "C" uint32_t pi_module_api_version();
extern "C" const char *pi_module_manifest_json();
extern "C" pi_module_handle_t *pi_module_create(const pi_host_services_t *);
extern "C" int pi_module_on_attach(pi_module_handle_t *, const char *);
extern "C" int pi_module_on_data(pi_module_handle_t *, uint8_t, const uint8_t *, uint32_t);
extern "C" int pi_module_action(pi_module_handle_t *, const char *);
extern "C" void pi_module_stop(pi_module_handle_t *);
extern "C" void pi_module_destroy(pi_module_handle_t *);

class ModuleTest : public QObject {
    Q_OBJECT

private:
    pi_host_services_t services_{};

private slots:
    void init() {
        g_events.clear();
        services_ = {};
        services_.api_version = PI_MODULE_API_VERSION;
        services_.emit_event = captureEvent;
        services_.send_data = noopSend;
        services_.publish_action = noopAction;
        services_.publish_event = noopPublish;
        services_.data_directory = noopDir;
        services_.log = noopLog;
    }

    // 宿主按 api_version 拒载旧模块，模块侧的返回值必须跟着头文件走。
    void apiVersionMatchesHeader() {
        QCOMPARE(pi_module_api_version(), PI_MODULE_API_VERSION);
    }

    // 宿主 api_version 不匹配时 create 必须返回 nullptr，而不是勉强造出一个实例。
    void createRejectsMismatchedHost() {
        pi_host_services_t stale = services_;
        stale.api_version = PI_MODULE_API_VERSION + 1;
        QVERIFY(pi_module_create(&stale) == nullptr);
    }

    // v3 宿主在加载前检查 platform_api 与 data_schema；模板必须自带合法声明。
    void manifestDeclaresV3Contract() {
        const QJsonObject manifest =
            QJsonDocument::fromJson(QByteArray(pi_module_manifest_json())).object();
        QCOMPARE(manifest.value(QStringLiteral("platform_api")).toInt(), 2);
        QCOMPARE(manifest.value(QStringLiteral("module_id")).toInt(), @MODULE_ID@);
        const QJsonObject records =
            manifest.value(QStringLiteral("data_schema")).toObject()
                    .value(QStringLiteral("records")).toObject();
        QVERIFY(records.contains(QStringLiteral("sample.demo")));
    }

    void attachSucceeds() {
        pi_module_handle_t *m = pi_module_create(&services_);
        QVERIFY(m != nullptr);
        QCOMPARE(pi_module_on_attach(m, R"({"transport":"ble"})"), 0);
        QCOMPARE(g_events.last().type, QStringLiteral("event.module_ready"));
        pi_module_destroy(m);
    }

    // 收到数据应当发出 sample.demo；名字必须与 manifest 的 data_schema 一致，
    // 否则宿主会静默丢弃。
    void dataEmitsDeclaredRecord() {
        pi_module_handle_t *m = pi_module_create(&services_);
        QVERIFY(m != nullptr);
        QCOMPARE(pi_module_on_attach(m, "{}"), 0);
        const QByteArray payload = R"({"value_a":24.6,"value_b":61.2,"value_c":720})";
        QCOMPARE(pi_module_on_data(m, PI_TRANSPORT_BLE,
                                   reinterpret_cast<const uint8_t *>(payload.constData()),
                                   uint32_t(payload.size())), 0);
        QVERIFY(!g_events.isEmpty());
        QCOMPARE(g_events.last().type, QStringLiteral("sample.demo"));
        QCOMPARE(g_events.last().data.value(QStringLiteral("value_a")).toDouble(), 24.6);
        pi_module_destroy(m);
    }

    // 未知 action 返回非 0，宿主据此提示「不支持」而不是假装成功。
    void unknownActionReturnsError() {
        pi_module_handle_t *m = pi_module_create(&services_);
        QVERIFY(m != nullptr);
        QCOMPARE(pi_module_action(m, "definitely_not_declared"), -1);
        pi_module_destroy(m);
    }
};

QTEST_MAIN(ModuleTest)
#include "module_test.moc"
