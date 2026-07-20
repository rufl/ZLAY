#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct ErrorLog {
    Clay_ErrorType types[32];
    int32_t length;
} ErrorLog;

static ErrorLog errors;

static void record_error(Clay_ErrorData error) {
    if (errors.length >= (int32_t)(sizeof(errors.types) / sizeof(errors.types[0]))) {
        oracle_fail_log_overflow("no-open API errors");
    }
    errors.types[errors.length++] = error.errorType;
}

static void probe_no_open(const char *label) {
    const int32_t error_start = errors.length;
    const uint32_t open_id = Clay_GetOpenElementId();
    const bool hovered = Clay_Hovered();
    Clay_OnHover(NULL, NULL);
    const Clay_Vector2 offset = Clay_GetScrollOffset();
    printf("probe %s open %u open-error 0 hovered %d hover-error 0 on-hover-error 0 offset %u %u errors %d",
           label,
           open_id,
           hovered ? 1 : 0,
           oracle_f32_bits(offset.x),
           oracle_f32_bits(offset.y),
           (int)(errors.length - error_start));
    for (int32_t index = error_start; index < errors.length; ++index) {
        printf(" %d", (int)errors.types[index]);
    }
    putchar('\n');
}

static Clay_ElementDeclaration recovery_box(void) {
    return (Clay_ElementDeclaration){
        .layout = {.sizing = {CLAY_SIZING_FIXED(23), CLAY_SIZING_FIXED(17)}},
        .backgroundColor = {31, 127, 223, 255},
    };
}

static void print_recovery(Clay_ElementId id, Clay_RenderCommandArray commands) {
    const Clay_ElementData data = Clay_GetElementData(id);
    printf("recovery element found %d box %u %u %u %u commands %d\n",
           data.found ? 1 : 0,
           oracle_f32_bits(data.boundingBox.x),
           oracle_f32_bits(data.boundingBox.y),
           oracle_f32_bits(data.boundingBox.width),
           oracle_f32_bits(data.boundingBox.height),
           (int)commands.length);
    for (int32_t index = 0; index < commands.length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        printf("recovery command %d type %d id %u box %u %u %u %u\n",
               (int)index,
               (int)command->commandType,
               command->id,
               oracle_f32_bits(command->boundingBox.x),
               oracle_f32_bits(command->boundingBox.y),
               oracle_f32_bits(command->boundingBox.width),
               oracle_f32_bits(command->boundingBox.height));
    }
}

int main(void) {
    Clay_SetMaxElementCount(32);
    Clay_SetMaxMeasureTextCacheWordCount(64);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){100, 80},
        (Clay_ErrorHandler){record_error, NULL});
    Clay_SetCullingEnabled(false);

    probe_no_open("before-first-begin");

    Clay_BeginLayout();
    CLAY(CLAY_ID("no-open-seed"), recovery_box()) {}
    (void)Clay_EndLayout(0.0f);
    probe_no_open("after-end");

    const int32_t recovery_error_start = errors.length;
    const Clay_ElementId recovery_id = CLAY_ID("no-open-recovery");
    Clay_BeginLayout();
    CLAY(recovery_id, recovery_box()) {}
    const Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);
    print_recovery(recovery_id, commands);
    printf("recovery errors %d\n", (int)(errors.length - recovery_error_start));
    printf("errors-total %d\n", (int)errors.length);

    free(memory);
    return 0;
}
