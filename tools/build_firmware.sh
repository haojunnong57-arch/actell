#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../firmware"
if ! command -v idf.py >/dev/null; then
  printf '%s\n' 'Source the official ESP-IDF v5.5.5 export.sh first.' >&2
  exit 1
fi
if [[ ! -f sdkconfig ]]; then
  idf.py set-target esp32s3
elif ! grep -q '^CONFIG_IDF_TARGET="esp32s3"$' sdkconfig; then
  printf '%s\n' 'Existing sdkconfig targets another chip; not overwriting it.' >&2
  exit 1
fi
idf.py build
idf.py size
