# 「开发者与感谢」改成彩蛋（2026-11-01）

## 1. 需求

「关于本机」里原本常驻一张「开发者与感谢」卡片，点进去是名单页。改成彩蛋：

1. 默认不显示这张卡片；
2. 连点「版本号」那一行 5 次才出现；
3. 名单页里加一个「取消」，关掉页面并把彩蛋收回。

## 2. 实现

### 2.1 触发（`qml/AboutDevicePage.qml`）

```qml
property bool creditsRevealed: false   // 彩蛋开没开
property int creditsTapCount: 0        // 连点计数

function registerVersionTap() {
    if (creditsRevealed) return
    creditsTapCount += 1
    creditsTapReset.restart()
    if (creditsTapCount >= 5) {
        creditsTapCount = 0
        creditsTapReset.stop()
        creditsRevealed = true
    }
}

Timer {                                 // 1.5 秒窗口，停手就清零
    id: creditsTapReset
    interval: 1500
    onTriggered: page.creditsTapCount = 0
}
```

- 版本号行 `AboutInfoRow`（`objectName: "aboutInfoVersion"`）内部挂一个
  `MouseArea { anchors.fill: parent; onClicked: page.registerVersionTap() }`，
  行本身没有其它交互，不会抢焦点；
- 计数用 1.5 秒窗口：零散点击凑不满 5 次，也不会因为手慢一点就失效；
- 状态只在本次运行内保持，不写 QSettings，重启即回到隐藏态。

### 2.2 显示与收回

```qml
SettingsGroup {
    visible: page.creditsRevealed     // 卡片整块不占位
    ...
}
```

```qml
CreditsPage {
    open: page.creditsOpen
    onCloseRequested: page.creditsOpen = false        // 返回箭头：只关页面
    onCancelRequested: {                              // 取消：关页面 + 收回彩蛋
        page.creditsOpen = false
        page.creditsRevealed = false
    }
}
```

两种退出方式的区别是刻意的：

| 操作 | 页面 | 彩蛋入口 |
| --- | --- | --- |
| 左上角返回箭头 / Esc | 关闭 | 保留 |
| 右上角「取消」 | 关闭 | 收回 |

### 2.3 「取消」按钮（`qml/CreditsPage.qml`）

`CreditsPage` 新增 `signal cancelRequested()`，标题行右侧加一个 `CarButton`
（`objectName: "creditsCancel"`，文案复用已有的 `I18n.t("取消")`）。
标题宽度改为 `header.width - backButton.width - cancelButton.width`，其余不变。

## 3. 测试

`tests/about_ui_test.cpp`（`about_credits_page`）补了四段断言，全部走 QML 的
`registerVersionTap()` 与真实鼠标点击：

1. 初始 `creditsEntry` 不可见、`creditsRevealed === false`；
2. 点 4 次仍不可见，第 5 次后 `creditsRevealed === true` 且入口可见；
3. 点返回箭头：页面关闭、入口仍在；
4. 点「取消」：页面关闭、`creditsRevealed === false`、入口再次不可见。

最后再触发一次彩蛋，验证原有「关闭关于本机时名单页一并归位」。

## 4. 验证

- 构建通过；`ctest -R about_credits_page` 通过（3.97 s）；
- `ctest` 全量：72 项，69 通过，失败仍是既有的
  `arkpets_sprite_packing`、`ui_responsive_touch`、`ui_highdpi_touch`；
- 真机流程：连点版本号 5 次 → 卡片出现 → 进入名单页 → 点「取消」→ 卡片消失。
