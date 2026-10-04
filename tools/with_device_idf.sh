#!/usr/bin/env bash
set -eo pipefail
device_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Reuse an installed SDK; never build inside the Host worktree.
export IDF_PATH="${IDF_PATH:-$device_root/../with-esp/.build/toolchains/esp-idf-v5.5.5}"
export IDF_TOOLS_PATH="${IDF_TOOLS_PATH:-$device_root/../with-esp/.build/toolchains/espressif}"
export IDF_PYTHON_ENV_PATH="$IDF_TOOLS_PATH/python_env/idf5.5_py3.12_env"
export IDF_COMPONENT_CACHE_PATH="$device_root/.build/component-cache"
export PATH="$IDF_PYTHON_ENV_PATH/bin:$PATH"
source "$IDF_PATH/export.sh"
exec "$@"
