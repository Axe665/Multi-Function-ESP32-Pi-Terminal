#include <QCoreApplication>
#include <QDateTime>
#include <QGuiApplication>
#include <QObject>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlError>
#include <QVariantList>
#include <QVariantMap>
#include <cmath>
#include <cstdio>

// 模拟宿主注入的 SessionModel：QObject + data 属性 + changed 信号。
class SessionModel : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap data READ data NOTIFY changed)
    Q_PROPERTY(bool online READ online NOTIFY changed)
public:
    explicit SessionModel(QObject *parent = nullptr) : QObject(parent) {}
    QVariantMap data() const { return data_; }
    bool online() const { return true; }
    void setData(const QVariantMap &value) { data_ = value; emit changed(); }
signals:
    void changed();
private:
    QVariantMap data_;
};

// 模拟宿主 v3 的 appData。字段是常见示例的并集，够所有模块页读取。
class FakeAppData : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready CONSTANT)
    Q_PROPERTY(bool schemaReady READ schemaReady CONSTANT)
    Q_PROPERTY(int moduleId READ moduleId CONSTANT)
    Q_PROPERTY(QString lastError READ lastError CONSTANT)
public:
signals:
    void dataChanged();
public:
    explicit FakeAppData(QObject *parent = nullptr) : QObject(parent) {}
    bool ready() const { return true; }
    bool schemaReady() const { return true; }
    int moduleId() const { return 200; }
    QString lastError() const { return QString(); }

    Q_INVOKABLE QVariantList query(const QString &, const QVariantMap &) {
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        return {QVariantMap{
            {QStringLiteral("received_at"), double(now)},
            {QStringLiteral("value_a"), 24.6}, {QStringLiteral("value_b"), 61.2},
            {QStringLiteral("value_c"), 720}, {QStringLiteral("online"), true},
            {QStringLiteral("temperature_C"), 24.6}, {QStringLiteral("humidity_RH"), 61.2},
            {QStringLiteral("light_lux"), 720}, {QStringLiteral("pressure_hPa"), 1015.1},
            {QStringLiteral("battery_pct"), 54}, {QStringLiteral("battery_V"), 3.85},
            {QStringLiteral("power_source"), QStringLiteral("battery")},
            {QStringLiteral("w"), 62.4}, {QStringLiteral("x"), 48}, {QStringLiteral("y"), 92},
            {QStringLiteral("bw"), 150}, {QStringLiteral("bl"), 200}, {QStringLiteral("em"), 20},
            {QStringLiteral("state"), QStringLiteral("in")},
            {QStringLiteral("armed"), true}, {QStringLiteral("trigger_count"), 2},
            {QStringLiteral("heartbeat_ms"), double(now)},
            {QStringLiteral("systolic"), 118}, {QStringLiteral("diastolic"), 76},
            {QStringLiteral("pulse"), 68}, {QStringLiteral("unit"), QStringLiteral("mmHg")},
            {QStringLiteral("source"), QStringLiteral("user.entry")}, {QStringLiteral("valid"), true},
        }};
    }

    Q_INVOKABLE QVariantList series(const QString &, const QString &, qint64, qint64) {
        QVariantList out;
        const qint64 end = QDateTime::currentMSecsSinceEpoch();
        for (int i = 23; i >= 0; --i) {
            const double v = 22 + 2.4 * std::sin(i / 4.0);
            out.append(QVariantMap{{QStringLiteral("t"), double(end - qint64(i) * 900000)},
                                   {QStringLiteral("v"), v},
                                   {QStringLiteral("min"), v - 0.6},
                                   {QStringLiteral("max"), v + 0.6}});
        }
        return out;
    }

    Q_INVOKABLE bool append(const QString &, const QVariantMap &) { return true; }
    Q_INVOKABLE bool appendBatch(const QString &, const QVariantList &) { return true; }
    Q_INVOKABLE bool validateRecord(const QString &, const QVariantMap &) { return true; }
    Q_INVOKABLE QVariantList records() const { return {}; }
    Q_INVOKABLE QVariantList historySeries(qint64, qint64) { return series({}, {}, 0, 0); }
    Q_INVOKABLE bool appendSample(const QVariantMap &) { return true; }
    Q_INVOKABLE bool appendMeasurement(const QVariantMap &) { return true; }
    Q_INVOKABLE QVariantList recentMeasurements(int) { return query({}, {}); }
};

// 模拟 appAdvice：ready / setModuleId / request / loadHistory + 异步信号。
class FakeAppAdvice : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready CONSTANT)
    Q_PROPERTY(QString lastError READ lastError CONSTANT)
    Q_PROPERTY(QVariantList history READ history NOTIFY historyChanged)
public:
    explicit FakeAppAdvice(QObject *parent = nullptr) : QObject(parent) {}
    bool ready() const { return true; }
    QString lastError() const { return QString(); }
    QVariantList history() const { return {}; }
    Q_INVOKABLE void setModuleId(int) {}
    Q_INVOKABLE void request(const QVariantMap &) {
        emit adviceReady(QStringLiteral("test"),
                         QVariantMap{{QStringLiteral("items"),
                                      QVariantList{QVariantMap{{QStringLiteral("text"), QStringLiteral("测试建议")},
                                                               {QStringLiteral("risk"), QStringLiteral("normal")}}}},
                                     {QStringLiteral("source"), QStringLiteral("local")}});
    }
    Q_INVOKABLE void loadHistory() { emit historyChanged(); }
signals:
    void adviceReady(const QString &requestId, const QVariantMap &payload);
    void adviceFailed(const QString &requestId, const QString &code);
    void historyChanged();
    void stateChanged();
};

// 离屏加载模块页面：模拟宿主注入项，任何 QML 警告都算失败。
int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    // 宿主 main.cpp 调 QQuickStyle::setStyle("Material")；页面用 Material Button，
    // 不设置时 Controls 会走另一套默认样式，重写 contentItem/background 的按钮会递归。
    qputenv("QT_QUICK_CONTROLS_STYLE", "Material");
    QGuiApplication app(argc, argv);
    if (argc < 2) {
        fprintf(stderr, "usage: qml_load_test ModulePage.qml\n");
        return 2;
    }

    QQmlEngine engine;
    int warnings = 0;
    QObject::connect(&engine, &QQmlEngine::warnings, [&warnings](const QList<QQmlError> &errors) {
        warnings += errors.size();
        for (const auto &error : errors) fprintf(stderr, "%s\n", qPrintable(error.toString()));
    });

    SessionModel model;
    FakeAppData appData;
    FakeAppAdvice appAdvice;
    QQmlContext context(engine.rootContext());
    context.setContextProperty(QStringLiteral("hostTheme"), QVariantMap{
        {QStringLiteral("background"), QStringLiteral("#08121f")},
        {QStringLiteral("surface"), QStringLiteral("#102238")},
        {QStringLiteral("foreground"), QStringLiteral("#ffffff")},
        {QStringLiteral("accent"), QStringLiteral("#85deff")},
        {QStringLiteral("scale"), 1.0},
    });
    context.setContextProperty(QStringLiteral("sessionModel"), &model);
    context.setContextProperty(QStringLiteral("appData"), &appData);
    context.setContextProperty(QStringLiteral("appAdvice"), &appAdvice);
    model.setData(appData.query({}, {}).value(0).toMap());

    QQmlComponent component(&engine, QUrl::fromLocalFile(QString::fromLocal8Bit(argv[1])));
    if (!component.isReady()) {
        for (const auto &error : component.errors()) fprintf(stderr, "%s\n", qPrintable(error.toString()));
        return 3;
    }

    QObject *page = component.create(&context);
    if (!page) {
        for (const auto &error : component.errors()) fprintf(stderr, "%s\n", qPrintable(error.toString()));
        return 3;
    }
    // 宿主给模块页的尺寸；没有窗口时 0×0 会触发布局绑定循环。
    page->setProperty("width", 1024);
    page->setProperty("height", 600);
    QCoreApplication::processEvents();
    QMetaObject::invokeMethod(page, "refreshLatest");
    QCoreApplication::processEvents();
    const QVariant status = page->property("statusKind");
    if (status.isValid()) {
        const QString value = status.toString();
        const QStringList allowed{
            QStringLiteral("live"), QStringLiteral("stale"), QStringLiteral("offline"),
            QStringLiteral("loading"), QStringLiteral("error"), QStringLiteral("empty")};
        if (!allowed.contains(value)) {
            fprintf(stderr, "unexpected statusKind: %s\n", qPrintable(value));
            warnings++;
        }
    }
    delete page;
    return warnings == 0 ? 0 : 4;
}

#include "qml_load_test.moc"
