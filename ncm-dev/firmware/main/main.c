/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "usb.h"
#include "nd_server.h"
#include "nd_http.h"
#include "esp_random.h"
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include <fcntl.h>
#include <string.h>
static void rotate(nd_http *http) { uint8_t nonce[16]; esp_fill_random(nonce,sizeof nonce);for(size_t i=0;i<sizeof nonce;i++)snprintf(http->token+2*i,3,"%02x",nonce[i]); }
static bool alive(void *context) { return nd_usb_online() && nd_usb_epoch()==*(uint32_t *)context; }
static void serve(void *unused) {
    (void)unused;
    int listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
    ESP_ERROR_CHECK(listener<0?ESP_FAIL:ESP_OK);
    struct sockaddr_in address={.sin_family=AF_INET,.sin_port=htons(28767)};
    inet_pton(AF_INET,"192.168.7.1",&address.sin_addr);
    ESP_ERROR_CHECK(bind(listener,(struct sockaddr *)&address,sizeof address)?ESP_FAIL:ESP_OK);
    ESP_ERROR_CHECK(listen(listener,1)?ESP_FAIL:ESP_OK);
    ESP_ERROR_CHECK(fcntl(listener,F_SETFL,O_NONBLOCK)<0?ESP_FAIL:ESP_OK);
    static nd_server server; static nd_http http; static char output[ND_HTTP_BODY_LIMIT]; rotate(&http);
    uint32_t epoch=nd_usb_epoch();
    nd_link link={.local4={192,168,7,1},.peer4={192,168,7,2},.interface_index=nd_network_index(),.alive=alive,.context=&epoch};
    ESP_LOGI("ncm_dev","ND1 diagnostic-only; no credentials, capture, input, HID or radio; idle until command");
    for (;;) {
        if (nd_usb_epoch()!=epoch) { epoch=nd_usb_epoch(); nd_server_reset(&server); rotate(&http); }
        if (nd_usb_online()) {
            struct sockaddr_in peer={0}; socklen_t length=sizeof peer;
            int fd=accept(listener,(struct sockaddr *)&peer,&length);
            if (fd>=0) {
                if (memcmp(&peer.sin_addr,link.peer4,4) || fcntl(fd,F_SETFL,O_NONBLOCK)<0) { close(fd); continue; }
                nd_socket socket={.fd=fd,.link=&link}; bridge_io io=nd_socket_io(&socket);
                char command[ND_COMMAND_LIMIT+1]; size_t n=0; uint64_t deadline=nd_now(NULL)+3000; bool complete=false;
                while (n<ND_COMMAND_LIMIT) {
                    uint8_t ch=0; if (bridge_read_exact(&io,&ch,1,deadline)!=BRIDGE_OK) break;
                    if (ch=='\n') { complete=true; break; }
                    if (ch=='\r') { if(bridge_read_exact(&io,&ch,1,deadline)==BRIDGE_OK && ch=='\n')complete=true; break; }
                    if (ch<32 || ch>126) break;
                    command[n++]=(char)ch;
                }
                command[n]=0;
                if(complete && (strstr(command," HTTP/")!=NULL))
                    (void)nd_http_serve(&http,&server,&link,&io,command,output,sizeof output,deadline);
                else if (complete && nd_server_command(&server,&link,command,output,sizeof output)==BRIDGE_OK)
                    (void)bridge_write_exact(&io,(const uint8_t *)output,strlen(output),nd_now(NULL)+1000);
                nd_socket_close(&socket);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}
void app_main(void) {
    ESP_ERROR_CHECK(nd_network_start());
    ESP_ERROR_CHECK(xTaskCreate(serve,"ncm_diagnostic",32768,NULL,4,NULL)==pdPASS?ESP_OK:ESP_ERR_NO_MEM);
}
