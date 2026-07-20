#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

static Clay_Dimensions measure_text(Clay_StringSlice text, Clay_TextElementConfig *config, void *user_data) {
    (void)config;
    (void)user_data;
    return (Clay_Dimensions){
        .width = (float)text.length * 6.0f,
        .height = 10.0f,
    };
}

static void print_box(const char *name, Clay_ElementId id) {
    Clay_ElementData element = Clay_GetElementData(id);
    printf("box %s %u %u %u %u\n",
           name,
           oracle_f32_bits(element.boundingBox.x),
           oracle_f32_bits(element.boundingBox.y),
           oracle_f32_bits(element.boundingBox.width),
           oracle_f32_bits(element.boundingBox.height));
}

/* Normalize pointer-bearing payloads by printing text contents, not addresses. */
static void print_command(int32_t index, Clay_RenderCommand *command) {
    printf("command %d %d %u %d %u %u %u %u",
           index,
           (int)command->commandType,
           command->id,
           (int)command->zIndex,
           oracle_f32_bits(command->boundingBox.x),
           oracle_f32_bits(command->boundingBox.y),
           oracle_f32_bits(command->boundingBox.width),
           oracle_f32_bits(command->boundingBox.height));
    switch (command->commandType) {
        case CLAY_RENDER_COMMAND_TYPE_RECTANGLE:
            printf(" rgba %u %u %u %u",
                   oracle_f32_bits(command->renderData.rectangle.backgroundColor.r),
                   oracle_f32_bits(command->renderData.rectangle.backgroundColor.g),
                   oracle_f32_bits(command->renderData.rectangle.backgroundColor.b),
                   oracle_f32_bits(command->renderData.rectangle.backgroundColor.a));
            break;
        case CLAY_RENDER_COMMAND_TYPE_BORDER:
            printf(" border %u %u %u %u %u %u %u %u %u",
                   oracle_f32_bits(command->renderData.border.color.r),
                   oracle_f32_bits(command->renderData.border.color.g),
                   oracle_f32_bits(command->renderData.border.color.b),
                   oracle_f32_bits(command->renderData.border.color.a),
                   command->renderData.border.width.left,
                   command->renderData.border.width.right,
                   command->renderData.border.width.top,
                   command->renderData.border.width.bottom,
                   command->renderData.border.width.betweenChildren);
            break;
        case CLAY_RENDER_COMMAND_TYPE_TEXT:
            printf(" text %d \"%.*s\"",
                   command->renderData.text.stringContents.length,
                   command->renderData.text.stringContents.length,
                   command->renderData.text.stringContents.chars);
            break;
        case CLAY_RENDER_COMMAND_TYPE_SCISSOR_START:
            printf(" clip %d %d",
                   command->renderData.clip.horizontal ? 1 : 0,
                   command->renderData.clip.vertical ? 1 : 0);
            break;
        default:
            break;
    }
    putchar('\n');
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){360, 220}, (Clay_ErrorHandler){oracle_fail_on_error, NULL});
    Clay_SetMeasureTextFunction(measure_text, NULL);

    Clay_BeginLayout();
    CLAY(CLAY_ID("panel"), {
        .layout = {
            .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()},
            .padding = CLAY_PADDING_ALL(10),
            .childGap = 8,
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .backgroundColor = {24, 28, 36, 255},
    }) {
        CLAY(CLAY_ID("header"), {
            .layout = {
                .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_FIXED(28)},
                .padding = CLAY_PADDING_ALL(4),
            },
            .backgroundColor = {48, 56, 72, 255},
        }) {
            CLAY_TEXT(CLAY_STRING("complex oracle"), CLAY_TEXT_CONFIG({
                .textColor = {240, 240, 240, 255},
                .fontSize = 10,
                .wrapMode = CLAY_TEXT_WRAP_NONE,
            }));
        }

        CLAY(CLAY_ID("row"), {
            .layout = {
                .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()},
                .padding = CLAY_PADDING_ALL(4),
                .childGap = 10,
            },
            .border = {
                .color = {220, 180, 40, 255},
                .width = CLAY_BORDER_ALL(2),
            },
        }) {
            CLAY(CLAY_ID("sidebar"), {
                .layout = {
                    .sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_GROW()},
                    .padding = CLAY_PADDING_ALL(3),
                    .layoutDirection = CLAY_TOP_TO_BOTTOM,
                },
                .backgroundColor = {72, 52, 64, 255},
            }) {
                CLAY_TEXT(CLAY_STRING("fixed"), CLAY_TEXT_CONFIG({
                    .textColor = {255, 220, 220, 255},
                    .fontSize = 10,
                    .wrapMode = CLAY_TEXT_WRAP_NONE,
                }));
            }

            CLAY(CLAY_ID("clipper"), {
                .layout = {
                    .sizing = {CLAY_SIZING_PERCENT(0.5f), CLAY_SIZING_FIXED(72)},
                    .padding = CLAY_PADDING_ALL(5),
                    .childGap = 3,
                    .layoutDirection = CLAY_TOP_TO_BOTTOM,
                },
                .backgroundColor = {34, 72, 82, 255},
                .clip = {.horizontal = true, .vertical = true},
            }) {
                CLAY(CLAY_ID("text-column"), {
                    .layout = {
                        .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIT()},
                        .layoutDirection = CLAY_TOP_TO_BOTTOM,
                    },
                }) {
                    CLAY_TEXT(CLAY_STRING("alpha beta gamma delta epsilon"), CLAY_TEXT_CONFIG({
                        .textColor = {210, 245, 250, 255},
                        .fontSize = 10,
                        .lineHeight = 12,
                        .wrapMode = CLAY_TEXT_WRAP_WORDS,
                        .textAlignment = CLAY_TEXT_ALIGN_CENTER,
                    }));
                }
                CLAY(CLAY_ID("clip-item"), {
                    .layout = {.sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_FIXED(14)}},
                    .backgroundColor = {20, 110, 120, 255},
                }) {}
            }

            CLAY(CLAY_ID("tail"), {
                .layout = {.sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()}},
                .backgroundColor = {58, 70, 50, 255},
            }) {}
        }

        CLAY(CLAY_ID("badge"), {
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(48), CLAY_SIZING_FIXED(18)},
                .padding = {4, 4, 2, 2},
            },
            .backgroundColor = {180, 64, 72, 255},
            .floating = {
                .offset = {-4, 4},
                .zIndex = 5,
                .parentId = CLAY_ID("clipper").id,
                .attachPoints = {
                    .element = CLAY_ATTACH_POINT_RIGHT_TOP,
                    .parent = CLAY_ATTACH_POINT_RIGHT_TOP,
                },
                .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
                .clipTo = CLAY_CLIP_TO_NONE,
            },
        }) {
            CLAY_TEXT(CLAY_STRING("float"), CLAY_TEXT_CONFIG({
                .textColor = {255, 255, 255, 255},
                .fontSize = 10,
                .wrapMode = CLAY_TEXT_WRAP_NONE,
            }));
        }
    }

    Clay_RenderCommandArray commands = Clay_EndLayout(0.016f);
    print_box("panel", CLAY_ID("panel"));
    print_box("header", CLAY_ID("header"));
    print_box("row", CLAY_ID("row"));
    print_box("sidebar", CLAY_ID("sidebar"));
    print_box("clipper", CLAY_ID("clipper"));
    print_box("text-column", CLAY_ID("text-column"));
    print_box("clip-item", CLAY_ID("clip-item"));
    print_box("tail", CLAY_ID("tail"));
    print_box("badge", CLAY_ID("badge"));
    for (int32_t index = 0; index < commands.length; ++index) {
        print_command(index, Clay_RenderCommandArray_Get(&commands, index));
    }

    free(memory);
    return 0;
}
