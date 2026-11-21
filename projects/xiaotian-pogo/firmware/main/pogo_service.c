// Contact identity only. No sensor control, user session, or Wi-Fi ownership.
#include "pogo_service.h"
#include "linkit.h"
#include "linkit_pins.h"
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_mac.h"
#include <stdio.h>
#include <string.h>

static portMUX_TYPE mux=portMUX_INITIALIZER_UNLOCKED;
static xt_pogo_status_t snapshot;
static char transport_config[256];

xt_pogo_status_t xt_pogo_snapshot(void) {
    portENTER_CRITICAL(&mux); xt_pogo_status_t out=snapshot; portEXIT_CRITICAL(&mux);
    return out;
}
static void send(uint8_t command,const char *payload) {
    const linkit_frame_t frame={.module_id=XT_POGO_MODULE_ID,.msg_type=LINKIT_MSG_STREAM,
        .flags=LINKIT_FLAG_NONE,.cmd_id=command,.seq=0,
        .payload=(const uint8_t *)payload,.payload_len=payload?(uint16_t)strlen(payload):0};
    (void)linkit_write_frame(&frame,0);
}
static void pump(void *arg) {
    (void)arg; bool was_wired=false; TickType_t last=0;
    for(;;) {
        (void)linkit_poll(0);
        uint32_t received=0; linkit_rx_frame_t frame;
        while(linkit_read_frame(&frame,0)==ESP_OK) ++received;
        bool wired=linkit_get_state()==LINKIT_STATE_WIRED;
        portENTER_CRITICAL(&mux); snapshot.ready=true; snapshot.wired=wired;
        snapshot.rx_frames+=received; portEXIT_CRITICAL(&mux);
        if(wired!=was_wired) {
            ESP_LOGW("XT_POGO","contact=%s module_id=0x51; monitoring unchanged",wired?"wired":"separated");
            last=0; was_wired=wired;
        }
        TickType_t now=xTaskGetTickCount();
        if(wired&&(!last||now-last>=pdMS_TO_TICKS(1000))) {
            send(0x03,transport_config); send(0x7e,NULL); last=now;
        }
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}
esp_err_t xt_pogo_start(void) {
    uint8_t mac[6];
    esp_err_t result=esp_read_mac(mac,ESP_MAC_WIFI_STA); if(result!=ESP_OK)return result;
    int length=snprintf(transport_config,sizeof(transport_config),
        "{\"schema\":\"module-transport-v1\",\"transport_mode\":\"fixed_hotspot_lan\","
        "\"package_transport\":\"data\",\"business_adapter\":\"xiaotian_https_v2\",\"https_port\":8443,"
        "\"module_instance\":\"xiaotian-%02x%02x%02x%02x%02x%02x\"}",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    if(length<=0||length>=(int)sizeof(transport_config))return ESP_ERR_INVALID_SIZE;
    // Release through an input, never drive DET high against an attached peer.
    gpio_config_t det={.pin_bit_mask=1ULL<<POGO_PIN_DET,.mode=GPIO_MODE_INPUT,
        .pull_up_en=GPIO_PULLUP_DISABLE,.pull_down_en=GPIO_PULLDOWN_DISABLE,.intr_type=GPIO_INTR_DISABLE};
    result=gpio_config(&det); if(result!=ESP_OK) return result;
    vTaskDelay(pdMS_TO_TICKS(1200)); // Existing bridge's removal debounce is about 1s.
    result=gpio_set_level(POGO_PIN_DET,0); if(result!=ESP_OK) return result;
    result=gpio_set_direction(POGO_PIN_DET,GPIO_MODE_OUTPUT); if(result!=ESP_OK) return result;
    static const linkit_ext_desc_t descriptor={.ext_version=1,.module_id=XT_POGO_MODULE_ID,
        .frame_proto_min=0x0201,.frame_proto_max=0x0201,
        .mtu_uart=LINKIT_FRAME_MAX_PAYLOAD,.mtu_espnow=0,.uart_high_baud=2000000,
        .pin_mux_caps=LINKIT_MUX_UART_DEFAULT,.feature_caps=LINKIT_FC_FRAME_V21|LINKIT_FC_STREAM};
    linkit_device_config_t config=LINKIT_DEVICE_CONFIG_DEFAULT();
    config.device_ext_desc=&descriptor;
    config.espnow.ownership=LINKIT_ESPNOW_OWNERSHIP_DISABLED;
    result=linkit_device_install(&config); if(result!=ESP_OK) return result;
    if(xTaskCreate(pump,"pogo_identity",8192,NULL,5,NULL)!=pdPASS) {
        (void)linkit_uninstall(); return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}
