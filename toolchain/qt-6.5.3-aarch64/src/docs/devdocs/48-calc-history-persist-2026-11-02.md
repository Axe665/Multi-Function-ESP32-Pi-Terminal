# 计算器历史：持久化 + 常驻 + 逐条删除（2026-11-02）

## 1. 需求

计算器原来的历史只是内存数组（`calcHistory`，最多 20 条），页面里也没有面板：

- 重启终端就丢；
- 没记录时整块面板隐藏，布局会跳。

现在要：**写进设置**（重启还在）、**面板常驻**（空时显示「暂无记录」）、**每条可单独删除**。

## 2. 后端

`SystemTools` 的页面设置白名单加了 `calc/` 前缀：

```cpp
static const QStringList prefixes{QStringLiteral("time/"), QStringLiteral("weather/"),
                                  QStringLiteral("layout/"), QStringLiteral("about/"),
                                  QStringLiteral("calc/")};
```

没有它 `settingsWrite("calc/history", …)` 会被拒绝（日志里会有 `page settings: rejected key`）。

## 3. 前端（`Main.qml`）

初始化时从设置读：

```qml
property var calcHistory: {
    if (typeof systemTools === "undefined" || !systemTools) return []
    const raw = systemTools.settingsRead("calc/history", "")
    if (raw.length === 0) return []
    try {
        const parsed = JSON.parse(raw)
        return Array.isArray(parsed) ? parsed : []
    } catch (e) { return [] }
}
```

写盘时机：每次 `=` 之后、清空、单条删除。

```qml
function saveCalcHistory() { systemTools.settingsWrite("calc/history", JSON.stringify(calcHistory)) }
function removeCalcHistoryAt(index) { /* 摘掉一条 */ saveCalcHistory() }
function clearCalcHistory() { calcHistory = []; saveCalcHistory() }
```

面板：

- 去掉 `visible: calcHistory.length > 0`，改成常驻；
- 空列表时显示「暂无记录」；
- 每条右侧加一个 `IconButton`（`iconName: "close"`），直接删这一条；
- 「清空」按钮在没有记录时禁用。

## 4. 验证

真机 1024×600：

| 检查 | 结果 |
| --- | --- |
| 面板常驻、空态文案 | 「历史 + 清空 + 暂无记录」正常显示 |
| 算 `1+2=` | 历史出现 `1+2 =` / `3`，右侧有 × |
| 清空 | 历史清空并回到「暂无记录」 |
| 落盘 | `~/.config/ModularTerminal/OrangePiTerminal.conf` 里出现 `[calc] history=[]` |

**没验证的**：单条删除的 × 按钮——真机上我的点击坐标一直对不上（窗口缩放和坐标换算反复出错），
只确认了按钮渲染出来，没实际点中。代码路径和「清空」共用同一套 `saveCalcHistory()`。
