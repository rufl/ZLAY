#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct HoverEvent {
    uint32_t id;
    Clay_PointerData pointer;
} HoverEvent;

typedef struct HoverLog {
    HoverEvent events[16];
    int32_t length;
} HoverLog;

static void record_hover(Clay_ElementId element_id, Clay_PointerData pointer, void *user_data) {
    HoverLog *log = (HoverLog *)user_data;
    if (log->length >= 16) oracle_fail_log_overflow("pointer hover");
    log->events[log->length++] = (HoverEvent){
        .id = element_id.id,
        .pointer = pointer,
    };
}

static void clear_hover_log(HoverLog *log) {
    log->length = 0;
}

static void print_hover_log(const char *label, const HoverLog *log) {
    printf("events %s %d", label, (int)log->length);
    for (int32_t index = 0; index < log->length; ++index) {
        const HoverEvent *event = &log->events[index];
        printf(" %u:%d:%u:%u",
               event->id,
               (int)event->pointer.state,
               oracle_f32_bits(event->pointer.position.x),
               oracle_f32_bits(event->pointer.position.y));
    }
    putchar('\n');
}

static void print_pointer(const char *label) {
    Clay_PointerData pointer = Clay_GetPointerState();
    Clay_ElementIdArray over = Clay_GetPointerOverIds();
    printf("pointer %s pos %u %u state %d over %d",
           label,
           oracle_f32_bits(pointer.position.x),
           oracle_f32_bits(pointer.position.y),
           (int)pointer.state,
           (int)over.length);
    for (int32_t index = 0; index < over.length; ++index) {
        Clay_ElementId *element_id = Clay_ElementIdArray_Get(&over, index);
        printf(" %u", element_id->id);
    }
    putchar('\n');
}

static void print_flags3(
    const char *label,
    const char *first_name,
    Clay_ElementId first,
    const char *second_name,
    Clay_ElementId second,
    const char *third_name,
    Clay_ElementId third
) {
    printf("flags %s %s %d %s %d %s %d\n",
           label,
           first_name,
           Clay_PointerOver(first) ? 1 : 0,
           second_name,
           Clay_PointerOver(second) ? 1 : 0,
           third_name,
           Clay_PointerOver(third) ? 1 : 0);
}

static void draw_nested_hover(HoverLog *log) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("hover-parent"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
        },
    }) {
        Clay_OnHover(record_hover, log);
        CLAY(CLAY_ID("hover-child"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(50), CLAY_SIZING_FIXED(50)},
            },
        }) {
            Clay_OnHover(record_hover, log);
        }
    }
    (void)Clay_EndLayout(0.0f);
}

static void draw_floating_stack(Clay_PointerCaptureMode high_capture_mode) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("base"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
        },
    }) {}
    CLAY(CLAY_ID("floating-low"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
        },
        .floating = {
            .zIndex = 5,
            .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
    }) {}
    CLAY(CLAY_ID("floating-high"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
        },
        .floating = {
            .zIndex = 10,
            .pointerCaptureMode = high_capture_mode,
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
    }) {}
    (void)Clay_EndLayout(0.0f);
}

static void draw_clipped_child(void) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("clip"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(40)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .clip = {.vertical = true},
    }) {
        CLAY(CLAY_ID("clipped-child"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
            },
        }) {}
    }
    (void)Clay_EndLayout(0.0f);
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){240, 160}, (Clay_ErrorHandler){oracle_fail_on_error, NULL});

    HoverLog hover_log = {0};
    Clay_ElementId root_id = CLAY_ID("Clay__RootContainer");
    Clay_ElementId parent_id = CLAY_ID("hover-parent");
    Clay_ElementId child_id = CLAY_ID("hover-child");
    Clay_ElementId base_id = CLAY_ID("base");
    Clay_ElementId low_id = CLAY_ID("floating-low");
    Clay_ElementId high_id = CLAY_ID("floating-high");
    Clay_ElementId clip_id = CLAY_ID("clip");
    Clay_ElementId clipped_child_id = CLAY_ID("clipped-child");

    print_pointer("initial");

    // Two released samples normalize the state before a layout exists. This
    // also proves that hit testing consumes only a completed prior frame.
    Clay_SetPointerState((Clay_Vector2){10, 10}, false);
    Clay_SetPointerState((Clay_Vector2){10, 10}, false);
    print_pointer("prelayout");
    print_flags3("prelayout", "root", root_id, "parent", parent_id, "child", child_id);

    draw_nested_hover(&hover_log);
    print_pointer("nested-before-input");

    clear_hover_log(&hover_log);
    Clay_SetPointerState((Clay_Vector2){10, 10}, true);
    print_hover_log("press", &hover_log);
    print_pointer("press");
    print_flags3("press", "root", root_id, "parent", parent_id, "child", child_id);

    clear_hover_log(&hover_log);
    Clay_SetPointerState((Clay_Vector2){10, 10}, true);
    print_hover_log("held", &hover_log);
    print_pointer("held");

    clear_hover_log(&hover_log);
    Clay_SetPointerState((Clay_Vector2){10, 10}, false);
    print_hover_log("release", &hover_log);
    print_pointer("release");

    clear_hover_log(&hover_log);
    Clay_SetPointerState((Clay_Vector2){10, 10}, false);
    print_hover_log("released", &hover_log);
    print_pointer("released");

    draw_floating_stack(CLAY_POINTER_CAPTURE_MODE_CAPTURE);
    Clay_SetPointerState((Clay_Vector2){10, 10}, false);
    print_pointer("floating-capture");
    print_flags3("floating-capture", "base", base_id, "low", low_id, "high", high_id);

    draw_floating_stack(CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH);
    Clay_SetPointerState((Clay_Vector2){10, 10}, false);
    print_pointer("floating-passthrough");
    print_flags3("floating-passthrough", "base", base_id, "low", low_id, "high", high_id);

    draw_clipped_child();
    Clay_SetPointerState((Clay_Vector2){10, 70}, false);
    print_pointer("clip-outside");
    print_flags3("clip-outside", "root", root_id, "clip", clip_id, "child", clipped_child_id);

    Clay_SetPointerState((Clay_Vector2){10, 20}, false);
    print_pointer("clip-inside");
    print_flags3("clip-inside", "root", root_id, "clip", clip_id, "child", clipped_child_id);

    free(memory);
    return 0;
}
