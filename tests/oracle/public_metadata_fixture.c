#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"

typedef struct ErrorLog {
    int32_t count;
    Clay_ErrorType last_type;
    bool last_text_static;
} ErrorLog;

static void record_error(Clay_ErrorData error) {
    ErrorLog *log = (ErrorLog *)error.userData;
    log->count++;
    log->last_type = error.errorType;
    log->last_text_static = error.errorText.isStaticallyAllocated;
}

int main(void) {
    ErrorLog errors = {0};
    Clay_SetMaxElementCount(8);

    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(
        arena,
        (Clay_Dimensions){100, 100},
        (Clay_ErrorHandler){record_error, &errors});

    Clay_BeginLayout();
    CLAY(CLAY_ID("metadata-box"), {
        .layout = {
            .sizing = {
                CLAY_SIZING_PERCENT(2),
                CLAY_SIZING_FIXED(20),
            },
        },
        .backgroundColor = {10, 20, 30, 255},
    }) {}
    Clay_RenderCommandArray commands = Clay_EndLayout(0.0f);

    Clay_SetPointerState((Clay_Vector2){10, 10}, false);
    Clay_ElementIdArray pointer_over = Clay_GetPointerOverIds();

    printf("render capacity %d length %d\n", (int)commands.capacity, (int)commands.length);
    printf("pointer capacity %d length %d\n", (int)pointer_over.capacity, (int)pointer_over.length);
    printf("error count %d type %d static %d\n",
           (int)errors.count,
           (int)errors.last_type,
           errors.last_text_static ? 1 : 0);

    free(memory);
    return 0;
}
