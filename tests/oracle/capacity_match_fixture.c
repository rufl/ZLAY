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

static unsigned char image_payload;
static unsigned char custom_payload;

static void record_error(Clay_ErrorData error) {
    ErrorLog *log = (ErrorLog *)error.userData;
    if (log->length >= 8) oracle_fail_log_overflow("capacity-match diagnostics");
    log->types[log->length++] = error.errorType;
}

static Clay_Dimensions measure_text(Clay_StringSlice text, Clay_TextElementConfig *config, void *user_data) {
    (void)user_data;
    return (Clay_Dimensions){
        .width = (float)text.length * (float)config->fontSize,
        .height = (float)config->fontSize,
    };
}

static void print_errors(const ErrorLog *log) {
    printf("errors %d", (int)log->length);
    for (int32_t index = 0; index < log->length; ++index) {
        printf(" %d", (int)log->types[index]);
    }
    putchar('\n');
}

int main(void) {
    ErrorLog error_log = {0};

    /*
     * Pinned Clay stores render commands in the max-element arena and leaves
     * one sentinel slot. A max element count of eight therefore gives the
     * same seven-command public limit configured explicitly by the Zig pair.
     */
    Clay_SetMaxElementCount(8);
    Clay_SetMaxMeasureTextCacheWordCount(32);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){200, 100}, (Clay_ErrorHandler){record_error, &error_log});
    Clay_SetMeasureTextFunction(measure_text, NULL);

    Clay_BeginLayout();
    CLAY_TEXT(
        CLAY_STRING("a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a"),
        CLAY_TEXT_CONFIG({.fontSize = 1, .textColor = {255, 255, 255, 255}}));
    CLAY(CLAY_ID("rich"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(20)}},
        .backgroundColor = {10, 20, 30, 255},
        .overlayColor = {40, 50, 60, 128},
        .image = {.imageData = &image_payload},
        .custom = {.customData = &custom_payload},
        .border = {.color = {70, 80, 90, 255}, .width = {1, 1, 1, 1, 0}},
    }) {}
    CLAY(CLAY_ID("dropped"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(20)}},
        .backgroundColor = {100, 110, 120, 255},
    }) {}
    Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);

    puts("limits element 8 text 32 render-effective 7");
    print_errors(&error_log);
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
