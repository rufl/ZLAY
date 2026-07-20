#include <stdint.h>
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

static ErrorLog errors;
static int32_t measure_calls;
static float measure_advance = 1.0f;
static float measure_height = 1.0f;

static const char text_a_chars[] =
    "a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a";
static const char text_b_chars[] =
    "b b b b b b b b b b b b b b b b b b b b b b b b b b b b b b";

static const Clay_String text_a = {
    .isStaticallyAllocated = false,
    .length = (int32_t)(sizeof(text_a_chars) - 1),
    .chars = text_a_chars,
};
static const Clay_String text_b = {
    .isStaticallyAllocated = false,
    .length = (int32_t)(sizeof(text_b_chars) - 1),
    .chars = text_b_chars,
};

static const Clay_String reset_text = CLAY_STRING("word");

static void record_error(Clay_ErrorData error) {
    if (errors.length >= (int32_t)(sizeof(errors.types) / sizeof(errors.types[0]))) {
        oracle_fail_log_overflow("text-cache errors");
    }
    errors.types[errors.length++] = error.errorType;
}

static Clay_Dimensions measure_text(
    Clay_StringSlice text,
    Clay_TextElementConfig *config,
    void *user_data
) {
    (void)config;
    (void)user_data;
    measure_calls++;
    return (Clay_Dimensions){
        .width = (float)text.length * measure_advance,
        .height = measure_height,
    };
}

static void print_frame(
    int32_t frame,
    int32_t error_start,
    Clay_RenderCommandArray commands
) {
    printf("frame %d measures %d errors %d commands %d",
           (int)frame,
           (int)measure_calls,
           (int)(errors.length - error_start),
           (int)commands.length);
    for (int32_t index = error_start; index < errors.length; ++index) {
        printf(" error-type %d", (int)errors.types[index]);
    }
    putchar('\n');

    for (int32_t index = 0; index < commands.length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        if (command->commandType != CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
        printf("text %d index %d id %u len %d box %u %u %u %u\n",
               (int)frame,
               (int)index,
               command->id,
               (int)command->renderData.text.stringContents.length,
               oracle_f32_bits(command->boundingBox.x),
               oracle_f32_bits(command->boundingBox.y),
               oracle_f32_bits(command->boundingBox.width),
               oracle_f32_bits(command->boundingBox.height));
    }
}

static void run_frame(int32_t frame, const Clay_String *text) {
    measure_calls = 0;
    const int32_t error_start = errors.length;
    Clay_BeginLayout();
    if (text) {
        CLAY(CLAY_ID("cache-lifecycle-row"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(200), CLAY_SIZING_FIXED(10)},
            },
        }) {
            Clay__OpenTextElement(*text, (Clay_TextElementConfig){
                .fontSize = 1,
                .wrapMode = CLAY_TEXT_WRAP_NONE,
            });
        }
    }
    const Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);
    print_frame(frame, error_start, commands);
}

static void run_reset_between_declaration_and_layout(int32_t frame) {
    measure_calls = 0;
    measure_advance = 5.0f;
    measure_height = 10.0f;
    const int32_t error_start = errors.length;
    Clay_BeginLayout();
    CLAY(CLAY_ID("cache-lifecycle-reset-row"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(200), CLAY_SIZING_FIXED(10)},
        },
    }) {
        Clay__OpenTextElement(reset_text, (Clay_TextElementConfig){
            .fontSize = 1,
            .wrapMode = CLAY_TEXT_WRAP_WORDS,
        });
        Clay_ResetMeasureTextCache();
        measure_advance = 25.0f;
        measure_height = 30.0f;
    }
    const Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);
    print_frame(frame, error_start, commands);
}

int main(void) {
    Clay_SetMaxElementCount(64);
    Clay_SetMaxMeasureTextCacheWordCount(32);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){240, 80},
        (Clay_ErrorHandler){record_error, NULL});
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_SetCullingEnabled(false);

    puts("cache buckets 1 words 32 text-words 30");
    run_frame(1, &text_a);
    run_frame(2, NULL);
    run_frame(3, NULL);
    run_frame(4, &text_a);
    run_frame(5, NULL);
    run_frame(6, NULL);
    run_frame(7, &text_b);
    run_frame(8, &text_b);
    run_frame(9, NULL);
    run_frame(10, NULL);
    run_frame(11, &text_a);
    run_reset_between_declaration_and_layout(12);

    printf("errors-total %d\n", (int)errors.length);
    free(memory);
    return errors.length == 0 ? 0 : 5;
}
