#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct ErrorRecord {
    int32_t tag;
    int32_t phase;
    Clay_ErrorType type;
    Clay_String text;
} ErrorRecord;

typedef struct ErrorLog {
    int32_t tag;
    int32_t phase;
    int32_t length;
    ErrorRecord records[8];
} ErrorLog;

static void record_error(Clay_ErrorData error) {
    ErrorLog *log = (ErrorLog *)error.userData;
    if (log->length >= 8) oracle_fail_log_overflow("api diagnostics");
    log->records[log->length++] = (ErrorRecord){
        .tag = log->tag,
        .phase = log->phase,
        .type = error.errorType,
        .text = error.errorText,
    };
}

static void print_checkpoint(const char *label, const ErrorLog *log) {
    printf("checkpoint %s errors %d\n", label, (int)log->length);
}

static void print_errors(const ErrorLog *log) {
    printf("errors %d\n", (int)log->length);
    for (int32_t index = 0; index < log->length; ++index) {
        const ErrorRecord *record = &log->records[index];
        printf("error %d tag %d phase %d type %d static %d len %d text %.*s\n",
               (int)index,
               (int)record->tag,
               (int)record->phase,
               (int)record->type,
               record->text.isStaticallyAllocated ? 1 : 0,
               (int)record->text.length,
               (int)record->text.length,
               record->text.chars);
    }
}

static Clay_ElementDeclaration fixed_box(float width, float height) {
    Clay_ElementDeclaration declaration = {0};
    declaration.layout.sizing.width = CLAY_SIZING_FIXED(width);
    declaration.layout.sizing.height = CLAY_SIZING_FIXED(height);
    return declaration;
}

int main(void) {
    ErrorLog errors = {.tag = 73};
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(
        arena,
        (Clay_Dimensions){300, 200},
        (Clay_ErrorHandler){record_error, &errors});

    printf("limits initial element %d text %d\n",
           (int)Clay_GetMaxElementCount(),
           (int)Clay_GetMaxMeasureTextCacheWordCount());
    Clay_SetMaxElementCount(64);
    Clay_SetMaxMeasureTextCacheWordCount(128);
    printf("limits set element %d text %d\n",
           (int)Clay_GetMaxElementCount(),
           (int)Clay_GetMaxMeasureTextCacheWordCount());

    Clay_Dimensions dimensions = Clay_GetLayoutDimensions();
    printf("dimensions initial %08x %08x\n", oracle_f32_bits(dimensions.width), oracle_f32_bits(dimensions.height));
    Clay_SetLayoutDimensions((Clay_Dimensions){320, 180});
    dimensions = Clay_GetLayoutDimensions();
    printf("dimensions set %08x %08x\n", oracle_f32_bits(dimensions.width), oracle_f32_bits(dimensions.height));

    printf("debug initial %d\n", Clay_IsDebugModeEnabled() ? 1 : 0);
    Clay_SetDebugModeEnabled(true);
    printf("debug enabled %d\n", Clay_IsDebugModeEnabled() ? 1 : 0);
    Clay_SetDebugModeEnabled(false);
    printf("debug disabled %d\n", Clay_IsDebugModeEnabled() ? 1 : 0);

    Clay_BeginLayout();
    errors.phase = 10;
    CLAY_TEXT(CLAY_STRING("measure me"), CLAY_TEXT_CONFIG({.fontSize = 12}));
    print_checkpoint("measure-declaration", &errors);
    (void)Clay_EndLayout(0.0f);

    Clay_ElementId duplicate_id = CLAY_ID("diagnostic-duplicate");
    Clay_BeginLayout();
    CLAY(duplicate_id, fixed_box(10, 10)) {}
    errors.phase = 20;
    CLAY(duplicate_id, fixed_box(20, 10)) {}
    print_checkpoint("duplicate-declaration", &errors);
    (void)Clay_EndLayout(0.0f);

    Clay_BeginLayout();
    errors.phase = 30;
    CLAY(CLAY_ID("diagnostic-percent"), {
        .layout = {
            .sizing = {CLAY_SIZING_PERCENT(1.25f), CLAY_SIZING_FIXED(10)},
        },
    }) {}
    print_checkpoint("percent-declaration", &errors);

    errors.phase = 40;
    CLAY(CLAY_ID("diagnostic-floating"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)},
        },
        .floating = {
            .parentId = CLAY_ID("diagnostic-missing-parent").id,
            .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
        },
    }) {}
    print_checkpoint("floating-declaration", &errors);
    (void)Clay_EndLayout(0.0f);

    print_errors(&errors);
    free(memory);
    return 0;
}
