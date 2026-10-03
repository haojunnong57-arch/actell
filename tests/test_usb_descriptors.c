/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_usb_descriptors.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static const uint8_t descriptor[]={9,2,32,0,1,4,0,0x80,50, 9,4,2,0,2,255,254,2,0, 7,5,0x81,2,64,0,0, 7,5,2,2,64,0,0};
static uint32_t rng=0x5acfe02;
static uint32_t next(void) { rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; }
int main(void) {
    bridge_usb_interface out;
    assert(bridge_usb_find_mux_interface(descriptor,sizeof descriptor,&out)==BRIDGE_OK);
    assert(out.configuration==4 && out.interface_number==2 && out.endpoint_in==0x81 && out.endpoint_out==2 && out.max_packet_in==64);
    for(size_t n=0;n<sizeof descriptor;n++) assert(bridge_usb_find_mux_interface(descriptor,n,&out)!=BRIDGE_OK);
    uint8_t b[64]; memcpy(b,descriptor,32);
    b[9]=0; assert(bridge_usb_find_mux_interface(b,32,&out)==BRIDGE_E_FORMAT);
    memcpy(b,descriptor,32); b[12]=1; assert(bridge_usb_find_mux_interface(b,32,&out)==BRIDGE_E_NOT_FOUND);
    memcpy(b,descriptor,32); b[14]=254; assert(bridge_usb_find_mux_interface(b,32,&out)==BRIDGE_E_NOT_FOUND);
    memcpy(b,descriptor,32); b[16]=255; assert(bridge_usb_find_mux_interface(b,32,&out)==BRIDGE_E_NOT_FOUND);
    memcpy(b,descriptor,32); b[22]=0; b[23]=2; assert(bridge_usb_find_mux_interface(b,32,&out)==BRIDGE_E_UNSUPPORTED);
    memcpy(b,descriptor,32); b[27]=0x82; assert(bridge_usb_find_mux_interface(b,32,&out)==BRIDGE_E_FORMAT);
    memcpy(b,descriptor,32); b[21]=3; assert(bridge_usb_find_mux_interface(b,32,&out)==BRIDGE_E_UNSUPPORTED);
    memcpy(b,descriptor,32); memcpy(b+32,descriptor+9,23); b[2]=55;
    assert(bridge_usb_find_mux_interface(b,55,&out)==BRIDGE_E_UNSUPPORTED);
    for(unsigned i=0;i<20000;i++) {
        memcpy(b,descriptor,32);
        for(unsigned j=0,n=next()%8+1;j<n;j++) b[next()%32]=(uint8_t)next();
        (void)bridge_usb_find_mux_interface(b,32,&out);
    }
    puts("PASS: USB mux Full Speed descriptor selection, truncation/ambiguity checks, 20000 mutations");
}
