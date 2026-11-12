// PBR secure v1 · 桥板侧实现。
//
// 与 Pi 侧（pi_terminal/src/protocol/pbr_aead.cpp、pbr_handshake.cpp、
// PogoControlTransport.cpp）逐字节对齐：
//   - 身份：P-256 ECDSA，公钥 65B 未压缩，签名 64B r||s，签的是 SHA256(transcript)
//   - 握手：X25519 临时密钥；HKDF-SHA256(salt=SHA256(T3), info="pbr-secure-v1", L=96)
//   - 信封：env_ver(1)|key_id(1)|nonce(12)|ciphertext|tag(16)
//           nonce = nonce_prefix(4) || auth_seq_u64le(8)
//           AAD   = env_ver|key_id|kind|dir|auth_seq_u32le|plaintext_len_u16le
//   - 方向：Pi→桥板 dir=0 kind=2；桥板→Pi dir=1 kind=1
//
// 注意 X25519 字节序：mbedTLS 的 ECP 点/标量按大端写，X25519 标准（OpenSSL）
// 是小端，读写各翻转 32 字节。

#include "pbr_secure.h"

#include <stdio.h>
#include <string.h>

#include "cJSON.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "mbedtls/chachapoly.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/ecdh.h"
#include "mbedtls/ecdsa.h"
#include "mbedtls/ecp.h"
#include "mbedtls/entropy.h"
#include "mbedtls/hkdf.h"
#include "mbedtls/md.h"
#include "mbedtls/sha256.h"

static const char *TAG = "pbr_secure";

#define PBR_ENV_VER 1u
#define PBR_KEY_BYTES 32u
#define PBR_HDR_BYTES 14u /* env_ver + key_id + nonce */
#define PBR_TAG_BYTES 16u
#define PBR_MAX_PAYLOAD 2048u
#define PBR_MAX_PLAIN (PBR_MAX_PAYLOAD - PBR_HDR_BYTES - PBR_TAG_BYTES)

typedef struct {
    bool have;
    uint8_t key_id;
    const char *bridge_id;
    const uint8_t *priv; /* 32B P-256 私钥 */
    const uint8_t *pub;  /* 65B 未压缩公钥 */
} identity_t;

/* 握手期状态。只服务一条桥板连接，单例足够。 */
typedef struct {
    uint8_t eph_priv[32];     /* X25519 临时私钥（标准小端，已 clamp） */
    bool eph_ready;
    uint8_t eph_pub[32];
    uint8_t pi_eph_pub[32];   /* Pi 临时公钥（标准小端） */
    uint8_t t2[140];
    uint8_t t3[226];
    uint8_t boot_id[4];
    bool have_req;
} handshake_t;

static identity_t s_id;
static handshake_t s_hs;
static bool s_authenticated;
static uint8_t s_keys[96]; /* handshake | pi2bridge | bridge2pi */
static uint8_t s_nonce_prefix[4];
static uint64_t s_tx_seq;
static uint64_t s_rx_seq;
static int s_hs_error;
static SemaphoreHandle_t s_lock;

static mbedtls_entropy_context s_entropy;
static mbedtls_ctr_drbg_context s_drbg;
static bool s_rng_ready;

/* ---------------------------------------------------------------- 基础工具 */

static void pbr_reverse32(uint8_t *value)
{
    for (int i = 0; i < 16; ++i) {
        const uint8_t tmp = value[i];
        value[i] = value[31 - i];
        value[31 - i] = tmp;
    }
}

static void pbr_put_le16(uint8_t *out, uint16_t value)
{
    out[0] = (uint8_t)value;
    out[1] = (uint8_t)(value >> 8);
}

static void pbr_put_le32(uint8_t *out, uint32_t value)
{
    out[0] = (uint8_t)value;
    out[1] = (uint8_t)(value >> 8);
    out[2] = (uint8_t)(value >> 16);
    out[3] = (uint8_t)(value >> 24);
}

static int pbr_hex_nibble(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool pbr_hex_decode(const char *hex, uint8_t *out, size_t out_capacity, size_t *out_len)
{
    if (!hex || !out || !out_len) return false;
    const size_t chars = strlen(hex);
    if (chars % 2 != 0 || chars / 2 > out_capacity) return false;
    for (size_t i = 0; i < chars / 2; ++i) {
        const int hi = pbr_hex_nibble(hex[i * 2]);
        const int lo = pbr_hex_nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    *out_len = chars / 2;
    return true;
}

static void pbr_hex_encode(const uint8_t *data, size_t length, char *out)
{
    static const char kDigits[] = "0123456789abcdef";
    for (size_t i = 0; i < length; ++i) {
        out[i * 2] = kDigits[data[i] >> 4];
        out[i * 2 + 1] = kDigits[data[i] & 0x0f];
    }
    out[length * 2] = '\0';
}

/* u16le(len(name)) || name || u16le(len(body)) || body */
static size_t pbr_element(const char *name, const uint8_t *body, size_t body_len,
                          uint8_t *out, size_t out_capacity)
{
    const size_t name_len = strlen(name);
    const size_t total = 2 + name_len + 2 + body_len;
    if (total > out_capacity) return 0;
    pbr_put_le16(out, (uint16_t)name_len);
    memcpy(out + 2, name, name_len);
    pbr_put_le16(out + 2 + name_len, (uint16_t)body_len);
    memcpy(out + 4 + name_len, body, body_len);
    return total;
}

static bool pbr_rng(uint8_t *out, size_t length)
{
    return s_rng_ready && mbedtls_ctr_drbg_random(&s_drbg, out, length) == 0;
}

static bool pbr_sha256(const uint8_t *data, size_t length, uint8_t out[32])
{
    return mbedtls_sha256(data, length, out, 0) == 0;
}

/* ---------------------------------------------------------------- 信封 */

static void pbr_build_aad(uint8_t aad[10], uint8_t key_id, uint8_t kind, uint8_t dir,
                          uint64_t seq, uint16_t plain_len)
{
    aad[0] = (uint8_t)PBR_ENV_VER;
    aad[1] = key_id;
    aad[2] = kind;
    aad[3] = dir;
    pbr_put_le32(aad + 4, (uint32_t)seq);
    pbr_put_le16(aad + 8, plain_len);
}

static void pbr_build_nonce(uint8_t nonce[12], const uint8_t prefix[4], uint64_t seq)
{
    memcpy(nonce, prefix, 4);
    for (int i = 0; i < 8; ++i) nonce[4 + i] = (uint8_t)(seq >> (8 * i));
}

static size_t pbr_seal(const uint8_t *plain, size_t plain_len, const uint8_t key[32],
                       const uint8_t prefix[4], uint64_t seq, uint8_t key_id,
                       uint8_t kind, uint8_t dir, uint8_t *out, size_t out_capacity)
{
    if (!plain || plain_len > PBR_MAX_PLAIN) return 0;
    const size_t total = PBR_HDR_BYTES + plain_len + PBR_TAG_BYTES;
    if (total > out_capacity || total > PBR_MAX_PAYLOAD) return 0;

    uint8_t aad[10];
    pbr_build_aad(aad, key_id, kind, dir, seq, (uint16_t)plain_len);
    out[0] = (uint8_t)PBR_ENV_VER;
    out[1] = key_id;
    pbr_build_nonce(out + 2, prefix, seq);

    mbedtls_chachapoly_context ctx;
    mbedtls_chachapoly_init(&ctx);
    const bool ok = mbedtls_chachapoly_setkey(&ctx, key) == 0
        && mbedtls_chachapoly_starts(&ctx, out + 2, MBEDTLS_CHACHAPOLY_ENCRYPT) == 0
        && mbedtls_chachapoly_update_aad(&ctx, aad, sizeof(aad)) == 0
        && mbedtls_chachapoly_update(&ctx, plain_len, plain, out + PBR_HDR_BYTES) == 0
        && mbedtls_chachapoly_finish(&ctx, out + PBR_HDR_BYTES + plain_len) == 0;
    mbedtls_chachapoly_free(&ctx);
    return ok ? total : 0;
}

static size_t pbr_open(const uint8_t *payload, size_t length, const uint8_t key[32],
                       uint8_t kind, uint8_t dir, uint8_t *out, size_t out_capacity)
{
    if (!payload || length < PBR_HDR_BYTES + PBR_TAG_BYTES || length > PBR_MAX_PAYLOAD)
        return 0;
    if (payload[0] != PBR_ENV_VER) return 0;
    const size_t plain_len = length - PBR_HDR_BYTES - PBR_TAG_BYTES;
    if (plain_len > out_capacity) return 0;

    uint64_t seq = 0;
    for (int i = 0; i < 8; ++i) seq |= (uint64_t)payload[2 + 4 + i] << (8 * i);
    /* 规范 §10 的拒绝顺序：tag 必须先于 auth_seq 单调性验证。否则未认证的
     * 伪造帧可以把接收序号推高，造成合法帧被拒的 DoS。这里先解密验 tag，
     * 单调性检查放到 tag 通过之后。 */

    uint8_t aad[10];
    pbr_build_aad(aad, payload[1], kind, dir, seq, (uint16_t)plain_len);

    mbedtls_chachapoly_context ctx;
    mbedtls_chachapoly_init(&ctx);
    bool ok = mbedtls_chachapoly_setkey(&ctx, key) == 0
        && mbedtls_chachapoly_starts(&ctx, payload + 2, MBEDTLS_CHACHAPOLY_DECRYPT) == 0
        && mbedtls_chachapoly_update_aad(&ctx, aad, sizeof(aad)) == 0
        && mbedtls_chachapoly_update(&ctx, plain_len, payload + PBR_HDR_BYTES, out) == 0;
    if (ok) ok = mbedtls_chachapoly_finish(&ctx, payload + PBR_HDR_BYTES + plain_len) == 0;
    mbedtls_chachapoly_free(&ctx);
    if (!ok) return 0;
    /* tag 已通过：现在才认这个序号。auth_seq=0 或回退一律失败关闭。 */
    if (seq == 0 || seq <= s_rx_seq) return 0;
    s_rx_seq = seq;
    return plain_len;
}

/* ---------------------------------------------------------------- 身份签名 */

static bool pbr_ecdsa_sign(const uint8_t hash[32], uint8_t signature[64])
{
    mbedtls_ecp_group grp;
    mbedtls_mpi d, r, s;
    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_mpi_init(&r);
    mbedtls_mpi_init(&s);
    bool ok = false;
    do {
        if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) != 0) break;
        if (mbedtls_mpi_read_binary(&d, s_id.priv, PBR_KEY_BYTES) != 0) break;
        if (mbedtls_ecdsa_sign(&grp, &r, &s, &d, hash, 32, mbedtls_ctr_drbg_random,
                               &s_drbg) != 0)
            break;
        if (mbedtls_mpi_write_binary(&r, signature, 32) != 0) break;
        if (mbedtls_mpi_write_binary(&s, signature + 32, 32) != 0) break;
        ok = true;
    } while (0);
    mbedtls_mpi_free(&d);
    mbedtls_mpi_free(&r);
    mbedtls_mpi_free(&s);
    mbedtls_ecp_group_free(&grp);
    return ok;
}

static bool pbr_ecdsa_verify(const uint8_t *public_key, size_t public_len,
                             const uint8_t hash[32], const uint8_t signature[64])
{
    if (!public_key || public_len != 65) return false;
    mbedtls_ecp_group grp;
    mbedtls_ecp_point q;
    mbedtls_mpi r, s;
    mbedtls_ecp_group_init(&grp);
    mbedtls_ecp_point_init(&q);
    mbedtls_mpi_init(&r);
    mbedtls_mpi_init(&s);
    bool ok = false;
    do {
        if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) != 0) break;
        if (mbedtls_ecp_point_read_binary(&grp, &q, public_key, public_len) != 0) break;
        if (mbedtls_mpi_read_binary(&r, signature, 32) != 0) break;
        if (mbedtls_mpi_read_binary(&s, signature + 32, 32) != 0) break;
        ok = mbedtls_ecdsa_verify(&grp, hash, 32, &q, &r, &s) == 0;
    } while (0);
    mbedtls_ecp_point_free(&q);
    mbedtls_mpi_free(&r);
    mbedtls_mpi_free(&s);
    mbedtls_ecp_group_free(&grp);
    return ok;
}

/* ---------------------------------------------------------------- X25519 */

/* mbedTLS 的 ECDH 对 CURVE25519 要 everest 变体（IDF 未启用），
 * 但 mbedtls_ecp_mul 的 Montgomery 分支（ecp_mul_mxz）可用，
 * 且点读写都是标准 X25519 小端格式。 */
static bool pbr_x25519_make_public(uint8_t pub_le[32])
{
    uint8_t scalar[32];
    if (!pbr_rng(scalar, sizeof(scalar))) {
        s_hs_error = 21;
        return false;
    }
    scalar[0] &= 248;
    scalar[31] = (uint8_t)((scalar[31] & 127) | 64);
    memcpy(s_hs.eph_priv, scalar, sizeof(scalar));

    mbedtls_ecp_group grp;
    mbedtls_mpi d;
    mbedtls_ecp_point r;
    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&r);
    bool ok = false;
    size_t olen = 32;
    do {
        if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_CURVE25519) != 0) {
            s_hs_error = 21;
            break;
        }
        if (mbedtls_mpi_read_binary_le(&d, scalar, 32) != 0) {
            s_hs_error = 22;
            break;
        }
        if (mbedtls_ecp_mul(&grp, &r, &d, &grp.G, mbedtls_ctr_drbg_random, &s_drbg) != 0) {
            s_hs_error = 22;
            break;
        }
        if (mbedtls_ecp_point_write_binary(&grp, &r, MBEDTLS_ECP_PF_UNCOMPRESSED, &olen,
                                           pub_le, 32) != 0
            || olen != 32) {
            s_hs_error = 23;
            break;
        }
        ok = true;
    } while (0);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_point_free(&r);
    mbedtls_ecp_group_free(&grp);
    memset(scalar, 0, sizeof(scalar));
    if (ok) {
        memcpy(s_hs.eph_pub, pub_le, 32);
        s_hs.eph_ready = true;
    }
    return ok;
}

static bool pbr_x25519_shared(const uint8_t peer_pub_le[32], uint8_t shared_le[32])
{
    if (!s_hs.eph_ready) {
        s_hs_error = 24;
        return false;
    }
    mbedtls_ecp_group grp;
    mbedtls_mpi d;
    mbedtls_ecp_point peer, r;
    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&peer);
    mbedtls_ecp_point_init(&r);
    bool ok = false;
    size_t olen = 32;
    do {
        if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_CURVE25519) != 0) break;
        if (mbedtls_mpi_read_binary_le(&d, s_hs.eph_priv, 32) != 0) break;
        if (mbedtls_ecp_point_read_binary(&grp, &peer, peer_pub_le, 32) != 0) {
            s_hs_error = 25;
            break;
        }
        if (mbedtls_ecp_mul(&grp, &r, &d, &peer, mbedtls_ctr_drbg_random, &s_drbg) != 0) {
            s_hs_error = 26;
            break;
        }
        if (mbedtls_ecp_point_write_binary(&grp, &r, MBEDTLS_ECP_PF_UNCOMPRESSED, &olen,
                                           shared_le, 32) != 0
            || olen != 32) {
            s_hs_error = 27;
            break;
        }
        ok = true;
    } while (0);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_point_free(&peer);
    mbedtls_ecp_point_free(&r);
    mbedtls_ecp_group_free(&grp);
    if (ok) {
        /* 低阶点：全零共享值视为无效。 */
        uint8_t acc = 0;
        for (int i = 0; i < 32; ++i) acc |= shared_le[i];
        if (acc == 0) ok = false;
    }
    s_hs.eph_ready = false;
    return ok;
}

/* ---------------------------------------------------------------- HKDF */

static bool pbr_derive_keys(const uint8_t shared[32], const uint8_t *transcript,
                            size_t transcript_len)
{
    uint8_t transcript_hash[32];
    if (!pbr_sha256(transcript, transcript_len, transcript_hash)) return false;
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (!md) return false;
    static const char kInfo[] = "pbr-secure-v1";
    if (mbedtls_hkdf(md, transcript_hash, sizeof(transcript_hash), shared, 32,
                     (const uint8_t *)kInfo, sizeof(kInfo) - 1, s_keys, sizeof(s_keys)) != 0)
        return false;
    memcpy(s_nonce_prefix, transcript_hash + 16, 4);
    return true;
}

/* ---------------------------------------------------------------- 握手 */

static int pbr_handle_hello_req(const uint8_t *body, size_t body_len,
                                uint8_t *reply, size_t reply_capacity, size_t *reply_len)
{
    if (body_len != 50 || body[0] != 1 || body[1] != 1) {
        s_hs_error = 1;
        return 0;
    }

    uint8_t msg2[55];
    if (!pbr_x25519_make_public(msg2 + 2)) {
        return 0; /* s_hs_error 由内部细分（21/22/23） */
    }
    memcpy(s_hs.pi_eph_pub, body + 2, 32);
    uint8_t nonce16[16];
    if (!pbr_rng(nonce16, sizeof(nonce16))) return 0;

    msg2[0] = 1;
    msg2[1] = 1;
    memcpy(msg2 + 34, nonce16, 16);
    const uint32_t random_boot = esp_random();
    s_hs.boot_id[0] = (uint8_t)(random_boot & 0xff);
    s_hs.boot_id[1] = (uint8_t)((random_boot >> 8) & 0xff);
    s_hs.boot_id[2] = (uint8_t)((random_boot >> 16) & 0xff);
    s_hs.boot_id[3] = (uint8_t)((random_boot >> 24) & 0xff);
    memcpy(msg2 + 50, s_hs.boot_id, 4);
    msg2[54] = s_id.key_id;

    size_t offset = pbr_element("pbr_hello_req", body, 50, s_hs.t2, sizeof(s_hs.t2));
    if (offset != 67) {
        s_hs_error = 3;
        return 0;
    }
    const size_t second = pbr_element("pbr_hello_resp", msg2, sizeof(msg2),
                                      s_hs.t2 + offset, sizeof(s_hs.t2) - offset);
    if (second != 73 || offset + second != sizeof(s_hs.t2)) {
        s_hs_error = 4;
        return 0;
    }

    uint8_t t2_hash[32];
    uint8_t signature[64];
    if (!pbr_sha256(s_hs.t2, sizeof(s_hs.t2), t2_hash)) return 0;
    if (!pbr_ecdsa_sign(t2_hash, signature)) {
        s_hs_error = 5;
        return 0;
    }

    char body_hex[sizeof(msg2) * 2 + 1];
    char sig_hex[sizeof(signature) * 2 + 1];
    pbr_hex_encode(msg2, sizeof(msg2), body_hex);
    pbr_hex_encode(signature, sizeof(signature), sig_hex);
    const int written = snprintf((char *)reply, reply_capacity,
                                 "{\"schema\":\"pbr-handshake-v1\",\"msg\":\"hello_resp\","
                                 "\"body\":\"%s\",\"sig\":\"%s\"}",
                                 body_hex, sig_hex);
    if (written <= 0 || (size_t)written >= reply_capacity) return 0;
    *reply_len = (size_t)written;
    s_hs.have_req = true;
    ESP_LOGI(TAG, "hello_resp (key_id=%u)", s_id.key_id);
    return 1;
}

static int pbr_handle_hello_finish(const uint8_t *body, size_t body_len,
                                   const uint8_t *sig, size_t sig_len,
                                   uint8_t *reply, size_t reply_capacity, size_t *reply_len)
{
    if (!s_hs.have_req || body_len != 66 || sig_len != 64) return 0;

    memcpy(s_hs.t3, s_hs.t2, sizeof(s_hs.t2));
    const size_t rest = pbr_element("pbr_hello_finish", body, 66, s_hs.t3 + sizeof(s_hs.t2),
                                    sizeof(s_hs.t3) - sizeof(s_hs.t2));
    if (rest != 86 || sizeof(s_hs.t2) + rest != sizeof(s_hs.t3)) return 0;

    uint8_t t3_hash[32];
    if (!pbr_sha256(s_hs.t3, sizeof(s_hs.t3), t3_hash)) return 0;
    if (!pbr_ecdsa_verify(body + 1, 65, t3_hash, sig)) {
        s_hs_error = 6;
        return 0;
    }

    uint8_t shared[32];
    if (!pbr_x25519_shared(s_hs.pi_eph_pub, shared)) return 0;
    if (!pbr_derive_keys(shared, s_hs.t3, sizeof(s_hs.t3))) return 0;
    memset(shared, 0, sizeof(shared));

    /* hello_ok 用握手密钥加密；Pi 侧用它判断握手完成。 */
    char ok_json[128];
    const int ok_len = snprintf(ok_json, sizeof(ok_json),
                                "{\"schema\":\"pbr-handshake-v1\",\"msg\":\"hello_ok\","
                                "\"uptime_ms\":%lld}",
                                (long long)(esp_timer_get_time() / 1000));
    if (ok_len <= 0 || (size_t)ok_len >= sizeof(ok_json)) return 0;
    const size_t sealed = pbr_seal((const uint8_t *)ok_json, (size_t)ok_len, s_keys,
                                   s_nonce_prefix, 1, s_id.key_id, 1, 1, reply,
                                   reply_capacity);
    if (sealed == 0) return 0;
    *reply_len = sealed;

    s_authenticated = true;
    s_tx_seq = 0;
    s_rx_seq = 0;
    s_hs.have_req = false;
    ESP_LOGI(TAG, "handshake ok (bridge=%s)", s_id.bridge_id ? s_id.bridge_id : "?");
    return 1;
}

/* ---------------------------------------------------------------- 对外接口 */

void pbr_secure_init(const pbr_secure_identity_t *identity)
{
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    memset(&s_id, 0, sizeof(s_id));
    memset(&s_hs, 0, sizeof(s_hs));
    memset(s_keys, 0, sizeof(s_keys));
    s_authenticated = false;
    s_tx_seq = 0;
    s_rx_seq = 0;
    if (identity && identity->priv && identity->pub) {
        s_id.have = true;
        s_id.key_id = identity->key_id;
        s_id.bridge_id = identity->bridge_id;
        s_id.priv = identity->priv;
        s_id.pub = identity->pub;
    }
    if (!s_rng_ready) {
        mbedtls_entropy_init(&s_entropy);
        mbedtls_ctr_drbg_init(&s_drbg);
        static const char kPers[] = "pbr-secure-bridge";
        if (mbedtls_ctr_drbg_seed(&s_drbg, mbedtls_entropy_func, &s_entropy,
                                  (const uint8_t *)kPers, sizeof(kPers) - 1) == 0)
            s_rng_ready = true;
        else
            ESP_LOGE(TAG, "ctr_drbg seed failed");
    }
}

bool pbr_secure_authenticated(void)
{
    return s_authenticated;
}

const char *pbr_secure_bridge_id(void)
{
    return s_id.bridge_id ? s_id.bridge_id : "";
}

void pbr_secure_boot_id_hex(char out[9])
{
    static const char kDigits[] = "0123456789abcdef";
    for (int i = 0; i < 4; ++i) {
        out[i * 2] = kDigits[s_hs.boot_id[i] >> 4];
        out[i * 2 + 1] = kDigits[s_hs.boot_id[i] & 0x0f];
    }
    out[8] = '\0';
}

size_t pbr_secure_wrap_tx(uint8_t kind, const uint8_t *plain, size_t plain_len,
                          uint8_t *out, size_t out_capacity)
{
    if (!s_authenticated) {
        if (plain_len > out_capacity) return 0;
        memcpy(out, plain, plain_len);
        return plain_len;
    }
    if (s_lock) xSemaphoreTake(s_lock, portMAX_DELAY);
    /* §10：auth_seq 接近 2^64-1 时不允许继续发（否则回绕后对端会判回退）。
     * 桥板无法主动重握手，这里失败关闭并丢弃会话。 */
    if (s_tx_seq >= (0xffffffffffffffffULL - (1ULL << 20))) {
        s_authenticated = false;
        if (s_lock) xSemaphoreGive(s_lock);
        return 0;
    }
    const size_t total = pbr_seal(plain, plain_len, s_keys + 64, s_nonce_prefix,
                                  ++s_tx_seq, s_id.key_id, kind, 1, out, out_capacity);
    if (s_lock) xSemaphoreGive(s_lock);
    return total;
}

int pbr_secure_handle_pi_frame(uint8_t kind, const uint8_t *payload, size_t length,
                               const uint8_t **plain, size_t *plain_len,
                               uint8_t *reply, size_t reply_capacity, size_t *reply_len)
{
    if (plain) *plain = NULL;
    if (plain_len) *plain_len = 0;
    if (reply_len) *reply_len = 0;
    if (!payload || !length) return 0;

    /* 握手消息是明文 JSON；业务帧是二进制信封（首字节 env_ver=1）。 */
    if (payload[0] == '{') {
        if (length > 512) return -1;
        char text[513];
        memcpy(text, payload, length);
        text[length] = '\0';
        cJSON *root = cJSON_Parse(text);
        if (!root) return -1;
        const cJSON *schema = cJSON_GetObjectItemCaseSensitive(root, "schema");
        const cJSON *msg = cJSON_GetObjectItemCaseSensitive(root, "msg");
        int handled = 0;
        if (cJSON_IsString(schema) && strcmp(schema->valuestring, "pbr-handshake-v1") == 0
            && cJSON_IsString(msg)) {
            const cJSON *body_item = cJSON_GetObjectItemCaseSensitive(root, "body");
            const cJSON *sig_item = cJSON_GetObjectItemCaseSensitive(root, "sig");
            uint8_t body[128];
            size_t body_len = 0;
            if (cJSON_IsString(body_item)
                && pbr_hex_decode(body_item->valuestring, body, sizeof(body), &body_len)) {
                if (strcmp(msg->valuestring, "hello_req") == 0) {
                    handled = pbr_handle_hello_req(body, body_len, reply, reply_capacity,
                                                   reply_len);
                } else if (strcmp(msg->valuestring, "hello_finish") == 0) {
                    uint8_t signature[64];
                    size_t sig_len = 0;
                    if (cJSON_IsString(sig_item)
                        && pbr_hex_decode(sig_item->valuestring, signature, sizeof(signature),
                                          &sig_len)) {
                        handled = pbr_handle_hello_finish(body, body_len, signature, sig_len,
                                                          reply, reply_capacity, reply_len);
                    }
                }
            }
        }
        const int was_handshake = (schema && cJSON_IsString(schema)
                                   && strcmp(schema->valuestring, "pbr-handshake-v1") == 0);
        cJSON_Delete(root);
        if (handled == 1) return 1;
        if (was_handshake) {
            // ESP_LOG 在这块板子上走 USB 而不是 CH343，Pi 侧看不到；
            // 握手失败用数据帧回传错误码，便于联调。
            const int written = snprintf((char *)reply, reply_capacity,
                                         "{\"event\":\"hs_error\",\"code\":%d}", s_hs_error);
            if (written > 0 && (size_t)written < reply_capacity) *reply_len = (size_t)written;
            return 1;
        }
        // 不是握手消息的明文 JSON：未认证时交给旧明文路径；已认证则拒绝。
        return s_authenticated ? -1 : 0;
    }

    if (!s_authenticated) return -1;
    static uint8_t s_plain[PBR_MAX_PLAIN];
    if (s_lock) xSemaphoreTake(s_lock, portMAX_DELAY);
    const size_t opened = pbr_open(payload, length, s_keys + 32, kind, 0, s_plain,
                                   sizeof(s_plain));
    if (s_lock) xSemaphoreGive(s_lock);
    if (opened == 0) return -1;
    if (plain) *plain = s_plain;
    if (plain_len) *plain_len = opened;
    return 1;
}
