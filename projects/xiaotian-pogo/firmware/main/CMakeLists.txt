idf_component_register(SRCS "node_main.c" "node_state.c" "pogo_service.c" INCLUDE_DIRS "."
    REQUIRES esp_driver_gpio esp_driver_uart esp_timer esp_wifi esp_event esp_netif
             nvs_flash esp_https_server mbedtls json bootloader_support linkit_sdk)
