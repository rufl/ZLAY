#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

static Clay_ElementDeclaration fixed_box(float width, float height) {
    return (Clay_ElementDeclaration){
        .layout = {.sizing = {CLAY_SIZING_FIXED(width), CLAY_SIZING_FIXED(height)}},
    };
}

static void print_element(const char *label, Clay_ElementId id) {
    const Clay_ElementData data = Clay_GetElementData(id);
    printf("element %s found %d box %u %u %u %u\n",
           label,
           data.found ? 1 : 0,
           oracle_f32_bits(data.boundingBox.x),
           oracle_f32_bits(data.boundingBox.y),
           oracle_f32_bits(data.boundingBox.width),
           oracle_f32_bits(data.boundingBox.height));
}

static void print_scroll(const char *label, Clay_ElementId id) {
    const Clay_ScrollContainerData data = Clay_GetScrollContainerData(id);
    const Clay_Vector2 position = data.scrollPosition ? *data.scrollPosition : (Clay_Vector2){0};
    printf("scroll %s found %d pos %u %u viewport %u %u content %u %u config %d %d\n",
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

static void draw_aspects(void) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("aspect-row"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(200), CLAY_SIZING_FIXED(100)},
            .layoutDirection = CLAY_LEFT_TO_RIGHT,
        },
    }) {
        CLAY(CLAY_ID("aspect-width-from-height"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIT(), CLAY_SIZING_FIXED(30)},
            },
            .aspectRatio = {.aspectRatio = 2},
            .backgroundColor = {10, 20, 30, 255},
        }) {}
        CLAY(CLAY_ID("aspect-height-from-width"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIT()},
            },
            .aspectRatio = {.aspectRatio = 4},
            .backgroundColor = {40, 50, 60, 255},
        }) {}
    }
    (void)Clay_EndLayout(0.0f);
}

static void draw_horizontal_scroll(void) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("horizontal-scroll"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(40)},
            .layoutDirection = CLAY_LEFT_TO_RIGHT,
        },
        .clip = {
            .horizontal = true,
            .childOffset = Clay_GetScrollOffset(),
        },
    }) {
        CLAY(CLAY_ID("horizontal-content"), fixed_box(300, 40)) {}
    }
    (void)Clay_EndLayout(0.0f);
}

int main(void) {
    Clay_SetMaxElementCount(32);
    Clay_SetMaxMeasureTextCacheWordCount(64);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){320, 200},
        (Clay_ErrorHandler){oracle_fail_on_error, NULL});
    Clay_SetCullingEnabled(false);

    draw_aspects();
    print_element("width-from-height", CLAY_ID("aspect-width-from-height"));
    print_element("height-from-width", CLAY_ID("aspect-height-from-width"));

    const Clay_ElementId scroll_id = CLAY_ID("horizontal-scroll");
    Clay_SetPointerState((Clay_Vector2){90, 20}, false);
    Clay_SetPointerState((Clay_Vector2){90, 20}, false);
    print_scroll("before", scroll_id);

    draw_horizontal_scroll();
    print_scroll("initial", scroll_id);
    Clay_SetPointerState((Clay_Vector2){90, 20}, true);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0}, 0.1f);
    print_scroll("press", scroll_id);

    draw_horizontal_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 20}, true);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0}, 0.1f);
    print_scroll("move-one", scroll_id);

    draw_horizontal_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 20}, true);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0}, 0.2f);
    print_scroll("stationary-one", scroll_id);

    draw_horizontal_scroll();
    Clay_SetPointerState((Clay_Vector2){50, 20}, true);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0}, 0.1f);
    print_scroll("stationary-reset", scroll_id);

    draw_horizontal_scroll();
    Clay_SetPointerState((Clay_Vector2){10, 20}, true);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0}, 0.1f);
    print_scroll("move-two", scroll_id);

    draw_horizontal_scroll();
    Clay_SetPointerState((Clay_Vector2){10, 20}, false);
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0}, 0.016f);
    print_scroll("release", scroll_id);

    draw_horizontal_scroll();
    Clay_SetPointerState((Clay_Vector2){10, 20}, false);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0}, 0.016f);
    print_scroll("momentum", scroll_id);

    free(memory);
    return 0;
}
