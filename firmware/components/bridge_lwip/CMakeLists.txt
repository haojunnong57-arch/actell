# SPDX-License-Identifier: GPL-3.0-or-later
idf_component_register(SRCS "bridge_lwip.c" INCLUDE_DIRS "include"
                       REQUIRES bridge_core lwip esp_hw_support heap)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror -Wconversion -Wshadow)
