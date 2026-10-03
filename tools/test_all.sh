#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./tools/test_host.sh
./tools/test_hid.sh
XPC_PYTHON="${PYTHON:-python3}" ./tools/test_xpc.sh
./tools/test_media_offer.sh
SANITIZE=1 ./tools/test_requests.sh
./tools/test_usb_descriptors.sh
./tools/test_usbmux.sh
./tools/test_lockdown_probe.sh

./tools/test_usb_host_sim.sh
./tools/test_lockdown_session.sh
./tools/test_cdtunnel.sh
./tools/test_coredevice_usb.sh
./tools/test_tls.sh
XPC_PYTHON="${PYTHON:-python3}" ./tools/test_remotexpc.sh
XPC_PYTHON="${PYTHON:-python3}" ./tools/test_rsd.sh
./tools/test_operations.sh
./tools/test_zlib.sh
./tools/test_network.sh
./tools/test_lwip.sh
