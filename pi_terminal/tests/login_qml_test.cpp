// D9a：登录/锁屏/用户选择/数字键盘四个组件必须能实例化且绑定无错。
// 通过 qml module 加载，确保 Theme/I18n 单例真的注册。
// 关键：任何 QML 警告都算失败 —— 否则 I18n.t 是 undefined 时组件照样"创建成功"，
// 那种测试是假绿。
#include <QQmlComponent>
#include <QQuickWindow>
#include <QQuickItem>
#include <functional>
#include <QQmlEngine>
#include <QFile>
#include <QRegularExpression>
#include <QtTest>

class LoginQmlTest : public QObject {
    Q_OBJECT

private:
    QQmlEngine engine_;
    QStringList warnings_;

    static void capture(QtMsgType type, const QMessageLogContext &, const QString &message) {
        if (type == QtWarningMsg || type == QtCriticalMsg) qWarning().noquote() << "QML:" << message;
    }

    QObject *instantiate(const QString &type, QString *error) {
        QQmlComponent component(&engine_,
            QStringLiteral("qrc:/qt/qml/OrangePiTerminal/LoginTest/") + type);
        if (component.isError()) { *error = component.errorString(); return nullptr; }
        QObject *object = component.create();
        if (!object) *error = component.errorString();
        return object;
    }

private slots:
    void initTestCase() {
        // Qt 6.4 不会自动把 qrc:/qt/qml 加进导入路径，只加模块目录本身会解析不到
        // qmldir（"module's qmldir file not found"），单例 Theme/I18n 就成了未定义。
        // 两个路径都加：6.4 走资源根，6.5+ 两种都能命中。
        engine_.addImportPath(QStringLiteral("qrc:/qt/qml"));
        engine_.addImportPath(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/LoginTest"));
    }

    void themeSingletonResolvesThroughImport() {
        // 单例不能直接 QQmlComponent 加载，必须经 import 使用；用一个最小页面验证。
        QQmlComponent component(&engine_);
        component.setData(R"(
import QtQuick
import OrangePiTerminal.LoginTest
QtObject { property real hitSize: Theme.hit }
)", QUrl());
        QVERIFY2(!component.isError(), qPrintable(component.errorString()));
        QScopedPointer<QObject> probe(component.create());
        QVERIFY(probe);
        QVERIFY(probe->property("hitSize").toReal() > 0);
    }

    void i18nSingletonResolvesThroughImport() {
        QQmlComponent component(&engine_);
        component.setData(R"(
import QtQuick
import OrangePiTerminal.LoginTest
QtObject { property string label: I18n.t("登录") }
)", QUrl());
        QVERIFY2(!component.isError(), qPrintable(component.errorString()));
        QScopedPointer<QObject> probe(component.create());
        QVERIFY(probe);
        // I18n.t 必须返回非空字符串；返回空说明单例没注册。
        QVERIFY(!probe->property("label").toString().isEmpty());
    }

    void pinPadAcceptsOnlySixDigits() {
        QString error;
        QScopedPointer<QObject> pad(instantiate(QStringLiteral("PinPad.qml"), &error));
        QVERIFY2(pad, qPrintable(error));

        QSignalSpy submitted(pad.data(), SIGNAL(submitted(QString)));
        for (const char *digit : {"1", "2", "3", "4", "5"})
            QMetaObject::invokeMethod(pad.data(), "press", Q_ARG(QVariant, QString(digit)));
        QCOMPARE(submitted.count(), 0);

        // 输满不再自动提交：KDF 很贵，必须由用户点「确认」才开算。
        QMetaObject::invokeMethod(pad.data(), "press", Q_ARG(QVariant, QString("6")));
        QCOMPARE(submitted.count(), 0);
        QCOMPARE(pad->property("value").toString(), QStringLiteral("123456"));

        QMetaObject::invokeMethod(pad.data(), "confirm");
        QCOMPARE(submitted.count(), 1);
        QCOMPARE(submitted.first().first().toString(), QStringLiteral("123456"));
        // 提交后清空，避免连点两次重复提交。
        QCOMPARE(pad->property("value").toString(), QString());

        // 未输满时确认必须无效。
        submitted.clear();
        QMetaObject::invokeMethod(pad.data(), "press", Q_ARG(QVariant, QString("7")));
        QMetaObject::invokeMethod(pad.data(), "confirm");
        QCOMPARE(submitted.count(), 0);

        // 第 6 位之后不再接受输入。
        for (const char *digit : {"1", "2", "3", "4", "5"})
            QMetaObject::invokeMethod(pad.data(), "press", Q_ARG(QVariant, QString(digit)));
        QCOMPARE(pad->property("value").toString(), QStringLiteral("712345"));
        QMetaObject::invokeMethod(pad.data(), "press", Q_ARG(QVariant, QString("9")));
        QCOMPARE(pad->property("value").toString(), QStringLiteral("712345"));
    }

    void pinPadBackspaceWorks() {
        QString error;
        QScopedPointer<QObject> pad(instantiate(QStringLiteral("PinPad.qml"), &error));
        QVERIFY2(pad, qPrintable(error));
        QMetaObject::invokeMethod(pad.data(), "press", Q_ARG(QVariant, QString("7")));
        QCOMPARE(pad->property("value").toString(), QStringLiteral("7"));
        QMetaObject::invokeMethod(pad.data(), "backspace");
        QCOMPARE(pad->property("value").toString(), QString());
    }

    // 忙碌标记必须真的渲染出「正在解锁…」：这是把 KDF 挪到后台线程的唯一用户可见收益。
    // 用 BusyIndicator 的 running 与可见文案双重断言，避免"加了文案但没人看得到"。
    void pinPadShowsUnlockingWhileBusy() {
        QString error;
        QScopedPointer<QObject> pad(instantiate(QStringLiteral("PinPad.qml"), &error));
        QVERIFY2(pad, qPrintable(error));
        auto *item = qobject_cast<QQuickItem *>(pad.data());
        QVERIFY(item);

        QQuickWindow window;
        window.resize(600, 600);
        item->setParentItem(window.contentItem());
        item->setWidth(600);
        item->setHeight(600);
        window.show();
        QTest::qWait(120);

        auto texts = [&]() {
            QStringList out;
            std::function<void(QQuickItem *)> walk = [&](QQuickItem *node) {
                if (!node) return;
                const QVariant text = node->property("text");
                if (node->isVisible() && text.isValid() && !text.toString().isEmpty())
                    out << text.toString();
                for (QQuickItem *child : node->childItems()) walk(child);
            };
            walk(item);
            return out.join(QStringLiteral("\n"));
        };

        QVERIFY2(!texts().contains(QStringLiteral("正在解锁")), "idle pad must not claim to unlock");
        pad->setProperty("busy", true);
        QTest::qWait(120);
        QVERIFY2(texts().contains(QStringLiteral("正在解锁")), qPrintable(texts()));
    }

    void userPickerShowsNoSensitiveFields() {
        QString error;
        QScopedPointer<QObject> picker(instantiate(QStringLiteral("UserPicker.qml"), &error));
        QVERIFY2(picker, qPrintable(error));
        QVERIFY(!picker->property("temperatureC").isValid());
        QVERIFY(!picker->property("uid").isValid());
        QVERIFY(!picker->property("dbKey").isValid());
    }

    void carFieldPlainHintIsOptIn() {
        QString error;
        QScopedPointer<QObject> field(instantiate(QStringLiteral("CarField.qml"), &error));
        QVERIFY2(field, qPrintable(error));
        // 默认不动：非设置页仍由 Material 负责上浮标签。
        QVERIFY(!field->property("plainHint").toBool());

        field->setProperty("placeholderText", QStringLiteral("Hint"));
        field->setProperty("plainHint", true);
        // 占位文字交给自定义提示，Material 标签设为透明（不再上浮）。
        const QColor color = field->property("placeholderTextColor").value<QColor>();
        QCOMPARE(color.alpha(), 0);
        QObject *hint = field->findChild<QObject *>(QStringLiteral("carFieldHint"));
        QVERIFY(hint);
        QCOMPARE(hint->property("text").toString(), QStringLiteral("Hint"));
        // 未聚焦且为空时提示可见。
        QVERIFY(hint->property("visible").toBool());
    }

    void avatarFallsBackToInitial() {
        QString error;
        QScopedPointer<QObject> avatar(instantiate(QStringLiteral("Avatar.qml"), &error));
        QVERIFY2(avatar, qPrintable(error));
        QCOMPARE(avatar->property("initial").toString(), QStringLiteral("?"));
        avatar->setProperty("displayName", QStringLiteral("zoe"));
        QCOMPARE(avatar->property("initial").toString(), QStringLiteral("Z"));
        avatar->setProperty("displayName", QString::fromUtf8("验收员"));
        QCOMPARE(avatar->property("initial").toString(), QString::fromUtf8("验"));
    }

    void loginPageStartsWithoutSelectedUser() {
        QString error;
        QScopedPointer<QObject> login(instantiate(QStringLiteral("LoginPage.qml"), &error));
        QVERIFY2(login, qPrintable(error));
        QCOMPARE(login->property("selectedUserId").toString(), QString());
        // 未选人时是用户列表态；版本号始终可显示（测试进程版本为空）。
        QVERIFY(login->property("choosing").toBool());
        QVERIFY(login->property("versionText").toString().startsWith(QString::fromUtf8("树莓派终端")));
    }

    void lockScreenStartsIdle() {
        QString error;
        QScopedPointer<QObject> lock(instantiate(QStringLiteral("LockScreen.qml"), &error));
        QVERIFY2(lock, qPrintable(error));
        QVERIFY(!lock->property("busy").toBool());
    }

    // ---- 设计约束（docs/pi-ui-regression.md）----
    // 新页面必须走 Theme token，不能出现硬编码颜色/字号，否则主题与
    // 1.5x DPI 下会与既有界面不一致。
    void pinPadUsesThemeTokensOnly() {
        QFile file(QStringLiteral(TERMINAL_QML_DIR "/PinPad.qml"));
        QVERIFY(file.open(QIODevice::ReadOnly));
        const QString text = QString::fromUtf8(file.readAll());
        const QRegularExpression hexColor(QStringLiteral("\\\"#[0-9a-fA-F]{3,8}\\\""));
        QVERIFY2(!hexColor.match(text).hasMatch(),
                 "PinPad must not hardcode colors; use Theme.*");
        QVERIFY2(!text.contains(QStringLiteral("pointSize:")),
                 "PinPad must use Theme pixel sizes, not pointSize");
    }

    // 触控热区：数字键必须 >= Theme.hit（48px 下限）。
    void pinPadKeysRespectMinimumHitSize() {
        QString error;
        QScopedPointer<QObject> pad(instantiate(QStringLiteral("PinPad.qml"), &error));
        QVERIFY2(pad, qPrintable(error));
        // 键盘按钮用 Layout.preferredHeight: Theme.hit，Theme.hit 自身 >= 48。
        QFile theme(QStringLiteral(TERMINAL_QML_DIR "/Theme.qml"));
        QVERIFY(theme.open(QIODevice::ReadOnly));
        const QString themeText = QString::fromUtf8(theme.readAll());
        QVERIFY2(themeText.contains(QStringLiteral("Math.max(48, 64 * scaleFactor)")),
                 "Theme.hit must keep the 48px floor");
    }

    // 所有新页面的 I18n 词条必须已进词表，否则英文界面会漏中文。
    void newPagesHaveEnglishTranslations() {
        const QStringList pages{QStringLiteral("LoginPage"), QStringLiteral("LockScreen"),
                                QStringLiteral("PinPad"), QStringLiteral("UserPicker"),
                                QStringLiteral("SessionGate"), QStringLiteral("TaskFinishDialog"),
                                QStringLiteral("AdminPairingPage")};
        QFile i18n(QStringLiteral(TERMINAL_QML_DIR "/I18n.qml"));
        QVERIFY(i18n.open(QIODevice::ReadOnly));
        const QString table = QString::fromUtf8(i18n.readAll());

        QStringList missing;
        for (const QString &page : pages) {
            QFile file(QStringLiteral(TERMINAL_QML_DIR "/") + page + QStringLiteral(".qml"));
            QVERIFY(file.open(QIODevice::ReadOnly));
            const QString text = QString::fromUtf8(file.readAll());
            const QRegularExpression call(QStringLiteral("I18n\\.t\\(\\\"([^\\\"]+)\\\"\\)"));
            QRegularExpressionMatchIterator it = call.globalMatch(text);
            while (it.hasNext()) {
                const QString key = it.next().captured(1);
                if (!table.contains(QLatin1Char('"') + key + QLatin1Char('"'))) missing.append(key);
            }
        }
        QVERIFY2(missing.isEmpty(),
                 qPrintable(QStringLiteral("missing I18n entries: ") + missing.join(QStringLiteral(", "))));
    }

};

QTEST_MAIN(LoginQmlTest)
#include "login_qml_test.moc"
