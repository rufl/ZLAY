#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

static void print_scroll_data(const char *label, Clay_ElementId id) {
    Clay_ScrollContainerData data = Clay_GetScrollContainerData(id);
    Clay_Vector2 position = data.scrollPosition ? *data.scrollPosition : (Clay_Vector2){0, 0};
    printf("data %s found %d pos %u %u viewport %u %u content %u %u config %d %d %u %u\n",
           label,
           data.found ? 1 : 0,
           oracle_f32_bits(position.x),
           oracle_f32_bits(position.y),
           oracle_f32_bits(data.scrollContainerDimensions.width),
           oracle_f32_bits(data.scrollContainerDimensions.height),
           oracle_f32_bits(data.contentDimensions.width),
           oracle_f32_bits(data.contentDimensions.height),
           data.config.horizontal ? 1 : 0,
           data.config.vertical ? 1 : 0,
           oracle_f32_bits(data.config.childOffset.x),
           oracle_f32_bits(data.config.childOffset.y));
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

static void draw_old_scroll(void) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("old-scroll"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .clip = {
            .horizontal = true,
            .vertical = true,
            .childOffset = Clay_GetScrollOffset(),
        },
    }) {
        CLAY(CLAY_ID("old-content"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(300), CLAY_SIZING_FIXED(300)},
            },
        }) {}
    }
    (void)Clay_EndLayout(0.0f);
}

static void draw_replacement_scroll(void) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("replacement-scroll"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .clip = {
            .vertical = true,
            .childOffset = Clay_GetScrollOffset(),
        },
    }) {
        CLAY(CLAY_ID("replacement-content"), {
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

    Clay_ElementId old_id = CLAY_ID("old-scroll");
    Clay_ElementId replacement_id = CLAY_ID("replacement-scroll");

    Clay_SetPointerState((Clay_Vector2){50, 50}, false);
    Clay_SetPointerState((Clay_Vector2){50, 50}, false);
    print_scroll_data("old-before", old_id);

    draw_old_scroll();
    print_scroll_data("old-initial", old_id);
    Clay_SetPointerState((Clay_Vector2){50, 50}, false);
    print_pointer_over("old");
    Clay_UpdateScrollContainers(false, (Clay_Vector2){-50, -50}, 0.016f);
    print_scroll_data("old-wheel-clamp", old_id);

    // The old container is now closed. Declaring a differently identified
    // container in the same layout-array slot before pruning exposes pinned
    // Clay's retained layoutElement-pointer and swap-remove behavior.
    draw_replacement_scroll();
    print_scroll_data("old-after-replacement", old_id);
    print_scroll_data("replacement-initial", replacement_id);

    Clay_SetPointerState((Clay_Vector2){50, 90}, true);
    print_pointer_over("replacement-press");
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.100f);
    print_scroll_data("replacement-press", replacement_id);
    print_scroll_data("old-pruned", old_id);

    draw_replacement_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 50}, true);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.100f);
    print_scroll_data("replacement-move-1", replacement_id);

    draw_replacement_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 10}, true);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.100f);
    print_scroll_data("replacement-move-2", replacement_id);

    draw_replacement_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 10}, false);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.016f);
    print_scroll_data("replacement-release", replacement_id);

    draw_replacement_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 10}, false);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, 0}, 0.016f);
    print_scroll_data("replacement-momentum", replacement_id);

    draw_empty();
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, 0}, 0.016f);
    print_scroll_data("replacement-stale", replacement_id);

    free(memory);
    return 0;
}
