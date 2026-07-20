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
    if (log->length >= 8) oracle_fail_log_overflow("text-capacity diagnostics");
    log->types[log->length++] = error.errorType;
}

static Clay_Dimensions measure_text(Clay_StringSlice text, Clay_TextElementConfig *config, void *user_data) {
    (void)user_data;
    return (Clay_Dimensions){
        .width = (float)text.length * (float)config->fontSize,
        .height = (float)config->fontSize,
    };
}

int main(void) {
    ErrorLog error_log = {0};
    Clay_SetMaxElementCount(8);
    Clay_SetMaxMeasureTextCacheWordCount(32);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){200, 40}, (Clay_ErrorHandler){record_error, &error_log});
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_BeginLayout();
    CLAY_TEXT(
        CLAY_STRING("a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a"),
        CLAY_TEXT_CONFIG({.fontSize = 1}));
    const int32_t errors_after_limit = error_log.length;
    CLAY_TEXT(
        CLAY_STRING("b b b b b b b b b b b b b b b b b b b b b b b b b b b b b b b b b"),
        CLAY_TEXT_CONFIG({.fontSize = 1}));
    const int32_t errors_after_over_limit = error_log.length;
    Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);

    puts("limits element 8 text 32");
    puts("text-api-returned-error 0 0");
    printf("callback-errors-after-limit %d\n", (int)errors_after_limit);
    printf("callback-errors-after-over-limit %d\n", (int)errors_after_over_limit);
    printf("errors %d", (int)error_log.length);
    for (int32_t index = 0; index < error_log.length; ++index) printf(" %d", (int)error_log.types[index]);
    putchar('\n');
    printf("commands %d\n", (int)commands.length);
    for (int32_t index = 0; index < commands.length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        const int32_t text_length = command->commandType == CLAY_RENDER_COMMAND_TYPE_TEXT
                                        ? command->renderData.text.stringContents.length
                                        : 0;
        printf("command %d type %d id %u text %d\n",
               (int)index,
               (int)command->commandType,
               command->id,
               (int)text_length);
    }

    free(memory);
    return 0;
}
