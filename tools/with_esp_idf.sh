#!/usr/bin/env bash
# Use the project-local ESP-IDF installation without changing shell startup files.
set -eo pipefail

bridge_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export IDF_PATH="$bridge_root/.build/toolchains/esp-idf-v5.5.5"
export IDF_TOOLS_PATH="$bridge_root/.build/toolchains/espressif"
export IDF_PYTHON_ENV_PATH="$IDF_TOOLS_PATH/python_env/idf5.5_py3.12_env"

if [[ ! -f "$IDF_PATH/export.sh" || ! -x "$IDF_PYTHON_ENV_PATH/bin/python" ]]; then
  echo 'Project-local ESP-IDF v5.5.5 / Python 3.12 environment is not installed.' >&2
  exit 1
fi

export PATH="$IDF_PYTHON_ENV_PATH/bin:$PATH"
source "$IDF_PATH/export.sh"
if [[ $# -eq 0 ]]; then
  set -- idf.py --version
fi
exec "$@"
