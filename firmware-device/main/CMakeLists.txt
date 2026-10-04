idf_component_register(SRCS "main.c" "usb_network.c" "usb_hid.c" "protocol.c" "hid_motion.c"
    INCLUDE_DIRS "." PRIV_REQUIRES esp_netif esp_event esp_timer)
