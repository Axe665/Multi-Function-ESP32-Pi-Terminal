# 连接设置：分类卡片 + 滑入二级页（2026-11-01）

> 范围：`ConnectionSettingsPage.qml`。内容组件（`SecurityStatusSection`、
> `ModuleAuthPanel`、`AdminPairingPage`）原样复用，只改导航与视觉外壳。

## 1. 结构

```
连接管理（右上角齿轮）
└─ 连接设置
   ├─ 主页：两列分类卡片
   │   ├─ 安全状态        信任库、本机身份、UID 索引与槽位
   │   ├─ 模块认证        已连接模块的能力与授权状态
   │   └─ 设备配对与授权   桥板信任、卡片与操作记录
   └─ 点卡片 → 240ms 从右侧滑入二级页
       ├─ 顶部只有「← 返回 + 分类名」
       └─ 内容为对应组件（ModuleAuthPanel / AdminPairingPage 的 showTitle:false）
```

与「用户与权限」主页同一套卡片语言：2 列、`surfaceContainer` 底、
`outlineVariant` 描边、hover 变 `accent`、圆形强调色图标 + 标题 + 描述 + 右箭头。

## 2. 改动

- 原先是三张 `SettingsGroup` 平铺在 Flickable 里；现在主页只有卡片，内容进二级页；
- 二级页用 `RightSlidePage`，背景内缩半格 + 面板同色，右边缘不压外层描边；
- 新增 `section`（-1 主页 / 0..2）；
- `connectionSettingsBack` 保留（整页返回），二级页另有 `connectionSettingsDetailBack`。

## 3. 未改

- 三个内容组件与它们的数据绑定；
- `keyboardRequested` 仍向上转发给宿主（设备配对页输入框用）。
