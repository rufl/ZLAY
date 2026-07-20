#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

static Clay_Dimensions measure_text(Clay_StringSlice text, Clay_TextElementConfig *config, void *user_data) {
    (void)user_data;
    const float advance = 5.0f + (float)config->letterSpacing;
    return (Clay_Dimensions){
        .width = (float)text.length * advance,
        .height = (float)config->fontSize,
    };
}

static void report_error(Clay_ErrorData error) {
    oracle_fail_on_error(error);
}

static void print_escaped(Clay_StringSlice text) {
    putchar('"');
    for (int32_t index = 0; index < text.length; ++index) {
        const unsigned char byte = (unsigned char)text.chars[index];
        if (byte == '\n') {
            fputs("\\n", stdout);
        } else if (byte == '\\') {
            fputs("\\\\", stdout);
        } else if (byte == '"') {
            fputs("\\\"", stdout);
        } else {
            putchar((int)byte);
        }
    }
    putchar('"');
}

static void print_box(int frame, const char *name, Clay_ElementId id) {
    const Clay_ElementData data = Clay_GetElementData(id);
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

    switch (command->commandType) {
        case CLAY_RENDER_COMMAND_TYPE_RECTANGLE: {
            const Clay_RectangleRenderData rectangle = command->renderData.rectangle;
            printf(" rect %08x %08x %08x %08x radius %08x %08x %08x %08x",
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
        case CLAY_RENDER_COMMAND_TYPE_TEXT: {
            const Clay_TextRenderData text = command->renderData.text;
            printf(" text %d ", text.stringContents.length);
            print_escaped(text.stringContents);
            printf(" rgba %08x %08x %08x %08x font %u %u spacing %u line %u",
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
        default:
            break;
    }
    putchar('\n');
}

static void declare_layout(void) {
    CLAY(CLAY_ID("sizing-text-root"), {
        .layout = {
            .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()},
            .padding = CLAY_PADDING_ALL(4),
            .childGap = 4,
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .backgroundColor = {12, 18, 28, 255},
    }) {
        CLAY(CLAY_ID("constraint-row"), {
            .layout = {
                .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_FIXED(34)},
                .padding = CLAY_PADDING_ALL(2),
                .childGap = 4,
            },
            .backgroundColor = {26, 34, 48, 255},
        }) {
            CLAY(CLAY_ID("fit-min"), {
                .layout = {
                    .sizing = {CLAY_SIZING_FIT(26), CLAY_SIZING_FIXED(20)},
                    .childAlignment = {.y = CLAY_ALIGN_Y_CENTER},
                },
                .backgroundColor = {145, 55, 65, 255},
            }) {
                CLAY_TEXT(CLAY_STRING("fit fit fit"), CLAY_TEXT_CONFIG({
                    .textColor = {255, 235, 235, 255},
                    .fontId = 4,
                    .fontSize = 7,
                    .wrapMode = CLAY_TEXT_WRAP_WORDS,
                }));
            }

            CLAY(CLAY_ID("fit-range"), {
                .layout = {
                    .sizing = {CLAY_SIZING_FIT(12, 38), CLAY_SIZING_FIXED(18)},
                },
                .backgroundColor = {155, 105, 35, 255},
            }) {
                CLAY(CLAY_ID("fit-range-content"), {
                    .layout = {.sizing = {CLAY_SIZING_FIXED(70), CLAY_SIZING_FIXED(8)}},
                    .backgroundColor = {235, 185, 55, 255},
                }) {}
            }

            CLAY(CLAY_ID("grow-min"), {
                .layout = {.sizing = {CLAY_SIZING_GROW(24), CLAY_SIZING_FIXED(16)}},
                .backgroundColor = {45, 135, 85, 255},
            }) {}

            CLAY(CLAY_ID("grow-range"), {
                .layout = {.sizing = {CLAY_SIZING_GROW(14, 48), CLAY_SIZING_FIXED(18)}},
                .backgroundColor = {35, 105, 155, 255},
            }) {}

            CLAY(CLAY_ID("aspect"), {
                .layout = {.sizing = {CLAY_SIZING_GROW(16, 44), CLAY_SIZING_FIT(6, 30)}},
                .backgroundColor = {105, 65, 165, 255},
                .aspectRatio = {.aspectRatio = 2.0f},
            }) {}
        }

        CLAY(CLAY_ID("text-row"), {
            .layout = {
                .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW(58, 112)},
                .padding = CLAY_PADDING_ALL(2),
                .childGap = 4,
            },
            .backgroundColor = {18, 27, 39, 255},
        }) {
            CLAY(CLAY_ID("words-box"), {
                .layout = {
                    .sizing = {CLAY_SIZING_PERCENT(0.33333334f), CLAY_SIZING_GROW()},
                    .padding = CLAY_PADDING_ALL(3),
                    .layoutDirection = CLAY_TOP_TO_BOTTOM,
                },
                .backgroundColor = {55, 75, 105, 255},
            }) {
                CLAY_TEXT(CLAY_STRING("alpha beta gamma delta"), CLAY_TEXT_CONFIG({
                    .textColor = {205, 225, 250, 255},
                    .fontId = 1,
                    .fontSize = 8,
                    .letterSpacing = 1,
                    .lineHeight = 11,
                    .wrapMode = CLAY_TEXT_WRAP_WORDS,
                    .textAlignment = CLAY_TEXT_ALIGN_CENTER,
                }));
            }

            CLAY(CLAY_ID("newlines-box"), {
                .layout = {
                    .sizing = {CLAY_SIZING_PERCENT(0.33333334f), CLAY_SIZING_GROW()},
                    .padding = CLAY_PADDING_ALL(3),
                    .layoutDirection = CLAY_TOP_TO_BOTTOM,
                },
                .backgroundColor = {65, 95, 75, 255},
            }) {
                CLAY_TEXT(CLAY_STRING("wide line\nx\nmid"), CLAY_TEXT_CONFIG({
                    .textColor = {215, 245, 220, 255},
                    .fontId = 2,
                    .fontSize = 9,
                    .letterSpacing = 2,
                    .lineHeight = 13,
                    .wrapMode = CLAY_TEXT_WRAP_NEWLINES,
                    .textAlignment = CLAY_TEXT_ALIGN_RIGHT,
                }));
            }

            CLAY(CLAY_ID("none-box"), {
                .layout = {
                    .sizing = {CLAY_SIZING_PERCENT(0.33333334f), CLAY_SIZING_GROW()},
                    .padding = CLAY_PADDING_ALL(3),
                    .layoutDirection = CLAY_TOP_TO_BOTTOM,
                },
                .backgroundColor = {105, 75, 55, 255},
            }) {
                CLAY_TEXT(CLAY_STRING("never wrap this"), CLAY_TEXT_CONFIG({
                    .textColor = {250, 225, 205, 255},
                    .fontId = 3,
                    .fontSize = 10,
                    .letterSpacing = 3,
                    .lineHeight = 14,
                    .wrapMode = CLAY_TEXT_WRAP_NONE,
                    .textAlignment = CLAY_TEXT_ALIGN_LEFT,
                }));
            }
        }
    }

    CLAY(CLAY_ID("cull-probe"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(30), CLAY_SIZING_FIXED(18)}},
        .backgroundColor = {245, 70, 35, 255},
        .floating = {
            .offset = {270, 150},
            .zIndex = 6,
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
    }) {}
}

static bool run_frame(int frame, Clay_Dimensions dimensions) {
    Clay_SetLayoutDimensions(dimensions);
    Clay_SetCullingEnabled(true);
    Clay_BeginLayout();
    declare_layout();
    Clay_RenderCommandArray commands = Clay_EndLayout(0);

    const Clay_ElementId probe_id = CLAY_ID("cull-probe");
    int probe_commands = 0;
    for (int32_t index = 0; index < commands.length; ++index) {
        const Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        if (command->id == probe_id.id && command->commandType == CLAY_RENDER_COMMAND_TYPE_RECTANGLE) {
            probe_commands++;
        }
    }

    printf("frame %d summary viewport %08x %08x commands %d probe-commands %d\n",
           frame,
           oracle_f32_bits(dimensions.width),
           oracle_f32_bits(dimensions.height),
           commands.length,
           probe_commands);

#define PRINT_BOX(name) print_box(frame, name, CLAY_ID(name))
    PRINT_BOX("sizing-text-root");
    PRINT_BOX("constraint-row");
    PRINT_BOX("fit-min");
    PRINT_BOX("fit-range");
    PRINT_BOX("fit-range-content");
    PRINT_BOX("grow-min");
    PRINT_BOX("grow-range");
    PRINT_BOX("aspect");
    PRINT_BOX("text-row");
    PRINT_BOX("words-box");
    PRINT_BOX("newlines-box");
    PRINT_BOX("none-box");
    PRINT_BOX("cull-probe");
#undef PRINT_BOX

    for (int32_t index = 0; index < commands.length; ++index) {
        print_command(frame, index, Clay_RenderCommandArray_Get(&commands, index));
    }

    const Clay_ElementData probe = Clay_GetElementData(probe_id);
    const int expected_probe_commands = frame == 0 ? 1 : 0;
    return probe.found && probe_commands == expected_probe_commands;
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){320, 190}, (Clay_ErrorHandler){report_error, NULL});
    Clay_SetMeasureTextFunction(measure_text, NULL);

    const bool valid = run_frame(0, (Clay_Dimensions){320, 190}) &&
                       run_frame(1, (Clay_Dimensions){150, 118});
    free(memory);
    return valid ? 0 : 3;
}
