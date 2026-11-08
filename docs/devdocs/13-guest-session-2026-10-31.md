# 临时用户（访客会话）

> 2026-10-31。补上 `12-ui-account-round-2026-10-30.md` 里反复引用、但**从未存在**的「§7 临时用户设计」。

## 0. 一句话现状

访客可无密码进入，数据在独立目录、加密落盘、退出即删；看不到设置、连接管理、用户与权限；锁屏固定 5 分钟。

## 1. 背景：这个设计为什么迟到了

`12-ui-account-round-2026-10-30.md` 有三处写「设计见 §7 / 交接文档 §7，代码未开工」，但：

- 交接文档 `08-handoff-to-L.md` 里没有 §7；
- 全仓库 `git log --all -S "临时用户"` 只有那两个文档提交；
- 历史文件名从未出现过 `guest` / `visitor`。

也就是说**只有一句规划，没有设计、没有代码**。本文件把设计补齐，并记录实现。

## 2. 决策（逐条为准则）

| 项 | 决定 | 理由 |
| :--- | :--- | :--- |
| 数据生命周期 | 每次会话独立目录，**退出即删** | 最符合「临时」语义，不留下任何痕迹 |
| 加密 | SQLCipher + **随机内存密钥** | 访客没有 PIN，不存在「用 PIN 派生」；密钥只存内存，退出随对象销毁 |
| 权限 | 浏览器、文件（仅自己目录）、音乐、天气、计算器、画图、便签可用；**禁设置、用户与权限、连接管理、配对** | 日常够用，但不碰系统级配置与账户 |
| 进入 | 登录页左下角「访客登录」，**无需 PIN** | 和 ChromeOS 的 Browse as guest 一致 |
| 退出 | 右上角「访客会话 · 退出」；锁屏的「退出登录」在访客态也走同一路径 | 必须有明确收尾点，否则「退出即删」落不了地 |
| 锁屏 | **固定 5 分钟**，且访客改不动 | 没有用户记录可读，也不该让访客改 |
| 浏览器 | WebEngine 存储/缓存/下载切到会话专属临时目录，退出整棵删 | 只隔离数据库不够，cookie 与 localStorage 也会串 |

## 3. 实现

### 3.1 会话（`SessionManager`）

```cpp
QString startGuestSession();   // 空串=成功；返回错误码时 UI 直接显示
void    endGuestSession();
bool    isGuest() const;
Q_PROPERTY(bool guestSession READ isGuest NOTIFY changed)
```

- userId 为 `guest<base36 时间戳>`：只含小写字母与数字，能通过 `openForSession`/`discardSession`
  共用的字符白名单（这两个接口都要拼路径，白名单是防穿越的唯一一道）。
- 库密钥 32 字节随机、只存内存；`begin()` 之后立即 `dbKey.fill('\0')`。
- 沿用 `begin()` + `openDatabase()`，**没有另开一套会话机制**——访客在这一层就是「一个没有用户记录的用户」。
- `openDatabase()` 失败时同样走 `endGuestSession()`：宁可回到登录页，也不留「已登录但没库」的态。

### 3.2 存储（`UserDatabase::discardSession`）

```cpp
bool discardSession(const QString &userId);   // 关库 + 删整个目录
```

删除前用与 `openForSession` **完全相同**的白名单校验 userId——删目录比开库更不能容忍路径穿越。

### 3.3 浏览器（`ViperBrowserController::setGuestProfile`）

不换 profile（换掉会丢正在运行的页面与 cookie store 连接），只切路径：

```
$XDG_CACHE_HOME/<app>/guest-web/guest<id>/storage   → setPersistentStoragePath
                                      /cache        → setCachePath
                                      /downloads    → setDownloadPath
```

进入时先 `deleteAllCookies()`，避免继承上一个用户的会话态；退出时路径复位并把 `guest-web` 整棵删掉。

### 3.4 界面

- `LoginPage.qml`：用户列表下方「访客登录」（`objectName: guestLoginButton`），与列表同一条左边线。
- `Main.qml`：`builtin(page)` 对访客屏蔽 route 1/4/15；右上角「访客会话 · 退出」条（`guestBanner`）。
- **坑**：`syncCards()` 原来只在启动时跑一次，访客登录后卡片表仍是登出状态那份，过滤等于没做。
  现在挂到 `SessionManager::changed`。

## 4. 权限边界怎么落地

两层：

1. **入口隐藏**（`builtin()` 返回空 entry）：访客看不到设置/连接管理/用户与权限。
2. **真正的拒绝**：`ownLockTimeoutMinutes()` 对访客固定 5、`setOwnLockTimeout()` 直接 false；
   账户类操作在 `SecurityService` 里本来就要管理员身份，访客 `admin_ = false` 自然过不去。

隐藏入口只是体验，安全靠第二层。

## 5. 测试

`session_gate_test::guestSessionLivesAndDiesCleanly`

- 无 PIN 进入成功；`isGuest()`/`loggedIn()` 为真、`isAdmin()` 为假；
- 库真的打开（`database() != nullptr`）；
- 锁屏固定 5 分钟，`setOwnLockTimeout(30)` 被拒；
- 退出后**按具体 id** 断言目录消失（不数目录个数——别的测试可能留下 `guest*`）。

手工验收（Xvfb :82，真实二进制）：

```
点「访客登录」→ 无 PIN 进桌面；设置/连接管理/用户与权限消失
日志：browser profile: guest at …/guest-web/guest<id>
      guest session started: guest<id>
点右上角「退出」→ 回登录页
日志：browser profile: back to default / guest session ended: guest<id>
users/guest* 目录 1 → 0；guest-web 目录已删除
```

## 6. 未做

- **访客状态栏**：底部 Linux 风格状态栏按需求跳过（不属于本轮）。
- ~~访客可见「最近使用」列表~~：已修。`recentApps` 是内存 `ListModel`（不落盘），
  但跨会话存活，访客打开过什么会留给下一个登录的人。现在挂到 `SessionManager::changed`，
  `!loggedIn` 时清空。实测：访客打开 1 个应用 → 退出 → `recent apps cleared, count= 1`
  → `guest session ended`。
- **Pi 实机**：从 2026-10-30 19:44 起 `192.168.77.1` 不可达（ping 无响应、ssh 被关闭），
  访客功能只有主机与单测证据，没有目标机证据。
