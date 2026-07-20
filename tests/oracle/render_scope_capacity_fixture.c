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
    if (log->length >= 8) oracle_fail_log_overflow("render-scope-capacity diagnostics");
    log->types[log->length++] = error.errorType;
}

int main(void) {
    ErrorLog errors = {0};
    Clay_SetMaxElementCount(4);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){100, 100}, (Clay_ErrorHandler){record_error, &errors});
    Clay_BeginLayout();
    CLAY(CLAY_ID("render-scope-capacity-a"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .clip = {.horizontal = true, .vertical = true},
    }) {}
    CLAY(CLAY_ID("render-scope-capacity-b"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .clip = {.horizontal = true, .vertical = true},
    }) {}
    Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);

    int32_t scissor_depth = 0;
    int32_t balanced = 1;
    puts("end-error 0 layout-open unknown");
    printf("commands %d\n", (int)commands.length);
    for (int32_t index = 0; index < commands.length; ++index) {
        Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        printf("command %d type %d\n", (int)index, (int)command->commandType);
        if (command->commandType == CLAY_RENDER_COMMAND_TYPE_SCISSOR_START) scissor_depth += 1;
        if (command->commandType == CLAY_RENDER_COMMAND_TYPE_SCISSOR_END) {
            if (scissor_depth == 0) balanced = 0;
            else scissor_depth -= 1;
        }
    }
    if (scissor_depth != 0) balanced = 0;
    printf("balanced %d\n", (int)balanced);
    printf("errors %d", (int)errors.length);
    for (int32_t index = 0; index < errors.length; ++index) printf(" %d", (int)errors.types[index]);
    putchar('\n');

    free(memory);
    return 0;
}
