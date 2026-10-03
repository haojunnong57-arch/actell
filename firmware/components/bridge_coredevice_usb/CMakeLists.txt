idf_component_register(SRCS "bridge_coredevice_usb.c" INCLUDE_DIRS "include"
    REQUIRES bridge_core bridge_usb_host bridge_tls heap)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror -Wconversion -Wshadow)
