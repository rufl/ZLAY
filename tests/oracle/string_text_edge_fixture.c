#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct MeasureState {
    int tag;
    float advance;
    float heightBias;
} MeasureState;

typedef struct MeasureRecord {
    int tag;
    int32_t length;
    int32_t offset;
    bool sameBase;
    uint16_t fontId;
    uint16_t fontSize;
    uint16_t letterSpacing;
    uint16_t lineHeight;
    char bytes[64];
} MeasureRecord;

typedef struct ExitRecord {
    Clay_TransitionState state;
    float elapsed;
    float duration;
} ExitRecord;

static MeasureRecord measureRecords[256];
static int measureRecordCount = 0;
static ExitRecord exitRecords[16];
static int exitRecordCount = 0;
static Clay_ErrorType errorRecords[16];
static int errorRecordCount = 0;

static MeasureState measureA = {1, 4.0f, 0.0f};
static MeasureState measureB = {2, 6.0f, 1.0f};

static const Clay_String EMPTY_STATIC = CLAY_STRING_CONST("");
static const Clay_String STATIC_TEXT = CLAY_STRING_CONST("static-lit");
static const Clay_String CACHE_PROBE = CLAY_STRING_CONST("cache probe");
static const Clay_String CLEAR_PROBE = CLAY_STRING_CONST("clear probe");
static char dynamicStorage[] = "dynamic-data";
static char derivedStorage[] = "__derived-slice__";
static char retainedStorage[] = "retained-life";

static Clay_String dynamic_text(void) {
    return (Clay_String){false, 12, dynamicStorage};
}

static Clay_String derived_text(void) {
    return (Clay_String){false, 7, derivedStorage + 2};
}

static Clay_String retained_text(void) {
    return (Clay_String){false, 13, retainedStorage};
}

static void print_escaped_bytes(const char *bytes, int32_t length) {
    putchar('"');
    for (int32_t index = 0; index < length; ++index) {
        const unsigned char byte = (unsigned char)bytes[index];
        switch (byte) {
            case '\n': fputs("\\n", stdout); break;
            case '\r': fputs("\\r", stdout); break;
            case '\t': fputs("\\t", stdout); break;
            case '\\': fputs("\\\\", stdout); break;
            case '"': fputs("\\\"", stdout); break;
            default: putchar((int)byte); break;
        }
    }
    putchar('"');
}

static int32_t slice_offset(Clay_StringSlice slice) {
    if (!slice.chars || !slice.baseChars) return 0;
    return (int32_t)(slice.chars - slice.baseChars);
}

static Clay_Dimensions measure_text(Clay_StringSlice text, Clay_TextElementConfig *config, void *userData) {
    MeasureState *state = (MeasureState *)userData;
    if (measureRecordCount >= (int)(sizeof(measureRecords) / sizeof(measureRecords[0]))) {
        oracle_fail_log_overflow("string-text measure records");
    }
    MeasureRecord *record = &measureRecords[measureRecordCount++];
    if (text.length > (int32_t)sizeof(record->bytes)) {
        oracle_fail_log_overflow("string-text measure bytes");
    }
    *record = (MeasureRecord){
        .tag = state->tag,
        .length = text.length,
        .offset = slice_offset(text),
        .sameBase = text.chars == text.baseChars,
        .fontId = config->fontId,
        .fontSize = config->fontSize,
        .letterSpacing = config->letterSpacing,
        .lineHeight = config->lineHeight,
    };
    if (text.length > 0) memcpy(record->bytes, text.chars, (size_t)text.length);

    return (Clay_Dimensions){
        (float)text.length * (state->advance + (float)config->letterSpacing),
        (float)config->fontSize + state->heightBias,
    };
}

static void report_error(Clay_ErrorData error) {
    if (errorRecordCount >= (int)(sizeof(errorRecords) / sizeof(errorRecords[0]))) {
        oracle_fail_log_overflow("string-text diagnostics");
    }
    errorRecords[errorRecordCount++] = error.errorType;
}

static void print_input(const char *name, Clay_String value, const char *baseChars) {
    const int32_t offset = value.chars && baseChars ? (int32_t)(value.chars - baseChars) : 0;
    printf("input %s static %d len %d source-offset %d bytes ",
           name,
           value.isStaticallyAllocated ? 1 : 0,
           value.length,
           offset);
    print_escaped_bytes(value.chars, value.length);
    putchar('\n');
}

static Clay_ElementDeclaration text_row(void) {
    Clay_ElementDeclaration declaration = {0};
    declaration.layout.sizing.width = CLAY_SIZING_FIXED(38);
    declaration.layout.sizing.height = CLAY_SIZING_FIT();
    return declaration;
}

static void declare_text_case(Clay_ElementId id, Clay_String text, uint16_t fontId, Clay_TextElementConfigWrapMode wrapMode) {
    CLAY(id, text_row()) {
        CLAY_TEXT(text, CLAY_TEXT_CONFIG({
            .textColor = {230, 235, 245, 255},
            .fontId = fontId,
            .fontSize = 8,
            .letterSpacing = 1,
            .lineHeight = 10,
            .wrapMode = wrapMode,
        }));
    }
}

static void declare_metadata_corpus(void) {
    CLAY(CLAY_ID("metadata-root"), {
        .layout = {
            .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()},
            .childGap = 1,
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
    }) {
        declare_text_case(CLAY_ID("empty-static"), EMPTY_STATIC, 1, CLAY_TEXT_WRAP_WORDS);
        declare_text_case(CLAY_ID("static-text"), STATIC_TEXT, 2, CLAY_TEXT_WRAP_WORDS);
        declare_text_case(CLAY_ID("dynamic-text"), dynamic_text(), 3, CLAY_TEXT_WRAP_WORDS);
        declare_text_case(CLAY_ID("derived-text"), derived_text(), 4, CLAY_TEXT_WRAP_WORDS);
        declare_text_case(CLAY_ID("space-one"), CLAY_STRING(" "), 10, CLAY_TEXT_WRAP_WORDS);
        declare_text_case(CLAY_ID("space-two"), CLAY_STRING("  "), 11, CLAY_TEXT_WRAP_WORDS);
        declare_text_case(CLAY_ID("newline-one"), CLAY_STRING("\n"), 12, CLAY_TEXT_WRAP_NEWLINES);
        declare_text_case(CLAY_ID("newline-two"), CLAY_STRING("\n\n"), 13, CLAY_TEXT_WRAP_NEWLINES);
        declare_text_case(CLAY_ID("leading-space"), CLAY_STRING(" lead"), 14, CLAY_TEXT_WRAP_WORDS);
        declare_text_case(CLAY_ID("trailing-space"), CLAY_STRING("trail "), 15, CLAY_TEXT_WRAP_WORDS);
        declare_text_case(CLAY_ID("double-space"), CLAY_STRING("a  b"), 16, CLAY_TEXT_WRAP_WORDS);
        declare_text_case(CLAY_ID("double-newline"), CLAY_STRING("a\n\nb"), 17, CLAY_TEXT_WRAP_NEWLINES);
        declare_text_case(CLAY_ID("tab-edge"), CLAY_STRING("tab\tedge"), 18, CLAY_TEXT_WRAP_WORDS);
    }
}

static void declare_cache_corpus(bool includeClearProbe) {
    CLAY(CLAY_ID("cache-root"), {
        .layout = {
            .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()},
            .childGap = 2,
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
    }) {
        declare_text_case(CLAY_ID("cache-probe-row"), CACHE_PROBE, 30, CLAY_TEXT_WRAP_NONE);
        if (includeClearProbe) {
            declare_text_case(CLAY_ID("clear-probe-row"), CLEAR_PROBE, 31, CLAY_TEXT_WRAP_NONE);
        }
    }
}

static Clay_TransitionData retained_exit_final(Clay_TransitionData current, Clay_TransitionProperty properties) {
    (void)properties;
    current.boundingBox.x += 12.0f;
    return current;
}

static bool retained_exit_handler(Clay_TransitionCallbackArguments arguments) {
    if (exitRecordCount >= (int)(sizeof(exitRecords) / sizeof(exitRecords[0]))) {
        oracle_fail_log_overflow("string-text exit records");
    }
    exitRecords[exitRecordCount++] = (ExitRecord){
        arguments.transitionState,
        arguments.elapsedTime,
        arguments.duration,
    };
    const float ratio = arguments.duration > 0 ? arguments.elapsedTime / arguments.duration : 1.0f;
    const float clamped = ratio > 1.0f ? 1.0f : ratio;
    arguments.current->boundingBox.x = arguments.initial.boundingBox.x +
                                       (arguments.target.boundingBox.x - arguments.initial.boundingBox.x) * clamped;
    return arguments.elapsedTime >= arguments.duration;
}

static Clay_ElementDeclaration retained_declaration(void) {
    Clay_ElementDeclaration declaration = {0};
    declaration.layout.sizing.width = CLAY_SIZING_FIXED(90);
    declaration.layout.sizing.height = CLAY_SIZING_FIXED(14);
    declaration.transition = (Clay_TransitionElementConfig){
        .handler = retained_exit_handler,
        .duration = 0.6f,
        .properties = CLAY_TRANSITION_PROPERTY_X,
        .exit = {
            .setFinalState = retained_exit_final,
            .trigger = CLAY_TRANSITION_EXIT_SKIP_WHEN_PARENT_EXITS,
            .siblingOrdering = CLAY_EXIT_TRANSITION_ORDERING_NATURAL_ORDER,
        },
    };
    return declaration;
}

static void declare_retained_corpus(bool showRetained) {
    CLAY(CLAY_ID("retained-root"), {
        .layout = {
            .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
    }) {
        if (showRetained) {
            CLAY(CLAY_ID("retained-owner"), retained_declaration()) {
                CLAY_TEXT(retained_text(), CLAY_TEXT_CONFIG({
                    .textColor = {245, 220, 120, 255},
                    .fontId = 40,
                    .fontSize = 8,
                    .wrapMode = CLAY_TEXT_WRAP_NONE,
                }));
            }
        }
    }
}

static void print_measure_records(int frame) {
    printf("frame %d measures %d\n", frame, measureRecordCount);
    for (int index = 0; index < measureRecordCount; ++index) {
        MeasureRecord *record = &measureRecords[index];
        printf("frame %d measure %d tag %d len %d offset %d same-base %d font %u %u spacing %u line %u bytes ",
               frame,
               index,
               record->tag,
               record->length,
               record->offset,
               record->sameBase ? 1 : 0,
               record->fontId,
               record->fontSize,
               record->letterSpacing,
               record->lineHeight);
        print_escaped_bytes(record->bytes, record->length);
        putchar('\n');
    }
}

static void print_exit_records(int frame) {
    printf("frame %d exits %d\n", frame, exitRecordCount);
    for (int index = 0; index < exitRecordCount; ++index) {
        printf("frame %d exit %d state %d elapsed %08x duration %08x\n",
               frame,
               index,
               (int)exitRecords[index].state,
               oracle_f32_bits(exitRecords[index].elapsed),
               oracle_f32_bits(exitRecords[index].duration));
    }
}

static void print_error_records(int frame) {
    printf("frame %d errors %d", frame, errorRecordCount);
    for (int index = 0; index < errorRecordCount; ++index) {
        printf(" %d", (int)errorRecords[index]);
    }
    putchar('\n');
}

static void print_text_commands(int frame, Clay_RenderCommandArray commands) {
    int textCount = 0;
    for (int32_t index = 0; index < commands.length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        if (command->commandType == CLAY_RENDER_COMMAND_TYPE_TEXT) textCount++;
    }
    printf("frame %d texts %d\n", frame, textCount);

    int textIndex = 0;
    for (int32_t index = 0; index < commands.length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        if (command->commandType != CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
        const Clay_TextRenderData text = command->renderData.text;
        printf("frame %d text %d len %d offset %d same-base %d box %08x %08x %08x %08x font %u %u spacing %u line %u bytes ",
               frame,
               textIndex++,
               text.stringContents.length,
               slice_offset(text.stringContents),
               text.stringContents.chars == text.stringContents.baseChars ? 1 : 0,
               oracle_f32_bits(command->boundingBox.x),
               oracle_f32_bits(command->boundingBox.y),
               oracle_f32_bits(command->boundingBox.width),
               oracle_f32_bits(command->boundingBox.height),
               text.fontId,
               text.fontSize,
               text.letterSpacing,
               text.lineHeight);
        print_escaped_bytes(text.stringContents.chars, text.stringContents.length);
        putchar('\n');
    }
}

typedef enum FrameKind {
    FRAME_METADATA,
    FRAME_CACHE,
    FRAME_RETAINED,
} FrameKind;

static void run_frame(int frame, FrameKind kind, bool option, float deltaTime) {
    measureRecordCount = 0;
    exitRecordCount = 0;
    errorRecordCount = 0;
    Clay_BeginLayout();
    if (kind == FRAME_METADATA) {
        declare_metadata_corpus();
    } else if (kind == FRAME_CACHE) {
        declare_cache_corpus(option);
    } else {
        declare_retained_corpus(option);
    }
    Clay_RenderCommandArray commands = Clay_EndLayout(deltaTime);
    print_error_records(frame);
    print_measure_records(frame);
    print_exit_records(frame);
    print_text_commands(frame, commands);
}

int main(void) {
    const uint32_t memorySize = Clay_MinMemorySize();
    void *memory = malloc(memorySize);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memorySize, memory);
    Clay_Initialize(arena, (Clay_Dimensions){180, 260}, (Clay_ErrorHandler){report_error, NULL});
    Clay_SetCullingEnabled(false);

    print_input("empty", EMPTY_STATIC, EMPTY_STATIC.chars);
    print_input("static", STATIC_TEXT, STATIC_TEXT.chars);
    print_input("dynamic", dynamic_text(), dynamicStorage);
    print_input("derived", derived_text(), derivedStorage);

    Clay_SetMeasureTextFunction(measure_text, &measureA);
    run_frame(0, FRAME_METADATA, false, 0.0f);
    run_frame(1, FRAME_CACHE, false, 0.0f);

    Clay_SetMeasureTextFunction(NULL, NULL);
    run_frame(2, FRAME_CACHE, true, 0.0f);

    Clay_SetMeasureTextFunction(measure_text, &measureB);
    run_frame(3, FRAME_CACHE, true, 0.0f);

    Clay_ResetMeasureTextCache();
    run_frame(4, FRAME_CACHE, true, 0.0f);

    run_frame(5, FRAME_RETAINED, true, 0.0f);
    run_frame(6, FRAME_RETAINED, false, 0.2f);
    run_frame(7, FRAME_RETAINED, false, 0.2f);
    run_frame(8, FRAME_RETAINED, false, 0.2f);
    run_frame(9, FRAME_RETAINED, false, 0.2f);

    free(memory);
    return 0;
}
