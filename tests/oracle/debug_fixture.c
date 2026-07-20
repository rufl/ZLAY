#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

static unsigned char image_payload;
static unsigned char custom_payload;
static bool inject_warning;

typedef struct ErrorLog {
    Clay_ErrorType types[32];
    int32_t length;
} ErrorLog;

typedef struct FixtureIds {
    Clay_ElementId root;
    Clay_ElementId parent;
    Clay_ElementId child;
    Clay_ElementId floating;
    Clay_ElementId text;
    Clay_ElementId panel;
    Clay_ElementId parentRow;
    Clay_ElementId childRow;
    Clay_ElementId collapse;
    Clay_ElementId highlight;
    Clay_ElementId highlightRectangle;
    Clay_ElementId scroll;
    Clay_ElementId close;
} FixtureIds;

static uint32_t f32_bits(float value) {
    uint32_t result = 0;
    memcpy(&result, &value, sizeof(result));
    return result;
}

static void record_error(Clay_ErrorData error) {
    ErrorLog *log = (ErrorLog *)error.userData;
    if (log->length >= 32) oracle_fail_log_overflow("debug diagnostics");
    log->types[log->length++] = error.errorType;
}

static Clay_Dimensions measure_text(Clay_StringSlice text, Clay_TextElementConfig *config, void *user_data) {
    (void)user_data;
    return (Clay_Dimensions){
        .width = (float)text.length * 8.0f,
        .height = config->fontSize == 0 ? 16.0f : (float)config->fontSize,
    };
}

static Clay_RenderCommandArray draw_frame(void) {
    Clay_BeginLayout();
    if (inject_warning) {
        Clay_Context *context = Clay_GetCurrentContext();
        Clay__WarningArray_Add(&context->warnings, (Clay__Warning){
            .baseMessage = CLAY_STRING("Injected warning: "),
            .dynamicMessage = CLAY_STRING("active payload"),
        });
    }
    CLAY(CLAY_ID("inspected-parent"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(200), CLAY_SIZING_FIXED(100)},
            .padding = CLAY_PADDING_ALL(4),
            .childGap = 2,
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .backgroundColor = {30, 60, 90, 255},
    }) {
        CLAY(CLAY_ID("inspected-child"), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(50), CLAY_SIZING_FIXED(30)}},
            .backgroundColor = {90, 60, 30, 255},
            .overlayColor = {14, 28, 42, 96},
            .cornerRadius = {1, 2, 3, 4},
            .aspectRatio = {.aspectRatio = 1.25f},
            .image = {.imageData = &image_payload},
            .clip = {.horizontal = true, .vertical = true},
            .border = {.color = {200, 120, 40, 255}, .width = {1, 2, 3, 4, 0}},
            .custom = {.customData = &custom_payload},
        }) {}
        CLAY_TEXT(
            CLAY_STRING("hello debug"),
            CLAY_TEXT_CONFIG({
                .textColor = {230, 220, 210, 255},
                .fontId = 7,
                .fontSize = 12,
                .letterSpacing = 3,
                .lineHeight = 19,
                .wrapMode = CLAY_TEXT_WRAP_NEWLINES,
                .textAlignment = CLAY_TEXT_ALIGN_RIGHT,
            }));
        CLAY(CLAY_ID("inspected-floating"), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(26), CLAY_SIZING_FIXED(18)}},
            .backgroundColor = {70, 80, 90, 255},
            .floating = {
                .offset = {11, 13},
                .expand = {3, 5},
                .parentId = CLAY_ID("inspected-parent").id,
                .zIndex = 9,
                .attachPoints = {CLAY_ATTACH_POINT_RIGHT_BOTTOM, CLAY_ATTACH_POINT_LEFT_TOP},
                .pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH,
                .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
                .clipTo = CLAY_CLIP_TO_NONE,
            },
        }) {}
    }
    return Clay_EndLayout(0.0f);
}

static bool text_equals(Clay_StringSlice text, const char *expected) {
    const size_t length = strlen(expected);
    return text.length == (int32_t)length && memcmp(text.chars, expected, length) == 0;
}

static int32_t count_text(Clay_RenderCommandArray *commands, const char *expected) {
    int32_t count = 0;
    for (int32_t index = 0; index < commands->length; ++index) {
        Clay_RenderCommand *command = Clay_RenderCommandArray_Get(commands, index);
        if (command->commandType == CLAY_RENDER_COMMAND_TYPE_TEXT && text_equals(command->renderData.text.stringContents, expected)) {
            count++;
        }
    }
    return count;
}

static void print_box(const char *label, Clay_ElementId id) {
    const Clay_ElementData data = Clay_GetElementData(id);
    printf("box %s found %d bits %u %u %u %u\n",
           label,
           data.found ? 1 : 0,
           f32_bits(data.boundingBox.x),
           f32_bits(data.boundingBox.y),
           f32_bits(data.boundingBox.width),
           f32_bits(data.boundingBox.height));
}

static void print_scroll(const char *label, Clay_ElementId id) {
    const Clay_ScrollContainerData data = Clay_GetScrollContainerData(id);
    const Clay_Vector2 position = data.scrollPosition ? *data.scrollPosition : (Clay_Vector2){0, 0};
    printf("scroll %s found %d pointer %d pos %u %u viewport %u %u content %u %u\n",
           label,
           data.found ? 1 : 0,
           data.scrollPosition ? 1 : 0,
           f32_bits(position.x),
           f32_bits(position.y),
           f32_bits(data.scrollContainerDimensions.width),
           f32_bits(data.scrollContainerDimensions.height),
           f32_bits(data.contentDimensions.width),
           f32_bits(data.contentDimensions.height));
}

static void print_errors(const ErrorLog *log) {
    printf("errors %d", (int)log->length);
    for (int32_t index = 0; index < log->length; ++index) printf(" %d", (int)log->types[index]);
    putchar('\n');
}

static void print_full_commands(int frame, Clay_RenderCommandArray *commands) {
    printf("full-frame %d enabled %d commands %d\n", frame, Clay_IsDebugModeEnabled() ? 1 : 0, (int)commands->length);
    for (int32_t index = 0; index < commands->length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(commands, index);
        printf("command %d %d type %d id %u z %d box %u %u %u %u user %d",
               frame,
               (int)index,
               (int)command->commandType,
               command->id,
               (int)command->zIndex,
               f32_bits(command->boundingBox.x),
               f32_bits(command->boundingBox.y),
               f32_bits(command->boundingBox.width),
               f32_bits(command->boundingBox.height),
               command->userData ? 1 : 0);
        if (command->commandType == CLAY_RENDER_COMMAND_TYPE_TEXT) {
            const Clay_StringSlice text = command->renderData.text.stringContents;
            printf(" text %d %.*s\n", (int)text.length, (int)text.length, text.chars);
        } else {
            puts(" text 0");
        }
    }
}

static void print_marker_command(const char *label, Clay_RenderCommandArray *commands, FixtureIds ids, bool selected_row) {
    int32_t count = 0;
    Clay_RenderCommand first = {0};
    for (int32_t index = 0; index < commands->length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(commands, index);
        if (command->commandType != CLAY_RENDER_COMMAND_TYPE_RECTANGLE) continue;
        bool matches = command->id == ids.highlightRectangle.id;
        if (selected_row) {
            const Clay_Color color = command->renderData.rectangle.backgroundColor;
            matches = color.r == 127.5f && color.g == 100.0f && color.b == 97.5f && color.a == 255.0f;
        }
        if (!matches) continue;
        if (count == 0) first = *command;
        count++;
    }
    printf("marker %s count %d id %u z %d box %u %u %u %u\n",
           label,
           (int)count,
           count ? first.id : 0,
           count ? (int)first.zIndex : 0,
           count ? f32_bits(first.boundingBox.x) : 0,
           count ? f32_bits(first.boundingBox.y) : 0,
           count ? f32_bits(first.boundingBox.width) : 0,
           count ? f32_bits(first.boundingBox.height) : 0);
}

static void print_state(const char *label, Clay_RenderCommandArray *commands, FixtureIds ids, const ErrorLog *errors) {
    printf("state %s enabled %d commands %d\n", label, Clay_IsDebugModeEnabled() ? 1 : 0, (int)commands->length);
    print_box("root", ids.root);
    print_box("panel", ids.panel);
    print_box("parent", ids.parent);
    print_box("child", ids.child);
    print_box("parent-row", ids.parentRow);
    print_box("child-row", ids.childRow);
    print_box("collapse", ids.collapse);
    print_box("highlight", ids.highlight);
    print_box("close", ids.close);
    printf("texts parent %d child %d plus %d minus %d details %d\n",
           (int)count_text(commands, "inspected-parent"),
           (int)count_text(commands, "inspected-child"),
           (int)count_text(commands, "+"),
           (int)count_text(commands, "-"),
           (int)count_text(commands, "Element Configuration"));
    print_marker_command("highlight", commands, ids, false);
    print_marker_command("selected-highlight-row", commands, ids, true);
    print_scroll(label, ids.scroll);
    print_errors(errors);
}

static Clay_Vector2 center_of(Clay_ElementId id) {
    const Clay_ElementData data = Clay_GetElementData(id);
    return (Clay_Vector2){
        data.boundingBox.x + data.boundingBox.width / 2.0f,
        data.boundingBox.y + data.boundingBox.height / 2.0f,
    };
}

int main(void) {
    ErrorLog error_log = {0};
    Clay_SetMaxElementCount(512);
    Clay_SetMaxMeasureTextCacheWordCount(2048);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){800, 400}, (Clay_ErrorHandler){record_error, &error_log});
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_SetDebugModeEnabled(true);

    FixtureIds ids = {0};
    ids.root = CLAY_ID("Clay__RootContainer");
    ids.parent = CLAY_ID("inspected-parent");
    ids.child = CLAY_ID("inspected-child");
    ids.floating = CLAY_ID("inspected-floating");
    ids.text = Clay__HashNumber(1, ids.parent.id);
    ids.panel = CLAY_ID("Clay__DebugView");
    ids.parentRow = CLAY_IDI("Clay__DebugView_ElementOuter", ids.parent.id);
    ids.childRow = CLAY_IDI("Clay__DebugView_ElementOuter", ids.child.id);
    ids.collapse = CLAY_IDI("Clay__DebugView_CollapseElement", ids.parent.id);
    ids.highlight = CLAY_ID("Clay__DebugView_ElementHighlight");
    ids.highlightRectangle = CLAY_ID("Clay__DebugView_ElementHighlightRectangle");
    ids.scroll = CLAY_ID("Clay__DebugViewOuterScrollPane");
    Clay_ElementId header = Clay__HashNumber(0, ids.panel.id);
    ids.close = Clay__HashNumber(2, header.id);

    Clay_SetPointerState((Clay_Vector2){0, 0}, false);
    Clay_SetPointerState((Clay_Vector2){0, 0}, false);

    Clay_RenderCommandArray commands = draw_frame();
    print_full_commands(0, &commands);
    print_state("initial", &commands, ids, &error_log);

    Clay_SetPointerState((Clay_Vector2){650, 65}, false);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, -2}, 0.016f);
    print_scroll("after-wheel", ids.scroll);
    commands = draw_frame();
    print_state("scrolled-highlight", &commands, ids, &error_log);

    Clay_SetPointerState((Clay_Vector2){650, 55}, true);
    commands = draw_frame();
    print_state("selected", &commands, ids, &error_log);
    print_full_commands(1, &commands);

    Clay_GetCurrentContext()->debugSelectedElementId = ids.child.id;
    Clay_SetPointerState((Clay_Vector2){0, 0}, false);
    commands = draw_frame();
    print_full_commands(2, &commands);

    Clay_GetCurrentContext()->debugSelectedElementId = ids.text.id;
    commands = draw_frame();
    print_full_commands(3, &commands);

    Clay_GetCurrentContext()->debugSelectedElementId = ids.floating.id;
    commands = draw_frame();
    print_full_commands(4, &commands);

    Clay_GetCurrentContext()->debugSelectedElementId = 0;
    inject_warning = true;
    commands = draw_frame();
    print_full_commands(5, &commands);
    inject_warning = false;

    const Clay_Vector2 collapse_point = center_of(ids.collapse);
    Clay_SetPointerState(collapse_point, false);
    Clay_SetPointerState(collapse_point, false);
    Clay_SetPointerState(collapse_point, true);
    commands = draw_frame();
    print_state("collapse-click", &commands, ids, &error_log);

    Clay_SetPointerState(collapse_point, false);
    commands = draw_frame();
    print_state("collapsed", &commands, ids, &error_log);

    const Clay_Vector2 close_point = center_of(ids.close);
    Clay_SetPointerState(close_point, false);
    Clay_SetPointerState(close_point, true);
    commands = draw_frame();
    print_state("close-press", &commands, ids, &error_log);

    Clay_SetPointerState(close_point, true);
    printf("close-callback enabled %d\n", Clay_IsDebugModeEnabled() ? 1 : 0);
    commands = draw_frame();
    print_state("closed", &commands, ids, &error_log);

    free(memory);
    return 0;
}
