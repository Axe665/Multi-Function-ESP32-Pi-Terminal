#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// PBR secure v1 的桥板侧实现（Pi 侧对应 pi_terminal/src/protocol/pbr_*.{h,cpp}）。
//
// 桥板固件原本只有明文 PBR1；这里补齐：
//   - X25519 临时密钥协商
//   - P-256 ECDSA 身份签名（hello_resp 的 sig）
//   - HKDF-SHA256 派生 96 字节（handshake / pi2bridge / bridge2pi）
//   - ChaCha20-Poly1305 信封（nonce = prefix4 || auth_seq_u64le，AAD 10 字节）
//   - 握手状态机：hello_req → hello_resp → hello_finish → hello_ok
//
// 帧格式不变（PBR1），握手消息是明文 JSON（schema pbr-handshake-v1），
// 握手完成后的业务帧是二进制 AEAD 信封。

typedef struct {
    uint8_t key_id;           // SHA256(公钥)[0]，Pi 侧用它查配对候选
    const char *bridge_id;    // 事件里的 bridge_id，必须与 Pi 配对记录一致
    const uint8_t *priv;      // 32 字节 P-256 私钥（大端）
    const uint8_t *pub;       // 65 字节未压缩公钥（04||X||Y）
} pbr_secure_identity_t;

void pbr_secure_init(const pbr_secure_identity_t *identity);

bool pbr_secure_authenticated(void);

// 处理 Pi→桥板 收到的一帧 payload（direction=0, kind=2）。
// 返回：
//   1 = 已被安全层消费。*plain 非空时要继续交给命令处理（AEAD 解密后的明文）；
//       reply_len 非零时要先把 reply 原样发回（握手应答）。
//   0 = 不是安全层帧，调用方按旧明文处理。
//  -1 = 认证失败，丢弃。
int pbr_secure_handle_pi_frame(uint8_t kind, const uint8_t *payload, size_t length,
                               const uint8_t **plain, size_t *plain_len,
                               uint8_t *reply, size_t reply_capacity, size_t *reply_len);

// 桥板→Pi 发送前封装：已认证则用 session key 封 AEAD，否则原样拷贝。
size_t pbr_secure_wrap_tx(uint8_t kind, const uint8_t *plain, size_t plain_len,
                          uint8_t *out, size_t out_capacity);

// 诊断：当前是否已完成握手、对端 bridge_id、握手时的 boot_id（8 hex）。
const char *pbr_secure_bridge_id(void);
void pbr_secure_boot_id_hex(char out[9]);
