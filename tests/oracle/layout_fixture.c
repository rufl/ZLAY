#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

static Clay_Dimensions measure_text(Clay_StringSlice text, Clay_TextElementConfig *config, void *user_data) {
    (void)user_data;
    return (Clay_Dimensions){
        .width = (float)text.length * (float)config->fontSize,
        .height = (float)config->fontSize,
    };
}

int main(void) {
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){300, 100}, (Clay_ErrorHandler){oracle_fail_on_error, NULL});
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_BeginLayout();
    CLAY(CLAY_ID("row"), {
        .layout = {
            .sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()},
            .childGap = 10,
        },
    }) {
        CLAY(CLAY_ID("left"), {
            .layout = {.sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()}},
            .backgroundColor = {255, 0, 0, 255},
        }) {}
        CLAY(CLAY_ID("right"), {
            .layout = {.sizing = {CLAY_SIZING_GROW(), CLAY_SIZING_GROW()}},
            .backgroundColor = {0, 0, 255, 255},
        }) {}
    }
    Clay_RenderCommandArray commands = Clay_EndLayout(0.016f);

    Clay_ElementData left = Clay_GetElementData(CLAY_ID("left"));
    Clay_ElementData right = Clay_GetElementData(CLAY_ID("right"));
    printf("left %u %u %u %u\n", oracle_f32_bits(left.boundingBox.x), oracle_f32_bits(left.boundingBox.y), oracle_f32_bits(left.boundingBox.width), oracle_f32_bits(left.boundingBox.height));
    printf("right %u %u %u %u\n", oracle_f32_bits(right.boundingBox.x), oracle_f32_bits(right.boundingBox.y), oracle_f32_bits(right.boundingBox.width), oracle_f32_bits(right.boundingBox.height));
    for (int32_t index = 0; index < commands.length; ++index) {
        Clay_RenderCommand *command = Clay_RenderCommandArray_Get(&commands, index);
        printf("command %d %u %u %u %u %u\n",
               (int)command->commandType,
               command->id,
               oracle_f32_bits(command->boundingBox.x),
               oracle_f32_bits(command->boundingBox.y),
               oracle_f32_bits(command->boundingBox.width),
               oracle_f32_bits(command->boundingBox.height));
    }

    free(memory);
    return 0;
}
