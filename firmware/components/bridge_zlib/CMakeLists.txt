# SPDX-License-Identifier: GPL-3.0-or-later
# Upstream source files are unmodified; see vendor/SOURCE_MANIFEST.json.
idf_component_register(
    SRCS "bridge_zlib.c" "vendor/zlib/adler32.c" "vendor/zlib/deflate.c"
         "vendor/zlib/trees.c" "vendor/zlib/zutil.c"
    INCLUDE_DIRS "include"
    PRIV_INCLUDE_DIRS "vendor/zlib"
    REQUIRES bridge_core
    PRIV_REQUIRES heap)
# Z_SOLO requires explicit allocators and removes file I/O/default allocators.
# NO_GZIP removes gzip/CRC dependencies; Z_PREFIX avoids system-zlib symbols.
target_compile_definitions(${COMPONENT_LIB} PRIVATE Z_SOLO Z_PREFIX NO_GZIP)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)
# Keep upstream warning policy unchanged; project wrapper receives extra checks.
set_source_files_properties(bridge_zlib.c PROPERTIES
    COMPILE_OPTIONS "-Wconversion;-Wshadow")
