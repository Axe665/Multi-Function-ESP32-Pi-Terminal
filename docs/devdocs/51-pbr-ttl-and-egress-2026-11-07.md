# PBR 事件 TTL 修复与内核出站白名单（2026-11-07）

> 现场基线：Pi 3B / Debian 12 / aarch64 / Qt 6.5.3 PGO 构建，桥板经 CH343 串口。
> 本文只记录本轮实测、修复与验证；未做实机验收的部分单独列出。

## 0. 一句话

控制面 PBR 握手一直是成功的，但**所有事件都被 TTL 判为过期**，模块永远接不进来。
根因是握手锚点把单向传输时延算进了 `offset`，事件 `age` 恒为约 **−34 ms**，
而判定要求 `age >= 0`。给负偏差留 2 s 容差后，`attach` 第一次被接受。

## 1. 现场证据

```
PBR hello_ok: bridge_uptime_ms=1351  pi_elapsed_ms=25491  offset_ms=-24140
PBR event: EVENT_EXPIRED verdict 2 event=attach ttl_ms=3000
          sender_ms=9997 receiver_ms=34171 offset_ms=-24140 age_ms=-34
PBR event: EVENT_EXPIRED verdict 2 event=attach
          sender_ms=19997 receiver_ms=44171 offset_ms=-24140 age_ms=-34
```

- sender 每 10 s +10000、receiver 同步 +10000 → **速率一致、单位是毫秒**，
  排除“固件时钟单位错”；
- `age = sender − (receiver + offset)` 稳定为负，说明 offset 把握手帧的
  单向时延（串口 + USB + 调度，实测 ~34 ms）一起算进去了；
- `EventTtl::evaluateWithOffset()` 要求 `age < 0` 即过期 → 100% 丢弃，
  `EVENT_EXPIRED` 累计 100+ 条，`Module session state` 一条都没有。

排除项：重启应用后**新会话的第一条事件仍然过期**，所以不是“桥板复位后 Pi 用旧密钥”。

## 2. 修复

```cpp
// pbr_session.cpp
- if (age < 0 || age > kMaxAgeMs) return Verdict::Expired;
+ if (age < -kMaxSkewMs || age > kMaxAgeMs) return Verdict::Expired;

// pbr_session.h
+ // 握手 offset 含单向时延，事件 age 会稳定为小幅负值。
+ // 2 s 远小于 60 s 上限；更早的事件仍是分钟级负值，重放由 auth_seq + event_id 拦截。
+ constexpr int kMaxSkewMs = 2000;
```

同时保留两处诊断/健壮性改动（`PogoControlTransport.cpp`）：

1. TTL 拒绝时打印 `ttl/sender/receiver/offset/age`（本次定位就靠这一行）；
2. 事件 `boot_id` 与握手记录的 `boot_id` 不一致时主动 `restartHandshake()`，
   避免桥板重启后旧密钥把新事件全部判过期、会话永久卡死。

## 3. 部署侧修正（packaging/）

- **新增 `orpi-egress.service`**：开机把 `net-egress.sh` 装到
  `/usr/local/sbin/orpi-net-egress.sh` 并加载一次。绑
  `user.slice/user-1000.slice/user@1000.service/app.slice`（level 4），
  **不绑具体 unit**——`nft` 的 `socket cgroupv2` 绑定的是 cgroup 实例，
  unit 重启后实例 ID 变化，规则会静默失效（实测 `nft list` 里路径退化成数字、计数器不再增长）。
- **新增 `orange-pi-net-proxy.service.d/10-policy-bootstrap.conf`**：
  代理启动时若策略文件不存在，`reloadPolicy()` 会提前 return 且不注册 watcher。
  drop-in 预落一份合法空策略。**不能写 `printf %s`**：`%s` 是 systemd specifier，
  会展开成用户 shell，策略文件变成 9 字节 `/bin/bash`，代理 `allowed=[]` 全拒；
  改用 `printf "\42..."` 八进制转义。
- `build_scripts/deploy_pi.sh` 负责安装以上两件并 enable，自检里加了 drop-in 与 `nft` 表。

## 4. 验证

```
Module session state: 80 pogo-device-test attached  检测到模块，Host 已完成唤醒确认
Module session state: 80 pogo-device-test connecting 正在连接模块
Module session state: 80 pogo-device-test error LAN 缺少已登记的证书指纹（pin_sha256）
```

- 控制面：从 0 条 session state 变为进入状态机；
- 下一道门是 **profile 缺 `pin_sha256`**（LAN 指纹固定，fail-closed），
  以及模块未连上 `pi-module-ap`（`192.168.50.2` 无响应、AP 无关联站点）；
- 沙箱：临时单元实测 `worker_uid 61689 ≠ host 1000`、netns 仅 lo、
  `ProtectHome` 下 `/home` 空壳、模块目录只读、`CapEff=0`、`NoNewPrivs=1`、
  `AF_INET socket()` 返回 `EAFNOSUPPORT`（对照组可建）；
- 联网门控：`34001 → 502`（过策略、上游不可达）/ `34002 → 403`（通道关闭）/
  私网与回环 `403`；nft 组内 0 ms RST、组外 timeout、计数器递增。

## 5. 未闭环

- 模块完整会话（`session_ready → 包 → 信任 → worker`）缺 `pin_sha256` 与模块在线；
- 登录 9.4 s：KDF 子进程在 `TerminalApplication.cpp` 里显式停用（开库自锁），需工程改造；
- 供电欠压 `throttled=0x50005`；
- 目标机 SQLCipher 3.4.1 与开发机 4.5.6 的版本差（已改用 3.4.1 对齐，见 sdk 说明）。

## 6. 回滚

```bash
# 代码
git revert <本组提交>
# 部署
systemctl disable --now orpi-egress && nft delete table inet orpi_egress
rm -f /etc/systemd/system/orange-pi-net-proxy.service.d/10-policy-bootstrap.conf
systemctl daemon-reload && systemctl restart orange-pi-net-proxy
```
