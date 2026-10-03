#ifndef SIM_TASK_H
#define SIM_TASK_H
#include "FreeRTOS.h"
typedef void *TaskHandle_t;
void vTaskDelay(TickType_t n);
TaskHandle_t xTaskGetCurrentTaskHandle(void);
#endif
