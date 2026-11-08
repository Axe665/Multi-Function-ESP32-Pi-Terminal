# bridge_id 持久化与绑定

> 2026-10-30。涉及两侧：固件 `pbr_secure.c`、Pi 侧 `PbrControl` + `PogoControlTransport`。

## 问题

规范 §2.1/§6.4 要求 `bridge_id` 在配对时绑定进 TrustStore，此后每个事件的
`bridge_id` 必须与已认证身份**逐字节相等**，否则 `IDENTITY_REJECTED`。

实际情况两条都不成立：

1. **固件每次上电换 ID**：`pbr_secure_init()` 里 `nvs_get_str("bridge_id")` 失败后
   `snprintf("pbr-%08lx", esp_random())`，**没有写回 NVS**。所以 ID 每次都不一样。
2. **Pi 侧只校验格式不校验归属**：`PbrControl::validate()` 用 `label()` 检查
   `bridge_id` 是 1–64 字符 `[A-Za-z0-9_-]`，从不与 TrustStore 记录比对。

合起来：`bridge_id` 既不稳定也不参与判定，等于一个装饰字段。

## 改法

**固件**（`esp/S3_PiBridge_LinkIt_Host/main/pbr_secure.c`）

首次生成即写回 NVS 并 commit；写失败只告警（ID 会在重启后变化，但不阻断启动）：

```c
if (nvs_get_str(handle, "bridge_id", s_bridge_id, &length) != ESP_OK) {
    snprintf(s_bridge_id, sizeof(s_bridge_id), "pbr-%08lx", (unsigned long)esp_random());
    if (nvs_set_str(handle, "bridge_id", s_bridge_id) != ESP_OK
        || nvs_commit(handle) != ESP_OK) {
        ESP_LOGW(TAG, "bridge_id persist failed, id will change on reboot");
    }
}
```

**Pi 侧**

- `PbrControl::bridgeIdMatches(expected, actual)`：`expected` 为空（还没有已认证身份）
  时不比对；否则严格相等——**不做大小写或空白归一化**，`bridge_id` 是身份字段，
  宽松匹配等于放宽身份。
- `PogoControlTransport` 在 `hello_resp` 验签通过的那一步，从 TrustStore 候选里
  记下该记录的 `bridge_id`（`candidates()` 本来就带回 `(bridgeId, publicKey)`）。
- 每个解密事件在 schema 校验之后、去重之前比对；不一致就丢弃并记
  `PBR event: bridge_id does not match authenticated identity`（不上线回错误，
  避免给攻击者 oracle）。
- `close()` 与 `failHandshake()` 都清空该绑定。

## 升级影响（重要）

如果某台设备**已经配对过**，而 TrustStore 里记的 `bridge_id` 与桥板实际值不同，
升级后该桥板的事件会全部被拒。三条恢复路径：

1. 管理员撤销后重新配对（`SecurityService::revokeBridge` → 重新登记），配对时填
   **实际值**——用 `pbr_info` 命令读回 `bridge_id`，不要手抄；
2. 直接把固件 NVS 里的 `bridge_id` 改成 TrustStore 记录里的值（需 `idf.py` 烧写，
   不推荐，容易再写错）；
3. 擦 NVS 重新配对（会丢 Pi 公钥，需重新配对整条链）。

现场升级前先跑一次 `pbr1_tool.py send <port> '{"command":"pbr_info"}'`，把返回的
`bridge_id` 与已登记的记录对一下。

## 验证状态

| 项 | 状态 |
| :--- | :--- |
| 固件编译（ESP-IDF 5.5.4 / S3） | ✅ `idf.py build` 通过 |
| Pi 侧比对逻辑单测 | ✅ `pibridge_protocol`（空/相同/不同/缺失/大小写五种） |
| 固件真机：写回 NVS 后重启 ID 不变 | ❌ NOT TESTED（无板子，本轮只做编译验证） |
| 端到端：Pi 侧拒绝错误 bridge_id 的事件 | ❌ NOT TESTED（需要真桥板配合） |

真机验证方法（下次上板）：

```bash
# 1. 连两次 pbr_info，确认 bridge_id 一致
pbr1_tool.py send /dev/ttyACM0 '{"command":"pbr_info"}'
# 2. 复位桥板后再读一次，应与上次相同
# 3. 在 Pi 侧把 TrustStore 记录改成另一个值 → 刷卡应被拒，
#    run.log 出现 "bridge_id does not match authenticated identity"
```
