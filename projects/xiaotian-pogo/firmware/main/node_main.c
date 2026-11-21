#include <inttypes.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_event.h"
#include "esp_https_server.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "bootloader_random.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "nvs_flash.h"
#include "mbedtls/pk.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/sha256.h"
#include "cJSON.h"
#include "node_state.h"
#include "pogo_service.h"

#define VERSION "2.1.0"
#define RPC_PORT 8443
static xt_state_t state;
static SemaphoreHandle_t lock;
static nvs_handle_t store;
static char device_id[32], boot_id[33], token[65], pin[65];
static char cert_pem[2048], key_pem[1024], ip[20]="0.0.0.0", setup_pass[24];
static bool wifi_up, setup_ap;

static int rng(void *ctx, unsigned char *out, size_t n) { (void)ctx; esp_fill_random(out,n); return 0; }
static void hex(const uint8_t *in, size_t n, char *out) {
    for(size_t i=0;i<n;++i) sprintf(out+2*i,"%02x",in[i]);
    out[2*n]=0;
}
static bool load(const char *name,char *out,size_t size) {
    return nvs_get_str(store,name,out,&size)==ESP_OK && size>1;
}
static void init_identity(void) {
    if(!load("token",token,sizeof(token))) {
        uint8_t bytes[32]; esp_fill_random(bytes,32); hex(bytes,32,token);
        ESP_ERROR_CHECK(nvs_set_str(store,"token",token));
    }
    if(!load("cert",cert_pem,sizeof(cert_pem)) || !load("key",key_pem,sizeof(key_pem))) {
        mbedtls_pk_context key; mbedtls_pk_init(&key);
        mbedtls_x509write_cert cert; mbedtls_x509write_crt_init(&cert);
        unsigned char serial[16];
        ESP_ERROR_CHECK(mbedtls_pk_setup(&key,mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY)));
        ESP_ERROR_CHECK(mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1,mbedtls_pk_ec(key),rng,NULL));
        ESP_ERROR_CHECK(mbedtls_pk_write_key_pem(&key,(unsigned char *)key_pem,sizeof(key_pem)));
        mbedtls_x509write_crt_set_version(&cert,MBEDTLS_X509_CRT_VERSION_3);
        mbedtls_x509write_crt_set_md_alg(&cert,MBEDTLS_MD_SHA256);
        mbedtls_x509write_crt_set_subject_key(&cert,&key); mbedtls_x509write_crt_set_issuer_key(&cert,&key);
        esp_fill_random(serial,sizeof(serial)); serial[0]=(serial[0]&0x7f)|1;
        ESP_ERROR_CHECK(mbedtls_x509write_crt_set_serial_raw(&cert,serial,sizeof(serial)));
        char name[64]; snprintf(name,sizeof(name),"CN=%s",device_id);
        ESP_ERROR_CHECK(mbedtls_x509write_crt_set_subject_name(&cert,name));
        ESP_ERROR_CHECK(mbedtls_x509write_crt_set_issuer_name(&cert,name));
        ESP_ERROR_CHECK(mbedtls_x509write_crt_set_validity(&cert,"20260101000000","20560101000000"));
        ESP_ERROR_CHECK(mbedtls_x509write_crt_set_basic_constraints(&cert,0,-1));
        ESP_ERROR_CHECK(mbedtls_x509write_crt_set_key_usage(&cert,MBEDTLS_X509_KU_DIGITAL_SIGNATURE));
        ESP_ERROR_CHECK(mbedtls_x509write_crt_pem(&cert,(unsigned char *)cert_pem,sizeof(cert_pem),rng,NULL));
        ESP_ERROR_CHECK(nvs_set_str(store,"cert",cert_pem)); ESP_ERROR_CHECK(nvs_set_str(store,"key",key_pem));
        mbedtls_x509write_crt_free(&cert); mbedtls_pk_free(&key);
    }
    ESP_ERROR_CHECK(nvs_commit(store));
    mbedtls_x509_crt cert; mbedtls_x509_crt_init(&cert);
    ESP_ERROR_CHECK(mbedtls_x509_crt_parse(&cert,(unsigned char *)cert_pem,strlen(cert_pem)+1));
    uint8_t digest[32]; ESP_ERROR_CHECK(mbedtls_sha256(cert.raw.p,cert.raw.len,digest,0));
    hex(digest,32,pin); mbedtls_x509_crt_free(&cert);
}
static cJSON *error(const char *why) {
    cJSON *j=cJSON_CreateObject(); cJSON_AddBoolToObject(j,"ok",false); cJSON_AddStringToObject(j,"error",why); return j;
}
static const char *str(const cJSON *j,const char *key) {
    const cJSON *v=cJSON_GetObjectItemCaseSensitive(j,key); return cJSON_IsString(v)?v->valuestring:NULL;
}
static bool identifier(const char *s) {
    if(!s || !s[0] || strlen(s)>64) return false;
    for(;*s;++s) if(!((*s>='a'&&*s<='z')||(*s>='A'&&*s<='Z')||(*s>='0'&&*s<='9')||*s=='-'||*s=='_')) return false;
    return true;
}
static bool number(const cJSON *j,const char *key,uint32_t *out) {
    const cJSON *v=cJSON_GetObjectItemCaseSensitive(j,key);
    if(!cJSON_IsNumber(v)||!isfinite(v->valuedouble)||v->valuedouble<0||v->valuedouble>UINT32_MAX||floor(v->valuedouble)!=v->valuedouble) return false;
    *out=(uint32_t)v->valuedouble; return true;
}
static cJSON *status(void) { // caller holds lock
    xt_tick(&state,esp_timer_get_time()/1000);
    cJSON *j=cJSON_CreateObject();
    cJSON_AddBoolToObject(j,"ok",true); cJSON_AddStringToObject(j,"schema","xiaotian.node.v2");
    cJSON_AddStringToObject(j,"app","xiaotian_io4_probe"); cJSON_AddStringToObject(j,"version",VERSION);
    cJSON_AddStringToObject(j,"device_id",device_id); cJSON_AddStringToObject(j,"boot_id",boot_id);
    cJSON_AddNumberToObject(j,"uptime_ms",esp_timer_get_time()/1000);
    cJSON_AddNumberToObject(j,"revision",state.revision); cJSON_AddBoolToObject(j,"enabled",state.enabled);
    cJSON_AddStringToObject(j,"mode",state.enabled?"monitoring":"standby");
    cJSON_AddNumberToObject(j,"gpio",4); cJSON_AddNumberToObject(j,"stable",state.stable);
    cJSON_AddStringToObject(j,"state",!state.enabled?"unknown":state.stable<0?"initializing":state.stable?"clear":"blocked");
    cJSON_AddNumberToObject(j,"changes",state.changes); cJSON_AddNumberToObject(j,"seq",state.seq);
    cJSON_AddBoolToObject(j,"recording",state.session[0]!=0); cJSON_AddNumberToObject(j,"record_epoch",state.record_epoch);
    cJSON_AddNumberToObject(j,"lease_remaining_ms",state.session[0]?state.lease_until_ms-esp_timer_get_time()/1000:0);
    cJSON_AddBoolToObject(j,"wifi_up",wifi_up); cJSON_AddStringToObject(j,"wifi_mode",setup_ap?"setup_ap":"station");
    xt_pogo_status_t p=xt_pogo_snapshot();
    cJSON *contact=cJSON_AddObjectToObject(j,"pogo");
    cJSON_AddNumberToObject(contact,"module_id",XT_POGO_MODULE_ID);
    cJSON_AddBoolToObject(contact,"ready",p.ready);
    cJSON_AddBoolToObject(contact,"wired",p.wired);
    cJSON_AddStringToObject(contact,"state",p.wired?"wired":p.ready?"waiting":"unavailable");
    cJSON_AddNumberToObject(contact,"rx_frames",p.rx_frames);
    cJSON_AddStringToObject(j,"business_transport","xiaotian_https_v2");
    cJSON_AddStringToObject(j,"ip",ip); cJSON_AddNumberToObject(j,"port",RPC_PORT); return j;
}
static bool revision_matches(const cJSON *j) {
    uint32_t rev; const char *boot=str(j,"boot_id");
    return boot&&!strcmp(boot,boot_id)&&number(j,"if_revision",&rev)&&rev==state.revision;
}
static void restart_later(void *arg) { (void)arg; vTaskDelay(pdMS_TO_TICKS(500)); esp_restart(); }
static cJSON *rpc(const cJSON *j,bool local) {
    const char *op=str(j,"op"); if(!op) return error("missing_op");
    if(!strcmp(op,"set_wifi")) {
        if(!local) return error("usb_only");
        const char *ssid=str(j,"ssid"),*pass=str(j,"password");
        if(!ssid||!ssid[0]||strlen(ssid)>32||!pass||strlen(pass)<8||strlen(pass)>63) return error("require_wpa2_credentials");
        if(nvs_set_str(store,"ssid",ssid)!=ESP_OK||nvs_set_str(store,"wifi_pass",pass)!=ESP_OK||nvs_commit(store)!=ESP_OK) return error("nvs_write_failed");
        cJSON *r=cJSON_CreateObject(); cJSON_AddBoolToObject(r,"ok",true); cJSON_AddBoolToObject(r,"restarting",true);
        xTaskCreate(restart_later,"restart",2048,NULL,3,NULL); return r;
    }
    if(!strcmp(op,"provision")) {
        if(!local) return error("usb_only");
        cJSON *r=cJSON_CreateObject(); cJSON_AddBoolToObject(r,"ok",true);
        cJSON_AddStringToObject(r,"device_id",device_id); cJSON_AddStringToObject(r,"token",token);
        cJSON_AddStringToObject(r,"pin_sha256",pin); cJSON_AddStringToObject(r,"host",ip); cJSON_AddNumberToObject(r,"port",RPC_PORT);
        if(setup_ap) { cJSON_AddStringToObject(r,"setup_ssid",device_id); cJSON_AddStringToObject(r,"setup_password",setup_pass); }
        return r;
    }
    xSemaphoreTake(lock,portMAX_DELAY); xt_tick(&state,esp_timer_get_time()/1000);
    cJSON *r=NULL;
    if(!strcmp(op,"status")) r=status();
    else if(!strcmp(op,"enable")||!strcmp(op,"disable")) {
        if(!revision_matches(j)) r=error("stale_revision_or_boot");
        else { if(!strcmp(op,"enable")) xt_enable(&state,esp_timer_get_time()); else xt_disable(&state); r=status(); }
    } else if(!strcmp(op,"record_start")||!strcmp(op,"record_keepalive")||!strcmp(op,"record_stop")||!strcmp(op,"events")) {
        const char *owner=str(j,"owner"),*session=str(j,"session"),*boot=str(j,"boot_id");
        if(!identifier(owner)||!identifier(session)) r=error("invalid_owner_or_session");
        else if(!boot||strcmp(boot,boot_id)) r=error("stale_boot");
        else if(!strcmp(op,"record_start")) {
            if(!xt_record_start(&state,owner,session,esp_timer_get_time()/1000)) r=error("disabled_or_other_session_active"); else r=status();
        } else if(!strcmp(owner,state.owner)&&!strcmp(session,state.session)&&state.session[0]) {
            if(!strcmp(op,"record_stop")) { xt_record_stop(&state); r=status(); }
            else if(!strcmp(op,"record_keepalive")) { xt_record_keepalive(&state,owner,session,esp_timer_get_time()/1000); r=status(); }
            else {
                uint32_t after;
                if(!number(j,"after_seq",&after)) r=error("invalid_after_seq");
                else {
                    r=status(); cJSON *events=cJSON_AddArrayToObject(r,"events"); const xt_event_t *oldest=xt_event_at(&state,0);
                    cJSON_AddBoolToObject(r,"gap",oldest&&after&&after<oldest->seq-1);
                    cJSON_AddNumberToObject(r,"buffer_capacity",XT_EVENT_CAPACITY);
                    for(unsigned i=0;i<state.count;++i) {
                        const xt_event_t *e=xt_event_at(&state,i); if(e->seq<=after) continue;
                        cJSON *v=cJSON_CreateObject(); cJSON_AddStringToObject(v,"event",e->event);
                        cJSON_AddNumberToObject(v,"seq",e->seq); cJSON_AddNumberToObject(v,"stable",e->stable);
                        cJSON_AddNumberToObject(v,"changes",e->changes); cJSON_AddNumberToObject(v,"uptime_ms",e->uptime_ms);
                        cJSON_AddNumberToObject(v,"record_epoch",e->record_epoch); cJSON_AddItemToArray(events,v);
                    }
                }
            }
        } else r=error("session_expired_or_mismatch");
    } else r=error("unknown_op");
    xSemaphoreGive(lock); return r;
}
static void print_json(cJSON *j) {
    char *text=cJSON_PrintUnformatted(j); if(text) { puts(text); fflush(stdout); free(text); } cJSON_Delete(j);
}
static bool bearer_ok(httpd_req_t *req) {
    char got[80]={0},expected[80]; snprintf(expected,sizeof(expected),"Bearer %s",token);
    size_t n=strlen(expected);
    if(httpd_req_get_hdr_value_len(req,"Authorization")!=n||httpd_req_get_hdr_value_str(req,"Authorization",got,sizeof(got))!=ESP_OK) return false;
    unsigned diff=0; for(size_t i=0;i<n;++i) diff|=(unsigned char)got[i]^(unsigned char)expected[i]; return diff==0;
}
static esp_err_t https_rpc(httpd_req_t *req) {
    if(!bearer_ok(req)) { httpd_resp_set_status(req,"401 Unauthorized"); return httpd_resp_sendstr(req,"{\"ok\":false,\"error\":\"unauthorized\"}"); }
    if(req->content_len<=0||req->content_len>768) return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"body must be 1..768 bytes");
    char body[769]; int used=0;
    while(used<req->content_len) { int n=httpd_req_recv(req,body+used,req->content_len-used); if(n<=0) return ESP_FAIL; used+=n; }
    body[used]=0; cJSON *j=cJSON_ParseWithLengthOpts(body,(size_t)used+1,NULL,true);
    if(!cJSON_IsObject(j)) { cJSON_Delete(j); return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"invalid JSON"); }
    cJSON *r=rpc(j,false); cJSON_Delete(j); char *text=cJSON_PrintUnformatted(r); cJSON_Delete(r);
    if(!text) return ESP_FAIL;
    httpd_resp_set_type(req,"application/json"); httpd_resp_set_hdr(req,"Cache-Control","no-store");
    esp_err_t result=httpd_resp_sendstr(req,text); free(text); return result;
}
static void wifi_event(void *arg,esp_event_base_t base,int32_t id,void *data) {
    (void)arg;
    if(base==WIFI_EVENT&&id==WIFI_EVENT_STA_START) esp_wifi_connect();
    if(base==WIFI_EVENT&&id==WIFI_EVENT_STA_DISCONNECTED) {
        xSemaphoreTake(lock,portMAX_DELAY); wifi_up=false; snprintf(ip,sizeof(ip),"0.0.0.0");
        xt_record_stop(&state); xSemaphoreGive(lock);
    }
    if(base==IP_EVENT&&id==IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e=data; xSemaphoreTake(lock,portMAX_DELAY);
        snprintf(ip,sizeof(ip),IPSTR,IP2STR(&e->ip_info.ip)); wifi_up=true; xSemaphoreGive(lock);
        printf("{\"event\":\"WIFI_READY\",\"ip\":\"%s\",\"port\":8443}\n",ip);
    }
}
static void init_wifi(void) {
    ESP_ERROR_CHECK(esp_netif_init()); ESP_ERROR_CHECK(esp_event_loop_create_default());
    char ssid[33]={0},pass[65]={0};
    setup_ap=!(load("ssid",ssid,sizeof(ssid))&&load("wifi_pass",pass,sizeof(pass)));
    if(setup_ap) esp_netif_create_default_wifi_ap(); else esp_netif_create_default_wifi_sta();
    wifi_init_config_t init=WIFI_INIT_CONFIG_DEFAULT(); ESP_ERROR_CHECK(esp_wifi_init(&init));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT,ESP_EVENT_ANY_ID,wifi_event,NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT,IP_EVENT_STA_GOT_IP,wifi_event,NULL));
    wifi_config_t cfg={0};
    if(setup_ap) {
        if(!load("ap_pass",setup_pass,sizeof(setup_pass))) {
            uint8_t bytes[8]; bootloader_random_enable(); esp_fill_random(bytes,8); bootloader_random_disable(); hex(bytes,8,setup_pass);
            ESP_ERROR_CHECK(nvs_set_str(store,"ap_pass",setup_pass)); ESP_ERROR_CHECK(nvs_commit(store));
        }
        snprintf((char *)cfg.ap.ssid,sizeof(cfg.ap.ssid),"%s",device_id);
        snprintf((char *)cfg.ap.password,sizeof(cfg.ap.password),"%s",setup_pass);
        cfg.ap.ssid_len=strlen(device_id); cfg.ap.max_connection=2; cfg.ap.channel=6; cfg.ap.authmode=WIFI_AUTH_WPA2_PSK;
        ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP)); ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP,&cfg));
        snprintf(ip,sizeof(ip),"192.168.4.1"); wifi_up=true;
    } else {
        memcpy(cfg.sta.ssid,ssid,strlen(ssid)); memcpy(cfg.sta.password,pass,strlen(pass));
        cfg.sta.threshold.authmode=WIFI_AUTH_WPA2_PSK; cfg.sta.pmf_cfg.capable=true;
        ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA)); ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA,&cfg));
    }
    ESP_ERROR_CHECK(esp_wifi_start()); ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
}
static void serial_task(void *arg) {
    (void)arg; char line[1024]; size_t used=0; bool overflow=false;
    for(;;) {
        uint8_t ch; if(uart_read_bytes(UART_NUM_0,&ch,1,pdMS_TO_TICKS(100))!=1) continue;
        if(ch=='\n') {
            line[used]=0;
            if(overflow) print_json(error("serial_line_too_long"));
            else if(used) {
                cJSON *j=cJSON_ParseWithLengthOpts(line,used+1,NULL,true);
                cJSON *r=cJSON_IsObject(j)?rpc(j,true):error("invalid_json");
                const char *id=str(j,"request_id"); if(id&&strlen(id)<=64) cJSON_AddStringToObject(r,"request_id",id);
                cJSON_Delete(j); print_json(r);
            }
            used=0; overflow=false;
        } else if(ch!='\r') { if(used<sizeof(line)-1) line[used++]=(char)ch; else overflow=true; }
    }
}
static void sampling_task(void *arg) {
    (void)arg;
    for(;;) {
        xSemaphoreTake(lock,portMAX_DELAY); xt_tick(&state,esp_timer_get_time()/1000);
        if(state.enabled) xt_sample(&state,gpio_get_level(GPIO_NUM_4),esp_timer_get_time());
        xSemaphoreGive(lock); vTaskDelay(pdMS_TO_TICKS(1));
    }
}
void app_main(void) {
    setvbuf(stdout,NULL,_IONBF,0); ESP_ERROR_CHECK(nvs_flash_init());
    ESP_ERROR_CHECK(nvs_open("xiaotian2",NVS_READWRITE,&store));
    lock=xSemaphoreCreateMutex(); assert(lock); xt_init(&state);
    uint8_t mac[6]; ESP_ERROR_CHECK(esp_read_mac(mac,ESP_MAC_WIFI_STA));
    snprintf(device_id,sizeof(device_id),"xiaotian-%02x%02x%02x%02x%02x%02x",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    gpio_config_t input={.pin_bit_mask=1ULL<<4,.mode=GPIO_MODE_INPUT,.pull_up_en=GPIO_PULLUP_ENABLE,
        .pull_down_en=GPIO_PULLDOWN_DISABLE,.intr_type=GPIO_INTR_DISABLE}; ESP_ERROR_CHECK(gpio_config(&input));
    init_wifi(); // Start radio entropy before generating identity material.
    ESP_ERROR_CHECK(xt_pogo_start()); // UART-only SDK; Wi-Fi stays owned by this application.
    uint8_t boot[16]; esp_fill_random(boot,16); hex(boot,16,boot_id); init_identity();
    httpd_ssl_config_t conf=HTTPD_SSL_CONFIG_DEFAULT(); conf.port_secure=RPC_PORT;
    conf.servercert=(const uint8_t *)cert_pem; conf.servercert_len=strlen(cert_pem)+1;
    conf.prvtkey_pem=(const uint8_t *)key_pem; conf.prvtkey_len=strlen(key_pem)+1;
    conf.httpd.stack_size=12288; conf.httpd.max_open_sockets=3;
    conf.httpd.recv_wait_timeout=2; conf.httpd.send_wait_timeout=2; conf.tls_handshake_timeout_ms=3000;
    httpd_handle_t server=NULL; ESP_ERROR_CHECK(httpd_ssl_start(&server,&conf));
    const httpd_uri_t uri={.uri="/v1/rpc",.method=HTTP_POST,.handler=https_rpc}; ESP_ERROR_CHECK(httpd_register_uri_handler(server,&uri));
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0,2048,0,0,NULL,0));
    assert(xTaskCreate(serial_task,"usb_console",8192,NULL,3,NULL)==pdPASS);
    assert(xTaskCreate(sampling_task,"ir_sample",3072,NULL,4,NULL)==pdPASS);
    puts("{\"event\":\"NODE_READY\",\"version\":\"" VERSION "\",\"enabled\":false,\"port\":8443}");
    int tick=0;
    for(;;) {
        vTaskDelay(pdMS_TO_TICKS(1000)); xSemaphoreTake(lock,portMAX_DELAY);
        cJSON *j=status(); cJSON_AddStringToObject(j,"event","STATUS"); xSemaphoreGive(lock); print_json(j);
        if(++tick%3==0&&!setup_ap&&!wifi_up) esp_wifi_connect();
    }
}
