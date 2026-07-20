#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"

typedef struct CoverageErrors {
    int32_t count;
} CoverageErrors;

static void count_error(Clay_ErrorData error) {
    CoverageErrors *errors = (CoverageErrors *)error.userData;
    if (errors) errors->count++;
}

static Clay_Dimensions measure_text(
    Clay_StringSlice text,
    Clay_TextElementConfig *config,
    void *user_data
) {
    (void)user_data;
    return (Clay_Dimensions){
        .width = (float)text.length,
        .height = config->fontSize ? (float)config->fontSize : 1.0f,
    };
}

static Clay_Dimensions measure_text_with_tall_leading_word(
    Clay_StringSlice text,
    Clay_TextElementConfig *config,
    void *user_data
) {
    (void)config;
    (void)user_data;
    return (Clay_Dimensions){
        .width = (float)text.length,
        .height = text.length > 0 && text.chars[0] == 'T' ? 50.0f : 1.0f,
    };
}

static Clay_Vector2 query_scroll(uint32_t element_id, void *user_data) {
    (void)element_id;
    (void)user_data;
    return (Clay_Vector2){0, 0};
}

static bool transition_handler(Clay_TransitionCallbackArguments arguments) {
    if (arguments.current) *arguments.current = arguments.target;
    return true;
}

static bool transition_pending_handler(Clay_TransitionCallbackArguments arguments) {
    if (arguments.current) *arguments.current = arguments.initial;
    return false;
}

static bool transition_warning_handler(Clay_TransitionCallbackArguments arguments) {
    Clay_GetCurrentContext()->booleanWarnings.maxElementsExceeded = true;
    if (arguments.current) *arguments.current = arguments.target;
    return true;
}

static Clay_TransitionData transition_initial_state(
    Clay_TransitionData target,
    Clay_TransitionProperty properties
) {
    (void)properties;
    target.boundingBox.x -= 1;
    target.boundingBox.y -= 1;
    return target;
}

static Clay_TransitionData transition_final_state(
    Clay_TransitionData initial,
    Clay_TransitionProperty properties
) {
    (void)properties;
    initial.boundingBox.x += 1;
    return initial;
}

#define EXERCISE_ARRAY(type_name, array_name)                                      \
    do {                                                                            \
        type_name storage[3] = {0};                                                  \
        type_name value = (type_name){0};                                           \
        array_name array = {.capacity = 3, .length = 1, .internalArray = storage};   \
        array_name##Slice slice = {.length = 1, .internalArray = storage};           \
        assert(array_name##_Get(&array, 0) == &storage[0]);                          \
        (void)array_name##_Get(&array, -1);                                          \
        (void)array_name##_GetValue(&array, 0);                                      \
        (void)array_name##_GetValue(&array, 1);                                      \
        assert(array_name##_GetCheckCapacity(&array, 2) == &storage[2]);             \
        (void)array_name##_GetCheckCapacity(&array, 3);                              \
        assert(array_name##_Add(&array, value) == &storage[1]);                      \
        array.length = array.capacity;                                               \
        (void)array_name##_Add(&array, value);                                       \
        assert(array_name##Slice_Get(&slice, 0) == &storage[0]);                     \
        (void)array_name##Slice_Get(&slice, 1);                                      \
        array.length = 2;                                                            \
        (void)array_name##_RemoveSwapback(&array, 0);                                \
        (void)array_name##_RemoveSwapback(&array, 2);                                \
        array.length = 1;                                                            \
        assert(array_name##_Set(&array, 0, value) == &storage[0]);                   \
        assert(array_name##_Set(&array, 2, value) == &storage[2]);                   \
        assert(array_name##_Set(&array, 3, value) == NULL);                          \
        assert(array_name##_Set_DontTouchLength(&array, 0, value) == &storage[0]);   \
        assert(array_name##_Set_DontTouchLength(&array, 3, value) == NULL);          \
    } while (0)

static void exercise_generated_arrays(void) {
    EXERCISE_ARRAY(bool, Clay__boolArray);
    EXERCISE_ARRAY(int32_t, Clay__int32_tArray);
    EXERCISE_ARRAY(char, Clay__charArray);
    EXERCISE_ARRAY(Clay_ElementId, Clay_ElementIdArray);
    EXERCISE_ARRAY(Clay_String, Clay__StringArray);
    EXERCISE_ARRAY(Clay_RenderCommand, Clay_RenderCommandArray);
    EXERCISE_ARRAY(Clay__WrappedTextLine, Clay__WrappedTextLineArray);
    EXERCISE_ARRAY(Clay_LayoutElement, Clay_LayoutElementArray);
    EXERCISE_ARRAY(Clay__ScrollContainerDataInternal, Clay__ScrollContainerDataInternalArray);
    EXERCISE_ARRAY(Clay__TransitionDataInternal, Clay__TransitionDataInternalArray);
    EXERCISE_ARRAY(Clay_LayoutElementHashMapItem, Clay__LayoutElementHashMapItemArray);
    EXERCISE_ARRAY(Clay__MeasuredWord, Clay__MeasuredWordArray);
    EXERCISE_ARRAY(Clay__MeasureTextCacheItem, Clay__MeasureTextCacheItemArray);
    EXERCISE_ARRAY(Clay__LayoutElementTreeNode, Clay__LayoutElementTreeNodeArray);
    EXERCISE_ARRAY(Clay__LayoutElementTreeRoot, Clay__LayoutElementTreeRootArray);
}

static void exercise_basic_internals(CoverageErrors *errors) {
    volatile int32_t low = 1;
    volatile int32_t high = 2;
    assert(CLAY__MAX(low, high) == high);
    assert(CLAY__MAX(high, low) == high);
    assert(CLAY__MIN(low, high) == low);
    assert(CLAY__MIN(high, low) == low);

    Clay__SuppressUnusedLatchDefinitionVariableWarning();
    Clay__ErrorHandlerFunctionDefault((Clay_ErrorData){0});

    unsigned char tiny_memory[sizeof(Clay_Context)] = {0};
    Clay_Arena context_arena = Clay_CreateArenaWithCapacityAndMemory(0, tiny_memory);
    assert(Clay__Context_Allocate_Arena(&context_arena) == NULL);
    assert(Clay_Initialize(context_arena, (Clay_Dimensions){1, 1}, (Clay_ErrorHandler){0}) == NULL);

    char chars[8] = {0};
    Clay__charArray buffer = {.capacity = 8, .length = 0, .internalArray = chars};
    Clay_String empty = Clay__WriteStringToCharBuffer(&buffer, CLAY_STRING(""));
    Clay_String word = Clay__WriteStringToCharBuffer(&buffer, CLAY_STRING("abc"));
    assert(empty.length == 0 && word.length == 3 && buffer.length == 3);

    unsigned char arena_memory[128] = {0};
    Clay_Arena tiny_arena = Clay_CreateArenaWithCapacityAndMemory(0, arena_memory);
    assert(Clay__WarningArray_Allocate_Arena(1, &tiny_arena).internalArray == NULL);
    assert(Clay__Array_Allocate_Arena(1, 1, &tiny_arena) == NULL);

    Clay__Warning warning_storage[1] = {0};
    Clay__WarningArray warnings = {
        .capacity = 1,
        .length = 0,
        .internalArray = warning_storage,
    };
    (void)Clay__WarningArray_Add(&warnings, (Clay__Warning){0});
    assert(Clay__WarningArray_Add(&warnings, (Clay__Warning){0}) == &CLAY__WARNING_DEFAULT);

    assert(errors->count > 0);

    Clay_LayoutElement aspect = {.config = {.aspectRatio = {.aspectRatio = 2}}};
    Clay__UpdateAspectRatioBox(&aspect);
    aspect.dimensions = (Clay_Dimensions){10, 0};
    Clay__UpdateAspectRatioBox(&aspect);
    aspect.dimensions = (Clay_Dimensions){10, 10};
    Clay__UpdateAspectRatioBox(&aspect);

    Clay_BoundingBox offscreen = {-20, 0, 10, 10};
    assert(Clay__ElementIsOffscreen(&offscreen));
    offscreen = (Clay_BoundingBox){0, -20, 10, 10};
    assert(Clay__ElementIsOffscreen(&offscreen));
}

static void exercise_default_handler_context(void) {
    Clay_Context *original = Clay_GetCurrentContext();
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    assert(memory);

    Clay_Context *context = Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){32, 32},
        (Clay_ErrorHandler){0});
    assert(context);
    assert(context->errorHandler.errorHandlerFunction == Clay__ErrorHandlerFunctionDefault);

    Clay_SetCurrentContext(original);
    free(memory);
}

static void exercise_open_state_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    Clay_BeginLayout();
    assert(Clay__GetParentElementId() == Clay__GetParentElement()->id);

    Clay_BorderElementConfig border = {0};
    assert(!Clay__BorderHasAnyWidth(&border));
    border.width.betweenChildren = 1;
    assert(Clay__BorderHasAnyWidth(&border));
    border = (Clay_BorderElementConfig){.width = {.left = 1}};
    assert(Clay__BorderHasAnyWidth(&border));
    border = (Clay_BorderElementConfig){.width = {.right = 1}};
    assert(Clay__BorderHasAnyWidth(&border));
    border = (Clay_BorderElementConfig){.width = {.top = 1}};
    assert(Clay__BorderHasAnyWidth(&border));
    border = (Clay_BorderElementConfig){.width = {.bottom = 1}};
    assert(Clay__BorderHasAnyWidth(&border));

    context->booleanWarnings.maxElementsExceeded = true;
    Clay__OpenElement();
    Clay__OpenElementWithId(CLAY_ID("blocked-open"));
    Clay__OpenTextElement(CLAY_STRING("blocked-text"), (Clay_TextElementConfig){0});
    assert(!Clay_Hovered());
    Clay_OnHover(NULL, NULL);
    assert(Clay_GetScrollOffset().x == 0);
    Clay_SetPointerState((Clay_Vector2){0, 0}, false);
    context->booleanWarnings.maxElementsExceeded = false;

    Clay__OpenElement();
    Clay__ConfigureOpenElement((Clay_ElementDeclaration){
        .layout = {.sizing = {
            CLAY_SIZING_PERCENT(1.5f),
            CLAY_SIZING_FIXED(1),
        }},
    });
    Clay__CloseElement();
    Clay__OpenElement();
    Clay__ConfigureOpenElement((Clay_ElementDeclaration){
        .layout = {.sizing = {
            CLAY_SIZING_FIXED(1),
            CLAY_SIZING_PERCENT(1.5f),
        }},
    });
    Clay__CloseElement();

    (void)Clay_EndLayout(0.0f);
}

static void exercise_capacity_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    Clay_TextElementConfig text_config = {.fontSize = 12};
    Clay_String text = CLAY_STRING("coverage-cache-capacity");

    const int32_t measured_length = context->measureTextHashMapInternal.length;
    context->measureTextHashMapInternal.length = context->measureTextHashMapInternal.capacity - 1;
    context->booleanWarnings.maxTextMeasureCacheExceeded = false;
    assert(Clay__MeasureTextCached(&text, &text_config) == &Clay__MeasureTextCacheItem_DEFAULT);
    assert(context->booleanWarnings.maxTextMeasureCacheExceeded);
    assert(Clay__MeasureTextCached(&text, &text_config) == &Clay__MeasureTextCacheItem_DEFAULT);
    context->measureTextHashMapInternal.length = measured_length;

    const int32_t map_length = context->layoutElementsHashMapInternal.length;
    context->layoutElementsHashMapInternal.length = context->layoutElementsHashMapInternal.capacity - 1;
    context->booleanWarnings.hashMapCapacityExceeded = false;
    assert(Clay__AddHashMapItem(CLAY_ID("coverage-map-capacity"), NULL) == NULL);
    assert(context->booleanWarnings.hashMapCapacityExceeded);
    assert(Clay__AddHashMapItem(CLAY_ID("coverage-map-capacity-2"), NULL) == NULL);
    context->layoutElementsHashMapInternal.length = map_length;

    context->renderCommands.length = context->renderCommands.capacity - 1;
    context->booleanWarnings.maxRenderCommandsExceeded = false;
    Clay__AddRenderCommand((Clay_RenderCommand){0});
    Clay__AddRenderCommand((Clay_RenderCommand){0});
    context->renderCommands.length = 0;
}

static void exercise_text_height_max_path(void) {
    Clay_String text = CLAY_STRING("Tall x");
    Clay_TextElementConfig config = {.fontSize = 37};
    Clay_SetMeasureTextFunction(measure_text_with_tall_leading_word, NULL);
    Clay__MeasureTextCacheItem *measured = Clay__MeasureTextCached(&text, &config);
    assert(measured != &Clay__MeasureTextCacheItem_DEFAULT);
    assert(measured->unwrappedDimensions.height == 50.0f);
    Clay_SetMeasureTextFunction(measure_text, NULL);
}

static Clay_ElementDeclaration coverage_box(float width, float height) {
    return (Clay_ElementDeclaration){
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(width), CLAY_SIZING_FIXED(height)},
        },
    };
}

static void exercise_layout_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    context->debugModeEnabled = false;
    Clay_Dimensions original_dimensions = Clay_GetLayoutDimensions();
    Clay_SetLayoutDimensions((Clay_Dimensions){
        original_dimensions.width,
        original_dimensions.height + 1,
    });
    Clay_SetLayoutDimensions(original_dimensions);
    Clay_SetLayoutDimensions(original_dimensions);
    Clay_BeginLayout();

    CLAY(CLAY_ID("coverage-percent-height"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_PERCENT(0.5f)},
        },
    }) {}

    Clay_ElementId floating_parent = CLAY_ID("coverage-floating-parent");
    CLAY(floating_parent, coverage_box(120, 80)) {
        CLAY(CLAY_ID("coverage-floating-grow-percent"), {
            .layout = {
                .sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_PERCENT(0.5f)},
            },
            .floating = {
                .parentId = floating_parent.id,
                .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
            },
        }) {}
        CLAY(CLAY_ID("coverage-floating-percent-grow"), {
            .layout = {
                .sizing = {CLAY_SIZING_PERCENT(0.5f), CLAY_SIZING_GROW(0)},
            },
            .floating = {
                .parentId = floating_parent.id,
                .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
            },
        }) {}
    }

    CLAY(CLAY_ID("coverage-horizontal-align"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
            .layoutDirection = CLAY_LEFT_TO_RIGHT,
            .childAlignment = {CLAY_ALIGN_X_RIGHT, CLAY_ALIGN_Y_BOTTOM},
        },
    }) {
        CLAY_AUTO_ID(coverage_box(10, 10)) {}
    }
    CLAY(CLAY_ID("coverage-vertical-align"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
            .childAlignment = {CLAY_ALIGN_X_LEFT, CLAY_ALIGN_Y_CENTER},
        },
    }) {
        CLAY_AUTO_ID(coverage_box(10, 10)) {}
    }
    CLAY(CLAY_ID("coverage-vertical-bottom-align"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(100), CLAY_SIZING_FIXED(100)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
            .childAlignment = {CLAY_ALIGN_X_LEFT, CLAY_ALIGN_Y_BOTTOM},
        },
    }) {
        CLAY_AUTO_ID(coverage_box(10, 10)) {}
    }

    CLAY(CLAY_ID("coverage-bounded-min-height"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIT(20, 40)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
    }) {
        CLAY_AUTO_ID(coverage_box(1, 1)) {}
    }

    CLAY(CLAY_ID("coverage-horizontal-overflow-align"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(20)},
            .layoutDirection = CLAY_LEFT_TO_RIGHT,
            .childAlignment = {CLAY_ALIGN_X_RIGHT, CLAY_ALIGN_Y_TOP},
        },
        .clip = {.horizontal = true},
    }) {
        CLAY_AUTO_ID(coverage_box(50, 5)) {}
    }
    CLAY(CLAY_ID("coverage-vertical-overflow-align"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(10)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
            .childAlignment = {CLAY_ALIGN_X_LEFT, CLAY_ALIGN_Y_BOTTOM},
        },
        .clip = {.vertical = true},
    }) {
        CLAY_AUTO_ID(coverage_box(5, 50)) {}
    }

    CLAY(CLAY_ID("coverage-missing-floating-parent"), {
        .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}},
        .floating = {
            .parentId = CLAY_ID("coverage-does-not-exist").id,
            .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
        },
    }) {}

    (void)Clay_EndLayout(0.0f);
}

static void exercise_invalid_enum_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    Clay_ElementId invalid_attach_id = CLAY_ID("coverage-invalid-attach-target");
    context->debugModeEnabled = false;

    Clay_BeginLayout();
    CLAY(CLAY_ID("coverage-invalid-layout-direction"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(40), CLAY_SIZING_FIXED(40)},
            .layoutDirection = (Clay_LayoutDirection)255,
        },
    }) {
        CLAY_AUTO_ID(coverage_box(10, 10)) {}
    }
    CLAY(CLAY_ID("coverage-invalid-y-alignment"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(40), CLAY_SIZING_FIXED(40)},
            .layoutDirection = CLAY_LEFT_TO_RIGHT,
            .childAlignment = {.y = (Clay_LayoutAlignmentY)255},
        },
    }) {
        CLAY_AUTO_ID(coverage_box(10, 10)) {}
    }
    CLAY(CLAY_ID("coverage-invalid-x-alignment"), {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(40), CLAY_SIZING_FIXED(40)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
            .childAlignment = {.x = (Clay_LayoutAlignmentX)255},
        },
    }) {
        CLAY_AUTO_ID(coverage_box(10, 10)) {}
    }
    CLAY(CLAY_ID("coverage-invalid-attach-points"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .floating = {
            .attachPoints = {
                .element = (Clay_FloatingAttachPointType)255,
                .parent = (Clay_FloatingAttachPointType)255,
            },
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
    }) {}
    CLAY(invalid_attach_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .floating = {.attachTo = (Clay_FloatingAttachToElement)255},
    }) {}
    Clay__RenderDebugLayoutSizing(
        (Clay_SizingAxis){.type = (Clay__SizingType)255},
        (Clay_TextElementConfig){.fontSize = 12});
    (void)Clay_EndLayout(0.0f);

    context->debugModeEnabled = true;
    context->debugSelectedElementId = invalid_attach_id.id;
    context->pointerInfo.state = CLAY_POINTER_DATA_RELEASED;
    context->pointerOverIds.length = 0;
    Clay_BeginLayout();
    CLAY(invalid_attach_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .floating = {.attachTo = (Clay_FloatingAttachToElement)255},
    }) {}
    (void)Clay_EndLayout(0.0f);
    context->debugModeEnabled = false;
    context->debugSelectedElementId = 0;
}

static void exercise_debug_label_and_sizing_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    (void)Clay__DebugGetElementConfigTypeLabel((Clay__DebugElementConfigType)255);

    context->debugModeEnabled = false;
    Clay_BeginLayout();
    Clay_TextElementConfig text_config = {.fontSize = 12};
    Clay__RenderDebugLayoutSizing(CLAY_SIZING_GROW(0), text_config);
    Clay__RenderDebugLayoutSizing(CLAY_SIZING_FIT(1, 2), text_config);
    Clay__RenderDebugLayoutSizing(CLAY_SIZING_FIXED(3), text_config);
    Clay__RenderDebugLayoutSizing(CLAY_SIZING_PERCENT(0.5f), text_config);
    Clay__RenderDebugLayoutSizing((Clay_SizingAxis){
        .size = {.minMax = {1, CLAY__MAXFLOAT}},
        .type = CLAY__SIZING_TYPE_FIT,
    }, text_config);
    Clay__RenderDebugLayoutSizing((Clay_SizingAxis){
        .size = {.minMax = {0, CLAY__MAXFLOAT}},
        .type = CLAY__SIZING_TYPE_GROW,
    }, text_config);
    (void)Clay_EndLayout(0.0f);
}

static unsigned char coverage_image;

static Clay_SizingAxis coverage_sizing_for_index(int32_t index) {
    switch (index & 3) {
        case 0: return CLAY_SIZING_GROW(1, 90);
        case 1: return CLAY_SIZING_FIT(1, 90);
        case 2: return CLAY_SIZING_FIXED(40);
        default: return CLAY_SIZING_PERCENT(0.5f);
    }
}

static void exercise_selected_debug_frames(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    context->debugModeEnabled = true;

    for (int32_t index = 0; index < 9; ++index) {
        Clay_BeginLayout();
        Clay_ElementId parent_id = Clay_GetElementIdWithIndex(CLAY_STRING("coverage-debug-parent"), (uint32_t)index + 1);
        CLAY(parent_id, coverage_box(100, 80)) {}

        Clay_ElementId selected_id = Clay_GetElementIdWithIndex(CLAY_STRING("coverage-debug-selected"), (uint32_t)index + 1);
        Clay_FloatingAttachToElement attach_to = index % 3 == 0
                                                     ? CLAY_ATTACH_TO_PARENT
                                                     : (index % 3 == 1 ? CLAY_ATTACH_TO_ELEMENT_WITH_ID : CLAY_ATTACH_TO_ROOT);
        Clay_ElementDeclaration declaration = {
            .layout = {
                .sizing = {coverage_sizing_for_index(index), coverage_sizing_for_index(index + 1)},
                .childAlignment = {
                    index & 1 ? CLAY_ALIGN_X_CENTER : CLAY_ALIGN_X_RIGHT,
                    index & 1 ? CLAY_ALIGN_Y_CENTER : CLAY_ALIGN_Y_BOTTOM,
                },
            },
            .backgroundColor = {20, 40, 60, 255},
            .overlayColor = {80, 100, 120, 128},
            .cornerRadius = {1, 2, 3, 4},
            .aspectRatio = {.aspectRatio = 1.05f},
            .image = {.imageData = &coverage_image},
            .floating = {
                .offset = {index == 8 ? 10000.0f : (float)index, (float)index},
                .parentId = parent_id.id,
                .attachPoints = {
                    .element = (Clay_FloatingAttachPointType)index,
                    .parent = (Clay_FloatingAttachPointType)index,
                },
                .pointerCaptureMode = index & 1
                                          ? CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH
                                          : CLAY_POINTER_CAPTURE_MODE_CAPTURE,
                .attachTo = attach_to,
                .clipTo = index & 1 ? CLAY_CLIP_TO_NONE : CLAY_CLIP_TO_ATTACHED_PARENT,
            },
            .clip = {.horizontal = true, .vertical = true},
            .border = {.width = {1, 1, 1, 1, 1}},
        };
        CLAY(selected_id, declaration) {}

        if (index == 0) {
            CLAY(selected_id, coverage_box(10, 10)) {}
        }

        context->debugSelectedElementId = selected_id.id;
        (void)Clay_EndLayout(0.0f);
        context->debugModeEnabled = true;
    }

    Clay_BeginLayout();
    CLAY_TEXT(
        CLAY_STRING("this debug text is deliberately longer than forty characters for coverage"),
        CLAY_TEXT_CONFIG({
            .fontSize = 12,
            .wrapMode = CLAY_TEXT_WRAP_NONE,
            .textAlignment = CLAY_TEXT_ALIGN_CENTER,
        }));
    context->debugSelectedElementId = context->layoutElements.internalArray[context->layoutElements.length - 1].id;
    (void)Clay_EndLayout(0.0f);
    context->debugModeEnabled = true;

    Clay_BeginLayout();
    Clay_ElementId rich_id = CLAY_ID("coverage-debug-rich-nonfloating");
    CLAY(rich_id, {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(40), CLAY_SIZING_FIXED(40)},
            .childAlignment = {CLAY_ALIGN_X_LEFT, CLAY_ALIGN_Y_TOP},
        },
        .image = {.imageData = &coverage_image},
        .clip = {.vertical = true},
    }) {}
    context->debugSelectedElementId = rich_id.id;
    (void)Clay_EndLayout(0.0f);
    context->debugModeEnabled = true;

    Clay_BeginLayout();
    CLAY(CLAY_ID("coverage-debug-exiting"), coverage_box(10, 10)) {}
    context->layoutElements.internalArray[context->layoutElements.length - 1].exiting = true;
    (void)Clay_EndLayout(0.0f);
    context->debugModeEnabled = true;
}

static void exercise_debug_close_and_external_scroll_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    context->debugModeEnabled = true;
    Clay_BeginLayout();
    context->pointerInfo.state = CLAY_POINTER_DATA_PRESSED_THIS_FRAME;
    Clay_ElementIdArray_Add(
        &context->pointerOverIds,
        CLAY_ID("Clay__DebugViewTopHeaderCloseButtonOuter"));
    (void)Clay_EndLayout(0.0f);

    context->debugModeEnabled = true;
    context->externalScrollHandlingEnabled = true;
    context->pointerInfo.state = CLAY_POINTER_DATA_RELEASED;
    context->pointerOverIds.length = 0;
    Clay_BeginLayout();
    Clay__ScrollContainerDataInternalArray_Add(
        &context->scrollContainerDatas,
        (Clay__ScrollContainerDataInternal){
            .elementId = CLAY_ID("Clay__DebugViewOuterScrollPane").id,
            .scrollPosition = {0, -20},
            .openThisFrame = true,
        });
    Clay__RenderDebugView();
    context->debugModeEnabled = false;
    (void)Clay_EndLayout(0.0f);
    context->externalScrollHandlingEnabled = false;
    context->debugModeEnabled = false;
}

static void exercise_offscreen_debug_path(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    Clay_ElementId offscreen_id = CLAY_ID("coverage-debug-offscreen");

    context->debugModeEnabled = false;
    Clay_BeginLayout();
    CLAY(offscreen_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .floating = {
            .offset = {10000, 10000},
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
    }) {
        CLAY_TEXT(CLAY_STRING("offscreen text"), CLAY_TEXT_CONFIG({
            .fontSize = 12,
            .wrapMode = CLAY_TEXT_WRAP_WORDS,
        }));
    }
    (void)Clay_EndLayout(0.0f);

    context->debugModeEnabled = true;
    context->pointerInfo.state = CLAY_POINTER_DATA_RELEASED;
    context->pointerOverIds.length = 0;
    Clay_BeginLayout();
    CLAY(offscreen_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .floating = {
            .offset = {10000, 10000},
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
    }) {
        CLAY_TEXT(CLAY_STRING("offscreen text"), CLAY_TEXT_CONFIG({
            .fontSize = 12,
            .wrapMode = CLAY_TEXT_WRAP_WORDS,
        }));
    }
    (void)Clay_EndLayout(0.0f);
    context->debugModeEnabled = false;
}

static void exercise_additional_debug_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    Clay_ElementId clip_id = CLAY_ID("coverage-debug-clip-row");

    context->debugModeEnabled = false;
    Clay_BeginLayout();
    CLAY(clip_id, {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(40)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .clip = {.vertical = true},
    }) {
        CLAY_AUTO_ID(coverage_box(10, 10)) {}
    }
    (void)Clay_EndLayout(0.0f);
    Clay_LayoutElementHashMapItem *clip_item = Clay__GetHashMapItem(clip_id.id);
    assert(clip_item != &Clay_LayoutElementHashMapItem_DEFAULT);
    clip_item->debugData.collapsed = true;

    context->debugModeEnabled = true;
    context->debugSelectedElementId = clip_id.id;
    context->pointerInfo.position.y = context->layoutDimensions.height;
    context->pointerInfo.state = CLAY_POINTER_DATA_RELEASED;
    context->pointerOverIds.length = 0;
    Clay_BeginLayout();
    CLAY(clip_id, {
        .layout = {
            .sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(40)},
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
        },
        .clip = {.horizontal = true},
    }) {
        CLAY_AUTO_ID(coverage_box(10, 10)) {}
    }
    (void)Clay_EndLayout(0.0f);

    context->debugModeEnabled = true;
    context->pointerInfo.position = (Clay_Vector2){0, 0};
    Clay_BeginLayout();
    CLAY_TEXT(CLAY_STRING("words aligned left"), CLAY_TEXT_CONFIG({
        .fontSize = 12,
        .wrapMode = CLAY_TEXT_WRAP_WORDS,
        .textAlignment = CLAY_TEXT_ALIGN_LEFT,
    }));
    context->debugSelectedElementId =
        context->layoutElements.internalArray[context->layoutElements.length - 1].id;
    (void)Clay__WarningArray_Add(&context->warnings, (Clay__Warning){
        .baseMessage = CLAY_STRING("coverage warning without detail"),
    });
    (void)Clay_EndLayout(0.0f);

    context->debugModeEnabled = true;
    context->debugSelectedElementId = 0;
    Clay_BeginLayout();
    (void)Clay__WarningArray_Add(&context->warnings, (Clay__Warning){
        .baseMessage = CLAY_STRING("coverage warning without detail"),
    });
    (void)Clay_EndLayout(0.0f);
    context->debugModeEnabled = false;
    context->debugSelectedElementId = 0;
}

static void exercise_pointer_transition_and_query_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    Clay_ElementId id = CLAY_ID("coverage-pointer-transition");
    context->debugModeEnabled = false;

    Clay_BeginLayout();
    CLAY(id, coverage_box(40, 40)) {}
    (void)Clay_EndLayout(0.0f);

    Clay_LayoutElementHashMapItem *item = Clay__GetHashMapItem(id.id);
    assert(item != &Clay_LayoutElementHashMapItem_DEFAULT);
    item->layoutElement->config.transition.handler = transition_handler;
    item->layoutElement->config.transition.interactionHandling =
        CLAY_TRANSITION_ALLOW_INTERACTIONS_WHILE_TRANSITIONING_POSITION;
    Clay__TransitionDataInternalArray_Add(
        &context->transitionDatas,
        (Clay__TransitionDataInternal){
            .elementThisFrame = item->layoutElement,
            .elementId = id.id,
            .state = CLAY_TRANSITION_STATE_EXITING,
        });
    Clay_SetPointerState((Clay_Vector2){1, 1}, false);
    context->transitionDatas.length = 0;

    item->generation = context->generation;
    Clay_SetPointerState((Clay_Vector2){1, 1}, false);
    item->generation = context->generation + 1;

    Clay_BoundingBox box = {0};
    Clay_LayoutElement element = {0};
    Clay_TransitionData transition = {
        .boundingBox = {1, 2, 3, 4},
    };
    Clay_ApplyTransitionedPropertiesToElement(
        &element,
        CLAY_TRANSITION_PROPERTY_DIMENSIONS,
        transition,
        &box,
        true);
    assert(box.width == 3 && box.height == 4);

    Clay_ElementId missing_layout_id = CLAY_ID("coverage-scroll-null-layout");
    Clay__ScrollContainerDataInternalArray_Add(
        &context->scrollContainerDatas,
        (Clay__ScrollContainerDataInternal){.elementId = missing_layout_id.id});
    assert(!Clay_GetScrollContainerData(missing_layout_id).found);
    context->scrollContainerDatas.length--;
}

static void exercise_floating_clip_axis_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    context->debugModeEnabled = false;
    context->externalScrollHandlingEnabled = true;

    Clay_BeginLayout();
    Clay_ElementId horizontal_id = CLAY_ID("coverage-horizontal-clip-parent");
    CLAY(horizontal_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(60)}},
        .clip = {.horizontal = true, .childOffset = {2, 3}},
    }) {
        CLAY(CLAY_ID("coverage-horizontal-clip-float"), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
            .floating = {
                .attachTo = CLAY_ATTACH_TO_PARENT,
                .clipTo = CLAY_CLIP_TO_ATTACHED_PARENT,
            },
            .transition = {
                .handler = transition_handler,
                .properties = CLAY_TRANSITION_PROPERTY_POSITION,
            },
        }) {}
    }

    Clay_ElementId vertical_id = CLAY_ID("coverage-vertical-clip-parent");
    CLAY(vertical_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(60)}},
        .clip = {.vertical = true, .childOffset = {4, 5}},
    }) {
        CLAY(CLAY_ID("coverage-vertical-clip-float"), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
            .floating = {
                .attachTo = CLAY_ATTACH_TO_PARENT,
                .clipTo = CLAY_CLIP_TO_ATTACHED_PARENT,
            },
        }) {}
    }

    Clay_ElementId offscreen_id = CLAY_ID("coverage-offscreen-clip-parent");
    CLAY(offscreen_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(60)}},
        .floating = {
            .offset = {10000, 10000},
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
        .clip = {.horizontal = true},
    }) {
        CLAY(CLAY_ID("coverage-offscreen-clipped-float"), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
            .floating = {
                .attachTo = CLAY_ATTACH_TO_PARENT,
                .clipTo = CLAY_CLIP_TO_ATTACHED_PARENT,
            },
        }) {}
    }
    (void)Clay_EndLayout(0.0f);

    context->transitionDatas.length = 0;
    context->externalScrollHandlingEnabled = false;
}

static void exercise_scroll_update_branches(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    Clay_LayoutElement element = {
        .dimensions = {50, 50},
        .config = {
            .clip = {.horizontal = true, .vertical = true},
        },
        .id = CLAY_ID("coverage-direct-scroll").id,
    };

    context->scrollContainerDatas.length = 0;
    context->pointerOverIds.length = 0;
    Clay__ScrollContainerDataInternal *scroll = Clay__ScrollContainerDataInternalArray_Add(
        &context->scrollContainerDatas,
        (Clay__ScrollContainerDataInternal){
            .layoutElement = &element,
            .contentSize = {200, 200},
            .scrollOrigin = {0, 0},
            .scrollPosition = {-20, 20},
            .momentumTime = 1,
            .elementId = element.id,
            .openThisFrame = true,
            .pointerScrollActive = true,
        });
    assert(scroll);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){1, 1}, 0.016f);

    context->scrollContainerDatas.length = 0;
    scroll = Clay__ScrollContainerDataInternalArray_Add(
        &context->scrollContainerDatas,
        (Clay__ScrollContainerDataInternal){
            .layoutElement = &element,
            .contentSize = {200, 200},
            .scrollPosition = {-500, -500},
            .elementId = element.id,
            .openThisFrame = true,
        });
    assert(scroll);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, 0}, 0.016f);

    context->scrollContainerDatas.length = 0;
    scroll = Clay__ScrollContainerDataInternalArray_Add(
        &context->scrollContainerDatas,
        (Clay__ScrollContainerDataInternal){
            .layoutElement = &element,
            .contentSize = {200, 200},
            .scrollOrigin = {0, 0},
            .scrollPosition = {20, 0},
            .momentumTime = 1,
            .elementId = element.id,
            .openThisFrame = true,
            .pointerScrollActive = true,
        });
    assert(scroll);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){1, 0}, 0.016f);

    context->scrollContainerDatas.length = 0;
    context->pointerOverIds.length = 0;
    scroll = Clay__ScrollContainerDataInternalArray_Add(
        &context->scrollContainerDatas,
        (Clay__ScrollContainerDataInternal){
            .layoutElement = &element,
            .contentSize = {25, 25},
            .elementId = element.id,
            .openThisFrame = true,
        });
    assert(scroll);
    Clay_ElementIdArray_Add(&context->pointerOverIds, (Clay_ElementId){.id = element.id});
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, 0}, 0.016f);

    context->scrollContainerDatas.length = 0;
    context->pointerOverIds.length = 0;
    scroll = Clay__ScrollContainerDataInternalArray_Add(
        &context->scrollContainerDatas,
        (Clay__ScrollContainerDataInternal){
            .layoutElement = &element,
            .contentSize = {200, 200},
            .boundingBox = {0, 0, 50, 50},
            .scrollPosition = {-50, -50},
            .elementId = element.id,
            .openThisFrame = true,
        });
    assert(scroll);
    Clay_ElementIdArray_Add(&context->pointerOverIds, (Clay_ElementId){.id = element.id});
    context->pointerInfo = (Clay_PointerData){
        .position = {0, 0},
        .state = CLAY_POINTER_DATA_PRESSED,
    };
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.1f);

    scroll->openThisFrame = true;
    context->pointerInfo.position = (Clay_Vector2){20, 0};
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.1f);

    scroll->openThisFrame = true;
    context->pointerInfo.position = (Clay_Vector2){20, 20};
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.1f);

    context->scrollContainerDatas.length = 0;
    context->pointerOverIds.length = 0;
    scroll = Clay__ScrollContainerDataInternalArray_Add(
        &context->scrollContainerDatas,
        (Clay__ScrollContainerDataInternal){
            .layoutElement = &element,
            .contentSize = {200, 200},
            .boundingBox = {0, 0, 50, 50},
            .elementId = element.id,
            .openThisFrame = true,
        });
    assert(scroll);
    Clay_ElementIdArray_Add(&context->pointerOverIds, (Clay_ElementId){.id = element.id});
    context->pointerInfo = (Clay_PointerData){
        .position = {0, 0},
        .state = CLAY_POINTER_DATA_PRESSED,
    };
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.1f);

    scroll->openThisFrame = true;
    context->pointerInfo.position = (Clay_Vector2){500, 500};
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.1f);

    scroll->openThisFrame = true;
    scroll->scrollOrigin = (Clay_Vector2){0, 0};
    scroll->pointerOrigin = (Clay_Vector2){0, 0};
    context->pointerInfo.position = (Clay_Vector2){-500, -500};
    Clay_UpdateScrollContainers(true, (Clay_Vector2){0, 0}, 0.1f);

    context->scrollContainerDatas.length = 0;
    context->pointerOverIds.length = 0;
    context->pointerInfo = (Clay_PointerData){.state = CLAY_POINTER_DATA_RELEASED};
}

static void exercise_clip_record_capacity_path(CoverageErrors *errors) {
    Clay_Context *original = Clay_GetCurrentContext();
    Clay_SetCurrentContext(NULL);
    Clay_SetMaxElementCount(256);
    Clay_SetMaxMeasureTextCacheWordCount(512);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *allocation = malloc((size_t)memory_size + 63);
    assert(allocation);
    void *memory = (void *)(((uintptr_t)allocation + 63) & ~(uintptr_t)63);

    Clay_Context *context = Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){640, 480},
        (Clay_ErrorHandler){count_error, errors});
    assert(context);

    int32_t error_count_before = errors->count;
    Clay_BeginLayout();
    for (int32_t index = 0; index < 101; ++index) {
        CLAY(CLAY_IDI("coverage-clip-record-capacity", index), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(1), CLAY_SIZING_FIXED(1)}},
            .clip = {.horizontal = true},
        }) {}
    }
    (void)Clay_EndLayout(0.0f);
    assert(context->scrollContainerDatas.length == 100);
    assert(errors->count > error_count_before);

    Clay_SetCurrentContext(original);
    free(allocation);
}

static void exercise_nested_transition_removal_path(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    context->debugModeEnabled = false;

    Clay_TransitionElementConfig parent_transition = {
        .handler = transition_handler,
        .properties = CLAY_TRANSITION_PROPERTY_POSITION,
        .exit = {.setFinalState = transition_final_state},
    };
    Clay_TransitionElementConfig child_transition = {
        .handler = transition_handler,
        .properties = CLAY_TRANSITION_PROPERTY_POSITION,
        .exit = {
            .setFinalState = transition_final_state,
            .trigger = CLAY_TRANSITION_EXIT_TRIGGER_WHEN_PARENT_EXITS,
        },
    };

    Clay_BeginLayout();
    CLAY(CLAY_ID("coverage-exiting-transition-parent"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(20)}},
        .transition = parent_transition,
    }) {
        CLAY(CLAY_ID("coverage-exiting-transition-child"), {
            .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
            .transition = child_transition,
        }) {}
    }
    (void)Clay_EndLayout(0.0f);

    Clay_BeginLayout();
    (void)Clay_EndLayout(0.0f);

    Clay_ElementId moved_parent_id = CLAY_ID("coverage-moved-transition-parent");
    Clay_ElementId moved_child_id = CLAY_ID("coverage-moved-transition-child");
    Clay_BeginLayout();
    CLAY(moved_parent_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(20)}},
        .transition = parent_transition,
    }) {
        CLAY(moved_child_id, coverage_box(10, 10)) {}
    }
    (void)Clay_EndLayout(0.0f);
    Clay_BeginLayout();
    CLAY(moved_child_id, coverage_box(10, 10)) {}
    (void)Clay_EndLayout(0.0f);

    Clay_ElementId plain_parent_id = CLAY_ID("coverage-plain-transition-parent");
    Clay_BeginLayout();
    CLAY(plain_parent_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(20)}},
        .transition = parent_transition,
    }) {
        CLAY(CLAY_ID("coverage-plain-transition-child"), coverage_box(10, 10)) {}
    }
    (void)Clay_EndLayout(0.0f);
    Clay_BeginLayout();
    (void)Clay_EndLayout(0.0f);
}

static void exercise_pointer_transition_blocking_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    Clay_ElementId id = CLAY_ID("coverage-blocked-transition-pointer");
    context->debugModeEnabled = false;

    Clay_BeginLayout();
    CLAY(id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(40), CLAY_SIZING_FIXED(40)}},
        .transition = {
            .handler = transition_pending_handler,
            .properties = CLAY_TRANSITION_PROPERTY_POSITION,
            .enter = {
                .setInitialState = transition_initial_state,
                .trigger = CLAY_TRANSITION_ENTER_TRIGGER_ON_FIRST_PARENT_FRAME,
            },
        },
    }) {}
    (void)Clay_EndLayout(0.0f);

    Clay__TransitionDataInternal *data = NULL;
    for (int32_t index = 0; index < context->transitionDatas.length; ++index) {
        Clay__TransitionDataInternal *candidate =
            Clay__TransitionDataInternalArray_Get(&context->transitionDatas, index);
        if (candidate->elementId == id.id) data = candidate;
    }
    assert(data);
    Clay_LayoutElementHashMapItem *item = Clay__GetHashMapItem(id.id);
    assert(item != &Clay_LayoutElementHashMapItem_DEFAULT);
    data->state = CLAY_TRANSITION_STATE_ENTERING;
    data->activeProperties = CLAY_TRANSITION_PROPERTY_POSITION;
    Clay_SetPointerState((Clay_Vector2){1, 1}, false);

    data->state = CLAY_TRANSITION_STATE_IDLE;
    data->activeProperties = CLAY_TRANSITION_PROPERTY_POSITION;
    Clay_SetPointerState((Clay_Vector2){1, 1}, false);

    item->layoutElement->config.transition.interactionHandling =
        (Clay_TransitionInteractionHandlingType)255;
    item->generation = context->generation + 1;
    data->state = CLAY_TRANSITION_STATE_EXITING;
    Clay_SetPointerState((Clay_Vector2){1, 1}, false);

    item->generation = context->generation;
    Clay_SetPointerState((Clay_Vector2){1, 1}, false);

    context->transitionDatas.length = 0;
}

static void exercise_transition_suppression_paths(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    context->debugModeEnabled = false;
    Clay_TransitionElementConfig transition = {
        .handler = transition_pending_handler,
        .properties = CLAY_TRANSITION_PROPERTY_BOUNDING_BOX,
    };

    Clay_ElementId moving_parent = CLAY_ID("coverage-moving-parent");
    Clay_ElementId moving_child = CLAY_ID("coverage-moving-child");
    Clay_BeginLayout();
    CLAY(moving_parent, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(60), CLAY_SIZING_FIXED(60)}},
        .floating = {.attachTo = CLAY_ATTACH_TO_ROOT},
    }) {
        CLAY(moving_child, {
            .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
            .transition = transition,
        }) {}
    }
    (void)Clay_EndLayout(0.0f);

    Clay_BeginLayout();
    CLAY(moving_parent, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(60), CLAY_SIZING_FIXED(60)}},
        .floating = {
            .offset = {10, 20},
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
    }) {
        CLAY(moving_child, {
            .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
            .transition = transition,
        }) {}
    }
    (void)Clay_EndLayout(0.0f);

    Clay_ElementId resize_id = CLAY_ID("coverage-resize-suppression");
    Clay_Dimensions dimensions = Clay_GetLayoutDimensions();
    Clay_BeginLayout();
    CLAY(resize_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .floating = {
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
        .transition = transition,
    }) {}
    (void)Clay_EndLayout(0.0f);

    Clay_SetLayoutDimensions((Clay_Dimensions){dimensions.width + 20, dimensions.height + 20});
    Clay_BeginLayout();
    CLAY(resize_id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(20), CLAY_SIZING_FIXED(20)}},
        .floating = {
            .offset = {10, 20},
            .attachTo = CLAY_ATTACH_TO_ROOT,
        },
        .transition = transition,
    }) {}
    (void)Clay_EndLayout(0.0f);
    Clay_SetLayoutDimensions(dimensions);
    Clay_SetLayoutDimensions(dimensions);
    context->transitionDatas.length = 0;
}

static void exercise_transition_warning_continuation(void) {
    Clay_Context *context = Clay_GetCurrentContext();
    Clay_ElementId id = CLAY_ID("coverage-transition-warning-continuation");
    Clay_TransitionElementConfig transition = {
        .handler = transition_warning_handler,
        .properties = CLAY_TRANSITION_PROPERTY_POSITION,
    };
    context->debugModeEnabled = false;
    context->booleanWarnings.maxElementsExceeded = false;

    Clay_BeginLayout();
    CLAY(id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .transition = transition,
    }) {}
    (void)Clay_EndLayout(0.0f);

    Clay__TransitionDataInternal *data = NULL;
    for (int32_t index = 0; index < context->transitionDatas.length; ++index) {
        Clay__TransitionDataInternal *candidate =
            Clay__TransitionDataInternalArray_Get(&context->transitionDatas, index);
        if (candidate->elementId == id.id) data = candidate;
    }
    assert(data);
    data->state = (Clay_TransitionState)255;
    data->activeProperties = CLAY_TRANSITION_PROPERTY_POSITION;

    Clay_BeginLayout();
    CLAY(id, {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .transition = transition,
    }) {}
    (void)Clay_EndLayout(0.0f);
    assert(context->booleanWarnings.maxElementsExceeded);

    context->booleanWarnings.maxElementsExceeded = false;
    context->transitionDatas.length = 0;
}

static void exercise_debug_overflow_paths(CoverageErrors *errors) {
    Clay_Context *original = Clay_GetCurrentContext();
    Clay_SetCurrentContext(NULL);
    Clay_SetMaxElementCount(64);
    Clay_SetMaxMeasureTextCacheWordCount(256);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    assert(memory);

    Clay_Context *context = Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){800, 400},
        (Clay_ErrorHandler){count_error, errors});
    assert(context);
    Clay_SetMeasureTextFunction(measure_text, NULL);

    context->debugModeEnabled = false;
    Clay_BeginLayout();
    CLAY(CLAY_ID("coverage-debug-transition"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .transition = {
            .handler = transition_handler,
            .properties = CLAY_TRANSITION_PROPERTY_POSITION,
        },
    }) {}
    (void)Clay_EndLayout(0.0f);

    context->debugModeEnabled = true;
    context->pointerInfo.state = CLAY_POINTER_DATA_RELEASED;
    context->pointerOverIds.length = 0;
    Clay_BeginLayout();
    CLAY(CLAY_ID("coverage-debug-transition"), {
        .layout = {.sizing = {CLAY_SIZING_FIXED(10), CLAY_SIZING_FIXED(10)}},
        .transition = {
            .handler = transition_handler,
            .properties = CLAY_TRANSITION_PROPERTY_POSITION,
        },
    }) {}
    (void)Clay_EndLayout(0.0f);
    context->transitionDatas.length = 0;

    context->debugModeEnabled = true;
    context->pointerInfo.state = CLAY_POINTER_DATA_RELEASED;
    context->pointerOverIds.length = 0;
    Clay_BeginLayout();
    for (int32_t index = 0; index < 50; ++index) {
        Clay__OpenElement();
        Clay__ConfigureOpenElement(coverage_box(1, 1));
        Clay__CloseElement();
    }
    (void)Clay_EndLayout(0.0f);

    Clay_SetCurrentContext(original);
    free(memory);
}

int main(void) {
    CoverageErrors errors = {0};
    Clay_SetMaxElementCount(512);
    Clay_SetMaxMeasureTextCacheWordCount(2048);
    const uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;

    Clay_Context *context = Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){640, 480},
        (Clay_ErrorHandler){count_error, &errors});
    if (!context) {
        free(memory);
        return 3;
    }
    Clay_SetMeasureTextFunction(measure_text, NULL);
    Clay_SetQueryScrollOffsetFunction(query_scroll, NULL);

    exercise_generated_arrays();
    exercise_basic_internals(&errors);
    exercise_default_handler_context();
    exercise_open_state_paths();
    exercise_capacity_paths();
    exercise_text_height_max_path();
    exercise_layout_paths();
    exercise_invalid_enum_paths();
    exercise_debug_label_and_sizing_paths();
    exercise_selected_debug_frames();
    exercise_debug_close_and_external_scroll_paths();
    exercise_offscreen_debug_path();
    exercise_additional_debug_paths();
    exercise_pointer_transition_and_query_paths();
    exercise_floating_clip_axis_paths();
    exercise_scroll_update_branches();
    exercise_clip_record_capacity_path(&errors);
    exercise_nested_transition_removal_path();
    exercise_pointer_transition_blocking_paths();
    exercise_transition_suppression_paths();
    exercise_transition_warning_continuation();
    exercise_debug_overflow_paths(&errors);

    free(memory);
    return 0;
}
