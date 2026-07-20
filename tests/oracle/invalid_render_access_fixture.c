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
    if (log->length >= 8) oracle_fail_log_overflow("invalid-render diagnostics");
    log->types[log->length++] = error.errorType;
}

static void print_access(const char *label, Clay_RenderCommand *command) {
    printf("access %s present %d type %d id %u\n",
           label,
           command ? 1 : 0,
           command ? (int)command->commandType : 0,
           command ? command->id : 0);
}

int main(void) {
    ErrorLog error_log = {0};
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){100, 40}, (Clay_ErrorHandler){record_error, &error_log});
    Clay_BeginLayout();
    CLAY(CLAY_ID("box"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .backgroundColor = {255, 0, 0, 255},
    }) {}
    Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);

    Clay_RenderCommand *negative = Clay_RenderCommandArray_Get(&commands, -1);
    Clay_RenderCommand *past_end = Clay_RenderCommandArray_Get(&commands, commands.length);
    printf("commands %d\n", (int)commands.length);
    print_access("valid", Clay_RenderCommandArray_Get(&commands, 0));
    print_access("negative", negative);
    print_access("past-end", past_end);
    printf("invalid-default-shared %d\n", negative == past_end ? 1 : 0);
    printf("errors %d", (int)error_log.length);
    for (int32_t index = 0; index < error_log.length; ++index) printf(" %d", (int)error_log.types[index]);
    putchar('\n');

    free(memory);
    return 0;
}
