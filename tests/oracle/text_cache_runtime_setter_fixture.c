#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"

static int32_t error_count;
static int32_t measure_calls;

static const char text_chars[] = "Clay";
static const Clay_String text = {
    .isStaticallyAllocated = false,
    .length = (int32_t)(sizeof(text_chars) - 1),
    .chars = text_chars,
};

static void record_error(Clay_ErrorData error) {
    (void)error;
    error_count++;
}

static Clay_Dimensions measure_text(
    Clay_StringSlice value,
    Clay_TextElementConfig *config,
    void *user_data
) {
    (void)config;
    (void)user_data;
    measure_calls++;
    return (Clay_Dimensions){.width = (float)value.length, .height = 1};
}

static void run_frame(const char *phase) {
    Clay_BeginLayout();
    Clay__OpenTextElement(text, (Clay_TextElementConfig){
        .fontId = 7,
        .fontSize = 24,
        .letterSpacing = 3,
        .wrapMode = CLAY_TEXT_WRAP_NONE,
    });
    const Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);
    printf("phase %s limit %d measures %d commands %d errors %d\n",
           phase,
           (int)Clay_GetMaxMeasureTextCacheWordCount(),
           (int)measure_calls,
           (int)commands.length,
           (int)error_count);
}

int main(void) {
    Clay_SetMaxElementCount(64);
    Clay_SetMaxMeasureTextCacheWordCount(96);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){240, 80},
        (Clay_ErrorHandler){record_error, NULL});
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_SetCullingEnabled(false);

    run_frame("initial");
    Clay_SetMaxMeasureTextCacheWordCount(64);
    run_frame("lowered");
    Clay_SetMaxMeasureTextCacheWordCount(96);
    run_frame("restored");

    free(memory);
    return error_count == 0 && measure_calls == 4 ? 0 : 5;
}
