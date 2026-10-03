idf_component_register(SRCS "bridge_network.c" INCLUDE_DIRS "include"
    REQUIRES bridge_core bridge_lwip lwip)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror -Wconversion -Wshadow)
