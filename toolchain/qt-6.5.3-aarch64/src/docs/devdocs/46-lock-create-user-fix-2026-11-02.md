# 登录页建号：卡死与引用错误修复（2026-11-02）

## 1. 用户报的两件事

1. 锁屏（其实是登录页）右上角的「树莓派终端」小字去掉；
2. 点「创建新用户」直接卡死，什么也没有。

## 2. 根因（三个叠加）

### 2.1 版本号与按钮叠在同一位置

`LoginPage.qml` 右上角原来有一个弱化的版本号 `CarText`，锚点和新建的按钮完全一样。
删掉它，按钮独占右上角。

### 2.2 锁屏右上角锚点引用报错

`LockScreen.qml` 里两个按钮互相锚定：

```qml
anchors.right: lockLogout.left     // ← ReferenceError: lockLogout is not defined
```

本页由 `SessionGate` 的 `Loader` 动态加载，锚点在创建期求值，被引用的 id 还不在作用域里，
整块右上角直接不渲染。改成 `Row` 排布，两个按钮不再互相引用。

### 2.3 Popup 挂在错误的层上（"卡死"的主因）

`LoginPage` 同样是由 `Loader` 动态加载的。这种上下文里 `Overlay.overlay` 解析不到，
三个 `Popup` 的 `parent: Overlay.overlay` 落空——弹窗内容被压暗、被登录页盖住，
而全屏遮罩照常吃掉所有点击：表现就是「点了没反应、整屏发暗、什么都看不到」。

四处尝试的过程：`Overlay.modal` 自定义遮罩 → 更暗；`dim: false` → 仍然暗；
加 Esc 兜底 → 能退但还是看不见。最后确认是层级问题，**改成自绘覆盖层**：

```qml
Item {
    anchors.fill: parent
    visible: stage !== ""      // "" 关闭；"auth" / "form" / "code"
    Rectangle { anchors.fill: parent; color: rgba(0,0,0,0.55); MouseArea {} }
    Rectangle { /* 卡片 */ }
}
```

不再依赖 `Overlay` / `Popup`，层级完全可控，三种状态各一张卡片。

## 3. 登录页建号还缺两样后端能力

登录页没有「当前用户」，原来的实现全都不成立：

| 原调用 | 问题 | 新增 |
| --- | --- | --- |
| `sessionManager.verifyPin(pin)` | 校验的是 `activeUserId`，登录页为空 → 永远 false | `verifyAdminPinFor(userId, pin)`：按指定账户验证，且只接受未停用的管理员 |
| `sessionManager.createUser(...)` | 内部要求 `loggedIn() && admin_` → `NOT_AUTHORIZED` | `createUserAs(actorUserId, ...)`：由界面先验过该管理员，再把他当 actor |

`LockCreateUser.qml` 的验证步骤因此多了一个**管理员选择列表**（多个管理员时单选，
默认选中当前登录者或第一个），验证失败会显示「PIN 不正确」。

## 4. 验证

真机 700×600 窗口，不自动登录直接进登录页，完整走了一遍：

1. 右上角人形+号 → 弹窗「创建新用户 / 需要先验证当前管理员 PIN」，管理员「验收员」已选中；
2. 输管理员 PIN → 继续 → 表单「新用户 / 显示名 / 初始 PIN / 设为管理员」；
3. 填「测试员」+ PIN → 创建 → 恢复码弹窗（`YM4X NRLR B235 / GRZF DRKG XB2T`）
   +「导出到 U 盘」+「我已抄写」；
4. 左侧用户列表当场多出「测试员」；
5. 点「我已抄写」→「确认已保存恢复码？」+「冷静期 4 秒」+ 返回/确认已保存。

全量测试见下一节记录。

## 5. 备注

- 「抄写」逻辑的三处统一（其他用户 / 锁屏建号 / OOBE 第 3 步）已在 45 号文档里，
  这次的覆盖层改动只影响锁屏与登录页这条路径；
- `RecoveryAckConfirm` 这个 Popup 组件在登录页里同样会遇到 Overlay 问题，
  所以锁屏这套用的是内联的自绘确认层；另外两处（有正常 Window 上下文）继续用组件。
