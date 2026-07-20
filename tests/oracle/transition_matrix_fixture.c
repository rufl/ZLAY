#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

#define ALL_TRANSITION_PROPERTIES ((Clay_TransitionProperty)(CLAY_TRANSITION_PROPERTY_BOUNDING_BOX | CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR | CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR | CLAY_TRANSITION_PROPERTY_CORNER_RADIUS | CLAY_TRANSITION_PROPERTY_BORDER))

typedef struct EventRecord {
    int tag;
    Clay_TransitionState state;
    Clay_TransitionProperty properties;
    float elapsed;
    float duration;
    Clay_TransitionData current;
} EventRecord;

static EventRecord events[64];
static int event_count = 0;
static int enter_skip_setters = 0;
static int enter_trigger_setters = 0;
static int parent_skip_finals = 0;
static int parent_trigger_finals = 0;
static int order_under_finals = 0;
static int order_natural_finals = 0;
static int order_above_finals = 0;

static Clay_Color color(float r, float g, float b, float a) {
    return (Clay_Color){r, g, b, a};
}

static float lerp(float initial, float target, float ratio) {
    return initial + (target - initial) * ratio;
}

static uint16_t lerp_width(uint16_t initial, uint16_t target, float ratio) {
    return (uint16_t)lerp((float)initial, (float)target, ratio);
}

static Clay_Color lerp_color(Clay_Color initial, Clay_Color target, float ratio) {
    return (Clay_Color){
        lerp(initial.r, target.r, ratio),
        lerp(initial.g, target.g, ratio),
        lerp(initial.b, target.b, ratio),
        lerp(initial.a, target.a, ratio),
    };
}

static bool matrix_handler(Clay_TransitionCallbackArguments arguments, int tag) {
    float ratio = arguments.duration > 0 ? arguments.elapsedTime / arguments.duration : 1;
    if (ratio > 1) ratio = 1;

    arguments.current->boundingBox.x = lerp(arguments.initial.boundingBox.x, arguments.target.boundingBox.x, ratio);
    arguments.current->boundingBox.y = lerp(arguments.initial.boundingBox.y, arguments.target.boundingBox.y, ratio);
    arguments.current->boundingBox.width = lerp(arguments.initial.boundingBox.width, arguments.target.boundingBox.width, ratio);
    arguments.current->boundingBox.height = lerp(arguments.initial.boundingBox.height, arguments.target.boundingBox.height, ratio);
    arguments.current->backgroundColor = lerp_color(arguments.initial.backgroundColor, arguments.target.backgroundColor, ratio);
    arguments.current->overlayColor = lerp_color(arguments.initial.overlayColor, arguments.target.overlayColor, ratio);
    arguments.current->borderColor = lerp_color(arguments.initial.borderColor, arguments.target.borderColor, ratio);
    arguments.current->borderWidth.left = lerp_width(arguments.initial.borderWidth.left, arguments.target.borderWidth.left, ratio);
    arguments.current->borderWidth.right = lerp_width(arguments.initial.borderWidth.right, arguments.target.borderWidth.right, ratio);
    arguments.current->borderWidth.top = lerp_width(arguments.initial.borderWidth.top, arguments.target.borderWidth.top, ratio);
    arguments.current->borderWidth.bottom = lerp_width(arguments.initial.borderWidth.bottom, arguments.target.borderWidth.bottom, ratio);
    arguments.current->borderWidth.betweenChildren = lerp_width(arguments.initial.borderWidth.betweenChildren, arguments.target.borderWidth.betweenChildren, ratio);

    if (event_count >= (int)(sizeof(events) / sizeof(events[0]))) {
        oracle_fail_log_overflow("transition-matrix event");
    }
    events[event_count++] = (EventRecord){
        tag,
        arguments.transitionState,
        arguments.properties,
        arguments.elapsedTime,
        arguments.duration,
        *arguments.current,
    };
    return arguments.elapsedTime >= arguments.duration;
}

#define DEFINE_HANDLER(name, tag)                                  \
    static bool name(Clay_TransitionCallbackArguments arguments) { \
        return matrix_handler(arguments, tag);                     \
    }

DEFINE_HANDLER(all_handler, 1)
DEFINE_HANDLER(zero_handler, 2)
DEFINE_HANDLER(corner_handler, 3)
DEFINE_HANDLER(resize_handler, 4)
DEFINE_HANDLER(enter_skip_handler, 5)
DEFINE_HANDLER(enter_trigger_handler, 6)
DEFINE_HANDLER(move_block_handler, 7)
DEFINE_HANDLER(move_allow_handler, 8)
DEFINE_HANDLER(parent_skip_handler, 9)
DEFINE_HANDLER(parent_trigger_handler, 10)
DEFINE_HANDLER(order_under_handler, 11)
DEFINE_HANDLER(order_natural_handler, 12)
DEFINE_HANDLER(order_above_handler, 13)
DEFINE_HANDLER(interaction_block_handler, 14)
DEFINE_HANDLER(interaction_allow_handler, 15)

#undef DEFINE_HANDLER

static Clay_TransitionData enter_skip_initial(Clay_TransitionData target, Clay_TransitionProperty properties) {
    (void)properties;
    enter_skip_setters++;
    target.backgroundColor = color(0, 0, 0, 255);
    return target;
}

static Clay_TransitionData enter_trigger_initial(Clay_TransitionData target, Clay_TransitionProperty properties) {
    (void)properties;
    enter_trigger_setters++;
    target.backgroundColor = color(0, 0, 0, 255);
    return target;
}

static Clay_TransitionData interaction_initial(Clay_TransitionData target, Clay_TransitionProperty properties) {
    (void)properties;
    target.boundingBox.x -= 12;
    return target;
}

static Clay_TransitionData parent_skip_final(Clay_TransitionData current, Clay_TransitionProperty properties) {
    (void)properties;
    parent_skip_finals++;
    current.backgroundColor = color(220, 30, 30, 255);
    return current;
}

static Clay_TransitionData parent_trigger_final(Clay_TransitionData current, Clay_TransitionProperty properties) {
    (void)properties;
    parent_trigger_finals++;
    current.backgroundColor = color(220, 30, 30, 255);
    return current;
}

static Clay_TransitionData order_under_final(Clay_TransitionData current, Clay_TransitionProperty properties) {
    (void)properties;
    order_under_finals++;
    current.backgroundColor = color(200, 20, 120, 255);
    return current;
}

static Clay_TransitionData order_natural_final(Clay_TransitionData current, Clay_TransitionProperty properties) {
    (void)properties;
    order_natural_finals++;
    current.backgroundColor = color(200, 20, 120, 255);
    return current;
}

static Clay_TransitionData order_above_final(Clay_TransitionData current, Clay_TransitionProperty properties) {
    (void)properties;
    order_above_finals++;
    current.backgroundColor = color(200, 20, 120, 255);
    return current;
}

static Clay_Dimensions measure_text(Clay_StringSlice text, Clay_TextElementConfig *config, void *user_data) {
    (void)user_data;
    return (Clay_Dimensions){(float)text.length * 5.0f, (float)config->fontSize};
}

static Clay_ElementDeclaration fixed_box(float width, float height, Clay_Color background) {
    return (Clay_ElementDeclaration){
        .layout = {.sizing = {CLAY_SIZING_FIXED(width), CLAY_SIZING_FIXED(height)}},
        .backgroundColor = background,
    };
}

static Clay_TransitionElementConfig base_transition(
    bool (*handler)(Clay_TransitionCallbackArguments),
    float duration,
    Clay_TransitionProperty properties) {
    return (Clay_TransitionElementConfig){
        .handler = handler,
        .duration = duration,
        .properties = properties,
    };
}

static Clay_ElementDeclaration floating_parent(const char *unused, float x, float y, float width, float height) {
    (void)unused;
    Clay_ElementDeclaration declaration = fixed_box(width, height, (Clay_Color){0});
    declaration.layout.padding = CLAY_PADDING_ALL(2);
    declaration.layout.childGap = 2;
    declaration.layout.layoutDirection = CLAY_TOP_TO_BOTTOM;
    declaration.floating.offset = (Clay_Vector2){x, y};
    declaration.floating.attachTo = CLAY_ATTACH_TO_ROOT;
    declaration.floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
    return declaration;
}

static Clay_ElementDeclaration all_declaration(bool changed) {
    Clay_ElementDeclaration declaration = fixed_box(
        changed ? 34 : 20,
        changed ? 24 : 16,
        changed ? color(180, 90, 30, 255) : color(20, 40, 60, 255));
    declaration.overlayColor = changed ? color(90, 20, 140, 128) : color(10, 30, 50, 64);
    declaration.cornerRadius = CLAY_CORNER_RADIUS(changed ? 9 : 2);
    declaration.border.color = changed ? color(230, 180, 40, 255) : color(80, 120, 160, 255);
    declaration.border.width = changed ? (Clay_BorderWidth){5, 6, 7, 8, 2} : (Clay_BorderWidth){1, 2, 3, 4, 0};
    declaration.floating.offset = changed ? (Clay_Vector2){52, 24} : (Clay_Vector2){8, 8};
    declaration.floating.zIndex = 4;
    declaration.floating.attachTo = CLAY_ATTACH_TO_ROOT;
    declaration.transition = base_transition(all_handler, 1, ALL_TRANSITION_PROPERTIES);
    return declaration;
}

static Clay_ElementDeclaration zero_declaration(bool changed) {
    Clay_ElementDeclaration declaration = fixed_box(20, 14, changed ? color(20, 210, 80, 255) : color(200, 40, 40, 255));
    declaration.cornerRadius = CLAY_CORNER_RADIUS(3);
    declaration.floating.offset = (Clay_Vector2){105, 8};
    declaration.floating.zIndex = 3;
    declaration.floating.attachTo = CLAY_ATTACH_TO_ROOT;
    declaration.transition = base_transition(zero_handler, 0, CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR);
    return declaration;
}

static Clay_ElementDeclaration corner_declaration(bool changed) {
    Clay_ElementDeclaration declaration = fixed_box(20, 14, color(90, 80, 180, 255));
    declaration.cornerRadius = CLAY_CORNER_RADIUS(changed ? 11 : 1);
    declaration.floating.offset = (Clay_Vector2){135, 8};
    declaration.floating.zIndex = 2;
    declaration.floating.attachTo = CLAY_ATTACH_TO_ROOT;
    declaration.transition = base_transition(corner_handler, 1, CLAY_TRANSITION_PROPERTY_CORNER_RADIUS);
    return declaration;
}

static Clay_ElementDeclaration resize_declaration(void) {
    Clay_ElementDeclaration declaration = {
        .layout = {.sizing = {CLAY_SIZING_PERCENT(0.25f), CLAY_SIZING_FIXED(10)}},
        .backgroundColor = {30, 150, 180, 255},
    };
    declaration.floating.offset = (Clay_Vector2){0, 238};
    declaration.floating.zIndex = 1;
    declaration.floating.attachTo = CLAY_ATTACH_TO_ROOT;
    declaration.transition = base_transition(resize_handler, 1, CLAY_TRANSITION_PROPERTY_WIDTH);
    return declaration;
}

static Clay_ElementDeclaration interaction_declaration(bool allow) {
    Clay_ElementDeclaration declaration = fixed_box(
        20,
        12,
        allow ? color(30, 210, 170, 255) : color(220, 80, 150, 255));
    declaration.floating.offset = allow ? (Clay_Vector2){230, 90} : (Clay_Vector2){200, 90};
    declaration.floating.zIndex = 5;
    declaration.floating.attachTo = CLAY_ATTACH_TO_ROOT;
    declaration.transition = base_transition(
        allow ? interaction_allow_handler : interaction_block_handler,
        1,
        CLAY_TRANSITION_PROPERTY_X);
    declaration.transition.interactionHandling = allow
                                                     ? CLAY_TRANSITION_ALLOW_INTERACTIONS_WHILE_TRANSITIONING_POSITION
                                                     : CLAY_TRANSITION_DISABLE_INTERACTIONS_WHILE_TRANSITIONING_POSITION;
    declaration.transition.enter.setInitialState = interaction_initial;
    declaration.transition.enter.trigger = CLAY_TRANSITION_ENTER_TRIGGER_ON_FIRST_PARENT_FRAME;
    return declaration;
}

static Clay_ElementDeclaration enter_child(
    bool trigger,
    Clay_Color target) {
    Clay_ElementDeclaration declaration = fixed_box(44, 16, target);
    declaration.transition = base_transition(
        trigger ? enter_trigger_handler : enter_skip_handler,
        0.5f,
        CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR);
    declaration.transition.enter.setInitialState = trigger ? enter_trigger_initial : enter_skip_initial;
    declaration.transition.enter.trigger = trigger ? CLAY_TRANSITION_ENTER_TRIGGER_ON_FIRST_PARENT_FRAME : CLAY_TRANSITION_ENTER_SKIP_ON_FIRST_PARENT_FRAME;
    return declaration;
}

static Clay_ElementDeclaration move_child(bool allow) {
    Clay_ElementDeclaration declaration = fixed_box(
        20,
        10,
        allow ? color(40, 180, 90, 255) : color(190, 80, 40, 255));
    declaration.transition = base_transition(
        allow ? move_allow_handler : move_block_handler,
        0.75f,
        CLAY_TRANSITION_PROPERTY_POSITION);
    declaration.transition.interactionHandling = allow
                                                     ? CLAY_TRANSITION_ALLOW_INTERACTIONS_WHILE_TRANSITIONING_POSITION
                                                     : CLAY_TRANSITION_DISABLE_INTERACTIONS_WHILE_TRANSITIONING_POSITION;
    return declaration;
}

static Clay_ElementDeclaration parent_exit_child(bool trigger) {
    Clay_ElementDeclaration declaration = fixed_box(
        42,
        14,
        trigger ? color(40, 130, 210, 255) : color(170, 120, 30, 255));
    declaration.transition = base_transition(
        trigger ? parent_trigger_handler : parent_skip_handler,
        0.5f,
        CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR);
    declaration.transition.exit.setFinalState = trigger ? parent_trigger_final : parent_skip_final;
    declaration.transition.exit.trigger = trigger ? CLAY_TRANSITION_EXIT_TRIGGER_WHEN_PARENT_EXITS : CLAY_TRANSITION_EXIT_SKIP_WHEN_PARENT_EXITS;
    declaration.transition.exit.siblingOrdering = CLAY_EXIT_TRANSITION_ORDERING_NATURAL_ORDER;
    return declaration;
}

static Clay_ElementDeclaration order_exit_child(int ordering) {
    Clay_ElementDeclaration declaration = fixed_box(60, 14, color(40, 170, 70, 255));
    bool (*handler)(Clay_TransitionCallbackArguments) = order_under_handler;
    Clay_TransitionData (*final_state)(Clay_TransitionData, Clay_TransitionProperty) = order_under_final;
    Clay_ExitTransitionSiblingOrdering sibling_ordering = CLAY_EXIT_TRANSITION_ORDERING_UNDERNEATH_SIBLINGS;
    if (ordering == 1) {
        handler = order_natural_handler;
        final_state = order_natural_final;
        sibling_ordering = CLAY_EXIT_TRANSITION_ORDERING_NATURAL_ORDER;
    } else if (ordering == 2) {
        handler = order_above_handler;
        final_state = order_above_final;
        sibling_ordering = CLAY_EXIT_TRANSITION_ORDERING_ABOVE_SIBLINGS;
    }
    declaration.transition = base_transition(handler, 0.5f, CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR);
    declaration.transition.exit.setFinalState = final_state;
    declaration.transition.exit.trigger = CLAY_TRANSITION_EXIT_SKIP_WHEN_PARENT_EXITS;
    declaration.transition.exit.siblingOrdering = sibling_ordering;
    return declaration;
}

static void declare_order_row(const char *unused, int ordering, bool show_removed) {
    (void)unused;
    const float y = 148.0f + (float)ordering * 28.0f;
    Clay_ElementId row_id = ordering == 0 ? CLAY_ID("order-under-row") : (ordering == 1 ? CLAY_ID("order-natural-row") : CLAY_ID("order-above-row"));
    Clay_ElementId first_id = ordering == 0 ? CLAY_ID("order-under-first") : (ordering == 1 ? CLAY_ID("order-natural-first") : CLAY_ID("order-above-first"));
    Clay_ElementId removed_id = ordering == 0 ? CLAY_ID("order-under-removed") : (ordering == 1 ? CLAY_ID("order-natural-removed") : CLAY_ID("order-above-removed"));
    Clay_ElementId last_id = ordering == 0 ? CLAY_ID("order-under-last") : (ordering == 1 ? CLAY_ID("order-natural-last") : CLAY_ID("order-above-last"));

    CLAY(row_id, floating_parent("order", 0, y, 140, 18)) {
        CLAY(first_id, fixed_box(10, 14, color(190, 40, 40, 255))) {}
        if (show_removed) {
            CLAY(removed_id, order_exit_child(ordering)) {
                if (ordering == 1) {
                    CLAY_TEXT(CLAY_STRING("retained text"), CLAY_TEXT_CONFIG({
                        .textColor = {240, 240, 255, 255},
                        .fontSize = 7,
                        .wrapMode = CLAY_TEXT_WRAP_NONE,
                    }));
                }
            }
        }
        CLAY(last_id, fixed_box(10, 14, color(40, 70, 200, 255))) {}
    }
}

static void declare_layout(int frame) {
    const bool changed = frame >= 1;
    const bool reparented = frame >= 1;
    const bool show_parent_exit = frame < 4;
    const bool show_order_removed = frame < 4;

    CLAY(CLAY_ID("all-props"), all_declaration(changed)) {}
    CLAY(CLAY_ID("zero-duration"), zero_declaration(changed)) {}
    CLAY(CLAY_ID("corner-noop"), corner_declaration(changed)) {}
    if (frame >= 1) {
        CLAY(CLAY_ID("interaction-block"), interaction_declaration(false)) {}
        CLAY(CLAY_ID("interaction-allow"), interaction_declaration(true)) {}
    }

    CLAY(CLAY_ID("enter-parent"), floating_parent("enter", 0, 48, 110, 24)) {
        CLAY(CLAY_ID("enter-skip"), enter_child(false, color(40, 170, 80, 255))) {}
        CLAY(CLAY_ID("enter-trigger"), enter_child(true, color(40, 90, 210, 255))) {}
    }

    CLAY(CLAY_ID("move-source"), floating_parent("source", 180, 48, 70, 30)) {
        if (!reparented) {
            CLAY(CLAY_ID("move-block"), move_child(false)) {}
            CLAY(CLAY_ID("move-allow"), move_child(true)) {}
        }
    }
    CLAY(CLAY_ID("move-destination"), floating_parent("destination", 270, 48, 70, 30)) {
        if (reparented) {
            CLAY(CLAY_ID("move-block"), move_child(false)) {}
            CLAY(CLAY_ID("move-allow"), move_child(true)) {}
        }
    }

    if (show_parent_exit) {
        CLAY(CLAY_ID("parent-skip"), floating_parent("parent-skip", 0, 100, 80, 22)) {
            CLAY(CLAY_ID("parent-skip-child"), parent_exit_child(false)) {}
        }
        CLAY(CLAY_ID("parent-trigger"), floating_parent("parent-trigger", 100, 100, 80, 22)) {
            CLAY(CLAY_ID("parent-trigger-child"), parent_exit_child(true)) {}
        }
    }

    declare_order_row("under", 0, show_order_removed);
    declare_order_row("natural", 1, show_order_removed);
    declare_order_row("above", 2, show_order_removed);
    CLAY(CLAY_ID("resize-suppressed"), resize_declaration()) {}
}

static void print_transition_data(const Clay_TransitionData *data) {
    printf("box %u %u %u %u bg %u %u %u %u ov %u %u %u %u border %u %u %u %u width %u %u %u %u %u",
           oracle_f32_bits(data->boundingBox.x),
           oracle_f32_bits(data->boundingBox.y),
           oracle_f32_bits(data->boundingBox.width),
           oracle_f32_bits(data->boundingBox.height),
           oracle_f32_bits(data->backgroundColor.r),
           oracle_f32_bits(data->backgroundColor.g),
           oracle_f32_bits(data->backgroundColor.b),
           oracle_f32_bits(data->backgroundColor.a),
           oracle_f32_bits(data->overlayColor.r),
           oracle_f32_bits(data->overlayColor.g),
           oracle_f32_bits(data->overlayColor.b),
           oracle_f32_bits(data->overlayColor.a),
           oracle_f32_bits(data->borderColor.r),
           oracle_f32_bits(data->borderColor.g),
           oracle_f32_bits(data->borderColor.b),
           oracle_f32_bits(data->borderColor.a),
           data->borderWidth.left,
           data->borderWidth.right,
           data->borderWidth.top,
           data->borderWidth.bottom,
           data->borderWidth.betweenChildren);
}

static bool box_is_zero(Clay_BoundingBox box) {
    return box.x == 0 && box.y == 0 && box.width == 0 && box.height == 0;
}

static void print_command(int frame, int32_t index, const Clay_RenderCommand *command) {
    printf("frame %d command %d type %d id %u z %d box %u %u %u %u",
           frame,
           (int)index,
           (int)command->commandType,
           command->id,
           (int)command->zIndex,
           oracle_f32_bits(command->boundingBox.x),
           oracle_f32_bits(command->boundingBox.y),
           oracle_f32_bits(command->boundingBox.width),
           oracle_f32_bits(command->boundingBox.height));
    switch (command->commandType) {
        case CLAY_RENDER_COMMAND_TYPE_RECTANGLE: {
            const Clay_RectangleRenderData rectangle = command->renderData.rectangle;
            printf(" rect %u %u %u %u radius %u %u %u %u",
                   oracle_f32_bits(rectangle.backgroundColor.r),
                   oracle_f32_bits(rectangle.backgroundColor.g),
                   oracle_f32_bits(rectangle.backgroundColor.b),
                   oracle_f32_bits(rectangle.backgroundColor.a),
                   oracle_f32_bits(rectangle.cornerRadius.topLeft),
                   oracle_f32_bits(rectangle.cornerRadius.topRight),
                   oracle_f32_bits(rectangle.cornerRadius.bottomLeft),
                   oracle_f32_bits(rectangle.cornerRadius.bottomRight));
            break;
        }
        case CLAY_RENDER_COMMAND_TYPE_BORDER: {
            const Clay_BorderRenderData border = command->renderData.border;
            printf(" border %u %u %u %u radius %u %u %u %u width %u %u %u %u %u",
                   oracle_f32_bits(border.color.r),
                   oracle_f32_bits(border.color.g),
                   oracle_f32_bits(border.color.b),
                   oracle_f32_bits(border.color.a),
                   oracle_f32_bits(border.cornerRadius.topLeft),
                   oracle_f32_bits(border.cornerRadius.topRight),
                   oracle_f32_bits(border.cornerRadius.bottomLeft),
                   oracle_f32_bits(border.cornerRadius.bottomRight),
                   border.width.left,
                   border.width.right,
                   border.width.top,
                   border.width.bottom,
                   border.width.betweenChildren);
            break;
        }
        case CLAY_RENDER_COMMAND_TYPE_TEXT: {
            const Clay_TextRenderData text = command->renderData.text;
            printf(" text %d \"%.*s\" rgba %u %u %u %u font %u %u spacing %u line %u",
                   text.stringContents.length,
                   text.stringContents.length,
                   text.stringContents.chars,
                   oracle_f32_bits(text.textColor.r),
                   oracle_f32_bits(text.textColor.g),
                   oracle_f32_bits(text.textColor.b),
                   oracle_f32_bits(text.textColor.a),
                   text.fontId,
                   text.fontSize,
                   text.letterSpacing,
                   text.lineHeight);
            break;
        }
        case CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START: {
            const Clay_Color overlay = command->renderData.overlayColor.color;
            printf(" overlay %u %u %u %u control-default %d",
                   oracle_f32_bits(overlay.r),
                   oracle_f32_bits(overlay.g),
                   oracle_f32_bits(overlay.b),
                   oracle_f32_bits(overlay.a),
                   box_is_zero(command->boundingBox) && command->zIndex == 0 ? 1 : 0);
            break;
        }
        case CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END:
            printf(" control-default %d", box_is_zero(command->boundingBox) && command->zIndex == 0 ? 1 : 0);
            break;
        default:
            break;
    }
    putchar('\n');
}

static void print_status(int frame, const char *name, Clay_ElementId id) {
    const Clay_ElementData data = Clay_GetElementData(id);
    printf("frame %d status %s found %d box %u %u %u %u\n",
           frame,
           name,
           data.found ? 1 : 0,
           oracle_f32_bits(data.boundingBox.x),
           oracle_f32_bits(data.boundingBox.y),
           oracle_f32_bits(data.boundingBox.width),
           oracle_f32_bits(data.boundingBox.height));
}

static bool pointer_over_center(Clay_ElementId id) {
    const Clay_ElementData data = Clay_GetElementData(id);
    if (!data.found) return false;
    Clay_SetPointerState((Clay_Vector2){
                             data.boundingBox.x + data.boundingBox.width / 2,
                             data.boundingBox.y + data.boundingBox.height / 2,
                         },
                         false);
    return Clay_PointerOver(id);
}

static bool pointer_over_at(Clay_ElementId id, float x, float y) {
    Clay_SetPointerState((Clay_Vector2){x, y}, false);
    return Clay_PointerOver(id);
}

static void run_frame(int frame, float delta_time) {
    event_count = 0;
    if (frame == 3) Clay_SetLayoutDimensions((Clay_Dimensions){360, 260});

    Clay_BeginLayout();
    declare_layout(frame);
    Clay_RenderCommandArray commands = Clay_EndLayout(delta_time);
    Clay_Dimensions dimensions = Clay_GetLayoutDimensions();

    printf("frame %d summary viewport %u %u commands %d events %d setters %d %d parent-finals %d %d order-finals %d %d %d\n",
           frame,
           oracle_f32_bits(dimensions.width),
           oracle_f32_bits(dimensions.height),
           commands.length,
           event_count,
           enter_skip_setters,
           enter_trigger_setters,
           parent_skip_finals,
           parent_trigger_finals,
           order_under_finals,
           order_natural_finals,
           order_above_finals);

    for (int index = 0; index < event_count; ++index) {
        const EventRecord *event = &events[index];
        printf("frame %d event %d tag %d state %d properties %d elapsed %u duration %u ",
               frame,
               index,
               event->tag,
               (int)event->state,
               (int)event->properties,
               oracle_f32_bits(event->elapsed),
               oracle_f32_bits(event->duration));
        print_transition_data(&event->current);
        putchar('\n');
    }

#define PRINT_STATUS(name) print_status(frame, name, CLAY_ID(name))
    PRINT_STATUS("all-props");
    PRINT_STATUS("zero-duration");
    PRINT_STATUS("corner-noop");
    PRINT_STATUS("resize-suppressed");
    PRINT_STATUS("enter-skip");
    PRINT_STATUS("enter-trigger");
    PRINT_STATUS("move-block");
    PRINT_STATUS("move-allow");
    PRINT_STATUS("interaction-block");
    PRINT_STATUS("interaction-allow");
    PRINT_STATUS("parent-skip-child");
    PRINT_STATUS("parent-trigger-child");
    PRINT_STATUS("order-under-removed");
    PRINT_STATUS("order-natural-removed");
    PRINT_STATUS("order-above-removed");
#undef PRINT_STATUS

    printf("frame %d hit move-block-current %d move-allow-current %d move-block-target %d move-allow-target %d interaction-block %d interaction-allow %d parent-trigger-exit %d natural-exit %d\n",
           frame,
           pointer_over_center(CLAY_ID("move-block")) ? 1 : 0,
           pointer_over_center(CLAY_ID("move-allow")) ? 1 : 0,
           pointer_over_at(CLAY_ID("move-block"), frame == 0 ? 192 : 282, 55) ? 1 : 0,
           pointer_over_at(CLAY_ID("move-allow"), frame == 0 ? 192 : 282, 67) ? 1 : 0,
           pointer_over_center(CLAY_ID("interaction-block")) ? 1 : 0,
           pointer_over_center(CLAY_ID("interaction-allow")) ? 1 : 0,
           pointer_over_center(CLAY_ID("parent-trigger-child")) ? 1 : 0,
           pointer_over_center(CLAY_ID("order-natural-removed")) ? 1 : 0);

    for (int32_t index = 0; index < commands.length; ++index) {
        print_command(frame, index, Clay_RenderCommandArray_Get(&commands, index));
    }
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){420, 260}, (Clay_ErrorHandler){oracle_fail_on_error, NULL});
    Clay_SetMeasureTextFunction(measure_text, NULL);

    for (int frame = 0; frame < 7; ++frame) run_frame(frame, 0.25f);

    free(memory);
    return 0;
}
