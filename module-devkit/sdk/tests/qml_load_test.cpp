#include <QDateTime>
#include <QGuiApplication>
#include <QObject>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlError>
#include <QVariantMap>
#include <cstdio>

// 模拟宿主的 SessionModel：QObject + data 属性 + changed 信号。
class SessionModel : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap data READ data NOTIFY changed)
public:
    explicit SessionModel(QObject *parent = nullptr) : QObject(parent) {}
    QVariantMap data() const { return data_; }
    void setData(const QVariantMap &value) { data_ = value; emit changed(); }
signals:
    void changed();
private:
    QVariantMap data_;
};

// 离屏加载模块页面：模拟宿主注入项，任何 QML 警告都算失败。
int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
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

    QQmlContext context(engine.rootContext());
    SessionModel model;
    context.setContextProperty(QStringLiteral("hostTheme"), QVariantMap{
        {QStringLiteral("background"), QStringLiteral("#08121f")},
        {QStringLiteral("surface"), QStringLiteral("#102238")},
        {QStringLiteral("foreground"), QStringLiteral("#ffffff")},
        {QStringLiteral("accent"), QStringLiteral("#85deff")},
        {QStringLiteral("scale"), 1.0},
    });
    context.setContextProperty(QStringLiteral("sessionModel"), &model);
    model.setData(QVariantMap{
        {QStringLiteral("temperature_C"), 24.6},
        {QStringLiteral("humidity_RH"), 61.2},
        {QStringLiteral("light_lux"), 720},
        {QStringLiteral("counter"), 42},
        {QStringLiteral("received_at"), double(QDateTime::currentMSecsSinceEpoch())},
    });

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
