/* SPDX-License-Identifier: GPL-3.0-or-later
 * USB descriptor wire format is from USB 2.0; Apple class tuple corroborated
 * by libimobiledevice/usbmuxd usb.h (3ded00c9985a5108cfc7591a309f9a23d57a8cba).
 * Independent bounded descriptor parser; no device serial strings are read.
 */
#include "bridge_usb_descriptors.h"
#include <string.h>
static uint16_t le16(const uint8_t *p) { return (uint16_t)((uint16_t)p[0] | (uint16_t)p[1] << 8); }
static bool valid_mps(uint16_t n) { return n==8 || n==16 || n==32 || n==64; }
bridge_status bridge_usb_find_mux_interface(const uint8_t *p, size_t size, bridge_usb_interface *out) {
    if (!p || !out) return BRIDGE_E_ARGUMENT;
    memset(out,0,sizeof *out);
    if(size < 9 || p[0] != 9 || p[1] != 2 || !p[5]) return BRIDGE_E_FORMAT;
    size_t total=le16(p+2);
    if(total > BRIDGE_USB_CONFIG_MAX) return BRIDGE_E_LIMIT;
    if(total!=size || total<9) return BRIDGE_E_FORMAT;
    bridge_usb_interface candidate={0}, found={0};
    bool active=false, have=false;
    unsigned endpoints=0;
    for(size_t pos=9; pos<total;) {
        if(total-pos<2) return BRIDGE_E_FORMAT;
        uint8_t n=p[pos],type=p[pos+1];
        if(n<2 || n>total-pos) return BRIDGE_E_FORMAT;
        if(type==4) {
            if(active) {
                if(endpoints!=2 || !candidate.endpoint_in || !candidate.endpoint_out) return BRIDGE_E_FORMAT;
                if(have) return BRIDGE_E_UNSUPPORTED;
                found=candidate; have=true;
            }
            if(n<9) return BRIDGE_E_FORMAT;
            active=p[pos+5]==255 && p[pos+6]==254 && p[pos+7]==2 && p[pos+3]==0;
            endpoints=0;
            candidate=(bridge_usb_interface){.configuration=p[5],.interface_number=p[pos+2],.alternate_setting=p[pos+3]};
            if(active && p[pos+4]!=2) return BRIDGE_E_UNSUPPORTED;
        } else if(type==5 && active) {
            if(n<7 || ++endpoints>2) return BRIDGE_E_FORMAT;
            uint8_t address=p[pos+2]; uint16_t mps=le16(p+pos+4);
            if((p[pos+3]&3u)!=2 || !(address&15u) || (address&0x70u) || !valid_mps(mps)) return BRIDGE_E_UNSUPPORTED;
            if(address&0x80u) {
                if(candidate.endpoint_in) return BRIDGE_E_FORMAT;
                candidate.endpoint_in=address; candidate.max_packet_in=mps;
            } else {
                if(candidate.endpoint_out) return BRIDGE_E_FORMAT;
                candidate.endpoint_out=address; candidate.max_packet_out=mps;
            }
        }
        pos+=n;
    }
    if(active) {
        if(endpoints!=2 || !candidate.endpoint_in || !candidate.endpoint_out) return BRIDGE_E_FORMAT;
        if(have) return BRIDGE_E_UNSUPPORTED;
        found=candidate; have=true;
    }
    if(!have) return BRIDGE_E_NOT_FOUND;
    *out=found; return BRIDGE_OK;
}
