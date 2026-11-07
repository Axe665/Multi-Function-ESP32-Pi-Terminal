# 联网权限二级页（六个分功能开关）

> 2026-10-31。设置页「联网权限」只留总开关与入口，六个分功能开关移入右侧滑入的二级页。
> 同轮修掉「单独开关点了没反应」的绑定 bug。

## 0. 一句话

设置 → 联网权限：总开关 + 说明 + 「管理各功能联网」；点进去是六行开关（只有功能名，不带描述小字），页面底部没有额外说明文字。
开关点一下立即生效、立即刷新。

## 1. Bug：为什么单独开关点了没反应

`NetworkPermissions.qml` 里的六个默认按钮写的是：

```qml
checked: networkGate.featureEnabled("browser")
onClicked: networkGate.setFeatureEnabledFromUi("browser", !networkGate.featureEnabled("browser"))
```

`featureEnabled()` 是 `Q_INVOKABLE` **方法**。QML 的绑定只追踪属性读取，不追踪方法调用，
所以 `changed()` 发出后这个绑定不会重新求值：C++ 里的状态已经切了，按钮外观还停在旧值，
看起来就是“点了没反应”。

`NetworkGate` 本来就有 `browserAllowed` / `musicAllowed` / … 六个 `Q_PROPERTY`（`NOTIFY changed`），
二级页改用属性绑定即可：

```qml
checked: networkGate.browserAllowed
onClicked: networkGate.setFeatureEnabledFromUi("browser", !networkGate.browserAllowed)
```

修完实测：点一下开关立刻变蓝，再点变灰，C++ 状态与界面同步。

## 2. 结构

| 位置 | 内容 |
|---|---|
| 设置页 `NetworkPermissions.qml` | 总开关（关闭前仍需确认弹窗）+ 一行状态说明 + 「管理各功能联网」入口 |
| 二级页 `NetworkPermissionsPage.qml` | 六行应用级开关（浏览器 / 音乐 / 网络电视 / 天气 / 网络校时 / 更新下载）；v2 不再有域名编辑或预置 |
| 交互 | 右侧滑入 240 ms（同关于本机/连接设置），返回箭头或 Esc 关闭；每次打开从顶部开始。首次打开后 Loader 保持实例，打开/返回都有滑入滑出动画；关闭/切换/最小化应用时由 `Main.closeAuxiliaryPanels()` 收起，不能带到下一个应用 |
| 置灰 | 总开关关闭时六个开关 `enabled: false`，但各自状态保留；重新打开总开关原样恢复 |

每行只有功能名（用正文默认字号，与「关闭」「完成」等按钮文字同级），不再带描述小字；
行高 64，图标与文字垂直居中。
## 3. 布局坑（值得记）

`SettingsGroup` 的内容容器是 **`ColumnLayout`**。行如果只写 `width` / `height` 而没有
`Layout.fillWidth` + `implicitHeight`，ColumnLayout 会按 `implicitWidth/implicitHeight = 0` 布局，
结果是行被压扁、标题与开关都看不见（第一版就踩了）。正确写法：

```qml
Item {
    Layout.fillWidth: true
    implicitHeight: 76 * Theme.scaleFactor
    ...
}
```

## 4. 代码位置

| 文件 | 作用 |
|---|---|
| `qml/NetworkPermissions.qml` | 设置页分区：总开关 + 入口 + 关闭确认 |
| `qml/NetworkPermissionsPage.qml` | 二级页：六个应用开关、说明 |
| `qml/Main.qml` | `networkPermissionsOpen`、页面挂载、Esc 守卫、打开二级页时禁用下层设置页 |
| `qml/I18n.qml` | 新文案中英对照 |
| `CMakeLists.txt` | 新 QML 文件加入 `UI_QML_FILES` |

## 5. 验证

- 点「管理各功能联网」→ 右侧滑入；返回箭头/Esc 关闭。
- 点「浏览器联网」开关：立即变蓝；再点立即变灰（bug 修复的关键证据）。
- 总开关关闭 → 重新进页：六个开关全部置灰，各自状态保留；
  列表底部显示「总开关已关闭，以上开关暂时不可改…」。
- 重新打开总开关 → 六个开关恢复可点，先前状态原样。
- 关闭确认弹窗（取消 / 确认关闭）文案与行为不变。
- 日志无 QML 报错。

## 6. 没验证的

- 英文界面下六项说明与三态的逐条词表命中（已补 `I18n.qml`）。
- 普通用户与访客两条账号路径（可见性沿用设置页原有规则，未改）。
