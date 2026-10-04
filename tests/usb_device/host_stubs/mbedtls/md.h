#pragma once
#include <CommonCrypto/CommonHMAC.h>
#define MBEDTLS_MD_SHA256 1
static inline const void *mbedtls_md_info_from_type(int type) { (void)type; return (const void*)1; }
static inline int mbedtls_md_hmac(const void *info,const unsigned char *key,size_t keylen,const unsigned char *input,size_t length,unsigned char *out) {
    (void)info; CCHmac(kCCHmacAlgSHA256,key,keylen,input,length,out); return 0;
}
