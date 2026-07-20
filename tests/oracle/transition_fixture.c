#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

#define ANIMATED_PROPERTIES ((Clay_TransitionProperty)(CLAY_TRANSITION_PROPERTY_X | CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR))

typedef struct CallbackRecord {
    Clay_TransitionState state;
    Clay_TransitionProperty properties;
    float elapsed;
    Clay_TransitionData before;
    Clay_TransitionData after;
    Clay_TransitionData target;
    bool complete;
} CallbackRecord;

typedef enum SetterKind {
    SETTER_NONE,
    SETTER_ENTER,
    SETTER_EXIT,
} SetterKind;

typedef struct SetterRecord {
    SetterKind kind;
    Clay_TransitionData input;
    Clay_TransitionData output;
} SetterRecord;

static CallbackRecord callback_records[4];
static int callback_count = 0;
static SetterRecord setter_record = {0};

static Clay_Color color(float r, float g, float b) {
    return (Clay_Color){r, g, b, 255};
}

static Clay_TransitionData enter_initial(Clay_TransitionData target, Clay_TransitionProperty properties) {
    (void)properties;
    Clay_TransitionData initial = target;
    initial.boundingBox.x -= 20;
    initial.backgroundColor = color(0, 0, 0);
    if (setter_record.kind != SETTER_NONE) oracle_fail_log_overflow("transition setter");
    setter_record = (SetterRecord){SETTER_ENTER, target, initial};
    return initial;
}

static Clay_TransitionData exit_final(Clay_TransitionData current, Clay_TransitionProperty properties) {
    (void)properties;
    Clay_TransitionData final = current;
    final.boundingBox.x += 20;
    final.backgroundColor = color(200, 0, 0);
    if (setter_record.kind != SETTER_NONE) oracle_fail_log_overflow("transition setter");
    setter_record = (SetterRecord){SETTER_EXIT, current, final};
    return final;
}

static float linear(float initial, float target, float ratio) {
    return initial + (target - initial) * ratio;
}

static bool linear_handler(Clay_TransitionCallbackArguments arguments) {
    float ratio = arguments.duration > 0 ? arguments.elapsedTime / arguments.duration : 1;
    if (ratio > 1) ratio = 1;

    if (callback_count >= (int)(sizeof(callback_records) / sizeof(callback_records[0]))) {
        oracle_fail_log_overflow("transition callback");
    }
    CallbackRecord *record = &callback_records[callback_count++];
    record->state = arguments.transitionState;
    record->properties = arguments.properties;
    record->elapsed = arguments.elapsedTime;
    record->before = *arguments.current;
    record->target = arguments.target;

    arguments.current->boundingBox.x = linear(arguments.initial.boundingBox.x, arguments.target.boundingBox.x, ratio);
    arguments.current->backgroundColor.r = linear(arguments.initial.backgroundColor.r, arguments.target.backgroundColor.r, ratio);
    arguments.current->backgroundColor.g = linear(arguments.initial.backgroundColor.g, arguments.target.backgroundColor.g, ratio);
    arguments.current->backgroundColor.b = linear(arguments.initial.backgroundColor.b, arguments.target.backgroundColor.b, ratio);
    arguments.current->backgroundColor.a = linear(arguments.initial.backgroundColor.a, arguments.target.backgroundColor.a, ratio);

    record->after = *arguments.current;
    record->complete = arguments.elapsedTime >= arguments.duration;
    return record->complete;
}

static Clay_ElementDeclaration fixed_box(float width, float height, Clay_Color background) {
    return (Clay_ElementDeclaration){
        .layout = {.sizing = {CLAY_SIZING_FIXED(width), CLAY_SIZING_FIXED(height)}},
        .backgroundColor = background,
    };
}

static Clay_ElementDeclaration animated_box(Clay_Color background) {
    Clay_ElementDeclaration declaration = fixed_box(10, 10, background);
    declaration.transition = (Clay_TransitionElementConfig){
        .handler = linear_handler,
        .duration = 0.5f,
        .properties = ANIMATED_PROPERTIES,
        .enter = {
            .setInitialState = enter_initial,
            .trigger = CLAY_TRANSITION_ENTER_TRIGGER_ON_FIRST_PARENT_FRAME,
        },
        .exit = {
            .setFinalState = exit_final,
            .trigger = CLAY_TRANSITION_EXIT_SKIP_WHEN_PARENT_EXITS,
            .siblingOrdering = CLAY_EXIT_TRANSITION_ORDERING_NATURAL_ORDER,
        },
    };
    return declaration;
}

static const char *name_for_id(uint32_t id, Clay_ElementId first, Clay_ElementId animated, Clay_ElementId last) {
    if (id == first.id) return "first";
    if (id == animated.id) return "animated";
    if (id == last.id) return "last";
    return NULL;
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

static void print_frame(int frame, Clay_RenderCommandArray commands) {
    Clay_ElementId first = CLAY_ID("first");
    Clay_ElementId animated = CLAY_ID("animated");
    Clay_ElementId last = CLAY_ID("last");

    if (setter_record.kind != SETTER_NONE) {
        printf("setter %d %s input ", frame, setter_record.kind == SETTER_ENTER ? "enter" : "exit");
        print_transition_data(&setter_record.input);
        printf(" output ");
        print_transition_data(&setter_record.output);
        putchar('\n');
    }
    for (int index = 0; index < callback_count; ++index) {
        CallbackRecord *record = &callback_records[index];
        printf("callback %d %d %d %u before ",
               frame,
               (int)record->state,
               (int)record->properties,
               oracle_f32_bits(record->elapsed));
        print_transition_data(&record->before);
        printf(" after ");
        print_transition_data(&record->after);
        printf(" target ");
        print_transition_data(&record->target);
        printf(" complete %d\n", record->complete ? 1 : 0);
    }

    Clay_RenderCommand *animated_command = NULL;
    int relevant_index = 0;
    for (int32_t index = 0; index < commands.length; ++index) {
        Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        if (command->commandType != CLAY_RENDER_COMMAND_TYPE_RECTANGLE) continue;
        const char *name = name_for_id(command->id, first, animated, last);
        if (!name) continue;
        if (command->id == animated.id) animated_command = command;
        printf("rect %d %d %s %u %u %u %u %u rgba %u %u %u %u\n",
               frame,
               relevant_index++,
               name,
               command->id,
               oracle_f32_bits(command->boundingBox.x),
               oracle_f32_bits(command->boundingBox.y),
               oracle_f32_bits(command->boundingBox.width),
               oracle_f32_bits(command->boundingBox.height),
               oracle_f32_bits(command->renderData.rectangle.backgroundColor.r),
               oracle_f32_bits(command->renderData.rectangle.backgroundColor.g),
               oracle_f32_bits(command->renderData.rectangle.backgroundColor.b),
               oracle_f32_bits(command->renderData.rectangle.backgroundColor.a));
    }

    if (animated_command) {
        printf("frame %d animated 1 box %u %u %u %u rgba %u %u %u %u\n",
               frame,
               oracle_f32_bits(animated_command->boundingBox.x),
               oracle_f32_bits(animated_command->boundingBox.y),
               oracle_f32_bits(animated_command->boundingBox.width),
               oracle_f32_bits(animated_command->boundingBox.height),
               oracle_f32_bits(animated_command->renderData.rectangle.backgroundColor.r),
               oracle_f32_bits(animated_command->renderData.rectangle.backgroundColor.g),
               oracle_f32_bits(animated_command->renderData.rectangle.backgroundColor.b),
               oracle_f32_bits(animated_command->renderData.rectangle.backgroundColor.a));
    } else {
        printf("frame %d animated 0 box 0 0 0 0 rgba 0 0 0 0\n", frame);
    }
}

static void run_frame(int frame, bool show_animated, float first_width, Clay_Color target_color, float delta_time) {
    callback_count = 0;
    setter_record = (SetterRecord){0};

    Clay_BeginLayout();
    CLAY(CLAY_ID("parent"), fixed_box(100, 20, (Clay_Color){0})) {
        CLAY(CLAY_ID("first"), fixed_box(first_width, 10, color(40, 40, 40))) {}
        if (show_animated) {
            CLAY(CLAY_ID("animated"), animated_box(target_color)) {}
        }
        CLAY(CLAY_ID("last"), fixed_box(10, 10, color(0, 0, 200))) {}
    }
    print_frame(frame, Clay_EndLayout(delta_time));
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){120, 40}, (Clay_ErrorHandler){oracle_fail_on_error, NULL});

    Clay_Color entering_target = color(0, 200, 0);
    Clay_Color changed_target = color(200, 100, 0);
    run_frame(0, true, 10, entering_target, 0.25f);
    run_frame(1, true, 10, entering_target, 0.25f);
    run_frame(2, true, 10, entering_target, 0.25f);
    run_frame(3, true, 10, entering_target, 0.25f);
    run_frame(4, true, 30, changed_target, 0.25f);
    run_frame(5, true, 30, changed_target, 0.25f);
    run_frame(6, true, 30, changed_target, 0.25f);
    run_frame(7, false, 30, changed_target, 0.25f);
    run_frame(8, false, 30, changed_target, 0.25f);
    run_frame(9, false, 30, changed_target, 0.25f);
    run_frame(10, false, 30, changed_target, 0.25f);

    free(memory);
    return 0;
}
