#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define PA_LINE_MAX 256
#define PA_HISTORY 32
#define PA_LEASE_MS 750

typedef enum { PA_PING, PA_STOP, PA_TAP, PA_DRAG } pa_kind;
typedef struct { uint32_t id; pa_kind kind; uint16_t x,y,tx,ty,duration; } pa_command;
typedef struct { bool valid, executed; pa_command command; } pa_receipt;
typedef struct { uint32_t highest; pa_receipt entries[PA_HISTORY]; size_t cursor; } pa_ledger;
// 1=new, 0=identical duplicate (receipt returned), -1=replay/conflict/invalid.
int pa_accept(pa_ledger *ledger, const pa_command *command, pa_receipt **receipt);
bool pa_parse(const char *body, pa_command *command);
void pa_complete(pa_ledger *ledger, uint32_t id);
