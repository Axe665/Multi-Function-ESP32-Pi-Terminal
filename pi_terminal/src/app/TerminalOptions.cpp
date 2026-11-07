#include "TerminalOptions.h"

#include <QCommandLineParser>

namespace TerminalOptions {

void configure(QCommandLineParser &parser) {
    parser.addHelpOption();
    parser.addOptions({{{"c", "config"}, "Product configuration JSON", "path"},
                       {"demo", "Attach simulator module 80"},
                       // 只给人工/自动化测试用：跳过登入门禁，不需要 PIN。
                       // 与 --ui-test 的区别是它不跑自动点按脚本，人可以正常操作。
                       {"no-login", "Test-only: skip the login gate without a PIN (no automation)"},
                       {"quit-after", "Quit after milliseconds", "ms"},
                       {"screenshot", "Save a window screenshot before quitting", "path"},
                       {"metrics", "Write frame-delivery and process-memory metrics on exit", "path"},
                       {"render-benchmark", "Continuously animate the actual home carousel for rendering measurements"},
                       {"notification-test", "Show a diagnostic notification and test Chinese speech"},
                       {"quick-panel-test", "Open Android-style quick settings panel for screenshot verification"},
                       {"paint-test", "Open the drawing app and report canvas geometry/state"},
                        {"app-drawer-test", "Open the application drawer and report its responsive geometry"},
                        {"keyboard-test", "Open the floating keyboard and verify local Chinese candidates"},
                        {"window-animation-test", "Audit app-card paging and window size animations"},
                       {"notification-layout-test", "Show example app-icon notification cards in the quick panel"},
                       {"notification-banner-test", "Show one app-style notification banner for screenshot verification"},
                       {"window-size", "Initial logical window size, e.g. 800x480", "size"},
                       {"preview-page", "Open a built-in page for target-screen layout testing", "page"},
                       {"open-module", "Open this ready module session in the foreground", "instance"},
                       {"invoke-action", "Invoke an available action after opening the module", "action"},
                       {"ui-audit", "Run responsive layout and injected touch tests", "directory"},
                       {"ui-test", "Exercise dynamic page/actions/disconnect automatically"},
                       // 首次管理员初始化：本地受控、无默认 PIN。注册表非空时拒绝。
                       {"init-admin", "Create the first administrator (local initialisation only); "
                                      "asks for PIN on stdin unless --init-pin-stdin is given", "display-name"},
                       {"init-pin-stdin", "Read the initial administrator PIN from stdin instead of a TTY prompt"},
                       // 首次开机向导（OOBE）：注册表为空时默认进入。仅调试/自动化绕过，
                       // 绕过时 qInfo 留痕；生产环境不要设置。
                       {"skip-onboarding", "Test-only: bypass the first-run setup wizard"},
                       // 注册表为空时默认会清掉上一次跑留下的鉴权与用户数据残留；
                       // 需要保留现场（排查用）时加这个开关。
                       {"keep-stale-data", "Keep leftover profile data even when no user exists"}});
}

} // namespace TerminalOptions
