#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

static unsigned char image_payload;
static unsigned char custom_payload;
static unsigned char outer_user;
static unsigned char inner_user;
static unsigned char image_user;
static unsigned char custom_user;
static unsigned char row_user;
static unsigned char child_a_user;
static unsigned char child_b_user;
static unsigned char offscreen_user;

static void report_error(Clay_ErrorData error) {
    oracle_fail_on_error(error);
}

static int pointer_token(const void *pointer) {
    if (!pointer) return 0;
    if (pointer == &image_payload) return 101;
    if (pointer == &custom_payload) return 102;
    if (pointer == &outer_user) return 201;
    if (pointer == &inner_user) return 202;
    if (pointer == &image_user) return 203;
    if (pointer == &custom_user) return 204;
    if (pointer == &row_user) return 205;
    if (pointer == &child_a_user) return 206;
    if (pointer == &child_b_user) return 207;
    if (pointer == &offscreen_user) return 208;
    return -1;
}

static bool box_is_zero(Clay_BoundingBox box) {
    return box.x == 0 && box.y == 0 && box.width == 0 && box.height == 0;
}

/*
 * Pointer payloads are normalized to stable integer tokens. For closing
 * control commands, inspect only fields outside Clay_RenderData: the C union
 * has no active tag, and these commands intentionally leave its bytes at the
 * default value.
 */
static bool print_command(int frame, int32_t index, const Clay_RenderCommand *command) {
    printf("frame %d command %d type %d id %u z %d box %08x %08x %08x %08x user %d",
           frame,
           (int)index,
           (int)command->commandType,
           command->id,
           (int)command->zIndex,
           oracle_f32_bits(command->boundingBox.x),
           oracle_f32_bits(command->boundingBox.y),
           oracle_f32_bits(command->boundingBox.width),
           oracle_f32_bits(command->boundingBox.height),
           pointer_token(command->userData));

    bool valid = true;
    switch (command->commandType) {
        case CLAY_RENDER_COMMAND_TYPE_RECTANGLE: {
            const Clay_RectangleRenderData *rectangle = &command->renderData.rectangle;
            printf(" rect %08x %08x %08x %08x radius %08x %08x %08x %08x",
                   oracle_f32_bits(rectangle->backgroundColor.r),
                   oracle_f32_bits(rectangle->backgroundColor.g),
                   oracle_f32_bits(rectangle->backgroundColor.b),
                   oracle_f32_bits(rectangle->backgroundColor.a),
                   oracle_f32_bits(rectangle->cornerRadius.topLeft),
                   oracle_f32_bits(rectangle->cornerRadius.topRight),
                   oracle_f32_bits(rectangle->cornerRadius.bottomLeft),
                   oracle_f32_bits(rectangle->cornerRadius.bottomRight));
            break;
        }
        case CLAY_RENDER_COMMAND_TYPE_BORDER: {
            const Clay_BorderRenderData *border = &command->renderData.border;
            printf(" border %08x %08x %08x %08x radius %08x %08x %08x %08x width %u %u %u %u %u",
                   oracle_f32_bits(border->color.r),
                   oracle_f32_bits(border->color.g),
                   oracle_f32_bits(border->color.b),
                   oracle_f32_bits(border->color.a),
                   oracle_f32_bits(border->cornerRadius.topLeft),
                   oracle_f32_bits(border->cornerRadius.topRight),
                   oracle_f32_bits(border->cornerRadius.bottomLeft),
                   oracle_f32_bits(border->cornerRadius.bottomRight),
                   border->width.left,
                   border->width.right,
                   border->width.top,
                   border->width.bottom,
                   border->width.betweenChildren);
            break;
        }
        case CLAY_RENDER_COMMAND_TYPE_IMAGE: {
            const Clay_ImageRenderData *image = &command->renderData.image;
            printf(" image %08x %08x %08x %08x radius %08x %08x %08x %08x data %d",
                   oracle_f32_bits(image->backgroundColor.r),
                   oracle_f32_bits(image->backgroundColor.g),
                   oracle_f32_bits(image->backgroundColor.b),
                   oracle_f32_bits(image->backgroundColor.a),
                   oracle_f32_bits(image->cornerRadius.topLeft),
                   oracle_f32_bits(image->cornerRadius.topRight),
                   oracle_f32_bits(image->cornerRadius.bottomLeft),
                   oracle_f32_bits(image->cornerRadius.bottomRight),
                   pointer_token(image->imageData));
            break;
        }
        case CLAY_RENDER_COMMAND_TYPE_CUSTOM: {
            const Clay_CustomRenderData *custom = &command->renderData.custom;
            printf(" custom %08x %08x %08x %08x radius %08x %08x %08x %08x data %d",
                   oracle_f32_bits(custom->backgroundColor.r),
                   oracle_f32_bits(custom->backgroundColor.g),
                   oracle_f32_bits(custom->backgroundColor.b),
                   oracle_f32_bits(custom->backgroundColor.a),
                   oracle_f32_bits(custom->cornerRadius.topLeft),
                   oracle_f32_bits(custom->cornerRadius.topRight),
                   oracle_f32_bits(custom->cornerRadius.bottomLeft),
                   oracle_f32_bits(custom->cornerRadius.bottomRight),
                   pointer_token(custom->customData));
            break;
        }
        case CLAY_RENDER_COMMAND_TYPE_SCISSOR_START:
            printf(" clip %d %d",
                   command->renderData.clip.horizontal ? 1 : 0,
                   command->renderData.clip.vertical ? 1 : 0);
            break;
        case CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START: {
            const Clay_Color color = command->renderData.overlayColor.color;
            const bool control_default = box_is_zero(command->boundingBox) && command->zIndex == 0;
            printf(" overlay %08x %08x %08x %08x control-default %d",
                   oracle_f32_bits(color.r),
                   oracle_f32_bits(color.g),
                   oracle_f32_bits(color.b),
                   oracle_f32_bits(color.a),
                   control_default ? 1 : 0);
            valid = control_default;
            break;
        }
        case CLAY_RENDER_COMMAND_TYPE_SCISSOR_END:
        case CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END: {
            const bool control_default = box_is_zero(command->boundingBox) && command->zIndex == 0;
            printf(" control-default %d", control_default ? 1 : 0);
            valid = control_default;
            break;
        }
        default:
            break;
    }
    putchar('\n');
    return valid;
}

static void declare_layout(void) {
    CLAY(CLAY_ID("render-outer"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(120), CLAY_SIZING_FIXED(90)},
            .padding = CLAY_PADDING_ALL(2),
            .childGap = 3,
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .backgroundColor = {12, 24, 36, 255},
        .overlayColor = {80, 40, 120, 96},
        .clip = {.horizontal = true, .vertical = true},
        .userData = &outer_user,
    }) {
        CLAY(CLAY_ID("render-inner"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(32)},
                .padding = CLAY_PADDING_ALL(1),
                .childGap = 4,
            },
            .backgroundColor = {20, 50, 70, 255},
            .clip = {.horizontal = true},
            .userData = &inner_user,
        }) {
            CLAY(CLAY_ID("render-image"), {
                .layout = {.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(16)}},
                .backgroundColor = {200, 180, 30, 128},
                .cornerRadius = CLAY_CORNER_RADIUS(2),
                .image = {.imageData = &image_payload},
                .userData = &image_user,
            }) {}
            CLAY(CLAY_ID("render-custom"), {
                .layout = {.sizing = {CLAY_SIZING_FIXED(22), CLAY_SIZING_FIXED(16)}},
                .backgroundColor = {40, 160, 100, 192},
                .cornerRadius = {1, 2, 3, 4},
                .custom = {.customData = &custom_payload},
                .userData = &custom_user,
            }) {}
        }

        CLAY(CLAY_ID("render-row"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(28)},
                .padding = CLAY_PADDING_ALL(1),
                .childGap = 7,
            },
            .cornerRadius = CLAY_CORNER_RADIUS(5),
            .border = {
                .color = {220, 70, 40, 255},
                .width = {1, 2, 3, 4, 3},
            },
            .userData = &row_user,
        }) {
            CLAY(CLAY_ID("render-child-a"), {
                .layout = {.sizing = {CLAY_SIZING_FIXED(12), CLAY_SIZING_FIXED(10)}},
                .backgroundColor = {180, 20, 30, 255},
                .cornerRadius = CLAY_CORNER_RADIUS(1),
                .userData = &child_a_user,
            }) {}
            CLAY(CLAY_ID("render-child-b"), {
                .layout = {.sizing = {CLAY_SIZING_FIXED(14), CLAY_SIZING_FIXED(10)}},
                .backgroundColor = {30, 60, 190, 255},
                .userData = &child_b_user,
            }) {}
        }
    }

    CLAY(CLAY_ID("render-offscreen"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(12)}},
        .backgroundColor = {250, 90, 20, 255},
        .floating = {
            .offset = {220, 8},
            .zIndex = 7,
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
        .userData = &offscreen_user,
    }) {}
}

static bool run_frame(int frame, bool culling_enabled) {
    Clay_SetCullingEnabled(culling_enabled);
    Clay_BeginLayout();
    declare_layout();
    Clay_RenderCommandArray commands = Clay_EndLayout(0);
    const Clay_ElementId offscreen_id = CLAY_ID("render-offscreen");
    const Clay_ElementData offscreen = Clay_GetElementData(offscreen_id);
    int offscreen_commands = 0;
    for (int32_t index = 0; index < commands.length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        if (command->id == offscreen_id.id && command->commandType == CLAY_RENDER_COMMAND_TYPE_RECTANGLE) {
            offscreen_commands++;
        }
    }

    printf("frame %d summary commands %d offscreen-found %d box %08x %08x %08x %08x offscreen-commands %d\n",
           frame,
           commands.length,
           offscreen.found ? 1 : 0,
           oracle_f32_bits(offscreen.boundingBox.x),
           oracle_f32_bits(offscreen.boundingBox.y),
           oracle_f32_bits(offscreen.boundingBox.width),
           oracle_f32_bits(offscreen.boundingBox.height),
           offscreen_commands);

    bool valid = offscreen.found && offscreen_commands == (culling_enabled ? 0 : 1);
    for (int32_t index = 0; index < commands.length; ++index) {
        if (!print_command(frame, index, Clay_RenderCommandArray_Get(&commands, index))) valid = false;
    }
    return valid;
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){180, 110}, (Clay_ErrorHandler){report_error, NULL});

    const bool valid = run_frame(0, true) && run_frame(1, false);
    free(memory);
    return valid ? 0 : 3;
}
