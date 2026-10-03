/* Minimal synthetic peer for the subset of IDF 5.5.5 APIs used by the adapter.
 * API shape is checked by real firmware compilation separately, not this file. */
#ifndef SIM_USB_HOST_H
#define SIM_USB_HOST_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
typedef void *usb_host_client_handle_t;
typedef void *usb_device_handle_t;
typedef struct { uint16_t idVendor; uint8_t bNumConfigurations; } usb_device_desc_t;
typedef struct __attribute__((packed)) { uint8_t bLength,bDescriptorType; uint16_t wTotalLength; uint8_t bNumInterfaces,bConfigurationValue,iConfiguration,bmAttributes,bMaxPower; } usb_config_desc_t;
enum { USB_SPEED_LOW,USB_SPEED_FULL,USB_SPEED_HIGH };
typedef struct { int speed; uint8_t bConfigurationValue; } usb_device_info_t;
typedef enum { USB_TRANSFER_STATUS_COMPLETED,USB_TRANSFER_STATUS_ERROR,USB_TRANSFER_STATUS_TIMED_OUT,USB_TRANSFER_STATUS_CANCELED,USB_TRANSFER_STATUS_STALL,USB_TRANSFER_STATUS_NO_DEVICE } usb_transfer_status_t;
typedef struct usb_transfer usb_transfer_t;
struct usb_transfer { uint8_t *data_buffer; size_t data_buffer_size; int num_bytes,actual_num_bytes; usb_device_handle_t device_handle; uint8_t bEndpointAddress; usb_transfer_status_t status; uint32_t flags; void (*callback)(usb_transfer_t *); void *context; };
#define USB_TRANSFER_FLAG_ZERO_PACK 1u
#define USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS 1u
#define USB_HOST_LIB_EVENT_FLAGS_ALL_FREE 2u
typedef enum { USB_HOST_CLIENT_EVENT_NEW_DEV,USB_HOST_CLIENT_EVENT_DEV_GONE } usb_host_client_event_t;
typedef struct { usb_host_client_event_t event; union { struct {uint8_t address;} new_dev; struct {usb_device_handle_t dev_hdl;} dev_gone; }; } usb_host_client_event_msg_t;
typedef struct { bool skip_phy_setup,root_port_unpowered; int intr_flags; bool (*enum_filter_cb)(const usb_device_desc_t *,uint8_t *); } usb_host_config_t;
typedef struct { bool is_synchronous; int max_num_event_msg; struct {void (*client_event_callback)(const usb_host_client_event_msg_t *,void *);void *callback_arg;} async; } usb_host_client_config_t;
esp_err_t usb_host_install(const usb_host_config_t *);
esp_err_t usb_host_uninstall(void);
esp_err_t usb_host_lib_handle_events(TickType_t,uint32_t *);
esp_err_t usb_host_lib_set_root_port_power(bool);
esp_err_t usb_host_client_register(const usb_host_client_config_t *,usb_host_client_handle_t *);
esp_err_t usb_host_client_deregister(usb_host_client_handle_t);
esp_err_t usb_host_client_handle_events(usb_host_client_handle_t,TickType_t);
esp_err_t usb_host_device_open(usb_host_client_handle_t,uint8_t,usb_device_handle_t *);
esp_err_t usb_host_device_close(usb_host_client_handle_t,usb_device_handle_t);
esp_err_t usb_host_device_info(usb_device_handle_t,usb_device_info_t *);
esp_err_t usb_host_get_device_descriptor(usb_device_handle_t,const usb_device_desc_t **);
esp_err_t usb_host_get_active_config_descriptor(usb_device_handle_t,const usb_config_desc_t **);
esp_err_t usb_host_interface_claim(usb_host_client_handle_t,usb_device_handle_t,uint8_t,uint8_t);
esp_err_t usb_host_interface_release(usb_host_client_handle_t,usb_device_handle_t,uint8_t);
esp_err_t usb_host_endpoint_halt(usb_device_handle_t,uint8_t);
esp_err_t usb_host_endpoint_flush(usb_device_handle_t,uint8_t);
esp_err_t usb_host_transfer_alloc(size_t,int,usb_transfer_t **);
esp_err_t usb_host_transfer_free(usb_transfer_t *);
esp_err_t usb_host_transfer_submit(usb_transfer_t *);
esp_err_t usb_host_device_free_all(void);
#endif
