# SPDX-License-Identifier: GPL-3.0-or-later
idf_component_register(SRCS "bridge_tls.c" INCLUDE_DIRS "include"
                       REQUIRES bridge_core mbedtls)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror -Wconversion -Wshadow)
