set(mdns_priv_requires "")
if(CONFIG_MODULE_DATA_MDNS_ENABLED)
    list(APPEND mdns_priv_requires mdns)
endif()

idf_component_register(
    SRCS "module_data_service.c" "module_data_ble.c" "module_data_ble_gatt.c" "module_data_wifi.c" "module_data_package.c" "module_data_http_package.c" "module_data_mdns.c"
    INCLUDE_DIRS "include"
    REQUIRES json freertos
    # mdns 只在 CONFIG_MODULE_DATA_MDNS_ENABLED=y 时进入依赖；默认关闭，
    # 保证没有 espressif/mdns 组件的离线环境也能编译。
    PRIV_REQUIRES lwip mbedtls esp_wifi esp_netif esp_event esp_timer nvs_flash bt esp_http_server ${mdns_priv_requires}
)
