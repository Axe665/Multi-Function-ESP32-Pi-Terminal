#pragma once

#include "esp_err.h"
#include <stdbool.h>
#include <stdint.h>

/* 模块设备绑定的 LAN 侧广播（设计 §3.2）。
 *
 * TXT 五元组：
 *   v=1                 协议版本
 *   uid=<32 hex>        模块指纹，与桥板 attach 里的 module_uid 同一算法
 *   mid=<module_id>     型号（1..255）
 *   port=<port>         数据面 TCP 端口
 *   name=<显示名>        给人看的名，可为空串
 * 服务名固定 _orpi-module._tcp，主机端按 uid 匹配已绑定设备。
 */

/* 计算模块指纹：SHA256(module_mac ‖ 16 字节定长 module_type)[0:16] → 32 hex + NUL。
 *
 * module_type 与桥板/主机两侧的哈希输入布局必须逐字节一致（见
 * S3_PiBridge_LinkIt_Host/main/main.c 的 pbridge_module_uid 同一段注释）：
 *   输入 = 6 字节 ESP_MAC_WIFI_STA + 16 字节定长 module_type（不足补 0）
 * 任一侧改了都要同时改另一侧，否则同一台设备会被当成两台。
 * 失败（无 MAC / 哈希错误）返回 false，调用方必须当成"没有指纹"。 */
bool module_data_module_uid(char out[33], const char *module_type);

/* 启动广播。必须在 LAN 数据面已就绪（拿到 IP 且 TCP 服务已监听）后调用。
 * module_type 为 NULL 时按 "GENERIC"（与 linkit SDK 默认值一致）；
 * display_name 为 NULL 时用主机名。
 * 幂等：重复调用会先撤销上一次广播。 */
esp_err_t module_data_mdns_start(uint8_t module_id, uint16_t port,
                                 const char *module_type, const char *display_name);

/* 撤销广播并释放 mDNS 实例。幂等。 */
void module_data_mdns_stop(void);

/* 当前广播用的 uid（32 hex）；未广播时为空串。供日志/自检使用。 */
const char *module_data_mdns_uid(void);
