#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct QueryState {
    uint32_t outer_id;
    uint32_t inner_id;
    int round;
    int count;
    int calls[4];
} QueryState;

static Clay_Vector2 query_scroll_offset(uint32_t element_id, void *user_data) {
    QueryState *state = user_data;
    int token = 0;
    Clay_Vector2 result = {0, 0};
    if (element_id == state->outer_id) {
        token = 1;
        result = state->round == 1 ? (Clay_Vector2){-9, -11} : (Clay_Vector2){-7, -8};
    } else if (element_id == state->inner_id) {
        token = 2;
        result = state->round == 1 ? (Clay_Vector2){-21, -23} : (Clay_Vector2){-17, -18};
    }
    if (state->count >= 4) oracle_fail_log_overflow("external-scroll query");
    state->calls[state->count] = token;
    state->count++;
    return result;
}

static void reset_query(QueryState *state, int round) {
    state->round = round;
    state->count = 0;
    for (int index = 0; index < 4; ++index) state->calls[index] = 0;
}

static void print_query(const char *label, const QueryState *state) {
    printf("query %s round %d count %d", label, state->round, state->count);
    for (int index = 0; index < state->count; ++index) printf(" %d", state->calls[index]);
    putchar('\n');
}

static void print_scroll_data(const char *label, const char *name, Clay_ElementId id) {
    const Clay_ScrollContainerData data = Clay_GetScrollContainerData(id);
    const Clay_Vector2 position = data.scrollPosition ? *data.scrollPosition : (Clay_Vector2){0, 0};
    printf("data %s %s found %d pos %u %u viewport %u %u content %u %u config %d %d %u %u\n",
           label,
           name,
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
        printf(" %u", Clay_ElementIdArray_Get(&over, index)->id);
    }
    putchar('\n');
}

static bool box_is_zero(Clay_BoundingBox box) {
    return box.x == 0 && box.y == 0 && box.width == 0 && box.height == 0;
}

static bool print_commands(const char *label, Clay_RenderCommandArray commands) {
    printf("commands %s %d\n", label, commands.length);
    bool valid = true;
    for (int32_t index = 0; index < commands.length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        printf("command %s %d type %d id %u z %d box %u %u %u %u",
               label,
               (int)index,
               (int)command->commandType,
               command->id,
               (int)command->zIndex,
               oracle_f32_bits(command->boundingBox.x),
               oracle_f32_bits(command->boundingBox.y),
               oracle_f32_bits(command->boundingBox.width),
               oracle_f32_bits(command->boundingBox.height));
        switch (command->commandType) {
            case CLAY_RENDER_COMMAND_TYPE_RECTANGLE:
                printf(" rect %u %u %u %u",
                       oracle_f32_bits(command->renderData.rectangle.backgroundColor.r),
                       oracle_f32_bits(command->renderData.rectangle.backgroundColor.g),
                       oracle_f32_bits(command->renderData.rectangle.backgroundColor.b),
                       oracle_f32_bits(command->renderData.rectangle.backgroundColor.a));
                break;
            case CLAY_RENDER_COMMAND_TYPE_SCISSOR_START:
                printf(" clip %d %d",
                       command->renderData.clip.horizontal ? 1 : 0,
                       command->renderData.clip.vertical ? 1 : 0);
                break;
            case CLAY_RENDER_COMMAND_TYPE_SCISSOR_END: {
                const bool control_default = box_is_zero(command->boundingBox) && command->zIndex == 0;
                printf(" control-default %d", control_default ? 1 : 0);
                valid = valid && control_default;
                break;
            }
            default:
                break;
        }
        putchar('\n');
    }
    return valid;
}

static Clay_RenderCommandArray draw_layout(void) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("external-outer"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(120), CLAY_SIZING_FIXED(100)},
            .padding = CLAY_PADDING_ALL(5),
            .childGap = 4,
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .backgroundColor = {16, 30, 48, 255},
        .clip = {
            .horizontal = true,
            .vertical = true,
            .childOffset = Clay_GetScrollOffset(),
        },
    }) {
        CLAY(CLAY_ID("external-inner"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(60)},
                .padding = CLAY_PADDING_ALL(2),
                .layoutDirection = CLAY_TOP_TO_BOTTOM,
            },
            .backgroundColor = {30, 70, 90, 255},
            .clip = {
                .horizontal = true,
                .vertical = true,
                .childOffset = Clay_GetScrollOffset(),
            },
        }) {
            CLAY(CLAY_ID("external-inner-content"), {
                .layout = {.sizing = {CLAY_SIZING_FIXED(160), CLAY_SIZING_FIXED(180)}},
                .backgroundColor = {80, 130, 170, 255},
            }) {}
        }
        CLAY(CLAY_ID("external-outer-tail"), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(160), CLAY_SIZING_FIXED(120)}},
            .backgroundColor = {120, 75, 45, 255},
        }) {}
    }
    return Clay_EndLayout(0);
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){180, 140}, (Clay_ErrorHandler){oracle_fail_on_error, NULL});

    const Clay_ElementId outer_id = CLAY_ID("external-outer");
    const Clay_ElementId inner_id = CLAY_ID("external-inner");
    QueryState query_state = {
        .outer_id = outer_id.id,
        .inner_id = inner_id.id,
    };
    Clay_SetQueryScrollOffsetFunction(query_scroll_offset, &query_state);

    bool valid = true;
    Clay_RenderCommandArray commands = draw_layout();
    valid = print_commands("internal-initial", commands) && valid;
    print_scroll_data("internal-initial", "outer", outer_id);
    print_scroll_data("internal-initial", "inner", inner_id);

    Clay_SetPointerState((Clay_Vector2){20, 20}, false);
    print_pointer_over("internal-nested");
    Clay_UpdateScrollContainers(false, (Clay_Vector2){-1, -2}, 0.016f);
    print_scroll_data("internal-nested-wheel", "outer", outer_id);
    print_scroll_data("internal-nested-wheel", "inner", inner_id);

    commands = draw_layout();
    valid = print_commands("internal-scrolled", commands) && valid;
    print_scroll_data("internal-scrolled", "outer", outer_id);
    print_scroll_data("internal-scrolled", "inner", inner_id);

    Clay_SetExternalScrollHandlingEnabled(true);
    reset_query(&query_state, 1);
    commands = draw_layout();
    print_query("external-first", &query_state);
    valid = print_commands("external-first", commands) && valid;
    print_scroll_data("external-first", "outer", outer_id);
    print_scroll_data("external-first", "inner", inner_id);

    Clay_SetPointerState((Clay_Vector2){20, 20}, false);
    print_pointer_over("external-nested");
    Clay_UpdateScrollContainers(false, (Clay_Vector2){-1, -1}, 0.016f);
    print_scroll_data("external-nested-wheel", "outer", outer_id);
    print_scroll_data("external-nested-wheel", "inner", inner_id);

    reset_query(&query_state, 2);
    commands = draw_layout();
    print_query("external-second", &query_state);
    valid = print_commands("external-second", commands) && valid;
    print_scroll_data("external-second", "outer", outer_id);
    print_scroll_data("external-second", "inner", inner_id);

    free(memory);
    return valid ? 0 : 3;
}
