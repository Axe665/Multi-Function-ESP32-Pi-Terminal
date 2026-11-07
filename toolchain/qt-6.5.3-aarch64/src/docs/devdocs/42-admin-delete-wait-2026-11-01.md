# 删除账户：二次确认 + 4 秒等待层（2026-11-01）

## 1. 需求与共识

| 决定 | 结论 |
| --- | --- |
| 等待时长 | 至少 4 秒；删除是同步的，计时从删完那一刻开始，删得慢就多等 |
| 转圈样式 | Win10 五点圆环（五个点错开亮起，绕圈追逐） |
| 背景 | 主题深色（`Theme.background`），不突兀变黑 |
| 二次确认范围 | 删除账户（自删 + 管理员删他人）补一层；清空数据已有 `purgeConfirm`，不叠 |
| 等待层范围 | 所有删账户都走 |
| 失败处理 | 先删，成功才进等待层；失败留在弹窗里报错 |
| 确认框内容 | 标题 + 被删账户名 + 不可撤销警告 + 取消/永久删除 |

## 2. 删除账户：从一次点击变成三段

原来点「永久删除」就直接删。现在拆成：

```
输入 PIN → 验 PIN → 二次确认弹窗 → 真正删除
```

`UserSecurityPage.qml`：

```qml
function confirmOwnDelete() {
    if (!sessionManager.verifyPin(selfDeletePin.text)) {
        selfDeleteError.text = page.deleteErrorText("AUTH_FAILED")
        return
    }
    page.pendingDeleteIsSelf = true
    page.pendingDeleteName = sessionManager.activeDisplayName
    deleteConfirm.open()
}
```

- PIN 先校验：错了就地报错，不让用户连点两层才失败；
- 校验通过才开 `deleteConfirm`（`objectName: "deleteAccountConfirm"`），
  内容是被删账户名 + 「账户及其绑定数据会被永久删除，无法恢复。」+ 两个按钮；
- 点确认才走 `executeDelete()`，那里才真正调 `deleteOwnAccount` / `deleteUser`；
- 上级弹窗关闭时 `onClosed: deleteConfirm.close()`，避免确认框悬空；
- 自删成功时先把 `page.lastAdmin` 存下来再删——删完 `adminCount` 就变了。

## 3. 等待层

新增 `qml/AdminDeleteWait.qml`（`objectName: "accountDeleteWait"`）：

- 纯 `Theme.background` 铺底，居中一个五点圆环 + 「正在删除，请稍候」；
- 五个点固定在同一圆周（半径 `24 * scale`，点径 `12 * scale`），
  每圈 2 秒，每个点亮起占 1/5 圈、其余 4/5 圈缓慢退回暗态，五个点错开 1/5 圈；
- 暗态透明度 0.28：五个点始终看得见，只有亮度在跑，才像 Win10 的转圈
  （第一版用 0.18，真机上几乎只剩一个亮点，已调亮）；
- 隐藏时停掉动画（`running: wait.visible`），不在后台空转；
- 不新增色板、不新增字体，只用现有 `Theme.foreground` / `Theme.title`。

## 4. 接线

```
UserSecurityPage.accountDeleted(lastAdmin)
  → UserSecurityView.accountDeleted(bool)
    → Main: deletingAccount = true; accountDeleteWaitTimer.restart()   // 4000ms
      → AdminDeleteWait 显示（z=45000）
      → 4 秒后 deletingAccount = false
        → 首次开机向导 Loader 放行（z=50000）
```

`Main.qml`：

```qml
Loader {
    id:onboardingLoader
    active:onboarding.active && win.startupComplete && !win.deletingAccount
}
AdminDeleteWait {
    parent:Overlay.overlay; anchors.fill:parent; z:45000
    visible:win.deletingAccount
}
```

- 向导 z=50000 高于等待层，但等待层期间 `active` 为 false，两个全屏层不会抢同一帧；
- 等待层 z=45000 高于设置页（30）、门禁（20000）与应用弹窗（40000+），
  删除后即使 SessionGate 想弹登录页也会被盖住；
- 删除普通账户同样走这段：4 秒后回到账户列表或登录页。

## 5. 验证

- 构建通过；`ctest` 全量 72 项，69 通过，失败仍是既有的
  `arkpets_sprite_packing`、`ui_responsive_touch`、`ui_highdpi_touch`；
- 真机走完一遍（隔离环境 `XDG_CONFIG_HOME=/tmp/oobe-test111/config`）：
  1. 高级页 → 删除我的账户 → 输入 PIN → 等冷静期 → 永久删除；
  2. 弹出「确认删除账户？」「验收员」，点永久删除；
  3. 立刻进入等待层，1.2 s、3.4 s 两次截图都还在；
  4. 约 5.7 s 时已经进了首次开机向导「开始使用」。

## 6. 附：构建环境

`/tmp/oobe-build` 已被系统清理，重建时发现本机缺 `libssl-dev` / `libsqlcipher-dev`，
现成的开发文件在 `/home/yuanzingo/wark/.deps/root/usr`。重新配置用：

```bash
DEPS=/home/yuanzingo/wark/.deps/root/usr
cmake -S . -B /tmp/oobe-build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH;$DEPS" \
  -DCMAKE_LIBRARY_PATH="$DEPS/lib/x86_64-linux-gnu" \
  -DCMAKE_INCLUDE_PATH="$DEPS/include" \
  -DOPENSSL_ROOT_DIR=$DEPS -DOPENSSL_INCLUDE_DIR=$DEPS/include \
  -DOPENSSL_CRYPTO_LIBRARY=$DEPS/lib/x86_64-linux-gnu/libcrypto.so \
  -DOPENSSL_SSL_LIBRARY=$DEPS/lib/x86_64-linux-gnu/libssl.so \
  -DMBEDTLS_ROOT=$DEPS -DSQLCIPHER_ROOT=$DEPS
```

`OPENSSL_CRYPTO_LIBRARY` 必须显式给：`FindOpenSSL` 只在 `$DEPS/lib` 下找，
而库实际在 `$DEPS/lib/x86_64-linux-gnu`。
