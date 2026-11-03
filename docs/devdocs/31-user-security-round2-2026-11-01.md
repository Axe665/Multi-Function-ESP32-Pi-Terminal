# 用户与权限：单一主标题 + 改名字 + 其他用户重做（2026-11-01）

> 范围：`设置 → 用户与权限`（section 15）的二级页与 `SessionManager` / `UserService`。
> 截图见 `user-security-shots/`。

## 1. 只保留最上面的主标题

二级页顶部已有「← 返回 + 分类名」。内部再出现的 title 级标题全部去掉：

- 其他用户页的「用户」标题（保留右侧「账户管理」按钮）；
- 数据页的「数据与备份」标题（主标题已经是「数据」）；
- 高级页的「删除账户」标题改成一条 danger 色分隔线，危险感由按钮与说明承担。

`fontLabel` 级的小标题（头像、修改我的 PIN、添加用户等）保留：它们是控件说明，不是页面标题。

## 2. 我的账户：更改名字

- 后端：`UserService::setDisplayName(userId, name)`（2..24 字符，只改注册表字段，
  不碰 PIN / 恢复码 / 加密库）；`SessionManager::changeOwnDisplayName(name)`
  返回 `""` / `NAME_INVALID` / `NOT_AUTHORIZED` / `STORAGE_UNAVAILABLE`，
  成功后刷新 `activeDisplayName_` 并发 `changed()`。
- 界面：名字右侧铅笔按钮 → 弹窗（预填当前名字）→ 保存。
  弹窗改为**顶部对齐**，软键盘从底部弹起时不会盖住输入框与保存按钮。
- 名字会同步到登录页、桌面与用户列表（都读同一份注册表）。

## 3. 其他用户：按 Windows / Android 的账户列表重做

- 列表卡片一行一个账户：首字母头像 + 显示名 + 角色徽章（管理员/普通用户）
  + 「（你）」标记 + 次行「可以登录这台终端 / 已停用」；
  管理员可在别人那一行右侧直接删除（走原来的 PIN 确认弹窗）。
- 「添加用户」按钮默认收起表单，点开后才出现显示名 / 初始 PIN / 设为管理员 / 创建；
  创建成功仍会弹恢复码。
- 「账户管理」按钮保留（批量管理弹窗）。
- 用户列表为空时显示「还没有用户」。

## 4. 测试

| 用例 | 断言 |
| --- | --- |
| `session_gate_test::changeOwnDisplayNameUpdatesRegistry` | 改名成功、注册表字段更新、原 PIN 仍可登录、过短/过长返回 `NAME_INVALID`、未登录返回 `NOT_AUTHORIZED` |
| `pairing_ui_test::userPageShowsUsersAndRecoveryCode` | 文案从「新建用户」改为「添加用户」 |
| `pairing_ui_test::userPageShowsBackupReadingsAndSecurity` | 「数据与备份」标题去掉后改断言「导出数据库」 |
| `pairing_ui_test::userPageFieldRequestsKeyboardOnTapOnly` | 先展开 `addUserOpen` 再点输入框 |

`session_gate_test` 20/20、`pairing_ui_test` 10/10、`about_credits_page`、`onboarding_first_run` 全过。

## 5. 截图

| 文件 | 内容 |
| --- | --- |
| `other-users.png` | 其他用户：账户行 + 添加用户 |
| `add-user-form.png` | 展开后的添加用户表单 |
| `my-account-rename.png` | 我的账户：名字右侧铅笔 |
| `rename-dialog.png` | 更改名字弹窗 |

## 6. 第二轮调整（同日）

1. **主页去标题**：`UserSecurityHome` 顶部只留「管理这台终端上的账户、安全与数据。」，
   分类卡片整体上移。
2. **数据页按 Windows / Android 重做**：一张卡片一件事——
   - 「导出数据库」（图标 + 说明 + 路径 + 密码 + 主按钮）；
   - 「备份与恢复」（创建备份 / 从备份恢复，用一条发丝线分隔两条流程）；
   - 「清空本用户数据」用红描边卡片，PIN 确认在卡片内。
   所有输入框与按钮的 `objectName` 未变（`exportPath`、`backupPath`、`purgePin` 等）。
3. **高级页重做**：先「安全状态」只读区，再一张红描边的「删除账户」卡片
   （图标 + 说明 + 最后管理员警告 + 红色按钮），删除流程与文案不变。
