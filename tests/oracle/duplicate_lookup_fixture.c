#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct ErrorLog {
    Clay_ErrorType types[8];
    int32_t length;
} ErrorLog;

static void record_error(Clay_ErrorData error) {
    ErrorLog *log = (ErrorLog *)error.userData;
    if (log->length >= 8) oracle_fail_log_overflow("duplicate-lookup diagnostics");
    log->types[log->length++] = error.errorType;
}

int main(void) {
    ErrorLog errors = {0};
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){400, 160}, (Clay_ErrorHandler){record_error, &errors});

    Clay_ElementId duplicate_id = CLAY_ID("duplicate");
    Clay_BeginLayout();
    CLAY(duplicate_id, {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(20)},
        },
    }) {}
    CLAY(duplicate_id, {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(30), CLAY_SIZING_FIXED(20)},
        },
    }) {}
    (void)Clay_EndLayout(0.0f);

    Clay_ElementData data = Clay_GetElementData(duplicate_id);
    printf("lookup duplicate found %d %u %u %u %u\n",
           data.found ? 1 : 0,
           oracle_f32_bits(data.boundingBox.x),
           oracle_f32_bits(data.boundingBox.y),
           oracle_f32_bits(data.boundingBox.width),
           oracle_f32_bits(data.boundingBox.height));
    printf("errors %d", (int)errors.length);
    for (int32_t index = 0; index < errors.length; ++index) {
        printf(" %d", (int)errors.types[index]);
    }
    putchar('\n');

    free(memory);
    return 0;
}
