idf_component_register(SRCS "bridge_usb_host.c" INCLUDE_DIRS "include"
    REQUIRES bridge_core usb esp_timer freertos heap)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror -Wconversion -Wshadow)
