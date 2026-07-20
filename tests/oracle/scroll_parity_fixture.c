#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

static void print_scroll_data(const char *label, Clay_ElementId id) {
    Clay_ScrollContainerData data = Clay_GetScrollContainerData(id);
    Clay_Vector2 position = data.scrollPosition ? *data.scrollPosition : (Clay_Vector2){0, 0};
    printf("data %s found %d pos %u %u viewport %u %u content %u %u config %d %d\n",
           label,
           data.found ? 1 : 0,
           oracle_f32_bits(position.x),
           oracle_f32_bits(position.y),
           oracle_f32_bits(data.scrollContainerDimensions.width),
           oracle_f32_bits(data.scrollContainerDimensions.height),
           oracle_f32_bits(data.contentDimensions.width),
           oracle_f32_bits(data.contentDimensions.height),
           data.config.horizontal ? 1 : 0,
           data.config.vertical ? 1 : 0);
}

static void print_pointer_over(const char *label) {
    Clay_ElementIdArray over = Clay_GetPointerOverIds();
    printf("over %s %d", label, (int)over.length);
    for (int32_t index = 0; index < over.length; ++index) {
        Clay_ElementId *element_id = Clay_ElementIdArray_Get(&over, index);
        printf(" %u", element_id->id);
    }
    putchar('\n');
}

static void draw_scroll(void) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("scroll"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .clip = {
            .vertical = true,
            .childOffset = Clay_GetScrollOffset(),
        },
    }) {
        CLAY(CLAY_ID("content"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(1000)},
            },
        }) {}
    }
    (void)Clay_EndLayout(0.0f);
}

static void draw_empty(void) {
    Clay_BeginLayout();
    (void)Clay_EndLayout(0.0f);
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){240, 180}, (Clay_ErrorHandler){oracle_fail_on_error, NULL});
    Clay_ElementId scroll_id = CLAY_ID("scroll");

    Clay_SetPointerState((Clay_Vector2){50, 50}, false);
    Clay_SetPointerState((Clay_Vector2){50, 50}, false);
    print_scroll_data("before", scroll_id);

    draw_scroll();
    print_scroll_data("initial", scroll_id);
    Clay_SetPointerState((Clay_Vector2){50, 90}, true);
    print_pointer_over("press");
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.100f);
    print_scroll_data("press", scroll_id);

    draw_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 50}, true);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.100f);
    print_scroll_data("move-1", scroll_id);

    draw_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 10}, true);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.100f);
    print_scroll_data("move-2", scroll_id);

    draw_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 10}, false);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.016f);
    print_scroll_data("release", scroll_id);

    draw_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 10}, false);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, 0}, 0.016f);
    print_scroll_data("momentum", scroll_id);

    draw_empty();
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, 0}, 0.016f);
    print_scroll_data("stale", scroll_id);

    free(memory);
    return 0;
}
