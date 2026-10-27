# PR 审核备注：pbr-secure-v1 修订 2 + T-05 控制事件校验

> 分支：`feat/p0-t05-control-schema` → `main`
> 关联：T-03 / T-05 / T-07 / T-08 / T-12 的**软件部分**；DR-01～DR-14；B-01、B-07
> 分工：**ESP 固件归 Mr.L**，本 PR 不含任何固件改动
> 审查记录：`docs/pbr-secure-v1/F-REVIEW-2.md`（F 第二轮，含 D 的完整开发任务书）

## 1. 这个 PR 做了什么

| 项 | 内容 |
|---|---|
| 规范 | `pbr-secure-v1.md` 升到**修订 2**：补桥板签名（双向认证）、拆分 `session_id`/`nonce_prefix`、给 TTL 加时间基准、重写 `auth_seq` 规则 |
| 向量 | 重新生成，含 `hello_ok`、`t2`、桥板签名、13 条反向用例 |
| 一致性工具 | `mbedtls_check.c` 改为 2.28/3.6 公共 API，**两个版本各 7/7 通过** |
| T-05 | `PbrControl::validate()` + `payloadAcceptable()`：字段校验、重复 key、深度、转义绕过 |
| 审查 | `F-REVIEW-2.md`：PR #28 复核结论 + D 的开发任务书 + 6 处必改的原因 |

## 2. 修订 1 有 1 处协议级错误、5 处必分叉的歧义

### 2.1 修订 1 的握手是单向认证（最严重）

修订 1 只有 Pi 签名，桥板从未证明自己是谁。攻击者拿不到会话密钥，伪造不出 `hello_ok`，但它可以**冒用任意一块真桥板**：复制那 1 字节 `bridge_key_id`、用自己的临时密钥。Pi 无从分辨是哪块板——因为 Pi 唯一的身份依据就是那个 1 字节，而规范自己写了"1 字节只用于选钥，不作身份判定"。

后果：`IT-003`（未签发桥身份被拒绝）无法成立，DR-03/DR-10 的"双向认证"只有一半。

**已修**：`hello_resp` 增加 `sig`，桥板对 `T2 = tag(hello_req)||msg1 || tag(hello_resp)||msg2` 签名；Pi 用 TrustStore 的完整公钥验签，失败即断连，且**先验签再发 `hello_finish`**。

### 2.2 另外 5 处

| # | 问题 | 修订 |
|---|---|---|
| 1 | `session_id` 一名两用（4 字节喂 nonce vs 32 hex 事件字段） | 拆成 `nonce_prefix = hash[16..20)` 与 `session_id = hash[0..16)` |
| 2 | `key_id` 三种宽度（1 / 8 字节 / "1～64 字符"） | §2.1 定死：1 字节选钥、2 位小写 hex、TrustStore 用完整公钥 SHA-256 前 8 字节 |
| 3 | `auth_seq` 上限自相矛盾（正文 2⁶⁴−1，拒绝规则 2⁶³） | 严格递增，`0` 与回退都算 `REPLAY`，到上限主动重握手 |
| 4 | TTL 没有时间基准（握手不带任何时间字段） | `hello_ok` 加 `uptime_ms`，只接受一次，Pi 据此算 `offset` |
| 5 | ESP 侧没有二进制发送路径 | L 必须新增按长度发送的入口，命令入口对信封帧跳过 NUL 扫描 |

## 3. 修掉的真桥板兼容性缺陷

`control_event.cpp` 原先把 `rfid_card` 归入"模块事件"，强制要求 `module_id` / `module_instance`。但桥板 `rfid_service.c` **根本不发这两个字段**——RC522 是桥板级事件。

**修之前校验器会拒绝桥板的每一次刷卡**，而调用方静默返回 false，日志里一行都不会有。注意：`rfid_card` 目前在 Pi 侧还没有消费者（`HostEventDetector` 只放行 attach/detach），接入属 T-08，所以这是"下一块多米诺骨牌"，不是线上正在丢卡。

同时修正：`pong`/`bridge_status` 移出事件校验器（诊断响应只有 `request_sequence`，没有 `event_id`/`ttl_ms`）；`key_id` 改为 `^[0-9a-f]{2}$`；测试改用桥板真实字段形状。

## 4. 验证证据（可复现）

| 项 | 命令 | 结果 |
|---|---|---|
| 向量稳定 | `python3 docs/pbr-secure-v1/gen_vectors.py` ×2 | 完全一致 |
| spec ↔ 向量 | 20 项交叉核对（msg 长度、T2/T3 拼接、hash 切片、AAD 六字段、nonce 布局、key_id） | 全部吻合 |
| mbedtls 2.28 | `cc -I<mbedtls-2.28>/include ... -lmbedcrypto` | **7/7 PASS** |
| mbedtls 3.6.5（IDF 5.5.4 源码，主机编译） | 同上 | **7/7 PASS** |
| 签名 | Pi 的 T3、桥板的 T2 各用 `r‖s` 独立验签 | 通过 |
| 反向向量 | 篡改密文/tag/方向密钥/kind/签名、`seq=0`、未知 key_id | 全部按预期拒绝 |
| Pi 单元测试 | `ctest -R pibridge_protocol` | 通过（32 条断言） |
| 全量构建 | `cmake --build` | 本次改动文件 0 新增警告 |

### 4.1 `mbedtls_check.c` 之前在 3.6.5 上编译都过不去

修订 1 的检查程序直接访问 `ecdh.d` / `ecdh.grp`。mbedtls 3.x 默认换了 `mbedtls_ecdh_context` 的结构，这些字段只在 `MBEDTLS_ECDH_LEGACY_CONTEXT` 下存在，而 IDF 不定义它：

```
error: 'mbedtls_ecdh_context' has no member named 'd'
```

所以当时"目标平台只验证了编译"并不成立。已改为只用公共 API（`mbedtls_ecp_mul` + `mbedtls_ecp_point_write_binary`），两个版本现在都真跑通。

**顺带发现第 5 个 mbedtls 陷阱**：3.x 对 `mbedtls_ecp_mul`／`mbedtls_ecdh_compute_shared` 传 `f_rng = NULL` 直接返回 `ECP_BAD_INPUT_DATA`，2.28 容忍。同一份代码在 2.28 能跑、在 IDF 上必失败。

## 5. NOT_RUN（不要当成已通过）

| 项 | 状态 |
|---|---|
| Pi 3B / ARM64 交叉编译 | **NOT_RUN** |
| ESP32-S3 实机、串口时序、RC522 | **NOT_RUN** |
| `PbrSession` / `ReplayGuard` / `EventAckManager` | **未实现**，属 T-07 |
| `payloadAcceptable` 模糊测试 | **未做** |
| mbedtls 3.6.5 在**真实 IDF 交叉编译环境**下跑检查程序 | **NOT_RUN**（只在主机用 IDF 源码编出的库跑过） |

按 DR-08：以上均为开发期证据，不得作为实机验收。

## 6. 跨仓依赖（ESP 侧，归 L）

| 项 | 不改的后果 |
|---|---|
| 二进制发送入口 + 命令入口跳过 NUL 扫描 | 密文含 `0x00`，AEAD 在 ESP 上不可能跑通 |
| 命令 payload 上限 256 → 512 | `hello_finish` 实测 329 字节，超限被**静默丢弃**，握手停在第二步 |
| 桥板签名（NVS 私钥） | Pi 无法认证桥板，等于单向认证 |
| `hello_ok.uptime_ms` | TTL 无时间基准 |
| `CONFIG_PBR_ISOLATION_BASELINE` | 产品构建无法编译期移除 `ping`/`status` 明文通道 |

已实测（供 L 参考，不必重做）：隔离基线 y/n 两种配置在 IDF 5.5.4 下均编过，固件 0xc6430 / 0xc6240，分区余量 47%；`CONFIG_MBEDTLS_CHACHAPOLY_C` 单独写会被 Kconfig 静默丢弃，必须连同 `CHACHA20_C`/`POLY1305_C`/`HKDF_C` 四项同写。

## 7. 已知遗留

1. **DR-01 未关闭**：D 尚未技术签认修订 2，B-01 不关闭，T-07 不开工。
2. **Legacy 明文入口**：schema-less 的 `attach`/`detach` 仍被接受（否则现有桥板全部失联）。**T-07 合入时必须删除该分支及规范 §6.6**，代码里已有到期标记。
3. **B-07 记为遗留、不阻塞**：只做只读扫描，未改 Git 历史。固件 `0x006984` 含明文 provision（instance/SSID/token/静态 IP），无私钥；token 与公开 archive README 一致。**token 是否仍在役未确认**。按当前优先级（先完成 Pi 终端软件、固件后续开发），本轮不阻塞合并，轮换归固件侧任务。**这是一条未关闭的风险，不是已解决的问题。**
4. **PR #28 流程问题**：无描述、未留 review 痕迹；内容已在 `00-decisions-for-f.md` §6.5 与 `F-REVIEW-2.md` §1 追认。

## 8. 审核建议顺序

1. `F-REVIEW-2.md` §2（六处必改的原因）——异议最可能在这里。
2. `pbr-secure-v1.md` §3.3（桥板签名）与 §3.5（TTL 基准）——修订 2 的新增部分。
3. `control_event.cpp` 的 `payloadAcceptable()`——手写扫描器，已知修过一次转义绕过。
4. 跑 `gen_vectors.py` 两次、两个 mbedtls 版本各跑一次 `mbedtls_check`。

---

## 9. PR 描述（复制到 GitHub）

```
feat(pbr): spec rev2 with mutual authentication, plus T-05 event validation

任务: T-03/T-05/T-07/T-08/T-12 软件部分；DR-01～DR-14；B-01、B-07
分工: ESP 固件归 Mr.L，本 PR 无固件改动

修订 2 修掉 1 处协议级错误：
- 修订 1 的握手只有 Pi 签名，桥板身份从未被证明，等于单向认证。
  攻击者可冒用任意一块真桥板（1 字节 key_id 可复制）。已加桥板签名，
  Pi 用 TrustStore 完整公钥验签，先验签再发 hello_finish。

另外 5 处必分叉的歧义：
- session_id 一名两用 -> 拆 nonce_prefix / session_id
- key_id 三种宽度 -> 1 字节选钥 + 2 位 hex + 完整公钥指纹
- auth_seq 上限自相矛盾 -> 严格递增，0 与回退都是 REPLAY
- TTL 无时间基准 -> hello_ok 带 uptime_ms，只接受一次
- ESP 无二进制发送路径 -> L 必须新增（密文含 0x00 会被 NUL 扫描丢弃）

修掉一个真桥板兼容性缺陷：
- rfid_card 被要求 module_id/module_instance，但 rfid_service.c 不发这两个字段。
  当前 rfid 在 Pi 侧还没有消费者（T-08 才接），这是下一块多米诺骨牌而不是线上故障。

验收:
- 向量重跑两次一致；spec 与向量 20 项交叉核对全吻合
- mbedtls 2.28 与 3.6.5 各 7/7 PASS（修订 1 的检查程序在 3.6.5 上编译失败，已重写）
- ctest -R pibridge_protocol 通过（32 条断言）
- 全量构建本次改动文件 0 新增警告

测试命令:
  python3 docs/pbr-secure-v1/gen_vectors.py          # 跑两次必须一致
  cc -I<mbedtls>/include docs/pbr-secure-v1/mbedtls_check.c -L<mbedtls>/lib -lmbedcrypto -o check
  ./check docs/pbr-secure-v1/vectors.json
  source pi_terminal/scripts/env.sh && ctest -R pibridge_protocol --output-on-failure

目标硬件: 主机 AMD x86_64（Qt 6.5.3 / mbedtls 2.28 与 3.6.5）
实机结果: NOT_RUN —— Pi 3B / ESP32-S3 / RC522 / ARM64 交叉编译均未执行

跨仓依赖（归 L）: 二进制发送入口、命令上限 512、桥板签名、hello_ok.uptime_ms、
隔离基线开关。不改则握手无法完成。

详细审查见 docs/pbr-secure-v1/F-REVIEW-2.md
```
