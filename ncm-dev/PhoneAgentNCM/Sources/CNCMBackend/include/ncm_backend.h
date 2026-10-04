/* SPDX-License-Identifier: GPL-3.0-only */
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define NCM_BACKEND_ABI 1
#define NCM_ALLOW_SCREEN 1u
#define NCM_ALLOW_MEDIA 2u
#define NCM_ALLOW_INPUT 4u
#define NCM_ALLOW_EXISTING_VERIFY 8u
/* All pointers are borrowed only for start(); caller owns/clears its secrets.
 * No disk/keychain lookup, identity generation, pairing or logging occurs. */
typedef struct { const uint8_t *data; size_t size; } ncm_bytes;
typedef struct {
    ncm_bytes seed, controller_id, peer_id, peer_public_key, alt_irk, peer_udid, peer_model;
} ncm_identity;
typedef struct { uint32_t abi,interface_index,generation,endpoint_index,permissions; } ncm_config;
enum ncm_failure_stage { NCM_STAGE_IDENTITY=1, NCM_STAGE_NCM_CONNECT=2, NCM_STAGE_PAIR_VERIFY=3, NCM_STAGE_TUNNEL_LISTENER=4, NCM_STAGE_TLS_TUNNEL=5, NCM_STAGE_RSD=6, NCM_STAGE_DEVELOPER_MODE=7, NCM_STAGE_DEVELOPER_IMAGE=8, NCM_STAGE_SCREENSHOT=9, NCM_STAGE_MEDIA=10, NCM_STAGE_INPUT=11, NCM_STAGE_CLOSED=12 };
enum ncm_failure_cause { NCM_CAUSE_PROTOCOL=1, NCM_CAUSE_TIMEOUT=2, NCM_CAUSE_INVALID=3, NCM_CAUSE_MISSING_SERVICE=4, NCM_CAUSE_UNPREPARED=5, NCM_CAUSE_MEDIA_INACTIVE=6, NCM_CAUSE_DELIVERY_UNCERTAIN=7 };
typedef struct { uint64_t request_id; uint32_t kind,stage,cause,reserved; size_t size; } ncm_event;
/* Return codes: 0 success/queued, 1 invalid, 2 busy, 3 closed, 4 empty,
 * 5 buffer too small (event retained), 6 not ready. Errors contain no payloads.
 * Events: 1 ready (JSON service names), 2 operation written/completed,
 * 3 stage/cause failure, 4 PNG (memory only). Input event 2 never proves visible effect.
 * At most 2 process sessions, 1 queued request and 1 pending event per session.
 * Tokens are monotonically allocated handles, never C pointers. */
uint32_t ncm_backend_abi(void);
int32_t ncm_backend_start(const ncm_config *,const ncm_identity *,uint64_t *handle);
/* Actions: 1 read-only developer/DDI check, 2 capture PNG, 3 start media drain,
 * 4 tap normalized x/y. Every accepted request id must increase; no replay.
 * Media may contain device audio as well as screen video. Caller obtains consent. */
int32_t ncm_backend_submit(uint64_t handle,uint64_t request_id,uint32_t action,uint16_t x,uint16_t y);
int32_t ncm_backend_poll(uint64_t handle,ncm_event *,uint8_t *buffer,size_t capacity);
/* Idempotent. Immediately revokes handle and requests worker cancellation. Does
 * not block UI waiting for join or assert remote media/touch release succeeded. */
void ncm_backend_close(uint64_t handle);
#ifdef NCM_OFFLINE_FIXTURES
/* Exists only in the separately built test archive; always 127.0.0.1. Public
 * deterministic fixture identity, no persistent keys or real-device fallback. */
int32_t ncm_test_start_loopback(uint16_t relay_port,uint64_t *handle);
#endif
#ifdef __cplusplus
}
#endif
