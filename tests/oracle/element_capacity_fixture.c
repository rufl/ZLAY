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
    if (log->length >= 8) oracle_fail_log_overflow("element-capacity diagnostics");
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
    Clay_SetMaxElementCount(4);
    Clay_SetMaxMeasureTextCacheWordCount(32);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){100, 40}, (Clay_ErrorHandler){record_error, &error_log});
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_BeginLayout();
    CLAY_TEXT(CLAY_STRING("a"), CLAY_TEXT_CONFIG({.fontSize = 1}));
    CLAY_TEXT(CLAY_STRING("b"), CLAY_TEXT_CONFIG({.fontSize = 1}));
    CLAY_TEXT(CLAY_STRING("c"), CLAY_TEXT_CONFIG({.fontSize = 1}));
    CLAY_TEXT(CLAY_STRING("d"), CLAY_TEXT_CONFIG({.fontSize = 1}));
    Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);

    puts("limits element 4 text 32");
    puts("text-attempts 4");
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
