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
    if (log->length >= 8) oracle_fail_log_overflow("id-collision diagnostics");
    log->types[log->length++] = error.errorType;
}

static void print_element(const char *label, Clay_ElementId id) {
    const Clay_ElementData data = Clay_GetElementData(id);
    printf("element %s found %d box %08x %08x %08x %08x\n",
           label,
           data.found ? 1 : 0,
           oracle_f32_bits(data.boundingBox.x),
           oracle_f32_bits(data.boundingBox.y),
           oracle_f32_bits(data.boundingBox.width),
           oracle_f32_bits(data.boundingBox.height));
}

int main(void) {
    ErrorLog error_log = {0};
    Clay_SetMaxElementCount(8);
    Clay_SetMaxMeasureTextCacheWordCount(32);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){100, 40}, (Clay_ErrorHandler){record_error, &error_log});

    const Clay_ElementId alpha = CLAY_ID("alpha");
    const Clay_ElementId delta = CLAY_ID("delta");
    const uint32_t alpha_bucket = alpha.id % 8;
    const uint32_t delta_bucket = delta.id % 8;

    Clay_BeginLayout();
    CLAY(alpha, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(20)}},
    }) {}
    CLAY(delta, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(30), CLAY_SIZING_FIXED(20)}},
    }) {}
    (void)Clay_EndLayout(0.0f);

    printf("id alpha %u bucket %u\n", alpha.id, alpha_bucket);
    printf("id delta %u bucket %u\n", delta.id, delta_bucket);
    printf("distinct %d same-bucket %d\n", alpha.id != delta.id ? 1 : 0, alpha_bucket == delta_bucket ? 1 : 0);
    print_element("alpha", alpha);
    print_element("delta", delta);
    printf("errors %d", (int)error_log.length);
    for (int32_t index = 0; index < error_log.length; ++index) printf(" %d", (int)error_log.types[index]);
    putchar('\n');

    free(memory);
    return 0;
}
