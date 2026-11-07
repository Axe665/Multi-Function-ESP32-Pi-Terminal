# 联网权限：保存要 sudo、PIN 弹窗不消失、联网应用全挂（2026-11-01）

## 1. 现象

1. 编辑联网权限时要求输入系统（sudo）密码；
2. 输入管理员 PIN 后弹窗不消失、没反应；
3. 退出设置后配置不生效；
4. 打开开关后天气、TV 等联网应用仍然全部不可用。

## 2. 根因（两条独立故障）

### 2.1 策略写盘链路没部署好

保存路径是 `NetworkPermissionsPage.commit()` → `NetworkPolicyController::save()`
（先验管理员 PIN）→ `writeViaHelper()` → `pkexec /usr/libexec/orange-pi-terminal/net-policy-helper`
以 root 写 `/etc/orange-pi-terminal/network-policy.json`。

本机实际情况：

- `/usr/libexec/orange-pi-terminal/` **不存在**，helper 没装；
- polkit 规则 `com.orangepi.terminal.network-policy.policy` 却在，策略文件也在——
  部署只做了一半；
- 一旦走到 `pkexec`，polkit **先弹系统认证框要密码**，认证完才发现 helper 不存在；
- 保存是同步阻塞调用（`waitForFinished` 最长 60 秒），期间 `saving=true`、按钮禁用；
  `adminPinDialog` 只在成功分支 `close()`，失败时弹窗原地不动，错误只写在被弹窗
  挡住的页面上——表现为"输入 PIN 后弹窗不消失"；
- `/etc` 下的策略文件是 root 所有，普通用户程序写不进去，所以保存失败后配置不生效。

### 2.2 代理进程从来没构建

`TerminalApplication` 启动时找主程序同目录的 `network_proxy`，找不到就放弃：

```
net-proxy: /tmp/oobe-build/network_proxy missing, every outbound request will fail
```

之前只构建了 `orange_pi_terminal`，`network_proxy` 从未构建，所有出网流量指向一个
没人监听的端口——与开关无关，全拒（fail-closed）。

## 3. 修复

1. **不降级**：撤销"helper 缺失时直接写策略文件"的开发降级，helper 不在就明确报错。
2. **安装 helper**：`/usr/local/libexec/orange-pi-terminal/net-policy-helper`
   （来自构建目录，pkexec 认证安装）。
3. **PIN 弹窗内显示失败原因**：保存失败时弹窗保持可重试，原因直接显示在弹窗里；
   成功才关闭。`pkexec` 的认证框由系统弹出，认证通过后 helper 写盘并立即生效。
4. **状态行**：网络策略页显示"已安装 helper / 未安装，保存会失败"。
5. **开发者选项**新增 `NET POLICY / HELPER` 分区（原始英文 JSON：policyPath、
   loaded、lastError、helperPath、helperInstalled、gateEnabled），与其它分区同格式。
6. **构建 network_proxy** 并与主程序同目录运行。

## 4. 部署必装（缺一不可）

```bash
# 1) 策略 helper（root 写 /etc，必须经 pkexec 认证）
sudo install -Dm755 /tmp/oobe-build/net-policy-helper \
  /usr/local/libexec/orange-pi-terminal/net-policy-helper

# 2) 代理与主程序同目录
cmake --build /tmp/oobe-build --target network_proxy
#    产物：/tmp/oobe-build/network_proxy

# 3) polkit 规则（已存在）：/usr/share/polkit-1/actions/com.orangepi.terminal.network-policy.policy
```

缺 helper：保存必失败，页面会明说。缺 proxy：所有联网应用不可用，日志会报
`net-proxy: ... missing`。

## 5. 验证

- 打开浏览器 + 天气策略开关 → 保存 → 管理员 PIN `111111` → 系统认证框输入密码；
- `/etc/orange-pi-terminal/network-policy.json` 更新：
  `browser=true, weather=true, time=true`；
- 代理日志：`net-proxy: policy loaded, allowed=[timesync,browser,qml]`；
- 打开天气页：显示珠海 27°C、24 小时与 7 天预报（更新于 20:46），数据经代理取回。
