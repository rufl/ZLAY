#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct FixtureIds {
    uint32_t query_auto;
    uint32_t row_auto;
    uint32_t local_content_auto;
    Clay_ElementId local_fit;
    Clay_ElementId indexed_global;
    Clay_ElementId indexed_local;
    Clay_ElementId align_content;
} FixtureIds;

static void report_error(Clay_ErrorData error) {
    oracle_fail_on_error(error);
}

static void print_id(int frame, const char *name, Clay_ElementId id) {
    printf("frame %d id %s %u %u %u %d\n",
           frame,
           name,
           id.id,
           id.offset,
           id.baseId,
           id.stringId.length);
}

static void print_box(int frame, const char *name, uint32_t id) {
    const Clay_ElementData data = Clay_GetElementData((Clay_ElementId){.id = id});
    printf("frame %d box %s found %d %08x %08x %08x %08x\n",
           frame,
           name,
           data.found ? 1 : 0,
           oracle_f32_bits(data.boundingBox.x),
           oracle_f32_bits(data.boundingBox.y),
           oracle_f32_bits(data.boundingBox.width),
           oracle_f32_bits(data.boundingBox.height));
}

static void print_command(int frame, int32_t index, const Clay_RenderCommand *command) {
    printf("frame %d command %d type %d id %u z %d box %08x %08x %08x %08x",
           frame,
           (int)index,
           (int)command->commandType,
           command->id,
           (int)command->zIndex,
           oracle_f32_bits(command->boundingBox.x),
           oracle_f32_bits(command->boundingBox.y),
           oracle_f32_bits(command->boundingBox.width),
           oracle_f32_bits(command->boundingBox.height));
    if (command->commandType == CLAY_RENDER_COMMAND_TYPE_RECTANGLE) {
        const Clay_Color color = command->renderData.rectangle.backgroundColor;
        printf(" rgba %08x %08x %08x %08x",
               oracle_f32_bits(color.r),
               oracle_f32_bits(color.g),
               oracle_f32_bits(color.b),
               oracle_f32_bits(color.a));
    }
    putchar('\n');
}

static FixtureIds declare_layout(bool *query_hovered) {
    FixtureIds ids = {0};

    CLAY(CLAY_ID("declaration-layout-root"), {
        .layout = {
            .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()},
            .padding = {7, 11, 5, 9},
            .childGap = 6,
            .childAlignment = {.x = CLAY_ALIGN_X_CENTER},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .backgroundColor = {18, 24, 34, 255},
    }) {
        CLAY_AUTO_ID({
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(120), CLAY_SIZING_FIXED(28)},
                .childAlignment = {CLAY_ALIGN_X_CENTER, CLAY_ALIGN_Y_CENTER},
            },
            .backgroundColor = (*query_hovered = Clay_Hovered())
                                   ? (Clay_Color){45, 180, 95, 255}
                                   : (Clay_Color){180, 65, 55, 255},
        }) {
            ids.query_auto = Clay_GetOpenElementId();
        }

        CLAY(CLAY_ID("compression-row"), {
            .layout = {
                .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_FIXED(62)},
                .padding = {8, 6, 7, 5},
                .childGap = 5,
                .childAlignment = {.y = CLAY_ALIGN_Y_CENTER},
            },
            .backgroundColor = {35, 48, 66, 255},
        }) {
            CLAY_AUTO_ID({
                .layout = {.sizing = {CLAY_SIZING_FIXED(82), CLAY_SIZING_FIXED(24)}},
                .backgroundColor = {185, 75, 85, 255},
            }) {
                ids.row_auto = Clay_GetOpenElementId();
            }

            ids.local_fit = CLAY_ID_LOCAL("local-fit");
            CLAY(ids.local_fit, {
                .layout = {.sizing = {CLAY_SIZING_FIT(18, 62), CLAY_SIZING_FIXED(36)}},
                .backgroundColor = {195, 125, 55, 255},
            }) {
                CLAY_AUTO_ID({
                    .layout = {.sizing = {CLAY_SIZING_FIXED(88), CLAY_SIZING_FIXED(14)}},
                    .backgroundColor = {240, 190, 80, 255},
                }) {
                    ids.local_content_auto = Clay_GetOpenElementId();
                }
            }

            ids.indexed_global = CLAY_IDI("indexed-global", 7);
            CLAY(ids.indexed_global, {
                .layout = {.sizing = {CLAY_SIZING_GROW(20, 70), CLAY_SIZING_FIXED(34)}},
                .backgroundColor = {55, 145, 95, 255},
            }) {}

            ids.indexed_local = CLAY_IDI_LOCAL("indexed-local", 3);
            CLAY(ids.indexed_local, {
                .layout = {.sizing = {CLAY_SIZING_PERCENT(0.22f), CLAY_SIZING_FIXED(20)}},
                .backgroundColor = {45, 125, 170, 255},
            }) {}
        }

        CLAY(CLAY_ID("nested-column"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(190), CLAY_SIZING_GROW()},
                .padding = {9, 5, 4, 8},
                .childGap = 4,
                .childAlignment = {.x = CLAY_ALIGN_X_RIGHT},
                .layoutDirection = CLAY_TOP_TO_BOTTOM,
            },
            .backgroundColor = {40, 42, 76, 255},
        }) {
            CLAY(CLAY_ID("align-fit"), {
                .layout = {.sizing = {CLAY_SIZING_FIT(30, 110), CLAY_SIZING_FIT(16, 40)}},
                .backgroundColor = {115, 75, 165, 255},
            }) {
                ids.align_content = CLAY_ID_LOCAL("align-content");
                CLAY(ids.align_content, {
                    .layout = {.sizing = {CLAY_SIZING_FIXED(96), CLAY_SIZING_FIXED(52)}},
                    .backgroundColor = {165, 105, 205, 255},
                }) {}
            }

            CLAY(CLAY_ID("align-percent"), {
                .layout = {.sizing = {CLAY_SIZING_PERCENT(0.55f), CLAY_SIZING_FIXED(30)}},
                .backgroundColor = {60, 120, 175, 255},
            }) {}

            CLAY(CLAY_ID("align-grow"), {
                .layout = {.sizing = {CLAY_SIZING_GROW(44, 120), CLAY_SIZING_GROW(18, 70)}},
                .backgroundColor = {55, 155, 130, 255},
            }) {}
        }
    }

    return ids;
}

static FixtureIds run_frame(int frame, Clay_Dimensions dimensions) {
    Clay_SetLayoutDimensions(dimensions);
    Clay_BeginLayout();
    bool query_hovered = false;
    const FixtureIds ids = declare_layout(&query_hovered);
    Clay_RenderCommandArray commands = Clay_EndLayout(0.016f);

    printf("frame %d summary viewport %08x %08x commands %d hovered %d query-auto %u row-auto %u local-content-auto %u\n",
           frame,
           oracle_f32_bits(dimensions.width),
           oracle_f32_bits(dimensions.height),
           commands.length,
           query_hovered ? 1 : 0,
           ids.query_auto,
           ids.row_auto,
           ids.local_content_auto);
    print_id(frame, "local-fit", ids.local_fit);
    print_id(frame, "indexed-global", ids.indexed_global);
    print_id(frame, "indexed-local", ids.indexed_local);
    print_id(frame, "align-content", ids.align_content);

    print_box(frame, "root", CLAY_ID("declaration-layout-root").id);
    print_box(frame, "query-auto", ids.query_auto);
    print_box(frame, "compression-row", CLAY_ID("compression-row").id);
    print_box(frame, "row-auto", ids.row_auto);
    print_box(frame, "local-fit", ids.local_fit.id);
    print_box(frame, "local-content-auto", ids.local_content_auto);
    print_box(frame, "indexed-global", ids.indexed_global.id);
    print_box(frame, "indexed-local", ids.indexed_local.id);
    print_box(frame, "nested-column", CLAY_ID("nested-column").id);
    print_box(frame, "align-fit", CLAY_ID("align-fit").id);
    print_box(frame, "align-content", ids.align_content.id);
    print_box(frame, "align-percent", CLAY_ID("align-percent").id);
    print_box(frame, "align-grow", CLAY_ID("align-grow").id);

    for (int32_t index = 0; index < commands.length; ++index) {
        print_command(frame, index, Clay_RenderCommandArray_Get(&commands, index));
    }
    return ids;
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){310, 220}, (Clay_ErrorHandler){report_error, NULL});

    const FixtureIds frame0 = run_frame(0, (Clay_Dimensions){310, 220});
    const Clay_ElementData query = Clay_GetElementData((Clay_ElementId){.id = frame0.query_auto});
    Clay_SetPointerState((Clay_Vector2){
                             query.boundingBox.x + query.boundingBox.width * 0.5f,
                             query.boundingBox.y + query.boundingBox.height * 0.5f,
                         },
                         false);
    (void)run_frame(1, (Clay_Dimensions){310, 220});

    Clay_SetPointerState((Clay_Vector2){-50, -50}, false);
    (void)run_frame(2, (Clay_Dimensions){222, 150});
    (void)run_frame(3, (Clay_Dimensions){420, 260});

    free(memory);
    return 0;
}
