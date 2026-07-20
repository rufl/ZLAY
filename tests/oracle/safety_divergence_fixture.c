#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct ErrorLog {
    Clay_ErrorType types[32];
    int32_t length;
} ErrorLog;

static void record_error(Clay_ErrorData error) {
    ErrorLog *log = (ErrorLog *)error.userData;
    if (log->length >= 32) oracle_fail_log_overflow("safety-divergence diagnostics");
    log->types[log->length++] = error.errorType;
}

static Clay_Dimensions measure_text(
    Clay_StringSlice text,
    Clay_TextElementConfig *config,
    void *user_data
) {
    (void)user_data;
    const float font_size = config->fontSize == 0 ? 1.0f : (float)config->fontSize;
    return (Clay_Dimensions){
        .width = (float)text.length * font_size,
        .height = font_size,
    };
}

static uint32_t f32_bits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static Clay_ElementDeclaration fixed_box(float width, float height, Clay_Color color) {
    return (Clay_ElementDeclaration){
        .layout = {.sizing = {CLAY_SIZING_FIXED(width), CLAY_SIZING_FIXED(height)}},
        .backgroundColor = color,
    };
}

static Clay_ElementDeclaration floating_box(float x, float y, Clay_Color color) {
    Clay_ElementDeclaration declaration = fixed_box(10, 10, color);
    declaration.floating = (Clay_FloatingElementConfig){
        .offset = {x, y},
        .attachTo = CLAY_ATTACH_TO_ROOT,
    };
    return declaration;
}

static void print_error_delta(const ErrorLog *errors, int32_t start) {
    printf(" errors %d", (int)(errors->length - start));
    for (int32_t index = start; index < errors->length; ++index) {
        printf(" %d", (int)errors->types[index]);
    }
}

static void print_commands(const char *label, Clay_RenderCommandArray commands) {
    printf("commands %s %d\n", label, (int)commands.length);
    for (int32_t index = 0; index < commands.length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        const int32_t text_length = command->commandType == CLAY_RENDER_COMMAND_TYPE_TEXT
                                        ? command->renderData.text.stringContents.length
                                        : 0;
        printf("command %s %d type %d id %u box %u %u %u %u text %d\n",
               label,
               (int)index,
               (int)command->commandType,
               command->id,
               f32_bits(command->boundingBox.x),
               f32_bits(command->boundingBox.y),
               f32_bits(command->boundingBox.width),
               f32_bits(command->boundingBox.height),
               (int)text_length);
    }
}

static void print_element(const char *label, Clay_ElementId id) {
    const Clay_ElementData data = Clay_GetElementData(id);
    printf("element %s found %d box %u %u %u %u\n",
           label,
           data.found ? 1 : 0,
           f32_bits(data.boundingBox.x),
           f32_bits(data.boundingBox.y),
           f32_bits(data.boundingBox.width),
           f32_bits(data.boundingBox.height));
}

static void run_malformed_depth(ErrorLog *errors, int32_t depth) {
    const int32_t error_start = errors->length;
    Clay_BeginLayout();
    for (int32_t index = 0; index < depth; ++index) {
        const Clay_ElementId id = Clay_GetElementIdWithIndex(
            CLAY_STRING("safety-malformed"),
            (uint32_t)(depth * 10 + index));
        Clay__OpenElementWithId(id);
        Clay__ConfigureOpenElement(floating_box(
            (float)(index * 15),
            (float)(depth * 20),
            (Clay_Color){(float)(20 + depth * 20), (float)(40 + index * 20), 90, 255}));
    }
    const Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);
    Clay_Context *context = Clay_GetCurrentContext();
    const int32_t residual_user_depth = context->openLayoutElementStack.length - 1;
    printf("malformed depth %d", (int)depth);
    print_error_delta(errors, error_start);
    printf(" residual %d\n", (int)residual_user_depth);
    char label[32];
    snprintf(label, sizeof(label), "malformed-%d", (int)depth);
    print_commands(label, commands);

    const int32_t recovery_error_start = errors->length;
    const Clay_ElementId recovery_id = Clay_GetElementIdWithIndex(
        CLAY_STRING("safety-recovery"),
        (uint32_t)depth);
    Clay_BeginLayout();
    CLAY(recovery_id, fixed_box(12, 7, (Clay_Color){10, 200, 30, 255})) {}
    const Clay_RenderCommandArray recovery_commands = Clay_EndLayout(0.0f);
    context = Clay_GetCurrentContext();
    const int32_t recovery_residual = context->openLayoutElementStack.length - 1;
    printf("recovery depth %d", (int)depth);
    print_error_delta(errors, recovery_error_start);
    printf(" residual %d\n", (int)recovery_residual);
    snprintf(label, sizeof(label), "recovery-%d", (int)depth);
    print_commands(label, recovery_commands);
    print_element(label, recovery_id);
}

static void run_floating_clip_leak(ErrorLog *errors) {
    const int32_t error_start = errors->length;
    Clay_BeginLayout();
    CLAY(CLAY_ID("safety-outer-clip"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(20)}},
        .clip = {.horizontal = true, .vertical = true},
    }) {
        CLAY(CLAY_ID("safety-floating-and-clip"), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
            .floating = {
                .attachTo = CLAY_ATTACH_TO_PARENT,
                .clipTo = CLAY_CLIP_TO_ATTACHED_PARENT,
            },
            .clip = {.horizontal = true, .vertical = true},
        }) {}
    }
    CLAY(CLAY_ID("safety-after-double-clip"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .floating = {
            .offset = {50, 0},
            .attachTo = CLAY_ATTACH_TO_PARENT,
            .clipTo = CLAY_CLIP_TO_ATTACHED_PARENT,
        },
        .backgroundColor = {255, 0, 255, 255},
    }) {}
    Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);
    Clay_Context *context = Clay_GetCurrentContext();
    printf("floating-clip");
    print_error_delta(errors, error_start);
    printf(" leaked-clips %d\n", (int)context->openClipElementStack.length);
    print_commands("floating-clip", commands);

    const int32_t recovery_error_start = errors->length;
    Clay_BeginLayout();
    CLAY(CLAY_ID("safety-floating-clip-recovery"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .floating = {
            .offset = {50, 0},
            .attachTo = CLAY_ATTACH_TO_PARENT,
            .clipTo = CLAY_CLIP_TO_ATTACHED_PARENT,
        },
        .backgroundColor = {30, 180, 220, 255},
    }) {}
    commands = Clay_EndLayout(0.0f);
    context = Clay_GetCurrentContext();
    printf("floating-clip-recovery");
    print_error_delta(errors, recovery_error_start);
    printf(" leaked-clips %d\n", (int)context->openClipElementStack.length);
    print_commands("floating-clip-recovery", commands);
    print_element("floating-clip-recovery", CLAY_ID("safety-floating-clip-recovery"));
}

static void run_negative_slice_edge(ErrorLog *errors) {
    const int32_t error_start = errors->length;
    Clay_BeginLayout();
    CLAY(CLAY_ID("safety-negative-container"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(1), CLAY_SIZING_FIXED(30)}},
    }) {
        CLAY_TEXT(
            CLAY_STRING(" \n"),
            CLAY_TEXT_CONFIG({.fontSize = 10, .lineHeight = 10}));
    }
    Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);
    printf("negative-slice");
    print_error_delta(errors, error_start);
    putchar('\n');
    print_commands("negative-slice", commands);
    print_element(
        "negative-slice",
        Clay__HashNumber(0, CLAY_ID("safety-negative-container").id));

    const int32_t recovery_error_start = errors->length;
    Clay_BeginLayout();
    CLAY(CLAY_ID("safety-text-recovery-container"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(30), CLAY_SIZING_FIXED(20)}},
    }) {
        CLAY_TEXT(
            CLAY_STRING("ok"),
            CLAY_TEXT_CONFIG({.fontSize = 10, .lineHeight = 10}));
    }
    commands = Clay_EndLayout(0.0f);
    printf("negative-slice-recovery");
    print_error_delta(errors, recovery_error_start);
    putchar('\n');
    print_commands("negative-slice-recovery", commands);
    print_element(
        "negative-slice-recovery",
        Clay__HashNumber(0, CLAY_ID("safety-text-recovery-container").id));
}

int main(void) {
    ErrorLog errors = {0};
    Clay_SetMaxElementCount(256);
    Clay_SetMaxMeasureTextCacheWordCount(512);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){200, 200},
        (Clay_ErrorHandler){record_error, &errors});
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_SetCullingEnabled(false);

    for (int32_t depth = 0; depth <= 3; ++depth) run_malformed_depth(&errors, depth);
    run_floating_clip_leak(&errors);
    run_negative_slice_edge(&errors);

    printf("total-errors %d", (int)errors.length);
    for (int32_t index = 0; index < errors.length; ++index) {
        printf(" %d", (int)errors.types[index]);
    }
    putchar('\n');

    free(memory);
    return 0;
}
