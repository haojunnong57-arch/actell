/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <inttypes.h>
#include <string.h>
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_psram.h"
#include "bridge_bplist.h"
#include "bridge_requests.h"
#include "bridge_usb_host.h"
#include "bridge_lockdown_probe.h"
#include "bridge_coredevice_usb.h"
#include "bridge_network.h"
#include "bridge_operations.h"
#include "bridge_zlib.h"

static const char *TAG = "iphone_bridge";
#if defined(CONFIG_BRIDGE_USB_HOST_ENABLE) && CONFIG_BRIDGE_USB_HOST_ENABLE
static bridge_status query_type_session(bridge_usb_host *host, void *unused) {
    (void)unused;
    bridge_usb_stream stream;
    bridge_status s=bridge_usb_stream_open(host,BRIDGE_LOCKDOWN_PORT,bridge_usb_host_now_ms()+5000,&stream);
    if(s!=BRIDGE_OK) return s;
    uint8_t *reply=heap_caps_malloc(4096,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
    if(!reply) return BRIDGE_E_IO;
    bridge_lockdown_probe_result result;
    s=bridge_lockdown_probe_query_type(&stream.io,reply,4096,bridge_usb_host_now_ms()+5000,&result);
    heap_caps_free(reply);
    if(s==BRIDGE_OK) ESP_LOGI(TAG,"USB mux QueryType reply verified; this does NOT prove pairing/TLS or screenshot support");
    bridge_status closed=bridge_usb_stream_close(&stream,bridge_usb_host_now_ms()+1000);
    return s!=BRIDGE_OK?s:closed;
}
static void run_usb_probe(void) {
    const bridge_usb_host_config config={
        .wiring_and_vbus_confirmed=CONFIG_BRIDGE_USB_WIRING_CONFIRMED,
        .enable_controller_requested=true,
        .configuration_value=CONFIG_BRIDGE_USB_CONFIGURATION_VALUE,
        .runtime_ms=CONFIG_BRIDGE_USB_PROBE_RUNTIME_MS,
        .session=query_type_session
    };
    bridge_usb_host_result result;
    bridge_status s=bridge_usb_host_run(&config,&result);
    ESP_LOGI(TAG,"USB probe status=%s driver=%s enumerated=%d claimed=%d mux=%d session=%d cleanup=%d RX=%" PRIu64 " TX=%" PRIu64,
        bridge_status_name(s),esp_err_to_name(result.driver_error),result.enumerated,result.interface_claimed,
        result.mux_ready,result.session_completed,result.cleanup_complete,result.rx_bytes,result.tx_bytes);
    if(!result.cleanup_complete) ESP_LOGE(TAG,"Controller cleanup incomplete; further runs rejected. No live DMA memory was freed.");
}
#endif
/* A self-contained synthetic bplist: root integer 42. Not an iPhone response. */
static const uint8_t sample[] = {
    'b','p','l','i','s','t','0','0', 0x10,0x2a, 0x08,
    0,0,0,0,0,0,1,1, 0,0,0,0,0,0,0,1,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,10
};
void app_main(void) {
    esp_chip_info_t chip; esp_chip_info(&chip);
    uint32_t flash_bytes = 0;
    esp_err_t err = esp_flash_get_size(NULL, &flash_bytes);
    ESP_LOGI(TAG, "EXPERIMENTAL TRANSPORT BUILD: actual pairing/TLS, screenshot and input remain unavailable");
    ESP_LOGI(TAG, "Chip cores=%u revision=%u; flash query=%s bytes=%" PRIu32,
             (unsigned)chip.cores, (unsigned)chip.revision, esp_err_to_name(err), flash_bytes);
    ESP_LOGI(TAG, "PSRAM initialized=%d bytes=%u; internal free=%u largest=%u",
             esp_psram_is_initialized(), (unsigned)esp_psram_get_size(),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    bridge_bplist p; uint64_t n = 0;
    bridge_status s = bridge_bplist_open(&p, sample, sizeof sample);
    if (s == BRIDGE_OK) s = bridge_bplist_uint(&p, p.root, &n);
    if (s != BRIDGE_OK || n != 42) {
        ESP_LOGE(TAG, "Synthetic plist self-test failed: %s", bridge_status_name(s));
        return;
    }
    ESP_LOGI(TAG, "Synthetic plist self-test passed");
    /* Link-check the real session/TLS/tunnel composition without activating a
     * controller or constructing an identity. The only expected result is a
     * preflight rejection; this is not a successful session/crypto self-test. */
    bridge_coredevice_usb_result absent_identity;
    if (bridge_coredevice_usb_run(NULL, NULL, &absent_identity) != BRIDGE_E_ARGUMENT) {
        ESP_LOGE(TAG, "CoreDevice missing-configuration rejection failed"); return;
    }
    ESP_LOGI(TAG, "CoreDevice missing-configuration preflight correctly rejected; no I/O or identity loaded");
    bridge_png_info no_image;
    bridge_home_result no_home;
    if (bridge_network_start(NULL,NULL,NULL,NULL,0,0)!=BRIDGE_E_ARGUMENT ||
        bridge_capture_screenshot(NULL,NULL,NULL,NULL,0,0,NULL,NULL,0,&no_image)!=BRIDGE_E_ARGUMENT ||
        bridge_press_home(NULL,NULL,NULL,NULL,0,0,&no_home)!=BRIDGE_E_ARGUMENT) {
        ESP_LOGE(TAG,"Network/operation missing-configuration rejection failed");return;
    }
    const size_t slab_size = 16384;
    uint8_t *slab = heap_caps_malloc(slab_size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!slab) { ESP_LOGE(TAG, "16 KiB PSRAM allocation failed"); return; }
    memset(slab, 0xa5, slab_size);
    for (size_t i = 0; i < slab_size; i++) {
        if (slab[i] != 0xa5) { ESP_LOGE(TAG, "PSRAM slab test failed"); heap_caps_free(slab); return; }
    }
    bridge_invocation invocation = {
        .device_identifier = "11111111-1111-4111-8111-111111111111",
        .invocation_identifier = "22222222-2222-4222-8222-222222222222",
        .message_id = 1
    };
    size_t encoded_size = 0;
    s = bridge_request_screenshot(&invocation, NULL, slab, slab_size, &encoded_size);
    if (s != BRIDGE_OK) {
        ESP_LOGE(TAG, "Offline CoreDevice request self-test failed: %s", bridge_status_name(s));
        heap_caps_free(slab); return;
    }
    ESP_LOGI(TAG, "Offline screenshot request serialized: %u bytes; NOT sent", (unsigned)encoded_size);
    const uint8_t call_uuid[16]={0x33,0x33,0x33,0x33,0x33,0x33,0x43,0x33,
        0x83,0x33,0x33,0x33,0x33,0x33,0x33,0x33};
    s=bridge_media_video_offer(1,call_uuid,bridge_zlib_compress,NULL,slab,slab_size,&encoded_size);
    if(s!=BRIDGE_OK) {
        ESP_LOGE(TAG,"Bounded synthetic zlib9 offer failed: %s",bridge_status_name(s));
        heap_caps_free(slab);return;
    }
    ESP_LOGI(TAG,"Offline media offer compressed: %u bytes; NOT sent",(unsigned)encoded_size);
    uint8_t touch[BRIDGE_TOUCH_REPORT_SIZE];
    s = bridge_hid_touch(touch, sizeof touch, BRIDGE_TOUCH_RELEASE, 0, 0, 0);
    if (s != BRIDGE_OK || touch[0] != 9 || touch[3] != 2) {
        ESP_LOGE(TAG, "Offline HID report self-test failed"); heap_caps_free(slab); return;
    }
    heap_caps_free(slab);
    ESP_LOGI(TAG, "PSRAM 16 KiB slab test passed; real screenshot/input chain remains unavailable");
#if defined(CONFIG_BRIDGE_USB_HOST_ENABLE) && CONFIG_BRIDGE_USB_HOST_ENABLE
    run_usb_probe();
#else
    ESP_LOGI(TAG,"USB Host activation disabled: board/VBUS and configuration must be verified first");
#endif
}
