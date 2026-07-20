#include <assert.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#define CLAY_IMPLEMENTATION
#include "clay.h"

static void print_text(const char *name, const uint8_t *bytes, int32_t length, Clay_TextElementConfig config) {
    Clay_String text = {
        .isStaticallyAllocated = false,
        .length = length,
        .chars = (const char *)bytes,
    };
    printf("text %s %" PRIu32 "\n", name, Clay__HashStringContentsWithConfig(&text, &config));
}

int main(void) {
    uint8_t sequence[64];
    for (int index = 0; index < 64; ++index) sequence[index] = (uint8_t)index;
    uint8_t comparison[64];
    for (int index = 0; index < 64; ++index) comparison[index] = sequence[index];
    assert(Clay__MemCmp((const char *)sequence, (const char *)comparison, 0));
    assert(Clay__MemCmp((const char *)sequence, (const char *)comparison, 33));
    comparison[0] ^= 1;
    assert(!Clay__MemCmp((const char *)sequence, (const char *)comparison, 32));
    comparison[0] ^= 1;
    comparison[32] ^= 1;
    assert(!Clay__MemCmp((const char *)sequence, (const char *)comparison, 33));

    const int lengths[] = {0, 1, 4, 7, 8, 9, 15, 16, 17, 24, 31, 32, 64};
    for (int index = 0; index < (int)(sizeof(lengths) / sizeof(lengths[0])); ++index) {
        const int length = lengths[index];
        printf("data %d %" PRIu64 "\n", length, Clay__HashData(sequence, (size_t)length));
    }

    const uint8_t binary[] = {0, 1, 2, 3, 127, 128, 255};
    printf("binary %" PRIu64 "\n", Clay__HashData(binary, sizeof(binary)));
    print_text("empty", sequence, 0, (Clay_TextElementConfig){0});
    print_text("clay", (const uint8_t *)"Clay", 4, (Clay_TextElementConfig){0});
    print_text("styled", (const uint8_t *)"Clay", 4, (Clay_TextElementConfig){
        .fontId = 7,
        .fontSize = 24,
        .letterSpacing = 3,
        .lineHeight = 40,
        .wrapMode = CLAY_TEXT_WRAP_NONE,
        .textAlignment = CLAY_TEXT_ALIGN_RIGHT,
    });
    print_text("binary", binary, (int32_t)sizeof(binary), (Clay_TextElementConfig){
        .fontId = 7,
        .fontSize = 24,
        .letterSpacing = 3,
    });
    return 0;
}
