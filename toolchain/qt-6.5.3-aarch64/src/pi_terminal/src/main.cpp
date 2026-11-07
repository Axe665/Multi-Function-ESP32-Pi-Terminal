#include <QApplication>
#include <QByteArray>
#include <QCommandLineParser>
#include <QIcon>
#include <QFontDatabase>
#include <QFont>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>
#include <QtQuickTemplates2/private/qquicktheme_p.h>

#include "app/TerminalOptions.h"
#include "net/NetChannels.h"
#include "app/AdminInitializer.h"
#include "app/TerminalRuntime.h"
#include "ui/TerminalUi.h"
#include "SchemeRegistry.h"

namespace {

// QGuiApplication::setFont() 只影响普通 Text；Material 控件从 QQuickTheme
// 的各 Scope 取字体，默认是 Roboto。这里先让 Controls 插件创建主题实例，
// 再逐个 Scope 只替换 family，保留每个控件原本的 px/pt 字号。
void applyControlFontFamily(const QFont &applicationFont)
{
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

    // 首次管理员初始化在起 UI 之前完成：无用户时可运行，之后永久拒绝。
    const int initResult = AdminInitializer::run(options);
    if (initResult >= 0) return initResult;

    TerminalRuntime runtime(application, options);
    return runtime.run();
}
