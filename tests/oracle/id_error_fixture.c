#include <stdio.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct ErrorLog {
    Clay_ErrorType types[8];
    int32_t length;
} ErrorLog;

static void record_error(Clay_ErrorData error) {
    ErrorLog *log = (ErrorLog *)error.userData;
    if (log->length >= 8) oracle_fail_log_overflow("id-error diagnostics");
    log->types[log->length++] = error.errorType;
}

static void print_id(const char *label, Clay_ElementId id) {
    // Pointer identity and isStaticallyAllocated intentionally are normalized
    // away; only the counted contents and public hash fields are serialized.
    printf("id %s %u %u %u text %d %.*s\n",
           label,
           id.id,
           id.offset,
           id.baseId,
           id.stringId.length,
           id.stringId.length,
           id.stringId.chars ? id.stringId.chars : "");
}

static void print_errors(const ErrorLog *log) {
    printf("errors %d", (int)log->length);
    for (int32_t index = 0; index < log->length; ++index) {
        printf(" %d", (int)log->types[index]);
    }
    putchar('\n');
}

static void print_lookup(const char *label, Clay_ElementId id) {
    Clay_ElementData data = Clay_GetElementData(id);
    printf("lookup %s found %d %08x %08x %08x %08x\n",
           label,
           data.found ? 1 : 0,
           oracle_f32_bits(data.boundingBox.x),
           oracle_f32_bits(data.boundingBox.y),
           oracle_f32_bits(data.boundingBox.width),
           oracle_f32_bits(data.boundingBox.height));
}

int main(void) {
    ErrorLog error_log = {0};
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(memory_size, memory);
    Clay_Initialize(arena, (Clay_Dimensions){400, 160}, (Clay_ErrorHandler){record_error, &error_log});

    char alpha_chars[] = {'a', 'l', 'p', 'h', 'a'};
    Clay_String alpha_dynamic = {
        .isStaticallyAllocated = false,
        .length = 5,
        .chars = alpha_chars,
    };
    char item_chars[] = {'i', 't', 'e', 'm'};
    Clay_String item_dynamic = {
        .isStaticallyAllocated = false,
        .length = 4,
        .chars = item_chars,
    };
    char child_chars[] = {'c', 'h', 'i', 'l', 'd'};
    Clay_String child_dynamic = {
        .isStaticallyAllocated = false,
        .length = 5,
        .chars = child_chars,
    };

    print_id("global-literal", CLAY_ID("alpha"));
    print_id("global-dynamic", Clay_GetElementId(alpha_dynamic));
    print_id("indexed-literal", CLAY_IDI("item", 7));
    print_id("indexed-dynamic", Clay_GetElementIdWithIndex(item_dynamic, 7));

    uint32_t automatic_first = 0;
    uint32_t automatic_nested = 0;
    uint32_t automatic_second = 0;
    Clay_BeginLayout();
    CLAY(CLAY_ID("parent"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(40)},
        },
    }) {
        print_id("local-literal", CLAY_ID_LOCAL("child"));
        print_id("local-dynamic", CLAY_SID_LOCAL(child_dynamic));
        print_id("indexed-local-literal", CLAY_IDI_LOCAL("child", 3));
        print_id("indexed-local-dynamic", CLAY_SIDI_LOCAL(child_dynamic, 3));

        CLAY_AUTO_ID({
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)},
            },
        }) {
            automatic_first = Clay_GetOpenElementId();
            CLAY_AUTO_ID({
                .layout = {
                    .sizing = {CLAY_SIZING_FIXED(5), CLAY_SIZING_FIXED(5)},
                },
            }) {
                automatic_nested = Clay_GetOpenElementId();
            }
        }
        CLAY_AUTO_ID({
            .layout = {
                .sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)},
            },
        }) {
            automatic_second = Clay_GetOpenElementId();
        }
    }
    (void)Clay_EndLayout(0.0f);
    printf("automatic first %u nested %u second %u\n",
           automatic_first,
           automatic_nested,
           automatic_second);

    error_log.length = 0;
    Clay_ElementId duplicate_id = CLAY_ID("duplicate");
    Clay_BeginLayout();
    CLAY(duplicate_id, {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(20)},
        },
    }) {}
    CLAY(duplicate_id, {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(30), CLAY_SIZING_FIXED(20)},
        },
    }) {}
    CLAY(CLAY_ID("percent-over"), {
        .layout = {
            .sizing = {CLAY_SIZING_PERCENT(1.5f), CLAY_SIZING_FIXED(10)},
        },
    }) {}
    CLAY(CLAY_ID("missing-floating-parent"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(5), CLAY_SIZING_FIXED(5)},
        },
        .floating = {
            .parentId = CLAY_ID("absent-parent").id,
            .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
        },
    }) {}
    (void)Clay_EndLayout(0.0f);

    print_errors(&error_log);
    print_lookup("missing", CLAY_ID("not-declared"));

    free(memory);
    return 0;
}
