#include <QApplication>
#include <QByteArray>
#include <QCommandLineParser>
#include <QIcon>
#include <QFontDatabase>
#include <QFont>
#include <QQuickStyle>
#include <QPainter>
#include <QPixmap>
#include <QSplashScreen>
#include <QCoreApplication>
#include <csignal>
#include <QTimer>
#include <QWindow>
#include <QQuickWindow>
#include <QScreen>
#include <QSysInfo>
#include <QElapsedTimer>
#include <QStringList>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>
#ifdef TERMINAL_HAVE_QUICKTHEME_PRIVATE
#include <QtQuickTemplates2/private/qquicktheme_p.h>
#endif

#include "app/TerminalOptions.h"
#include "net/NetChannels.h"
#include "app/AdminInitializer.h"
#include "app/TerminalRuntime.h"
#include "ui/TerminalUi.h"
#include "SchemeRegistry.h"

// PGO：instrumented 构建里由 gcov 运行时提供；普通构建里是空弱符号。
extern "C" void __gcov_dump(void) __attribute__((weak));

namespace {

// 启动期原生 splash：Linux 控制台风格的滚动日志。
// 只显示真实信息（内核/架构/Qt/平台/配置），加一行真实耗时的“仍在初始化”，
// 不伪造阶段进度；QML 窗口一可见就被 main() 里替换/关闭。
class BootConsole : public QSplashScreen
{
public:
    explicit BootConsole(const QSize &size) : size_(size)
    {
        lines_ << QStringLiteral("Linux %1 %2").arg(QSysInfo::kernelVersion(),
                                                    QSysInfo::currentCpuArchitecture())
               << QStringLiteral("qt %1 · platform %2 · display %3")
                      .arg(QString::fromLatin1(qVersion()),
                           QGuiApplication::platformName(),
                           QString::fromLocal8Bit(qgetenv("DISPLAY")))
               << QStringLiteral("init: 加载产品配置与控制桥 profile")
               << QStringLiteral("init: 启动 QML 引擎与 WebEngine（首次加载较慢）");
        clock_.start();          // 必须先 start：QElapsedTimer 未启动时 elapsed() 是未定义值
        setPixmap(render());
        ticker_.setInterval(120);
        QObject::connect(&ticker_, &QTimer::timeout, this, [this] { setPixmap(render()); });
        ticker_.start();
    }

    void note(const QString &text) { lines_ << text; setPixmap(render()); }

private:
    QString stamp() const
    {
        const qint64 ms = clock_.elapsed();
        return QStringLiteral("[%1.%2]")
            .arg(ms / 1000, 5, 10, QLatin1Char(' '))
            .arg(ms % 1000, 3, 10, QLatin1Char('0'));
    }

    QPixmap render() const
    {
        QPixmap pm(size_);
        pm.fill(QColor(5, 8, 11));
        QPainter p(&pm);
        p.setRenderHint(QPainter::TextAntialiasing);
        QFont base = QFontDatabase::systemFont(QFontDatabase::FixedFont);
        base.setPixelSize(15);
        p.setFont(base);

        const int margin = 28;
        const int lineHeight = 22;
        const int maxLines = qMax(6, (size_.height() - 2 * margin - lineHeight) / lineHeight);
        int y = margin + base.pixelSize();
        const QColor dim(95, 113, 131);
        const QColor ink(207, 218, 230);

        // 头部：伪 tty 横幅
        p.setPen(dim);
        p.drawText(margin, y, QStringLiteral("orpi-terminal boot console · tty1"));
        y += lineHeight;

        QStringList visible = lines_;
        while (visible.size() > maxLines - 2) visible.removeFirst();
        // 时间戳列固定宽度，按实际字体度量，避免和正文重叠
        const int stampWidth = p.fontMetrics().horizontalAdvance(QStringLiteral("[99999.999]"));
        const int textX = margin + stampWidth + 14;
        for (const QString &line : visible) {
            p.setPen(dim);
            p.drawText(margin, y, stamp());
            p.setPen(line.startsWith(QLatin1String("init:")) ? QColor(210, 153, 34) : ink);
            p.drawText(textX, y, line);
            y += lineHeight;
        }

        // 实时行 + 闪烁光标
        p.setPen(dim);
        p.drawText(margin, y, stamp());
        p.setPen(QColor(110, 231, 135));
        p.drawText(textX, y, QStringLiteral("启动中，请稍候 …"));
        if ((clock_.elapsed() / 500) % 2 == 0) {
            const int w = p.fontMetrics().horizontalAdvance(QStringLiteral("启动中，请稍候 …"));
            p.fillRect(QRect(textX + w + 6, y - base.pixelSize(), 9, base.pixelSize()),
                       QColor(110, 231, 135));
        }
        p.end();
        return pm;
    }

    QSize size_;
    QStringList lines_;
    QElapsedTimer clock_;
    QTimer ticker_;
};


// QGuiApplication::setFont() 只影响普通 Text；Material 控件从 QQuickTheme
// 的各 Scope 取字体，默认是 Roboto。这里先让 Controls 插件创建主题实例，
// 再逐个 Scope 只替换 family，保留每个控件原本的 px/pt 字号。
//
// QQuickTheme 是私有接口：官方 Qt 安装器自带私有头，Debian/Ubuntu 把它拆到
// qt6-declarative-private-dev（Qt 6.4.2 系统包默认不带）。没有私有头时退回
// 仅 setFont() 的 System scope，构建不再因缺头失败。
void applyControlFontFamily(const QFont &applicationFont)
{
#ifdef TERMINAL_HAVE_QUICKTHEME_PRIVATE
    // 独立热身引擎：初始化 Controls 主题；销毁后 QQuickTheme 的全局实例
    // 仍会保留字体设置，后续 TerminalRuntime 的引擎直接复用。
    QQmlEngine warmEngine;
    QQmlComponent warmup(&warmEngine);
    warmup.setData("import QtQuick\nimport QtQuick.Controls\nItem {}",
                   QUrl(QStringLiteral("qrc:/font-theme-warmup.qml")));
    QObject *warm = warmup.create();
    if (!warm) {
        qWarning().noquote() << "font-theme: warmup failed:" << warmup.errorString();
        return;
    }

    QQuickTheme *theme = QQuickTheme::instance();
    if (!theme) {
        delete warm;
        qWarning("font-theme: QQuickTheme unavailable; controls keep style font");
        return;
    }

    QFont base[QQuickTheme::Tumbler + 1];
    for (int scope = QQuickTheme::System; scope <= QQuickTheme::Tumbler; ++scope)
        base[scope] = QQuickTheme::font(static_cast<QQuickTheme::Scope>(scope));
    base[QQuickTheme::System] = applicationFont;

    for (int scope = QQuickTheme::System; scope <= QQuickTheme::Tumbler; ++scope) {
        QFont font = base[scope];
        font.setFamily(applicationFont.family());
        theme->setFont(static_cast<QQuickTheme::Scope>(scope), font);
    }
    delete warm;
#else
    Q_UNUSED(applicationFont);
    qInfo().noquote() << "font-theme: QQuickTheme private API unavailable;"
                         " controls keep style default font";
#endif
}

}  // namespace

int main(int argc, char **argv) {
    QByteArray chromiumFlags=qgetenv("QTWEBENGINE_CHROMIUM_FLAGS");
    if(!chromiumFlags.contains("--touch-events=")) {
        if(!chromiumFlags.isEmpty()) chromiumFlags.append(' ');
        chromiumFlags.append("--touch-events=enabled");
    }
    // 浏览器是独立网络栈（Chromium），只能在进程启动前用参数把它指向本地代理。
    // 端口来自 NetChannels，避免与 TerminalApplication/代理端漂移；代理关闭该
    // 通道时会回 403，Chromium 表现为 ERR_TUNNEL_CONNECTION_FAILED。
    // --disable-quic：QUIC 走 UDP，不经过 HTTP 代理，必须关掉。
    if(!chromiumFlags.contains("--proxy-server=")) {
        if(!chromiumFlags.isEmpty()) chromiumFlags.append(' ');
        chromiumFlags.append("--proxy-server=http://127.0.0.1:"
                             + QByteArray::number(NetChannels::BrowserPort)
                             + " --disable-quic");
    }
    if(!chromiumFlags.isEmpty()) qputenv("QTWEBENGINE_CHROMIUM_FLAGS",chromiumFlags);
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    QQuickStyle::setStyle("Material");
    SchemeRegistry::registerSchemes();
    QtWebEngineQuick::initialize();

    QApplication application(argc, argv);
    // PGO：正常退出时把 .gcda 落盘（非 instrumented 构建里符号为 weak/null）。
    QObject::connect(&application, &QCoreApplication::aboutToQuit, [] {
        if (__gcov_dump) __gcov_dump();
    });
    std::signal(SIGTERM, [](int) { QCoreApplication::quit(); });
    std::signal(SIGINT, [](int) { QCoreApplication::quit(); });
    application.setApplicationVersion(QStringLiteral(ORANGE_PI_VERSION));
    initializeTerminalUi();
    const int googleSansId=QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/GoogleSans.ttf"));
    if(googleSansId>=0) {
        const auto families=QFontDatabase::applicationFontFamilies(googleSansId);
        if(!families.isEmpty()) {
            QFont appFont(families.first());
            appFont.setPointSize(18);
            application.setFont(appFont);
            applyControlFontFamily(appFont);
            qInfo().noquote() << "UI_FONT_FAMILY:" << families.first();
        }
    } else qWarning() << "Google Sans resource unavailable; using system fallback font";
    application.setWindowIcon(QIcon(QStringLiteral(":/icons/orange_pi_terminal.svg")));
    application.setOrganizationName("ModularTerminal");
    application.setApplicationName("OrangePiTerminal");

    QCommandLineParser options;
    TerminalOptions::configure(options);
    options.process(application);
    if (options.isSet(QStringLiteral("quit-after")))
        QTimer::singleShot(options.value(QStringLiteral("quit-after")).toInt(),
                           &application, [&application] { application.quit(); });

    // 首次管理员初始化在起 UI 之前完成：无用户时可运行，之后永久拒绝。
    const int initResult = AdminInitializer::run(options);
    if (initResult >= 0) return initResult;

    // 启动黑屏期：QML 引擎加载 + SystemTools/WebEngine 初始化要几十秒，
    // 先用纯 C++ splash 占位；QML 窗口可见后自动关闭。
    QSize splashSize(1024, 600);
    if (QScreen *screen = QGuiApplication::primaryScreen())
        splashSize = screen->geometry().size();
    BootConsole splash(splashSize);
    splash.show();
    application.processEvents();

    // QML 窗口一可见就撤掉 splash（轮询，避免依赖 QML 侧信号）。
    QTimer splashWatcher;
    QObject::connect(&splashWatcher, &QTimer::timeout, &splash, [&splash] {
        for (QWindow *w : QGuiApplication::topLevelWindows()) {
            if (w == splash.windowHandle()) continue;
            if (w->isVisible() && w->isExposed()) {
                splash.note(QStringLiteral("OK: 桌面窗口已呈现，关闭启动日志"));
                splash.close();
                break;
            }
        }
    });
    splashWatcher.start(200);

    TerminalRuntime runtime(application, options);
    return runtime.run();
}
