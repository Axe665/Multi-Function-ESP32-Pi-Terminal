# 天气设置：分类卡片 + 滑入二级页（2026-11-01）

> 范围：`WeatherSettings.qml` 与 `WeatherTools.qml` 的设置层容器。
> 控件、绑定、`objectName` 与 `WeatherEngine` 全部沿用；只改导航与视觉结构。

## 1. 结构

```
天气设置（右上角齿轮打开）
├─ 主页：两列分类卡片
│   ├─ 数据源        顺序、启用与连通性测试
│   ├─ OpenWeather   API Key 与接口版本
│   ├─ 自定义 API     URL、Key 与字段映射
│   ├─ MET Norway    请求头里的联系邮箱
│   └─ 刷新与单位    自动刷新间隔与公制/英制
└─ 点卡片 → 240ms 从右侧滑入二级页
    ├─ 顶部只有「← 返回 + 分类名」
    └─ 页内是原来的分组内容（分组标题已去掉，不再重复）
```

与「用户与权限」主页同一套卡片语言：2 列、`surfaceContainer` 底、
`outlineVariant` 描边、hover 变 `accent`、左圆形图标（分类强调色）+ 标题 + 描述 + 右箭头。

## 2. 改动点

- `WeatherSettings.qml` 根从 `SettingsGroup` 改为 `Item`：
  - 新增 `section`（-1 主页 / 0..4 分类）；
  - 主页 Flickable + 卡片 `GridLayout`；
  - 二级页用 `RightSlidePage`，顶部固定「返回 + 分类名」；
  - 原来的五段内容整段搬进二级页，各自包在 `ColumnLayout` 里按 `section` 显示；
  - 函数（`sourceEnabled` / `sourceStatus` / `mappingFields`）原样保留。
- `WeatherTools.qml` 的设置层容器去掉外层 `Flickable`，直接把 `WeatherSettings`
  放进 `Layout.fillHeight` 的位置——滚动由组件内部负责（主页与二级页各有一个 Flickable）。

## 3. 未改

- 数据源行、Key 输入、字段映射、MET Norway、刷新与单位的控件与绑定；
- 所有 `objectName`（`weatherProbe_*`、`weatherSourceSwitch_*`、`weatherCustomKey` 等）；
- 键盘只在点输入框时请求（`keyboardRequested` 仍然向上转发给宿主）。
