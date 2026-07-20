#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct ErrorRecord {
    int32_t phase;
    Clay_ErrorType type;
    Clay_String text;
} ErrorRecord;

typedef struct ErrorLog {
    int32_t phase;
    int32_t length;
    ErrorRecord records[16];
} ErrorLog;

static void record_error(Clay_ErrorData error) {
    ErrorLog *log = (ErrorLog *)error.userData;
    if (log->length >= 16) oracle_fail_log_overflow("parity-regression diagnostics");
    log->records[log->length++] = (ErrorRecord){
        .phase = log->phase,
        .type = error.errorType,
        .text = error.errorText,
    };
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

static void print_diagnostics(const ErrorLog *log) {
    printf("diagnostics %d\n", (int)log->length);
    for (int32_t index = 0; index < log->length; ++index) {
        const ErrorRecord *record = &log->records[index];
        printf("diagnostic %d phase %d type %d static %d len %d text %.*s\n",
               (int)index,
               (int)record->phase,
               (int)record->type,
               record->text.isStaticallyAllocated ? 1 : 0,
               (int)record->text.length,
               (int)record->text.length,
               record->text.chars);
    }
}

static int32_t hover_calls = 0;
static int32_t mutation_space_calls = 0;

static void count_hover(Clay_ElementId id, Clay_PointerData pointer, void *user_data) {
    (void)id;
    (void)pointer;
    (void)user_data;
    hover_calls++;
}

static Clay_Dimensions mutating_measure_text(
    Clay_StringSlice text,
    Clay_TextElementConfig *config,
    void *user_data
) {
    (void)user_data;
    if (text.length == 1 && text.chars[0] == ' ') {
        mutation_space_calls++;
        if (mutation_space_calls == 2) config->fontId = 77;
    }
    return (Clay_Dimensions){.width = (float)text.length, .height = 1};
}

int main(void) {
    ErrorLog errors = {0};

    Clay_SetMaxElementCount(64);
    Clay_SetMaxMeasureTextCacheWordCount(128);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Context *primary_context = Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){200, 200},
        (Clay_ErrorHandler){record_error, &errors});
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_SetCullingEnabled(false);

    const Clay_ElementId fresh_id = CLAY_ID("parity-fresh");
    Clay_BeginLayout();
    Clay__OpenElementWithId(fresh_id);
    print_element("fresh-open", fresh_id);
    Clay__ConfigureOpenElement((Clay_ElementDeclaration){
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
    });
    Clay__CloseElement();
    print_element("fresh-closed", fresh_id);
    Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);
    print_element("fresh-ended", fresh_id);
    print_commands("fresh", commands);

    Clay_BeginLayout();
    CLAY(CLAY_ID("parity-floating-aspect"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(20)}},
        .aspectRatio = {.aspectRatio = 2},
        .floating = {.attachTo = CLAY_ATTACH_TO_ROOT},
        .backgroundColor = {255, 0, 0, 255},
    }) {}
    commands = Clay_EndLayout(0.0f);
    print_element("floating-aspect", CLAY_ID("parity-floating-aspect"));
    print_commands("floating-aspect", commands);

    Clay_BeginLayout();
    CLAY(CLAY_ID("parity-clip-row"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(200), CLAY_SIZING_FIXED(40)},
            .layoutDirection = CLAY_LEFT_TO_RIGHT,
        },
    }) {
        CLAY(CLAY_ID("parity-spacer"), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(50), CLAY_SIZING_FIXED(40)}},
        }) {}
        CLAY(CLAY_ID("parity-clipper"), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(20)}},
            .clip = {.horizontal = true, .vertical = true},
        }) {
            errors.phase = 30;
            CLAY(CLAY_ID("parity-missing-clipped-float"), {
                .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
                .floating = {
                    .parentId = CLAY_ID("parity-not-there").id,
                    .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
                    .clipTo = CLAY_CLIP_TO_ATTACHED_PARENT,
                },
                .backgroundColor = {0, 0, 255, 255},
            }) {}
        }
    }
    commands = Clay_EndLayout(0.0f);
    print_element("missing-parent-clipper", CLAY_ID("parity-clipper"));
    print_element("missing-parent-float", CLAY_ID("parity-missing-clipped-float"));
    print_commands("missing-parent", commands);

    Clay_SetMaxElementCount(8);
    Clay_SetMaxMeasureTextCacheWordCount(128);
    const uint32_t capacity_memory_size = Clay_MinMemorySize();
    void *capacity_memory = malloc(capacity_memory_size);
    if (!capacity_memory) {
        free(memory);
        return 2;
    }
    Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(capacity_memory_size, capacity_memory),
        (Clay_Dimensions){200, 200},
        (Clay_ErrorHandler){record_error, &errors});
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_SetCullingEnabled(false);

    Clay_BeginLayout();
    CLAY(CLAY_ID("parity-wrap-container"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(1), CLAY_SIZING_GROW()}},
    }) {
        CLAY_TEXT(
            CLAY_STRING("a a a a a a a a a a a a a a a a a a a a"),
            CLAY_TEXT_CONFIG({.fontSize = 1}));
    }
    errors.phase = 40;
    commands = Clay_EndLayout(0.0f);
    const Clay_ElementId wrapped_text_id = Clay__HashNumber(0, CLAY_ID("parity-wrap-container").id);
    print_element("wrapped-text", wrapped_text_id);
    print_commands("wrapped-text", commands);

    Clay_SetCurrentContext(primary_context);
    Clay_SetMaxElementCount(64);
    Clay_SetMaxMeasureTextCacheWordCount(128);

    const int32_t missing_start = errors.length;
    Clay_SetMeasureTextFunction(NULL, NULL);
    Clay_BeginLayout();
    errors.phase = 50;
    CLAY_TEXT(
        CLAY_STRING("missing measure one"),
        CLAY_TEXT_CONFIG({.fontSize = 1, .lineHeight = 3}));
    const int32_t missing_after_first = errors.length - missing_start;
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_SetMeasureTextFunction(NULL, NULL);
    CLAY_TEXT(
        CLAY_STRING("missing measure two"),
        CLAY_TEXT_CONFIG({.fontSize = 1, .lineHeight = 3}));
    const int32_t missing_after_second = errors.length - missing_start;
    (void)Clay_EndLayout(0.0f);
    const int32_t missing_after_end = errors.length - missing_start;
    printf("missing-measure diagnostics %d %d %d\n",
           (int)missing_after_first,
           (int)missing_after_second,
           (int)missing_after_end);

    Clay_SetMeasureTextFunction(measure_text, NULL);
    const Clay_LayoutConfig saved_layout_default = CLAY_LAYOUT_DEFAULT;
    CLAY_LAYOUT_DEFAULT.sizing.width = CLAY_SIZING_PERCENT(0.5f);
    CLAY_LAYOUT_DEFAULT.sizing.height = CLAY_SIZING_PERCENT(0.5f);
    CLAY_LAYOUT_DEFAULT.padding = (Clay_Padding){7, 3, 5, 1};
    Clay_BeginLayout();
    CLAY(CLAY_ID("parity-layout-default-container"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(20)}},
    }) {
        CLAY_TEXT(CLAY_STRING("abc"), CLAY_TEXT_CONFIG({.fontSize = 1}));
    }
    commands = Clay_EndLayout(0.0f);
    const Clay_ElementId layout_default_text_id = Clay__HashNumber(
        0,
        CLAY_ID("parity-layout-default-container").id);
    print_element("layout-default-text", layout_default_text_id);
    print_commands("layout-default", commands);
    CLAY_LAYOUT_DEFAULT = saved_layout_default;

    mutation_space_calls = 0;
    Clay_SetMeasureTextFunction(mutating_measure_text, NULL);
    Clay_BeginLayout();
    CLAY(CLAY_ID("parity-measure-mutation-container"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(1), CLAY_SIZING_FIXED(10)}},
    }) {
        CLAY_TEXT(CLAY_STRING("a a"), CLAY_TEXT_CONFIG({.fontId = 1, .fontSize = 1}));
    }
    commands = Clay_EndLayout(0.0f);
    printf("measure-mutation spaces %d commands %d\n",
           (int)mutation_space_calls,
           (int)commands.length);
    for (int32_t index = 0; index < commands.length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        if (command->commandType != CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
        printf("mutation-command %d font %u text %d box %u %u %u %u\n",
               (int)index,
               (unsigned int)command->renderData.text.fontId,
               (int)command->renderData.text.stringContents.length,
               f32_bits(command->boundingBox.x),
               f32_bits(command->boundingBox.y),
               f32_bits(command->boundingBox.width),
               f32_bits(command->boundingBox.height));
    }
    Clay_SetMeasureTextFunction(measure_text, NULL);

    Clay_BeginLayout();
    CLAY(CLAY_ID("parity-hover-retained"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
    }) {
        Clay_OnHover(count_hover, NULL);
    }
    CLAY(CLAY_ID("parity-hover-cleared"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
    }) {
        Clay_OnHover(count_hover, NULL);
        Clay_OnHover(NULL, NULL);
    }
    (void)Clay_EndLayout(0.0f);
    hover_calls = 0;
    Clay_SetPointerState((Clay_Vector2){5, 5}, false);
    const int32_t retained_calls = hover_calls;
    Clay_SetPointerState((Clay_Vector2){5, 15}, false);
    const int32_t cleared_calls = hover_calls - retained_calls;
    printf("hover retained %d cleared %d\n", (int)retained_calls, (int)cleared_calls);

    print_diagnostics(&errors);
    free(capacity_memory);
    free(memory);
    return 0;
}
