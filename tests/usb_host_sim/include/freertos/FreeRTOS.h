#ifndef SIM_FREERTOS_H
#define SIM_FREERTOS_H
#include <stdint.h>
typedef uint32_t TickType_t;
typedef unsigned portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0u
#define portENTER_CRITICAL(p) ((void)(p))
#define portEXIT_CRITICAL(p) ((void)(p))
#endif
