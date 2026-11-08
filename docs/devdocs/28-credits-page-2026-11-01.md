# 关于本机 →「开发者与感谢」名单页（2026-11-01）

> 范围：`设置 → 关于本机` 新增一张入口卡片，点开从右侧滑入名单二级页。
> 名单目前是占位数据（开发人员 1–6、感谢人员 1–6），换真名只改两个数组。

## 1. 结构

```
关于本机
├─ 设备铭牌（名称 / 型号）
├─ 设备信息
├─ 开发者与感谢   ← 新入口卡片（开发者 6 · 致谢 6  ›）
├─ 运行记录
└─ 软件更新
        ↓ 点击入口，240ms OutCubic 从右侧滑入
开发者与感谢（二级页）
├─ ← 返回 / 标题
├─ 分段控件：[ 开发者 ] [ 感谢 ]
├─ 「COUNT 位开发者」小字
└─ 名单卡片：编号徽章 + 姓名 + 右侧组标签（6 行，发丝线分隔）
```

单独滑一页承载两个分组（而不是两组各一个二级页），因为一共 12 条占位条目，
拆两层导航只会让返回路径变长；分段切换是 Material 3 的标准 tab 语义。

## 2. 文件

| 文件 | 作用 |
| --- | --- |
| `qml/CreditsPage.qml` | 名单二级页，派生自 `RightSlidePage` |
| `qml/AboutDevicePage.qml` | 新增 `creditsOpen` 属性、入口卡片、`CreditsPage` 实例 |
| `qml/I18n.qml` | 名单与提示的英文词条 |
| `tests/about_ui_test.cpp` | 入口存在、滑入、两个分段、关闭归位、一屏内不显示滚动条 |

## 3. 视觉规则

沿用项目现有 `Theme` 深色 token 与 M3 列表语义，不引入第二套色板：

- **分组色**：开发者 `#4c9dff`（与「设备信息」卡同色，蓝=工程）、
  感谢 `#ad8cff`（与「运行记录」卡同色，紫=致谢）。两者都是项目里已有的强调色。
- **类型**：`CarText` 单一字体族。标题 `Theme.title`，姓名 `Theme.fontStrong`，
  组标签/人数 `Theme.fontCaption`（subdued）。
- **条目不编号成序列**：左侧圆形徽章写的是占位数据的 `badge` 字段（1–6），
  换成真名时填姓名首字即可，不是"01/02/03"式的流程编号。
- **动效只有两处**：整页滑入（240ms OutCubic，与开发者选项一致）；
  分段切换时胶囊底色 160ms 变色。名单行不做逐行入场。
- **一屏内不显示滚动条**：Qt 6.5 的 `ScrollBar.AsNeeded` 在 `contentHeight`
  恰好等于 `height` 时仍会保持可见，`CreditsPage` 用显式 `visible` 兜住这一类浮点边界。
  小屏内容超出一屏时仍可滚动。

## 4. 数据

```qml
property var developers: [
    { name: I18n.t("开发人员 1"), badge: "1", tag: I18n.t("开发") },
    ...
]
property var thanks: [
    { name: I18n.t("感谢人员 1"), badge: "1", tag: I18n.t("致谢") },
    ...
]
```

入口卡片上的人数摘要由数组长度算出（`开发者 D · 致谢 T`），改数据不用改布局。
换真实名单时只改这两个数组，以及对应的 `I18n.qml` 词条。

## 5. 交互细节

- 关于本机整体关闭时，`creditsOpen` 复位并调 `hideImmediately()`，
  下一次打开不会停在名单页；
- 名单页打开时 Esc 只关名单（父页的 Esc `Shortcut` 以 `!creditsOpen` 为条件），
  再按一次才关关于本机；
- 页面无输入框，不需要虚拟键盘，未新增 `keyboardRequested` 转发。

## 6. 测试

`tests/about_ui_test.cpp`（`ctest -R about_credits_page`）：

1. 关于本机里有 `creditsEntry` 且可见；
2. 置 `creditsOpen=true` 后滑入完成，文本包含「开发人员 1」「开发人员 6」，
   且不包含「感谢人员 1」（未切分段时另一组不渲染）；
3. 切 `tab=1` 后包含「感谢人员 1」「感谢人员 6」；
4. 关闭关于本机后名单页 `shown=false`、`creditsOpen=false`；
5. 一屏内 `creditsScrollBar` 不可见。

测试同时导出三张截图：`credits-developer.png`、`credits-thanks.png`、
`about-with-credits.png`（入口卡片在设备信息之后）。
