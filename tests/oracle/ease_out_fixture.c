#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"

static uint32_t fbits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static void print_data(int case_index, int time_index, bool complete, const Clay_TransitionData *data) {
    printf("ease %d %d %d box %08x %08x %08x %08x bg %08x %08x %08x %08x overlay %08x %08x %08x %08x border %08x %08x %08x %08x width %u %u %u %u %u\n",
           case_index,
           time_index,
           complete ? 1 : 0,
           fbits(data->boundingBox.x), fbits(data->boundingBox.y),
           fbits(data->boundingBox.width), fbits(data->boundingBox.height),
           fbits(data->backgroundColor.r), fbits(data->backgroundColor.g),
           fbits(data->backgroundColor.b), fbits(data->backgroundColor.a),
           fbits(data->overlayColor.r), fbits(data->overlayColor.g),
           fbits(data->overlayColor.b), fbits(data->overlayColor.a),
           fbits(data->borderColor.r), fbits(data->borderColor.g),
           fbits(data->borderColor.b), fbits(data->borderColor.a),
           (unsigned)data->borderWidth.left, (unsigned)data->borderWidth.right,
           (unsigned)data->borderWidth.top, (unsigned)data->borderWidth.bottom,
           (unsigned)data->borderWidth.betweenChildren);
}

int main(void) {
    const Clay_TransitionData initial = {
        .boundingBox = {-11.25f, 7.5f, 13.0f, 17.75f},
        .backgroundColor = {1.0f, 17.0f, 63.5f, 127.0f},
        .overlayColor = {2.0f, 19.0f, 71.5f, 131.0f},
        .borderColor = {3.0f, 23.0f, 79.5f, 137.0f},
        .borderWidth = {1001, 1003, 1005, 1007, 1009},
    };
    const Clay_TransitionData target = {
        .boundingBox = {101.5f, -31.25f, 47.0f, 89.5f},
        .backgroundColor = {201.0f, 217.0f, 231.5f, 251.0f},
        .overlayColor = {202.0f, 219.0f, 233.5f, 253.0f},
        .borderColor = {203.0f, 223.0f, 239.5f, 255.0f},
        .borderWidth = {1020, 1040, 1060, 1080, 1100},
    };
    const Clay_TransitionData sentinel = {
        .boundingBox = {301.0f, 302.0f, 303.0f, 304.0f},
        .backgroundColor = {305.0f, 306.0f, 307.0f, 308.0f},
        .overlayColor = {309.0f, 310.0f, 311.0f, 312.0f},
        .borderColor = {313.0f, 314.0f, 315.0f, 316.0f},
        .borderWidth = {317, 318, 319, 320, 321},
    };
    const Clay_TransitionProperty properties[] = {
        CLAY_TRANSITION_PROPERTY_NONE,
        CLAY_TRANSITION_PROPERTY_X,
        CLAY_TRANSITION_PROPERTY_Y,
        CLAY_TRANSITION_PROPERTY_WIDTH,
        CLAY_TRANSITION_PROPERTY_HEIGHT,
        CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR,
        CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR,
        CLAY_TRANSITION_PROPERTY_CORNER_RADIUS,
        CLAY_TRANSITION_PROPERTY_BORDER_COLOR,
        CLAY_TRANSITION_PROPERTY_BORDER_WIDTH,
        CLAY_TRANSITION_PROPERTY_BOUNDING_BOX,
        CLAY_TRANSITION_PROPERTY_BORDER,
        (Clay_TransitionProperty)511,
    };
    const float elapsed[] = {0.0f, 0.0f, 2.0f, 4.0f, 8.0f, -1.0f};
    const float duration[] = {0.0f, 4.0f, 4.0f, 4.0f, 4.0f, 4.0f};

    for (int case_index = 0; case_index < (int)(sizeof(properties) / sizeof(properties[0])); ++case_index) {
        for (int time_index = 0; time_index < (int)(sizeof(elapsed) / sizeof(elapsed[0])); ++time_index) {
            Clay_TransitionData current = sentinel;
            const bool complete = Clay_EaseOut((Clay_TransitionCallbackArguments){
                .transitionState = CLAY_TRANSITION_STATE_TRANSITIONING,
                .initial = initial,
                .current = &current,
                .target = target,
                .elapsedTime = elapsed[time_index],
                .duration = duration[time_index],
                .properties = properties[case_index],
            });
            print_data(case_index, time_index, complete, &current);
        }
    }
    return 0;
}
