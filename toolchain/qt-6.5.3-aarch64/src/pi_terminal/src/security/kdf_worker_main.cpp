// KDF 子进程：只做 PBKDF2，不碰 SQLite、不碰用户数据、不写磁盘。
//
// 为什么要有这个进程：登录必须算一次 600k 次 PBKDF2，而这段计算如果放在
// 主线程，Qt 的场景图就不会更新——动画停、点击无响应（Pi 上尤其明显）。
// 放线程里试过：SQLite/OpenSSL 的进程级全局状态会跨线程自锁，实测登录永久卡死。
// 进程隔离不共享这些状态，主进程全程只等管道，UI 能保持流畅。
//
// 协议（一行一条，UTF-8，\n 结尾）：
//   请求：kdf <iterations> <salt_hex> <pin_hex>
//   成功：ok <kek_hex>
//   失败：err <reason>
// PIN 只在这条管道里出现，不落盘、不写日志。
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>

#include "security/PinPolicy.h"

namespace {

std::string trim(const std::string &s)
{
    const auto first = s.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    const auto last = s.find_last_not_of(" \t\r\n");
    return s.substr(first, last - first + 1);
}

// 只接受严格的偶数长度十六进制，避免半截输入被当成合法参数。
bool parseHex(const std::string &text, QByteArray *out)
{
    if (text.empty() || text.size() % 2 != 0) return false;
    for (const char c : text) {
        const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!hex) return false;
    }
    *out = QByteArray::fromHex(QByteArray::fromStdString(text));
    return true;
}

}  // namespace

int main()
{
    // 行缓冲：每算完一条必须立刻刷出去，主进程在等它。
    std::ios::sync_with_stdio(false);

    std::string line;
    while (std::getline(std::cin, line)) {
        line = trim(line);
        if (line.empty()) continue;
        if (line == "quit") break;

        // 解析 "kdf <iterations> <salt_hex> <pin_hex>"
        const auto sp1 = line.find(' ');
        const auto sp2 = line.find(' ', sp1 + 1);
        const auto sp3 = line.find(' ', sp2 + 1);
        if (sp1 == std::string::npos || sp2 == std::string::npos || sp3 == std::string::npos
            || line.substr(0, sp1) != "kdf") {
            std::cout << "err bad-request\n" << std::flush;
            continue;
        }

        const std::string iterText = line.substr(sp1 + 1, sp2 - sp1 - 1);
        const std::string saltText = line.substr(sp2 + 1, sp3 - sp2 - 1);
        const std::string pinText = line.substr(sp3 + 1);

        char *end = nullptr;
        const long iterations = std::strtol(iterText.c_str(), &end, 10);
        // 迭代数下限与上限都卡住：前者防降级攻击，后者防一次请求把设备拖死。
        if (end == iterText.c_str() || iterations < 1 || iterations > 50000000) {
            std::cout << "err bad-iterations\n" << std::flush;
            continue;
        }

        QByteArray salt;
        QByteArray pinBytes;
        if (!parseHex(saltText, &salt) || !parseHex(pinText, &pinBytes)) {
            std::cout << "err bad-hex\n" << std::flush;
            continue;
        }

        const QString pin = QString::fromUtf8(pinBytes);
        const QByteArray kek = security::PinPolicy::deriveKek(pin, salt, static_cast<int>(iterations));
        if (kek.isEmpty()) {
            // 空结果只可能来自参数不合法（PIN 格式/盐长度），不泄漏细节。
            std::cout << "err invalid-params\n" << std::flush;
            continue;
        }
        std::cout << "ok " << kek.toHex().toStdString() << "\n" << std::flush;
    }
    return 0;
}
