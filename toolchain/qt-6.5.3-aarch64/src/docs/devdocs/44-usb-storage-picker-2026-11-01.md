# 数据页改成选 U 盘（2026-11-01）

## 1. 共识

| 决定 | 结论 |
| --- | --- |
| 无 U 盘 | 按钮置灰，列表区提示「插上 U 盘后会自动出现在这里」 |
| 文件名 | 固定前缀 + 时间戳（`terminal-backup-20261101-234012.optbk`），多次备份不互相覆盖 |
| 恢复选文件 | 列出该 U 盘根目录下的备份，显示「备份 2026-11-01 23:40」 |
| 多个 U 盘 | 卡片列表单选 |
| 未挂载 | 点选时自动 `udisksctl mount`，失败在卡片里报一句 |
| 只读盘 | 列表里标注「只读」；导出/备份不可选，恢复可选 |
| 扫描深度 | 只扫根目录，按时间倒序 |
| 位置 | 导出、备份、恢复三张卡片各自一个选择器（不共用） |

界面上一律不出现挂载点、文件名后缀。

## 2. C++

`src/ui/RemovableStorage.cpp`：设备条目补两个字段。

```cpp
const bool readOnly = readStorageText(node + "/ro") == "1";
const qint64 sectors = readStorageText(node + "/size").toLongLong(&sizeOk);
// readOnly、sizeBytes 一起塞进 devices()
```

`src/ui/SystemTools.h/.cpp`：暴露给 QML 的两个方法。

```cpp
Q_INVOKABLE QString resolveRemovablePath(const QString &location, bool creating) const
{ return removableStorage_.resolve(location, creating); }

Q_INVOKABLE QVariantList removableBackups(const QString &id) const;  // 扫根目录 *.optbk
```

`removableBackups` 返回 `{fileName, location, modifiedMs, sizeBytes}`，按修改时间倒序。

## 3. QML

新增 `qml/UsbDevicePicker.qml`（`objectName: "usbDevicePicker"`）：

- 每个盘一行：图标 + 名字 + 「512 MB / 只读 / 未挂载」；
- 选中行高亮描边；`writableOnly` 为真时只读盘灰掉且点不动；
- 点未挂载的盘先 `storage.openRemovableDevice(id)`，`devices` 刷新后自动选中；
- 挂载失败读 `removableDeviceError` 显示在卡片底部；
- 空列表时显示「插上 U 盘后会自动出现在这里」。

`qml/UserSecurityPage.qml`：三处路径输入换成选择器。

| 卡片 | 原控件 | 现控件 |
| --- | --- | --- |
| 导出数据库 | `exportPath`（文本框） | `exportDevicePicker` |
| 创建备份 | `backupPath`（文本框） | `backupDevicePicker` |
| 从备份恢复 | `restorePath`（文本框） | `restoreDevicePicker` + 备份文件列表 |

行为：

- 三个按钮 `enabled` 分别绑 `exportUsbId` / `backupUsbId` / `restoreFileLocation`，没选就点不了；
- 校验顺序先密码后盘（用户已经填的内容先提示）；
- 导出/备份成功后提示「已导出到 U 盘 / 已备份到 U 盘」，不显示路径；
- 备份成功后若恢复选的是同一个盘，顺手刷新备份列表；
- `onUsbDevicesChanged` 会在拔盘时清掉失效的选中，避免按钮停在可点状态。

## 4. 验证

- 构建通过；
- `pairing_ui_page` 更新断言（三个选择器代替三个路径框，且没插盘时按钮必须是禁用的）后通过；
- 全量 72 项，71 通过，仍只剩 `arkpets_sprite_packing`；
- 真机（1024x600）数据页：列表里出现了本机检测到的可移动盘 `LINUXESP / 512 MB`，
  只有名字与容量，没有挂载点和后缀，未选中时「备份当前用户」「从备份恢复」都是灰的。

## 5. 备注

- 真机上只有一块 512 MB 的可移动盘，本次没有做「只读盘」和「未挂载自动挂载」的实际点击验证，
  这两条路径由代码分支覆盖（`writableOnly` 与 `openRemovableDevice`）；
- 备份文件列表按根目录扫，U 盘上如果用户自己建了子目录放备份，列表里看不到。
