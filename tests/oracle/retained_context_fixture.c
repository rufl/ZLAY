#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

typedef struct ErrorLog {
    Clay_ErrorType types[16];
    int32_t length;
} ErrorLog;

typedef struct MeasureProbe {
    char data_owner;
    char observed_function;
    int32_t calls;
} MeasureProbe;

typedef struct QueryProbe {
    char data_owner;
    char observed_function;
    int32_t calls;
} QueryProbe;

static const char callback_text_chars[] = "owner";
static const Clay_String callback_text = {
    .isStaticallyAllocated = false,
    .length = (int32_t)(sizeof(callback_text_chars) - 1),
    .chars = callback_text_chars,
};

static void record_error(Clay_ErrorData error) {
    ErrorLog *log = (ErrorLog *)error.userData;
    if (log->length >= 16) oracle_fail_log_overflow("retained-context diagnostics");
    log->types[log->length++] = error.errorType;
}

static Clay_Dimensions record_measure(
    Clay_StringSlice text,
    void *user_data,
    char function_owner
) {
    MeasureProbe *probe = (MeasureProbe *)user_data;
    if (!probe) oracle_fail_log_overflow("retained-context measure data");
    probe->observed_function = function_owner;
    probe->calls++;
    return (Clay_Dimensions){.width = (float)text.length, .height = 1};
}

static Clay_Dimensions measure_a(
    Clay_StringSlice text,
    Clay_TextElementConfig *config,
    void *user_data
) {
    (void)config;
    return record_measure(text, user_data, 'A');
}

static Clay_Dimensions measure_b(
    Clay_StringSlice text,
    Clay_TextElementConfig *config,
    void *user_data
) {
    (void)config;
    return record_measure(text, user_data, 'B');
}

static Clay_Vector2 record_query(
    uint32_t element_id,
    void *user_data,
    char function_owner
) {
    (void)element_id;
    QueryProbe *probe = (QueryProbe *)user_data;
    if (!probe) oracle_fail_log_overflow("retained-context query data");
    probe->observed_function = function_owner;
    probe->calls++;
    return (Clay_Vector2){2, 3};
}

static Clay_Vector2 query_a(uint32_t element_id, void *user_data) {
    return record_query(element_id, user_data, 'A');
}

static Clay_Vector2 query_b(uint32_t element_id, void *user_data) {
    return record_query(element_id, user_data, 'B');
}

static uint32_t f32_bits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static Clay_ElementDeclaration fixed_box(float width, float height) {
    return (Clay_ElementDeclaration){
        .layout = {.sizing = {CLAY_SIZING_FIXED(width), CLAY_SIZING_FIXED(height)}},
    };
}

static void route_context(const char *label, Clay_Context *context) {
    Clay_SetCurrentContext(context);
    const Clay_Dimensions dimensions = Clay_GetLayoutDimensions();
    printf("route %s owner %d dims %u %u\n",
           label,
           Clay_GetCurrentContext() == context ? 1 : 0,
           f32_bits(dimensions.width),
           f32_bits(dimensions.height));
}

static void print_query(const char *context_label, const char *label, Clay_ElementId id) {
    const Clay_ElementData data = Clay_GetElementData(id);
    printf("query %s %s id %u found %d box %u %u %u %u\n",
           context_label,
           label,
           id.id,
           data.found ? 1 : 0,
           f32_bits(data.boundingBox.x),
           f32_bits(data.boundingBox.y),
           f32_bits(data.boundingBox.width),
           f32_bits(data.boundingBox.height));
}

static void print_error_delta(
    const char *context_label,
    const char *label,
    const ErrorLog *log,
    int32_t start
) {
    printf("errors %s %s delta %d", context_label, label, (int)(log->length - start));
    for (int32_t index = start; index < log->length; ++index) {
        printf(" %d", (int)log->types[index]);
    }
    printf(" total %d\n", (int)log->length);
}

static void print_pointer(const char *context_label, const char *label) {
    const Clay_PointerData pointer = Clay_GetPointerState();
    Clay_ElementIdArray over = Clay_GetPointerOverIds();
    printf("pointer %s %s pos %u %u state %d over %d",
           context_label,
           label,
           f32_bits(pointer.position.x),
           f32_bits(pointer.position.y),
           (int)pointer.state,
           (int)over.length);
    for (int32_t index = 0; index < over.length; ++index) {
        const Clay_ElementId *element_id = Clay_ElementIdArray_Get(&over, index);
        printf(" %u", element_id->id);
    }
    putchar('\n');
}

static void print_scroll(const char *context_label, const char *label, Clay_ElementId id) {
    const Clay_ScrollContainerData data = Clay_GetScrollContainerData(id);
    const Clay_Vector2 position = data.scrollPosition ? *data.scrollPosition : (Clay_Vector2){0};
    printf("scroll %s %s id %u found %d pos %u %u viewport %u %u content %u %u config %d %d\n",
           context_label,
           label,
           id.id,
           data.found ? 1 : 0,
           f32_bits(position.x),
           f32_bits(position.y),
           f32_bits(data.scrollContainerDimensions.width),
           f32_bits(data.scrollContainerDimensions.height),
           f32_bits(data.contentDimensions.width),
           f32_bits(data.contentDimensions.height),
           data.config.horizontal ? 1 : 0,
           data.config.vertical ? 1 : 0);
}

static void draw_pointer_frame(Clay_ElementId id, bool print_retained_hover) {
    Clay_BeginLayout();
    Clay__OpenElementWithId(id);
    if (print_retained_hover) {
        printf("hovered A retained-declaration %d\n", Clay_Hovered() ? 1 : 0);
    }
    Clay__ConfigureOpenElement(fixed_box(40, 40));
    Clay__CloseElement();
    (void)Clay_EndLayout(0.0f);
}

static void draw_scroll(
    const char *context_label,
    const char *frame_label,
    Clay_ElementId scroll_id,
    Clay_ElementId content_id,
    float viewport_width,
    float viewport_height,
    float content_height
) {
    Clay_BeginLayout();
    Clay__OpenElementWithId(scroll_id);
    const Clay_Vector2 offset = Clay_GetScrollOffset();
    printf("offset %s %s %u %u\n",
           context_label,
           frame_label,
           f32_bits(offset.x),
           f32_bits(offset.y));
    Clay__ConfigureOpenElement((Clay_ElementDeclaration){
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(viewport_width), CLAY_SIZING_FIXED(viewport_height)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .clip = {
            .vertical = true,
            .childOffset = offset,
        },
    });
    Clay__OpenElementWithId(content_id);
    Clay__ConfigureOpenElement(fixed_box(viewport_width, content_height));
    Clay__CloseElement();
    Clay__CloseElement();
    (void)Clay_EndLayout(0.0f);
}

static void draw_empty(void) {
    Clay_BeginLayout();
    (void)Clay_EndLayout(0.0f);
}

static void draw_measure_probe(Clay_Context *context) {
    Clay_SetCurrentContext(context);
    Clay_BeginLayout();
    Clay__OpenTextElement(callback_text, (Clay_TextElementConfig){
        .fontSize = 1,
        .wrapMode = CLAY_TEXT_WRAP_NONE,
    });
    (void)Clay_EndLayout(0.0f);
}

static void print_measure_probe(const char *context_label, const MeasureProbe *probe) {
    printf("callback-owner %s install-order A-then-B function %c data %c calls %d\n",
           context_label,
           probe->observed_function,
           probe->data_owner,
           (int)probe->calls);
}

static void print_query_probe(const char *context_label, const QueryProbe *probe) {
    printf("query-callback-owner %s install-order A-then-B function %c data %c calls %d\n",
           context_label,
           probe->observed_function,
           probe->data_owner,
           (int)probe->calls);
}

static void print_debug_probe(const char *context_label) {
    printf("debug-global-owner %s after-A-set width %u color %u %u %u %u\n",
           context_label,
           Clay__debugViewWidth,
           f32_bits(Clay__debugViewHighlightColor.r),
           f32_bits(Clay__debugViewHighlightColor.g),
           f32_bits(Clay__debugViewHighlightColor.b),
           f32_bits(Clay__debugViewHighlightColor.a));
}

int main(void) {
    Clay_SetMaxElementCount(8);
    Clay_SetMaxMeasureTextCacheWordCount(32);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory_a = malloc(memory_size);
    void *memory_b = malloc(memory_size);
    if (!memory_a || !memory_b) {
        free(memory_a);
        free(memory_b);
        return 2;
    }

    ErrorLog errors_a = {0};
    ErrorLog errors_b = {0};
    Clay_Context *context_a = Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory_a),
        (Clay_Dimensions){100, 80},
        (Clay_ErrorHandler){record_error, &errors_a});
    Clay_Context *context_b = Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory_b),
        (Clay_Dimensions){160, 120},
        (Clay_ErrorHandler){record_error, &errors_b});
    if (!context_a || !context_b) {
        free(memory_a);
        free(memory_b);
        return 3;
    }

    const Clay_ElementId shared_id = CLAY_ID("retained-shared");
    const Clay_ElementId missing_id = CLAY_ID("retained-missing");
    const Clay_ElementId duplicate_id = CLAY_ID("retained-duplicate");
    const Clay_ElementId alpha_id = CLAY_ID("alpha");
    const Clay_ElementId delta_id = CLAY_ID("delta");
    const Clay_ElementId pointer_id = CLAY_ID("retained-pointer");
    const Clay_ElementId scroll_id = CLAY_ID("retained-scroll");
    const Clay_ElementId content_id = CLAY_ID("retained-scroll-content");
    const Clay_ElementId callback_scroll_id = CLAY_ID("retained-callback-scroll");
    const Clay_ElementId callback_content_id = CLAY_ID("retained-callback-scroll-content");

    puts("context-model global-current");

    route_context("A", context_a);
    Clay_SetPointerState((Clay_Vector2){1, 1}, false);
    Clay_SetPointerState((Clay_Vector2){1, 1}, false);
    print_query("A", "initial-missing", shared_id);
    print_query("A", "unknown-missing", missing_id);
    Clay_BeginLayout();
    print_query("A", "fresh-before-open", shared_id);
    Clay__OpenElementWithId(shared_id);
    print_query("A", "fresh-open", shared_id);
    Clay__ConfigureOpenElement(fixed_box(20, 30));
    Clay__CloseElement();
    print_query("A", "fresh-closed", shared_id);
    (void)Clay_EndLayout(0.0f);
    print_query("A", "fresh-ended", shared_id);
    print_pointer("A", "normalized-initial");

    route_context("B", context_b);
    Clay_SetPointerState((Clay_Vector2){150, 110}, false);
    Clay_SetPointerState((Clay_Vector2){150, 110}, false);
    print_query("B", "isolated-missing", shared_id);
    Clay_BeginLayout();
    Clay__OpenElementWithId(shared_id);
    print_query("B", "fresh-open", shared_id);
    Clay__ConfigureOpenElement(fixed_box(70, 40));
    Clay__CloseElement();
    (void)Clay_EndLayout(0.0f);
    print_query("B", "fresh-ended", shared_id);
    print_pointer("B", "normalized-initial");

    route_context("A", context_a);
    print_query("A", "prior-idle", shared_id);
    Clay_BeginLayout();
    print_query("A", "prior-open-frame", shared_id);
    (void)Clay_EndLayout(0.0f);
    print_query("A", "stale-ended", shared_id);
    print_query("A", "unknown-ended", missing_id);

    route_context("B", context_b);
    print_query("B", "retained-while-A-stale", shared_id);

    route_context("A", context_a);
    const int32_t duplicate_error_start = errors_a.length;
    Clay_BeginLayout();
    Clay__OpenElementWithId(duplicate_id);
    Clay__ConfigureOpenElement(fixed_box(10, 12));
    Clay__CloseElement();
    Clay__OpenElementWithId(duplicate_id);
    Clay__ConfigureOpenElement(fixed_box(30, 12));
    Clay__CloseElement();
    Clay__OpenElementWithId(alpha_id);
    Clay__ConfigureOpenElement(fixed_box(11, 13));
    Clay__CloseElement();
    Clay__OpenElementWithId(delta_id);
    Clay__ConfigureOpenElement(fixed_box(17, 13));
    Clay__CloseElement();
    (void)Clay_EndLayout(0.0f);
    printf("collision ids %u %u buckets %u %u distinct %d same-bucket %d\n",
           alpha_id.id,
           delta_id.id,
           alpha_id.id % 8,
           delta_id.id % 8,
           alpha_id.id != delta_id.id ? 1 : 0,
           alpha_id.id % 8 == delta_id.id % 8 ? 1 : 0);
    print_error_delta("A", "duplicate-frame", &errors_a, duplicate_error_start);
    print_query("A", "duplicate-ended", duplicate_id);
    print_query("A", "collision-alpha", alpha_id);
    print_query("A", "collision-delta", delta_id);

    const int32_t recovery_error_start = errors_a.length;
    Clay_BeginLayout();
    Clay__OpenElementWithId(duplicate_id);
    Clay__ConfigureOpenElement(fixed_box(14, 12));
    Clay__CloseElement();
    Clay__OpenElementWithId(alpha_id);
    Clay__ConfigureOpenElement(fixed_box(11, 13));
    Clay__CloseElement();
    Clay__OpenElementWithId(delta_id);
    Clay__ConfigureOpenElement(fixed_box(17, 13));
    Clay__CloseElement();
    (void)Clay_EndLayout(0.0f);
    print_error_delta("A", "duplicate-recovery", &errors_a, recovery_error_start);
    print_query("A", "duplicate-recovery", duplicate_id);
    print_query("A", "collision-alpha-recovery", alpha_id);
    print_query("A", "collision-delta-recovery", delta_id);

    draw_pointer_frame(pointer_id, false);
    Clay_SetPointerState((Clay_Vector2){5, 5}, true);
    print_pointer("A", "press");

    route_context("B", context_b);
    print_pointer("B", "unchanged-during-A-press");

    route_context("A", context_a);
    print_pointer("A", "retained-after-switch");
    draw_pointer_frame(pointer_id, true);
    print_pointer("A", "retained-after-frame");
    Clay_SetPointerState((Clay_Vector2){5, 5}, true);
    print_pointer("A", "held-resampled");
    Clay_SetPointerState((Clay_Vector2){5, 5}, false);
    Clay_SetPointerState((Clay_Vector2){5, 5}, false);

    draw_scroll("A", "frame-1", scroll_id, content_id, 40, 30, 90);
    print_pointer("A", "scroll-before-sample");
    Clay_SetPointerState((Clay_Vector2){5, 5}, false);
    print_pointer("A", "scroll-sampled");
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, -2}, 0.016f);
    print_scroll("A", "wheel", scroll_id);

    route_context("B", context_b);
    print_scroll("B", "isolated-missing", scroll_id);

    route_context("A", context_a);
    print_scroll("A", "retained-after-switch", scroll_id);
    draw_scroll("A", "frame-2", scroll_id, content_id, 40, 30, 90);
    print_scroll("A", "redrawn", scroll_id);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, 0}, 0.016f);

    route_context("B", context_b);
    draw_scroll("B", "frame-1", scroll_id, content_id, 50, 25, 75);
    Clay_SetPointerState((Clay_Vector2){5, 5}, false);
    print_pointer("B", "scroll-sampled");
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, -1}, 0.016f);
    print_scroll("B", "wheel", scroll_id);

    route_context("A", context_a);
    print_scroll("A", "unchanged-during-B-wheel", scroll_id);
    print_pointer("A", "retained-before-stale-frame");
    draw_empty();
    print_pointer("A", "retained-after-stale-frame");
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, 0}, 0.016f);
    print_scroll("A", "stale-pruned", scroll_id);
    Clay_SetPointerState((Clay_Vector2){5, 5}, false);
    print_pointer("A", "resampled-after-stale-frame");

    route_context("B", context_b);
    print_scroll("B", "retained-after-A-prune", scroll_id);

    MeasureProbe measure_probe_a = {.data_owner = 'A'};
    MeasureProbe measure_probe_b = {.data_owner = 'B'};
    Clay_SetCurrentContext(context_a);
    Clay_SetMeasureTextFunction(measure_a, &measure_probe_a);
    Clay_SetCurrentContext(context_b);
    Clay_SetMeasureTextFunction(measure_b, &measure_probe_b);
    draw_measure_probe(context_a);
    draw_measure_probe(context_b);
    print_measure_probe("A", &measure_probe_a);
    print_measure_probe("B", &measure_probe_b);

    QueryProbe query_probe_a = {.data_owner = 'A'};
    QueryProbe query_probe_b = {.data_owner = 'B'};
    Clay_SetCurrentContext(context_a);
    Clay_SetExternalScrollHandlingEnabled(true);
    Clay_SetQueryScrollOffsetFunction(query_a, &query_probe_a);
    Clay_SetCurrentContext(context_b);
    Clay_SetExternalScrollHandlingEnabled(true);
    Clay_SetQueryScrollOffsetFunction(query_b, &query_probe_b);
    Clay_SetCurrentContext(context_a);
    draw_scroll("A", "callback-owner", callback_scroll_id, callback_content_id, 40, 30, 90);
    Clay_SetCurrentContext(context_b);
    draw_scroll("B", "callback-owner", callback_scroll_id, callback_content_id, 50, 25, 75);
    print_query_probe("A", &query_probe_a);
    print_query_probe("B", &query_probe_b);

    Clay_SetCurrentContext(context_a);
    Clay__debugViewWidth = 321;
    Clay__debugViewHighlightColor = (Clay_Color){1.25f, 2.5f, 3.75f, 4.0f};
    print_debug_probe("A");
    Clay_SetCurrentContext(context_b);
    print_debug_probe("B");

    print_error_delta("B", "final", &errors_b, 0);

    route_context("A", context_a);
    print_error_delta("A", "final", &errors_a, 0);

    free(memory_a);
    free(memory_b);
    return 0;
}
