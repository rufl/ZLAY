#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct EventRecord {
    int tag;
    Clay_TransitionState state;
    Clay_TransitionProperty properties;
    float elapsed;
    float duration;
    Clay_TransitionData initial;
    Clay_TransitionData before;
    Clay_TransitionData after;
    Clay_TransitionData target;
    bool complete;
} EventRecord;

static EventRecord events[128];
static int event_count = 0;
static int reappear_finals = 0;
static int parent_finals = 0;
static int nested_initials = 0;

static Clay_Color color(float r, float g, float b, float a) {
    return (Clay_Color){r, g, b, a};
}

static bool lifecycle_handler(Clay_TransitionCallbackArguments arguments, int tag) {
    if (event_count >= (int)(sizeof(events) / sizeof(events[0]))) {
        oracle_fail_log_overflow("transition lifecycle events");
    }

    EventRecord *event = &events[event_count++];
    event->tag = tag;
    event->state = arguments.transitionState;
    event->properties = arguments.properties;
    event->elapsed = arguments.elapsedTime;
    event->duration = arguments.duration;
    event->initial = arguments.initial;
    event->before = *arguments.current;
    event->target = arguments.target;
    event->complete = arguments.elapsedTime >= arguments.duration;
    *arguments.current = event->complete ? arguments.target : arguments.initial;
    event->after = *arguments.current;
    return event->complete;
}

#define DEFINE_HANDLER(name, tag)                                  \
    static bool name(Clay_TransitionCallbackArguments arguments) { \
        return lifecycle_handler(arguments, tag);                  \
    }

DEFINE_HANDLER(prune_handler, 11)
DEFINE_HANDLER(reappear_handler, 21)
DEFINE_HANDLER(move_handler, 31)
DEFINE_HANDLER(parent_handler, 41)
DEFINE_HANDLER(nested_handler, 42)

#undef DEFINE_HANDLER

static Clay_TransitionData reappear_final(Clay_TransitionData current, Clay_TransitionProperty properties) {
    (void)properties;
    reappear_finals++;
    current.boundingBox.x += 13.0f;
    current.backgroundColor = color(230, 31, 47, 255);
    return current;
}

static Clay_TransitionData parent_final(Clay_TransitionData current, Clay_TransitionProperty properties) {
    (void)properties;
    parent_finals++;
    current.boundingBox.y += 17.0f;
    current.backgroundColor = color(19, 211, 73, 255);
    return current;
}

static Clay_TransitionData nested_initial(Clay_TransitionData target, Clay_TransitionProperty properties) {
    (void)properties;
    nested_initials++;
    target.backgroundColor = color(3, 5, 7, 255);
    return target;
}

static Clay_ElementDeclaration fixed_box(float width, float height, Clay_Color background) {
    return (Clay_ElementDeclaration){
        .layout = {.sizing = {CLAY_SIZING_FIXED(width), CLAY_SIZING_FIXED(height)}},
        .backgroundColor = background,
    };
}

static Clay_ElementDeclaration floating_box(float x, float y, float width, float height, Clay_Color background) {
    Clay_ElementDeclaration declaration = fixed_box(width, height, background);
    declaration.floating.offset = (Clay_Vector2){x, y};
    declaration.floating.attachTo = CLAY_ATTACH_TO_ROOT;
    declaration.floating.pointerCaptureMode = CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH;
    return declaration;
}

static Clay_TransitionElementConfig transition_config(
    bool (*handler)(Clay_TransitionCallbackArguments),
    float duration,
    Clay_TransitionProperty properties) {
    return (Clay_TransitionElementConfig){
        .handler = handler,
        .duration = duration,
        .properties = properties,
    };
}

static Clay_ElementDeclaration prune_box(Clay_Color background) {
    Clay_ElementDeclaration declaration = floating_box(7, 9, 23, 13, background);
    declaration.transition = transition_config(prune_handler, 1.0f, CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR);
    return declaration;
}

static Clay_ElementDeclaration reappear_box(Clay_Color background) {
    Clay_ElementDeclaration declaration = floating_box(43, 9, 25, 13, background);
    declaration.transition = transition_config(reappear_handler, 1.0f, CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR);
    declaration.transition.exit.setFinalState = reappear_final;
    declaration.transition.exit.trigger = CLAY_TRANSITION_EXIT_SKIP_WHEN_PARENT_EXITS;
    declaration.transition.exit.siblingOrdering = CLAY_EXIT_TRANSITION_ORDERING_NATURAL_ORDER;
    return declaration;
}

static Clay_ElementDeclaration move_box(void) {
    Clay_ElementDeclaration declaration = fixed_box(17, 11, color(71, 83, 97, 255));
    declaration.transition = transition_config(move_handler, 1.0f, CLAY_TRANSITION_PROPERTY_POSITION);
    return declaration;
}

static Clay_ElementDeclaration parent_exit_box(void) {
    Clay_ElementDeclaration declaration = floating_box(83, 91, 53, 31, color(101, 37, 149, 255));
    declaration.layout.padding = CLAY_PADDING_ALL(3);
    declaration.transition = transition_config(parent_handler, 0.75f, CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR);
    declaration.transition.exit.setFinalState = parent_final;
    declaration.transition.exit.trigger = CLAY_TRANSITION_EXIT_SKIP_WHEN_PARENT_EXITS;
    declaration.transition.exit.siblingOrdering = CLAY_EXIT_TRANSITION_ORDERING_NATURAL_ORDER;
    return declaration;
}

static Clay_ElementDeclaration nested_box(Clay_Color background) {
    Clay_ElementDeclaration declaration = fixed_box(19, 9, background);
    declaration.transition = transition_config(nested_handler, 0.5f, CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR);
    declaration.transition.enter.setInitialState = nested_initial;
    declaration.transition.enter.trigger = CLAY_TRANSITION_ENTER_SKIP_ON_FIRST_PARENT_FRAME;
    return declaration;
}

static Clay_ElementDeclaration plain_prune_box(void) {
    return floating_box(7, 9, 23, 13, color(59, 181, 43, 255));
}

static void declare_layout(int frame) {
    if (frame == 0) {
        CLAY(CLAY_ID("prune"), prune_box(color(193, 17, 29, 255))) {}
    } else if (frame == 1) {
        CLAY(CLAY_ID("prune"), prune_box(color(31, 47, 223, 255))) {}
    } else if (frame == 2) {
        CLAY(CLAY_ID("prune"), plain_prune_box()) {}
    } else if (frame == 3 || frame == 4) {
        CLAY(CLAY_ID("prune"), prune_box(color(241, 199, 11, 255))) {}
    } else if (frame >= 6) {
        CLAY(CLAY_ID("prune"), prune_box(color(241, 199, 11, 255))) {}
    }

    if (frame == 0) {
        CLAY(CLAY_ID("reappear"), reappear_box(color(181, 23, 41, 255))) {}
    } else if (frame == 1) {
        CLAY(CLAY_ID("reappear"), reappear_box(color(37, 61, 211, 255))) {}
    } else if (frame == 3 || frame >= 5) {
        CLAY(CLAY_ID("reappear"), reappear_box(color(43, 197, 89, 255))) {}
    }

    CLAY(CLAY_ID("move-a"), floating_box(11, 43, 41, 25, (Clay_Color){0})) {
        if (frame == 0 || frame == 2 || frame >= 6) {
            CLAY(CLAY_ID("move"), move_box()) {}
        }
    }
    CLAY(CLAY_ID("move-b"), floating_box(151, 57, 41, 25, (Clay_Color){0})) {
        if (frame == 1 || frame == 3 || frame == 4) {
            CLAY(CLAY_ID("move"), move_box()) {}
        }
    }

    if (frame <= 1) {
        CLAY(CLAY_ID("exit-parent"), parent_exit_box()) {
            CLAY(
                CLAY_ID("nested"),
                nested_box(frame == 0 ? color(167, 53, 79, 255) : color(29, 173, 191, 255))) {}
        }
    }

    CLAY(CLAY_ID("rescue-parent"), floating_box(211, 91, 53, 31, (Clay_Color){0})) {
        if (frame >= 3) {
            CLAY(
                CLAY_ID("nested"),
                nested_box(frame < 5 ? color(47, 193, 107, 255) : color(229, 157, 13, 255))) {}
        }
    }
}

static void print_data(const Clay_TransitionData *data) {
    printf("%08x %08x %08x %08x %08x %08x %08x %08x",
           oracle_f32_bits(data->boundingBox.x),
           oracle_f32_bits(data->boundingBox.y),
           oracle_f32_bits(data->boundingBox.width),
           oracle_f32_bits(data->boundingBox.height),
           oracle_f32_bits(data->backgroundColor.r),
           oracle_f32_bits(data->backgroundColor.g),
           oracle_f32_bits(data->backgroundColor.b),
           oracle_f32_bits(data->backgroundColor.a));
}

static const char *name_for_id(uint32_t id) {
    if (id == CLAY_ID("prune").id) return "prune";
    if (id == CLAY_ID("reappear").id) return "reappear";
    if (id == CLAY_ID("move").id) return "move";
    if (id == CLAY_ID("exit-parent").id) return "exit-parent";
    if (id == CLAY_ID("nested").id) return "nested";
    return NULL;
}

static void print_status(int frame, const char *name, Clay_ElementId id) {
    Clay_ElementData data = Clay_GetElementData(id);
    printf("status %d %s %d %08x %08x %08x %08x\n",
           frame,
           name,
           data.found ? 1 : 0,
           oracle_f32_bits(data.boundingBox.x),
           oracle_f32_bits(data.boundingBox.y),
           oracle_f32_bits(data.boundingBox.width),
           oracle_f32_bits(data.boundingBox.height));
}

static void run_frame(int frame) {
    event_count = 0;
    Clay_BeginLayout();
    declare_layout(frame);
    Clay_RenderCommandArray commands = Clay_EndLayout(0.25f);

    printf("frame %d commands %d events %d finals %d %d initials %d\n",
           frame,
           (int)commands.length,
           event_count,
           reappear_finals,
           parent_finals,
           nested_initials);

    for (int index = 0; index < event_count; ++index) {
        EventRecord *event = &events[index];
        printf("event %d %d %d %d %08x %08x initial ",
               frame,
               index,
               event->tag,
               (int)event->state,
               (unsigned)event->properties,
               oracle_f32_bits(event->elapsed));
        print_data(&event->initial);
        printf(" before ");
        print_data(&event->before);
        printf(" after ");
        print_data(&event->after);
        printf(" target ");
        print_data(&event->target);
        printf(" duration %08x complete %d\n", oracle_f32_bits(event->duration), event->complete ? 1 : 0);
    }

    int relevant_index = 0;
    for (int32_t index = 0; index < commands.length; ++index) {
        Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        if (command->commandType != CLAY_RENDER_COMMAND_TYPE_RECTANGLE) continue;
        const char *name = name_for_id(command->id);
        if (!name) continue;
        Clay_Color command_color = command->renderData.rectangle.backgroundColor;
        printf("rect %d %d %s %u %08x %08x %08x %08x %08x %08x %08x %08x\n",
               frame,
               relevant_index++,
               name,
               command->id,
               oracle_f32_bits(command->boundingBox.x),
               oracle_f32_bits(command->boundingBox.y),
               oracle_f32_bits(command->boundingBox.width),
               oracle_f32_bits(command->boundingBox.height),
               oracle_f32_bits(command_color.r),
               oracle_f32_bits(command_color.g),
               oracle_f32_bits(command_color.b),
               oracle_f32_bits(command_color.a));
    }

    print_status(frame, "prune", CLAY_ID("prune"));
    print_status(frame, "reappear", CLAY_ID("reappear"));
    print_status(frame, "move", CLAY_ID("move"));
    print_status(frame, "exit-parent", CLAY_ID("exit-parent"));
    print_status(frame, "nested", CLAY_ID("nested"));
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(
        arena,
        (Clay_Dimensions){300, 180},
        (Clay_ErrorHandler){oracle_fail_on_error, NULL});

    for (int frame = 0; frame < 8; ++frame) run_frame(frame);

    free(memory);
    return 0;
}
