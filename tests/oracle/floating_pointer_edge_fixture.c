#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct ErrorLog {
    Clay_ErrorType types[64];
    int32_t length;
} ErrorLog;

typedef struct QueryLog {
    uint32_t calls[8];
    int32_t length;
} QueryLog;

static const Clay_FloatingAttachPointType ATTACH_POINTS[9] = {
    CLAY_ATTACH_POINT_LEFT_TOP,
    CLAY_ATTACH_POINT_LEFT_CENTER,
    CLAY_ATTACH_POINT_LEFT_BOTTOM,
    CLAY_ATTACH_POINT_CENTER_TOP,
    CLAY_ATTACH_POINT_CENTER_CENTER,
    CLAY_ATTACH_POINT_CENTER_BOTTOM,
    CLAY_ATTACH_POINT_RIGHT_TOP,
    CLAY_ATTACH_POINT_RIGHT_CENTER,
    CLAY_ATTACH_POINT_RIGHT_BOTTOM,
};

static void record_error(Clay_ErrorData error) {
    ErrorLog *log = (ErrorLog *)error.userData;
    if (log->length >= 64) oracle_fail_log_overflow("floating-pointer error");
    log->types[log->length++] = error.errorType;
    oracle_fail_on_error(error);
}

static Clay_Vector2 query_scroll_offset(uint32_t element_id, void *user_data) {
    QueryLog *log = (QueryLog *)user_data;
    if (log->length >= 8) oracle_fail_log_overflow("floating-pointer query");
    log->calls[log->length] = element_id;
    log->length++;
    return (Clay_Vector2){-11, 17};
}

static Clay_Color color(float r, float g, float b) {
    return (Clay_Color){r, g, b, 255};
}

static Clay_ElementDeclaration fixed_box(float width, float height, Clay_Color background) {
    return (Clay_ElementDeclaration){
        .layout = {.sizing = {CLAY_SIZING_FIXED(width), CLAY_SIZING_FIXED(height)}},
        .backgroundColor = background,
    };
}

static Clay_ElementDeclaration floating_box(
    float width,
    float height,
    Clay_Vector2 offset,
    uint32_t parent_id,
    int16_t z_index,
    Clay_FloatingAttachPointType element_point,
    Clay_FloatingAttachPointType parent_point,
    Clay_PointerCaptureMode capture_mode,
    Clay_FloatingAttachToElement attach_to,
    Clay_FloatingClipToElement clip_to,
    Clay_Color background
) {
    Clay_ElementDeclaration declaration = fixed_box(width, height, background);
    declaration.floating = (Clay_FloatingElementConfig){
        .offset = offset,
        .parentId = parent_id,
        .zIndex = z_index,
        .attachPoints = {.element = element_point, .parent = parent_point},
        .pointerCaptureMode = capture_mode,
        .attachTo = attach_to,
        .clipTo = clip_to,
    };
    return declaration;
}

static void print_command(const char *label, int32_t index, const Clay_RenderCommand *command) {
    printf("command %s %d type %d id %u z %d box %u %u %u %u\n",
           label,
           (int)index,
           (int)command->commandType,
           command->id,
           (int)command->zIndex,
           oracle_f32_bits(command->boundingBox.x),
           oracle_f32_bits(command->boundingBox.y),
           oracle_f32_bits(command->boundingBox.width),
           oracle_f32_bits(command->boundingBox.height));
}

static void print_commands(const char *label, Clay_RenderCommandArray commands) {
    printf("commands %s %d\n", label, (int)commands.length);
    for (int32_t index = 0; index < commands.length; ++index) {
        print_command(label, index, Clay_RenderCommandArray_Get(&commands, index));
    }
}

static void print_element(
    const char *label,
    int32_t first,
    int32_t second,
    Clay_ElementId id,
    Clay_RenderCommandArray commands
) {
    Clay_ElementData data = Clay_GetElementData(id);
    int32_t rectangle_count = 0;
    int32_t rectangle_index = -1;
    Clay_RenderCommand rectangle = {0};
    for (int32_t index = 0; index < commands.length; ++index) {
        Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        if (command->commandType != CLAY_RENDER_COMMAND_TYPE_RECTANGLE || command->id != id.id) continue;
        if (rectangle_count == 0) {
            rectangle = *command;
            rectangle_index = index;
        }
        rectangle_count++;
    }
    printf("element %s %d %d id %u found %d box %u %u %u %u rect %d index %d z %d box %u %u %u %u\n",
           label,
           (int)first,
           (int)second,
           id.id,
           data.found ? 1 : 0,
           oracle_f32_bits(data.boundingBox.x),
           oracle_f32_bits(data.boundingBox.y),
           oracle_f32_bits(data.boundingBox.width),
           oracle_f32_bits(data.boundingBox.height),
           (int)rectangle_count,
           (int)rectangle_index,
           rectangle_count ? (int)rectangle.zIndex : 0,
           rectangle_count ? oracle_f32_bits(rectangle.boundingBox.x) : 0,
           rectangle_count ? oracle_f32_bits(rectangle.boundingBox.y) : 0,
           rectangle_count ? oracle_f32_bits(rectangle.boundingBox.width) : 0,
           rectangle_count ? oracle_f32_bits(rectangle.boundingBox.height) : 0);
}

static void print_pointer(const char *label) {
    const Clay_PointerData pointer = Clay_GetPointerState();
    Clay_ElementIdArray over = Clay_GetPointerOverIds();
    printf("pointer %s pos %u %u state %d over %d",
           label,
           oracle_f32_bits(pointer.position.x),
           oracle_f32_bits(pointer.position.y),
           (int)pointer.state,
           (int)over.length);
    for (int32_t index = 0; index < over.length; ++index) {
        printf(" %u", Clay_ElementIdArray_Get(&over, index)->id);
    }
    putchar('\n');
}

static void print_query(const char *label, const QueryLog *log) {
    printf("query %s %d", label, (int)log->length);
    for (int32_t index = 0; index < log->length; ++index) printf(" %u", log->calls[index]);
    putchar('\n');
}

static void print_errors(const ErrorLog *log) {
    printf("errors %d", (int)log->length);
    for (int32_t index = 0; index < log->length; ++index) printf(" %d", (int)log->types[index]);
    putchar('\n');
}

static Clay_RenderCommandArray draw_attachment_matrix(void) {
    const Clay_ElementId anchor_id = CLAY_ID("floating-anchor");
    Clay_BeginLayout();

    CLAY(anchor_id, floating_box(
        80,
        60,
        (Clay_Vector2){100, 200},
        0,
        1,
        CLAY_ATTACH_POINT_LEFT_TOP,
        CLAY_ATTACH_POINT_LEFT_TOP,
        CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
        CLAY_ATTACH_TO_ROOT,
        CLAY_CLIP_TO_NONE,
        color(30, 50, 70))) {
        for (int32_t parent_index = 0; parent_index < 9; ++parent_index) {
            for (int32_t element_index = 0; element_index < 9; ++element_index) {
                const uint32_t index = (uint32_t)(parent_index * 9 + element_index);
                const Clay_ElementId matrix_id = Clay_GetElementIdWithIndex(CLAY_STRING("floating-matrix"), index);
                Clay_ElementDeclaration declaration = floating_box(
                    20,
                    10,
                    (Clay_Vector2){3, -4},
                    0,
                    2,
                    ATTACH_POINTS[element_index],
                    ATTACH_POINTS[parent_index],
                    CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
                    CLAY_ATTACH_TO_PARENT,
                    CLAY_CLIP_TO_NONE,
                    color((float)(20 + parent_index), (float)(40 + element_index), 90));
                CLAY(matrix_id, declaration) {}
            }
        }
    }

    CLAY(CLAY_ID("floating-root-probe"), floating_box(
        24,
        12,
        (Clay_Vector2){-5, 7},
        0,
        3,
        CLAY_ATTACH_POINT_LEFT_TOP,
        CLAY_ATTACH_POINT_CENTER_CENTER,
        CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
        CLAY_ATTACH_TO_ROOT,
        CLAY_CLIP_TO_ATTACHED_PARENT,
        color(100, 60, 30))) {}

    CLAY(CLAY_ID("floating-id-probe"), floating_box(
        16,
        14,
        (Clay_Vector2){2, -3},
        anchor_id.id,
        4,
        CLAY_ATTACH_POINT_CENTER_CENTER,
        CLAY_ATTACH_POINT_RIGHT_BOTTOM,
        CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
        CLAY_ATTACH_TO_ELEMENT_WITH_ID,
        CLAY_CLIP_TO_ATTACHED_PARENT,
        color(120, 80, 40))) {}

    return Clay_EndLayout(0);
}

static Clay_RenderCommandArray draw_clip_frame(void) {
    const Clay_ElementId clip_id = CLAY_ID("floating-clip");
    const Clay_ElementId target_id = CLAY_ID("floating-clip-target");
    Clay_BeginLayout();
    CLAY(clip_id, {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(40)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .backgroundColor = {15, 25, 35, 255},
        .clip = {
            .horizontal = true,
            .vertical = true,
            .childOffset = {-7, 13},
        },
    }) {
        CLAY(target_id, fixed_box(30, 20, color(45, 55, 65))) {}

        CLAY(CLAY_ID("floating-clip-parent"), floating_box(
            50,
            20,
            (Clay_Vector2){10, 50},
            0,
            6,
            CLAY_ATTACH_POINT_LEFT_TOP,
            CLAY_ATTACH_POINT_LEFT_TOP,
            CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
            CLAY_ATTACH_TO_PARENT,
            CLAY_CLIP_TO_ATTACHED_PARENT,
            color(70, 100, 130))) {}

        CLAY(CLAY_ID("floating-clip-none"), floating_box(
            50,
            20,
            (Clay_Vector2){10, 50},
            0,
            7,
            CLAY_ATTACH_POINT_LEFT_TOP,
            CLAY_ATTACH_POINT_LEFT_TOP,
            CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
            CLAY_ATTACH_TO_PARENT,
            CLAY_CLIP_TO_NONE,
            color(90, 120, 150))) {}
    }

    CLAY(CLAY_ID("floating-clip-id"), floating_box(
        45,
        18,
        (Clay_Vector2){20, 55},
        target_id.id,
        8,
        CLAY_ATTACH_POINT_LEFT_TOP,
        CLAY_ATTACH_POINT_LEFT_TOP,
        CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
        CLAY_ATTACH_TO_ELEMENT_WITH_ID,
        CLAY_CLIP_TO_ATTACHED_PARENT,
        color(110, 140, 170))) {}

    return Clay_EndLayout(0);
}

static Clay_RenderCommandArray draw_z_stack(Clay_PointerCaptureMode high_capture_mode) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("pointer-base"), fixed_box(100, 100, color(20, 30, 40))) {}
    CLAY(CLAY_ID("pointer-low"), floating_box(
        100,
        100,
        (Clay_Vector2){0, 0},
        0,
        5,
        CLAY_ATTACH_POINT_LEFT_TOP,
        CLAY_ATTACH_POINT_LEFT_TOP,
        CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
        CLAY_ATTACH_TO_ROOT,
        CLAY_CLIP_TO_NONE,
        color(50, 60, 70))) {}
    CLAY(CLAY_ID("pointer-high"), floating_box(
        100,
        100,
        (Clay_Vector2){0, 0},
        0,
        10,
        CLAY_ATTACH_POINT_LEFT_TOP,
        CLAY_ATTACH_POINT_LEFT_TOP,
        high_capture_mode,
        CLAY_ATTACH_TO_ROOT,
        CLAY_CLIP_TO_NONE,
        color(80, 90, 100))) {
        CLAY(CLAY_ID("pointer-high-child"), fixed_box(40, 40, color(110, 120, 130))) {}
    }
    return Clay_EndLayout(0);
}

int main(void) {
    ErrorLog errors = {0};
    QueryLog query = {0};

    Clay_SetMaxElementCount(256);
    Clay_SetMaxMeasureTextCacheWordCount(512);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    const Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){640, 480}, (Clay_ErrorHandler){record_error, &errors});
    Clay_SetQueryScrollOffsetFunction(query_scroll_offset, &query);

    Clay_SetPointerState((Clay_Vector2){0, 0}, false);
    Clay_SetPointerState((Clay_Vector2){0, 0}, false);
    print_pointer("normalized");

    Clay_RenderCommandArray commands = draw_attachment_matrix();
    print_commands("matrix", commands);
    for (int32_t parent_index = 0; parent_index < 9; ++parent_index) {
        for (int32_t element_index = 0; element_index < 9; ++element_index) {
            const uint32_t index = (uint32_t)(parent_index * 9 + element_index);
            print_element(
                "matrix",
                parent_index,
                element_index,
                Clay_GetElementIdWithIndex(CLAY_STRING("floating-matrix"), index),
                commands);
        }
    }
    print_element("anchor", -1, -1, CLAY_ID("floating-anchor"), commands);
    print_element("root", -1, -1, CLAY_ID("floating-root-probe"), commands);
    print_element("id", -1, -1, CLAY_ID("floating-id-probe"), commands);

    commands = draw_clip_frame();
    print_commands("clip-internal", commands);
    print_element("clip-target-internal", -1, -1, CLAY_ID("floating-clip-target"), commands);
    print_element("clip-parent-internal", -1, -1, CLAY_ID("floating-clip-parent"), commands);
    print_element("clip-none-internal", -1, -1, CLAY_ID("floating-clip-none"), commands);
    print_element("clip-id-internal", -1, -1, CLAY_ID("floating-clip-id"), commands);
    Clay_SetPointerState((Clay_Vector2){25, 69}, false);
    print_pointer("clip-internal-overlap");

    Clay_SetExternalScrollHandlingEnabled(true);
    query.length = 0;
    commands = draw_clip_frame();
    print_query("clip-external", &query);
    print_commands("clip-external", commands);
    print_element("clip-target-external", -1, -1, CLAY_ID("floating-clip-target"), commands);
    print_element("clip-parent-external", -1, -1, CLAY_ID("floating-clip-parent"), commands);
    print_element("clip-none-external", -1, -1, CLAY_ID("floating-clip-none"), commands);
    print_element("clip-id-external", -1, -1, CLAY_ID("floating-clip-id"), commands);
    Clay_SetPointerState((Clay_Vector2){15, 68}, false);
    print_pointer("clip-external-overlap");
    Clay_SetExternalScrollHandlingEnabled(false);

    commands = draw_z_stack(CLAY_POINTER_CAPTURE_MODE_CAPTURE);
    print_commands("z-capture", commands);
    Clay_SetPointerState((Clay_Vector2){10, 10}, true);
    print_pointer("capture-press");
    Clay_SetPointerState((Clay_Vector2){10, 10}, true);
    print_pointer("capture-held");
    Clay_SetPointerState((Clay_Vector2){10, 10}, false);
    print_pointer("capture-release");
    Clay_SetPointerState((Clay_Vector2){10, 10}, false);
    print_pointer("capture-released");
    Clay_SetPointerState((Clay_Vector2){100, 100}, false);
    print_pointer("capture-inclusive-edge");
    Clay_SetPointerState((Clay_Vector2){100.25f, 100}, false);
    print_pointer("capture-outside-edge");

    commands = draw_z_stack(CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH);
    print_commands("z-passthrough", commands);
    Clay_SetPointerState((Clay_Vector2){10, 10}, false);
    print_pointer("passthrough-overlap");
    Clay_SetPointerState((Clay_Vector2){40, 40}, false);
    print_pointer("passthrough-child-edge");
    Clay_SetPointerState((Clay_Vector2){40.25f, 40}, false);
    print_pointer("passthrough-child-outside");

    print_errors(&errors);
    free(memory);
    return errors.length == 0 ? 0 : 3;
}
