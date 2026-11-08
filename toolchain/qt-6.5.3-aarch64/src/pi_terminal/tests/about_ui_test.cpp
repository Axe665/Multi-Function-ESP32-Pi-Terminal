// 「关于本机 → 开发者与感谢」二级页的渲染回归。
//
// 只验证渲染与结构，不碰服务端：
// - 「开发者与感谢」是彩蛋：默认不出现，连点版本号 5 次才放出入口；
// - 点开后从右侧滑入名单页（RightSlidePage，240ms），默认停在「开发者」；
// - 切到「感谢」后显示感谢名单；
// - 返回箭头只关页面；「取消」关页面并把入口一起收回；
// - 关闭关于本机时名单页一并归位，不会留到下一次打开。

#include <QtTest>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QFile>
#include <QRegularExpression>
#include <QVariantList>
#include <QVariantMap>

#include "ui/TerminalUi.h"

namespace {

// AboutDevicePage 只需要这几个只读接口；真实实现读 /proc，测试里给固定值。
class StubMachineInfo : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE QVariantMap snapshot() const
    {
        QVariantMap m;
        m.insert(QStringLiteral("cpuModel"), QStringLiteral("Test CPU"));
        m.insert(QStringLiteral("cpuCores"), 4);
        m.insert(QStringLiteral("cpuArch"), QStringLiteral("x86_64"));
        m.insert(QStringLiteral("memTotalBytes"), qint64(8) * 1024 * 1024 * 1024);
        m.insert(QStringLiteral("memAvailableBytes"), qint64(4) * 1024 * 1024 * 1024);
        return m;
    }
};

class StubSystemTools : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString uiLanguage READ uiLanguage CONSTANT)
    Q_PROPERTY(QVariantList logs READ logs CONSTANT)
public:
    QString uiLanguage() const { return QStringLiteral("zh"); }
    QVariantList logs() const { return {}; }
    Q_INVOKABLE QString settingsRead(const QString &, const QString &fallback) const
    {
        return fallback;
    }
    Q_INVOKABLE bool settingsWrite(const QString &, const QString &) { return true; }
    // 与真实 SystemTools 一样走 qrc 里的 Material 图标，并按明暗替换描边色，
    // 这样截图里的返回箭头等图标与产品一致。
    Q_INVOKABLE QUrl monochromeIcon(const QString &name, bool white) const
    {
        QFile file(QStringLiteral(":/icons/material/light/") + name + QStringLiteral(".svg"));
        if (!file.exists())
            file.setFileName(QStringLiteral(":/icons/material/dark/") + name + QStringLiteral(".svg"));
        if (!file.open(QIODevice::ReadOnly)) return {};
        QString svg = QString::fromUtf8(file.readAll());
        static const QRegularExpression paint(
            QStringLiteral("(fill|stroke)=\"#[0-9a-fA-F]{3,8}\""));
        svg.replace(paint, QStringLiteral("\\1=\"%1\"").arg(white ? "#ffffff" : "#000000"));
        return QUrl(QStringLiteral("data:image/svg+xml;base64,")
                    + QString::fromLatin1(svg.toUtf8().toBase64()));
    }
};

QQuickItem *findItemByObjectName(QQuickItem *root, const QString &name)
{
    if (!root) return nullptr;
    if (root->objectName() == name) return root;
    for (QQuickItem *child : root->childItems()) {
        if (QQuickItem *hit = findItemByObjectName(child, name)) return hit;
    }
    return nullptr;
}

void collectTexts(QQuickItem *root, QStringList *out)
{
    if (!root) return;
    const QVariant text = root->property("text");
    if (text.isValid() && !text.toString().isEmpty()) out->append(text.toString());
    for (QQuickItem *child : root->childItems()) collectTexts(child, out);
}

} // namespace

class AboutUiTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase()
    {
        QQuickStyle::setStyle(QStringLiteral("Material"));
        initializeTerminalUi();
    }

    void aboutDeviceShowsCreditsEntryAndPage()
    {
        StubMachineInfo machineInfo;
        StubSystemTools tools;

        QQmlEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("machineInfo"), &machineInfo);
        engine.rootContext()->setContextProperty(QStringLiteral("systemTools"), &tools);

        QQmlComponent component(
            &engine, QUrl(QStringLiteral("qrc:/qt/qml/OrangePiTerminal/AboutDevicePage.qml")));
        QVERIFY2(component.isReady(), qPrintable(component.errorString()));
        QScopedPointer<QObject> object(component.createWithInitialProperties(
            {{QStringLiteral("width"), 1024}, {QStringLiteral("height"), 760},
             {QStringLiteral("open"), true}}));
        QVERIFY2(object, qPrintable(component.errorString()));
        auto *page = qobject_cast<QQuickItem *>(object.data());
        QVERIFY(page);

        QQuickWindow window;
        window.resize(1024, 760);
        page->setParentItem(window.contentItem());
        page->setWidth(1024);
        page->setHeight(760);
        window.show();
        // 240ms 滑入 + 布局余量。
        QTest::qWait(400);

        // 彩蛋：默认不出现入口，连点版本号 5 次才放出来。
        auto *entry = findItemByObjectName(page, QStringLiteral("creditsEntry"));
        QVERIFY2(entry, "credits entry row missing");
        QVERIFY2(!entry->isVisible(), "credits entry must stay hidden until the easter egg fires");
        QCOMPARE(page->property("creditsRevealed").toBool(), false);

        for (int i = 0; i < 4; ++i) QMetaObject::invokeMethod(page, "registerVersionTap");
        QTest::qWait(50);
        QVERIFY2(!entry->isVisible(), "four taps must not reveal the credits entry");
        QMetaObject::invokeMethod(page, "registerVersionTap");
        QTest::qWait(100);
        QCOMPARE(page->property("creditsRevealed").toBool(), true);
        QVERIFY2(entry->isVisible(), "five taps must reveal the credits entry");

        QStringList texts;
        collectTexts(page, &texts);
        const QString joined = texts.join(QStringLiteral(" | "));
        QVERIFY2(joined.contains(QStringLiteral("开发者与感谢")), qPrintable(joined));
        // 入口在「设备信息」之后，先把滚动区滚到它，截图才看得到。
        auto *aboutFlick = findItemByObjectName(page, QStringLiteral("aboutDeviceFlick"));
        QVERIFY(aboutFlick);
        const qreal entryY = entry->mapToItem(page, QPointF(0, 0)).y();
        if (entryY > 520) {
            const qreal target = aboutFlick->property("contentY").toReal() + entryY - 320;
            aboutFlick->setProperty("contentY", target);
            QTest::qWait(200);
        }
        window.grabWindow().save(QStringLiteral("/tmp/about-with-credits.png"));

        // 打开名单页：先按真实鼠标点击入口行（覆盖 MouseArea 接线），
        // 滑入结束后默认停在开发者分组。
        const QPoint clickAt = entry->mapToScene(QPointF(entry->width() / 2, entry->height() / 2)).toPoint();
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, clickAt);
        QTest::qWait(400);
        QCOMPARE(page->property("creditsOpen").toBool(), true);
        QTest::qWait(400);
        QStringList devTexts;
        collectTexts(page, &devTexts);
        const QString devJoined = devTexts.join(QStringLiteral(" | "));
        QVERIFY2(devJoined.contains(QStringLiteral("开发人员 1")), qPrintable(devJoined));
        QVERIFY2(devJoined.contains(QStringLiteral("开发人员 6")), qPrintable(devJoined));
        QVERIFY2(!devJoined.contains(QStringLiteral("感谢人员 1")),
                 "contributor list must stay hidden until the Thanks segment is selected");
        window.grabWindow().save(QStringLiteral("/tmp/credits-developer.png"));

        // 切到「感谢」分段。
        auto *credits = findItemByObjectName(page, QStringLiteral("creditsPageHost"));
        QVERIFY(credits);
        credits->setProperty("tab", 1);
        QTest::qWait(300);
        QStringList thanksTexts;
        collectTexts(page, &thanksTexts);
        const QString thanksJoined = thanksTexts.join(QStringLiteral(" | "));
        QVERIFY2(thanksJoined.contains(QStringLiteral("感谢人员 1")), qPrintable(thanksJoined));
        QVERIFY2(thanksJoined.contains(QStringLiteral("感谢人员 6")), qPrintable(thanksJoined));
        // 一屏放得下时不应出现滚动条：Qt 6.5 的 AsNeeded 在 contentHeight
        // 恰好等于 height 时仍会保持可见，CreditsPage 用显式 visible 兜住了。
        auto *bar = findItemByObjectName(page, QStringLiteral("creditsScrollBar"));
        QVERIFY2(bar, "credits scroll bar missing");
        QVERIFY2(!bar->isVisible(), "a one-screen list must not show a scroll bar");
        window.grabWindow().save(QStringLiteral("/tmp/credits-thanks.png"));

        // 返回箭头只关页面，彩蛋入口保留。
        auto *back = findItemByObjectName(page, QStringLiteral("creditsBack"));
        QVERIFY2(back, "credits back button missing");
        const QPoint backAt = back->mapToScene(QPointF(back->width() / 2, back->height() / 2)).toPoint();
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, backAt);
        QTest::qWait(400);
        QCOMPARE(page->property("creditsOpen").toBool(), false);
        QCOMPARE(page->property("creditsRevealed").toBool(), true);
        QVERIFY2(entry->isVisible(), "back must keep the easter egg entry");

        // 「取消」：关页面并把彩蛋入口一起收回。
        page->setProperty("creditsOpen", true);
        QTest::qWait(400);
        auto *cancelButton = findItemByObjectName(page, QStringLiteral("creditsCancel"));
        QVERIFY2(cancelButton, "credits cancel button missing");
        const QPoint cancelAt = cancelButton->mapToScene(QPointF(cancelButton->width() / 2,
                                                                 cancelButton->height() / 2)).toPoint();
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, cancelAt);
        QTest::qWait(400);
        QCOMPARE(page->property("creditsOpen").toBool(), false);
        QCOMPARE(page->property("creditsRevealed").toBool(), false);
        QVERIFY2(!entry->isVisible(), "cancel must hide the easter egg entry again");

        // 再触发一次，供最后一段验证「关闭关于本机时名单页一并收起」。
        for (int i = 0; i < 5; ++i) QMetaObject::invokeMethod(page, "registerVersionTap");
        page->setProperty("creditsOpen", true);
        QTest::qWait(400);

        // 关闭关于本机：名单页必须一起收起。
        page->setProperty("open", false);
        QTest::qWait(350);
        QVERIFY(!credits->property("shown").toBool());
        QCOMPARE(page->property("creditsOpen").toBool(), false);
    }
};

QTEST_MAIN(AboutUiTest)
#include "about_ui_test.moc"
