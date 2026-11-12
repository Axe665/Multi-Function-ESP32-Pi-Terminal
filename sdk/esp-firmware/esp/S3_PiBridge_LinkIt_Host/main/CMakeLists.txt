idf_component_register(
    SRCS "main.c" "rc522.c" "rfid_service.c" "rfid_tracker.c" "max17043.c" "pbr_secure.c"
    INCLUDE_DIRS "."
    REQUIRES linkit_sdk board_pins nvs_flash driver json esp_timer esp_hw_support mbedtls
)
