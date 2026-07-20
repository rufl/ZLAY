#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CLAY_DISABLE_SIMD
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "oracle_contract.h"

static uint32_t f32_bits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static void print_axis(const char *label, Clay_SizingAxis axis) {
    uint32_t min_bits = 0;
    uint32_t max_bits = 0;
    uint32_t percent_bits = 0;
    if (axis.type == CLAY__SIZING_TYPE_PERCENT) {
        percent_bits = f32_bits(axis.size.percent);
    } else {
        min_bits = f32_bits(axis.size.minMax.min);
        max_bits = f32_bits(axis.size.minMax.max);
    }
    printf("axis %s type %u min %08x max %08x percent %08x\n",
           label,
           (unsigned)axis.type,
           min_bits,
           max_bits,
           percent_bits);
}

static void print_color(const char *label, Clay_Color color) {
    printf("color %s %08x %08x %08x %08x\n",
           label,
           f32_bits(color.r),
           f32_bits(color.g),
           f32_bits(color.b),
           f32_bits(color.a));
}

static void print_box(const char *label, Clay_BoundingBox box) {
    printf("box %s %08x %08x %08x %08x\n",
           label,
           f32_bits(box.x),
           f32_bits(box.y),
           f32_bits(box.width),
           f32_bits(box.height));
}

static void print_border_width(const char *label, Clay_BorderWidth width) {
    printf("border-width %s %u %u %u %u %u\n",
           label,
           (unsigned)width.left,
           (unsigned)width.right,
           (unsigned)width.top,
           (unsigned)width.bottom,
           (unsigned)width.betweenChildren);
}

static void print_id(const char *label, Clay_ElementId id) {
    printf("id %s %u %u %u static %u len %d bytes ",
           label,
           id.id,
           id.offset,
           id.baseId,
           id.stringId.isStaticallyAllocated ? 1u : 0u,
           (int)id.stringId.length);
    for (int32_t index = 0; index < id.stringId.length; ++index) {
        printf("%02x", (unsigned)(uint8_t)id.stringId.chars[index]);
    }
    putchar('\n');
}

static void report_error(Clay_ErrorData error) {
    oracle_fail_on_error(error);
}

static Clay_ElementDeclaration fixed_box(float width, float height) {
    Clay_ElementDeclaration declaration = {0};
    declaration.layout.sizing.width = CLAY_SIZING_FIXED(width);
    declaration.layout.sizing.height = CLAY_SIZING_FIXED(height);
    return declaration;
}

static int print_enums(void) {
    int count = 0;
#define PRINT_ENUM(group, value) do { printf("enum %s %s %d\n", #group, #value, (int)(value)); count++; } while (0)
    PRINT_ENUM(LayoutDirection, CLAY_LEFT_TO_RIGHT);
    PRINT_ENUM(LayoutDirection, CLAY_TOP_TO_BOTTOM);
    PRINT_ENUM(LayoutAlignmentX, CLAY_ALIGN_X_LEFT);
    PRINT_ENUM(LayoutAlignmentX, CLAY_ALIGN_X_RIGHT);
    PRINT_ENUM(LayoutAlignmentX, CLAY_ALIGN_X_CENTER);
    PRINT_ENUM(LayoutAlignmentY, CLAY_ALIGN_Y_TOP);
    PRINT_ENUM(LayoutAlignmentY, CLAY_ALIGN_Y_BOTTOM);
    PRINT_ENUM(LayoutAlignmentY, CLAY_ALIGN_Y_CENTER);
    PRINT_ENUM(SizingType, CLAY__SIZING_TYPE_FIT);
    PRINT_ENUM(SizingType, CLAY__SIZING_TYPE_GROW);
    PRINT_ENUM(SizingType, CLAY__SIZING_TYPE_PERCENT);
    PRINT_ENUM(SizingType, CLAY__SIZING_TYPE_FIXED);
    PRINT_ENUM(TextWrapMode, CLAY_TEXT_WRAP_WORDS);
    PRINT_ENUM(TextWrapMode, CLAY_TEXT_WRAP_NEWLINES);
    PRINT_ENUM(TextWrapMode, CLAY_TEXT_WRAP_NONE);
    PRINT_ENUM(TextAlignment, CLAY_TEXT_ALIGN_LEFT);
    PRINT_ENUM(TextAlignment, CLAY_TEXT_ALIGN_CENTER);
    PRINT_ENUM(TextAlignment, CLAY_TEXT_ALIGN_RIGHT);
    PRINT_ENUM(FloatingAttachPoint, CLAY_ATTACH_POINT_LEFT_TOP);
    PRINT_ENUM(FloatingAttachPoint, CLAY_ATTACH_POINT_LEFT_CENTER);
    PRINT_ENUM(FloatingAttachPoint, CLAY_ATTACH_POINT_LEFT_BOTTOM);
    PRINT_ENUM(FloatingAttachPoint, CLAY_ATTACH_POINT_CENTER_TOP);
    PRINT_ENUM(FloatingAttachPoint, CLAY_ATTACH_POINT_CENTER_CENTER);
    PRINT_ENUM(FloatingAttachPoint, CLAY_ATTACH_POINT_CENTER_BOTTOM);
    PRINT_ENUM(FloatingAttachPoint, CLAY_ATTACH_POINT_RIGHT_TOP);
    PRINT_ENUM(FloatingAttachPoint, CLAY_ATTACH_POINT_RIGHT_CENTER);
    PRINT_ENUM(FloatingAttachPoint, CLAY_ATTACH_POINT_RIGHT_BOTTOM);
    PRINT_ENUM(PointerCaptureMode, CLAY_POINTER_CAPTURE_MODE_CAPTURE);
    PRINT_ENUM(PointerCaptureMode, CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH);
    PRINT_ENUM(FloatingAttachTo, CLAY_ATTACH_TO_NONE);
    PRINT_ENUM(FloatingAttachTo, CLAY_ATTACH_TO_PARENT);
    PRINT_ENUM(FloatingAttachTo, CLAY_ATTACH_TO_ELEMENT_WITH_ID);
    PRINT_ENUM(FloatingAttachTo, CLAY_ATTACH_TO_ROOT);
    PRINT_ENUM(FloatingClipTo, CLAY_CLIP_TO_NONE);
    PRINT_ENUM(FloatingClipTo, CLAY_CLIP_TO_ATTACHED_PARENT);
    PRINT_ENUM(TransitionState, CLAY_TRANSITION_STATE_IDLE);
    PRINT_ENUM(TransitionState, CLAY_TRANSITION_STATE_ENTERING);
    PRINT_ENUM(TransitionState, CLAY_TRANSITION_STATE_TRANSITIONING);
    PRINT_ENUM(TransitionState, CLAY_TRANSITION_STATE_EXITING);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_NONE);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_X);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_Y);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_POSITION);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_WIDTH);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_HEIGHT);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_DIMENSIONS);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_BOUNDING_BOX);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_CORNER_RADIUS);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_BORDER_COLOR);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_BORDER_WIDTH);
    PRINT_ENUM(TransitionProperty, CLAY_TRANSITION_PROPERTY_BORDER);
    PRINT_ENUM(TransitionEnterTrigger, CLAY_TRANSITION_ENTER_SKIP_ON_FIRST_PARENT_FRAME);
    PRINT_ENUM(TransitionEnterTrigger, CLAY_TRANSITION_ENTER_TRIGGER_ON_FIRST_PARENT_FRAME);
    PRINT_ENUM(TransitionExitTrigger, CLAY_TRANSITION_EXIT_SKIP_WHEN_PARENT_EXITS);
    PRINT_ENUM(TransitionExitTrigger, CLAY_TRANSITION_EXIT_TRIGGER_WHEN_PARENT_EXITS);
    PRINT_ENUM(TransitionInteraction, CLAY_TRANSITION_DISABLE_INTERACTIONS_WHILE_TRANSITIONING_POSITION);
    PRINT_ENUM(TransitionInteraction, CLAY_TRANSITION_ALLOW_INTERACTIONS_WHILE_TRANSITIONING_POSITION);
    PRINT_ENUM(ExitSiblingOrdering, CLAY_EXIT_TRANSITION_ORDERING_UNDERNEATH_SIBLINGS);
    PRINT_ENUM(ExitSiblingOrdering, CLAY_EXIT_TRANSITION_ORDERING_NATURAL_ORDER);
    PRINT_ENUM(ExitSiblingOrdering, CLAY_EXIT_TRANSITION_ORDERING_ABOVE_SIBLINGS);
    PRINT_ENUM(RenderCommandType, CLAY_RENDER_COMMAND_TYPE_NONE);
    PRINT_ENUM(RenderCommandType, CLAY_RENDER_COMMAND_TYPE_RECTANGLE);
    PRINT_ENUM(RenderCommandType, CLAY_RENDER_COMMAND_TYPE_BORDER);
    PRINT_ENUM(RenderCommandType, CLAY_RENDER_COMMAND_TYPE_TEXT);
    PRINT_ENUM(RenderCommandType, CLAY_RENDER_COMMAND_TYPE_IMAGE);
    PRINT_ENUM(RenderCommandType, CLAY_RENDER_COMMAND_TYPE_SCISSOR_START);
    PRINT_ENUM(RenderCommandType, CLAY_RENDER_COMMAND_TYPE_SCISSOR_END);
    PRINT_ENUM(RenderCommandType, CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START);
    PRINT_ENUM(RenderCommandType, CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END);
    PRINT_ENUM(RenderCommandType, CLAY_RENDER_COMMAND_TYPE_CUSTOM);
    PRINT_ENUM(PointerState, CLAY_POINTER_DATA_PRESSED_THIS_FRAME);
    PRINT_ENUM(PointerState, CLAY_POINTER_DATA_PRESSED);
    PRINT_ENUM(PointerState, CLAY_POINTER_DATA_RELEASED_THIS_FRAME);
    PRINT_ENUM(PointerState, CLAY_POINTER_DATA_RELEASED);
    PRINT_ENUM(ErrorType, CLAY_ERROR_TYPE_TEXT_MEASUREMENT_FUNCTION_NOT_PROVIDED);
    PRINT_ENUM(ErrorType, CLAY_ERROR_TYPE_ARENA_CAPACITY_EXCEEDED);
    PRINT_ENUM(ErrorType, CLAY_ERROR_TYPE_ELEMENTS_CAPACITY_EXCEEDED);
    PRINT_ENUM(ErrorType, CLAY_ERROR_TYPE_TEXT_MEASUREMENT_CAPACITY_EXCEEDED);
    PRINT_ENUM(ErrorType, CLAY_ERROR_TYPE_DUPLICATE_ID);
    PRINT_ENUM(ErrorType, CLAY_ERROR_TYPE_FLOATING_CONTAINER_PARENT_NOT_FOUND);
    PRINT_ENUM(ErrorType, CLAY_ERROR_TYPE_PERCENTAGE_OVER_1);
    PRINT_ENUM(ErrorType, CLAY_ERROR_TYPE_INTERNAL_ERROR);
    PRINT_ENUM(ErrorType, CLAY_ERROR_TYPE_UNBALANCED_OPEN_CLOSE);
    PRINT_ENUM(ErrorType, CLAY_ERROR_TYPE_HASH_MAP_CAPACITY_EXCEEDED);
#undef PRINT_ENUM
    printf("enum-count %d\n", count);
    return count;
}

static void print_transition_masks(void) {
    printf("transition-mask position %u\n", (unsigned)(CLAY_TRANSITION_PROPERTY_X | CLAY_TRANSITION_PROPERTY_Y));
    printf("transition-mask dimensions %u\n", (unsigned)(CLAY_TRANSITION_PROPERTY_WIDTH | CLAY_TRANSITION_PROPERTY_HEIGHT));
    printf("transition-mask bounding-box %u\n", (unsigned)(CLAY_TRANSITION_PROPERTY_POSITION | CLAY_TRANSITION_PROPERTY_DIMENSIONS));
    printf("transition-mask border %u\n", (unsigned)(CLAY_TRANSITION_PROPERTY_BORDER_COLOR | CLAY_TRANSITION_PROPERTY_BORDER_WIDTH));
    printf("transition-mask supported %u\n", (unsigned)(CLAY_TRANSITION_PROPERTY_BOUNDING_BOX |
                                                           CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR |
                                                           CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR |
                                                           CLAY_TRANSITION_PROPERTY_BORDER));
    printf("transition-mask all-declared %u\n", (unsigned)(CLAY_TRANSITION_PROPERTY_BOUNDING_BOX |
                                                            CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR |
                                                            CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR |
                                                            CLAY_TRANSITION_PROPERTY_CORNER_RADIUS |
                                                            CLAY_TRANSITION_PROPERTY_BORDER));
}

static void print_defaults(void) {
    Clay_String string = {0};
    Clay_StringSlice string_slice = {0};
    Clay_Arena arena = {0};
    Clay_Dimensions dimensions = {0};
    Clay_Vector2 vector = {0};
    Clay_Color color = {0};
    Clay_BoundingBox box = {0};
    Clay_ElementId id = {0};
    Clay_ElementIdArray id_array = {0};
    Clay_CornerRadius radius = {0};
    Clay_ChildAlignment alignment = {0};
    Clay_SizingMinMax min_max = {0};
    Clay_SizingAxis axis = {0};
    Clay_Sizing sizing = {0};
    Clay_Padding padding = {0};
    Clay_LayoutConfig layout = {0};
    Clay_TextElementConfig text = {0};
    Clay_AspectRatioElementConfig aspect = {0};
    Clay_ImageElementConfig image = {0};
    Clay_FloatingAttachPoints attach_points = {0};
    Clay_FloatingElementConfig floating = {0};
    Clay_CustomElementConfig custom = {0};
    Clay_ClipElementConfig clip = {0};
    Clay_BorderWidth border_width = {0};
    Clay_BorderElementConfig border = {0};
    Clay_TransitionData transition_data = {0};
    Clay_TransitionData transition_current = {0};
    Clay_TransitionCallbackArguments transition_arguments = { .current = &transition_current };
    Clay_TransitionElementConfig transition = {0};
    Clay_TextRenderData text_render = {0};
    Clay_RectangleRenderData rectangle_render = {0};
    Clay_ImageRenderData image_render = {0};
    Clay_CustomRenderData custom_render = {0};
    Clay_ClipRenderData clip_render = {0};
    Clay_OverlayColorRenderData overlay_render = {0};
    Clay_BorderRenderData border_render = {0};
    Clay_RenderData render_data = {0};
    Clay_ScrollContainerData scroll_data = {0};
    Clay_ElementData element_data = {0};
    Clay_RenderCommand render_command = {0};
    Clay_RenderCommandArray render_array = {0};
    Clay_PointerData pointer = {0};
    Clay_ElementDeclaration declaration = {0};
    Clay_ErrorData error_data = {0};
    Clay_ErrorHandler error_handler = {0};

    printf("default String static %u length %d\n", string.isStaticallyAllocated ? 1u : 0u, (int)string.length);
    printf("default StringSlice length %d\n", (int)string_slice.length);
    printf("default Arena next %zu capacity %zu\n", (size_t)arena.nextAllocation, arena.capacity);
    printf("default Dimensions %08x %08x\n", f32_bits(dimensions.width), f32_bits(dimensions.height));
    printf("default Vector2 %08x %08x\n", f32_bits(vector.x), f32_bits(vector.y));
    print_color("default-Color", color);
    print_box("default-BoundingBox", box);
    printf("default ElementId %u %u %u static %u length %d\n", id.id, id.offset, id.baseId, id.stringId.isStaticallyAllocated ? 1u : 0u, (int)id.stringId.length);
    printf("default ElementIdArray capacity %d length %d\n", (int)id_array.capacity, (int)id_array.length);
    printf("default CornerRadius %08x %08x %08x %08x\n", f32_bits(radius.topLeft), f32_bits(radius.topRight), f32_bits(radius.bottomLeft), f32_bits(radius.bottomRight));
    printf("default ChildAlignment %u %u\n", (unsigned)alignment.x, (unsigned)alignment.y);
    printf("default SizingMinMax %08x %08x\n", f32_bits(min_max.min), f32_bits(min_max.max));
    print_axis("default-SizingAxis", axis);
    print_axis("default-Sizing.width", sizing.width);
    print_axis("default-Sizing.height", sizing.height);
    printf("default Padding %u %u %u %u\n", (unsigned)padding.left, (unsigned)padding.right, (unsigned)padding.top, (unsigned)padding.bottom);
    print_axis("default-LayoutConfig.width", layout.sizing.width);
    print_axis("default-LayoutConfig.height", layout.sizing.height);
    printf("default LayoutConfig padding %u %u %u %u gap %u align %u %u direction %u\n",
           (unsigned)layout.padding.left, (unsigned)layout.padding.right, (unsigned)layout.padding.top, (unsigned)layout.padding.bottom,
           (unsigned)layout.childGap, (unsigned)layout.childAlignment.x, (unsigned)layout.childAlignment.y, (unsigned)layout.layoutDirection);
    printf("default TextElementConfig userdata %u color %08x %08x %08x %08x font %u %u spacing %u line %u wrap %u align %u\n",
           text.userData ? 1u : 0u,
           f32_bits(text.textColor.r), f32_bits(text.textColor.g), f32_bits(text.textColor.b), f32_bits(text.textColor.a),
           (unsigned)text.fontId, (unsigned)text.fontSize, (unsigned)text.letterSpacing, (unsigned)text.lineHeight,
           (unsigned)text.wrapMode, (unsigned)text.textAlignment);
    printf("default AspectRatio %08x\n", f32_bits(aspect.aspectRatio));
    printf("default Image data %u\n", image.imageData ? 1u : 0u);
    printf("default FloatingAttachPoints %u %u\n", (unsigned)attach_points.element, (unsigned)attach_points.parent);
    printf("default Floating offset %08x %08x expand %08x %08x parent %u z %d points %u %u capture %u attach %u clip %u\n",
           f32_bits(floating.offset.x), f32_bits(floating.offset.y), f32_bits(floating.expand.width), f32_bits(floating.expand.height),
           floating.parentId, (int)floating.zIndex, (unsigned)floating.attachPoints.element, (unsigned)floating.attachPoints.parent,
           (unsigned)floating.pointerCaptureMode, (unsigned)floating.attachTo, (unsigned)floating.clipTo);
    printf("default Custom data %u\n", custom.customData ? 1u : 0u);
    printf("default Clip %u %u offset %08x %08x\n", clip.horizontal ? 1u : 0u, clip.vertical ? 1u : 0u, f32_bits(clip.childOffset.x), f32_bits(clip.childOffset.y));
    print_border_width("default-BorderWidth", border_width);
    print_color("default-Border.color", border.color);
    print_border_width("default-Border.width", border.width);
    print_box("default-TransitionData.box", transition_data.boundingBox);
    print_color("default-TransitionData.background", transition_data.backgroundColor);
    print_color("default-TransitionData.overlay", transition_data.overlayColor);
    print_color("default-TransitionData.border", transition_data.borderColor);
    print_border_width("default-TransitionData.width", transition_data.borderWidth);
    printf("default TransitionCallbackArguments state %u current %u elapsed %08x duration %08x properties %u\n",
           (unsigned)transition_arguments.transitionState, transition_arguments.current ? 1u : 0u,
           f32_bits(transition_arguments.elapsedTime), f32_bits(transition_arguments.duration), (unsigned)transition_arguments.properties);
    printf("default TransitionElementConfig handler %u duration %08x properties %u interaction %u enter-fn %u enter-trigger %u exit-fn %u exit-trigger %u ordering %u\n",
           transition.handler ? 1u : 0u, f32_bits(transition.duration), (unsigned)transition.properties, (unsigned)transition.interactionHandling,
           transition.enter.setInitialState ? 1u : 0u, (unsigned)transition.enter.trigger,
           transition.exit.setFinalState ? 1u : 0u, (unsigned)transition.exit.trigger, (unsigned)transition.exit.siblingOrdering);
    printf("default TextRender length %d color %08x %08x %08x %08x font %u %u spacing %u line %u\n",
           (int)text_render.stringContents.length,
           f32_bits(text_render.textColor.r), f32_bits(text_render.textColor.g), f32_bits(text_render.textColor.b), f32_bits(text_render.textColor.a),
           (unsigned)text_render.fontId, (unsigned)text_render.fontSize, (unsigned)text_render.letterSpacing, (unsigned)text_render.lineHeight);
    print_color("default-RectangleRender.color", rectangle_render.backgroundColor);
    printf("default RectangleRender radius %08x %08x %08x %08x\n", f32_bits(rectangle_render.cornerRadius.topLeft), f32_bits(rectangle_render.cornerRadius.topRight), f32_bits(rectangle_render.cornerRadius.bottomLeft), f32_bits(rectangle_render.cornerRadius.bottomRight));
    printf("default ImageRender data %u\n", image_render.imageData ? 1u : 0u);
    printf("default CustomRender data %u\n", custom_render.customData ? 1u : 0u);
    printf("default ClipRender %u %u\n", clip_render.horizontal ? 1u : 0u, clip_render.vertical ? 1u : 0u);
    print_color("default-OverlayRender.color", overlay_render.color);
    print_color("default-BorderRender.color", border_render.color);
    print_border_width("default-BorderRender.width", border_render.width);
    print_color("default-RenderData.rectangle", render_data.rectangle.backgroundColor);
    printf("default ScrollContainer pointer %u container %08x %08x content %08x %08x config %u %u found %u\n",
           scroll_data.scrollPosition ? 1u : 0u,
           f32_bits(scroll_data.scrollContainerDimensions.width), f32_bits(scroll_data.scrollContainerDimensions.height),
           f32_bits(scroll_data.contentDimensions.width), f32_bits(scroll_data.contentDimensions.height),
           scroll_data.config.horizontal ? 1u : 0u, scroll_data.config.vertical ? 1u : 0u, scroll_data.found ? 1u : 0u);
    print_box("default-ElementData.box", element_data.boundingBox);
    printf("default ElementData found %u\n", element_data.found ? 1u : 0u);
    print_box("default-RenderCommand.box", render_command.boundingBox);
    printf("default RenderCommand userdata %u id %u z %d type %u active-rectangle-a %08x\n",
           render_command.userData ? 1u : 0u, render_command.id, (int)render_command.zIndex,
           (unsigned)render_command.commandType, f32_bits(render_command.renderData.rectangle.backgroundColor.a));
    printf("default RenderCommandArray capacity %d length %d\n", (int)render_array.capacity, (int)render_array.length);
    printf("default PointerData position %08x %08x state %u\n", f32_bits(pointer.position.x), f32_bits(pointer.position.y), (unsigned)pointer.state);
    printf("default ElementDeclaration background-a %08x overlay-a %08x aspect %08x image %u floating-attach %u custom %u clip %u %u border-between %u transition-handler %u userdata %u\n",
           f32_bits(declaration.backgroundColor.a), f32_bits(declaration.overlayColor.a), f32_bits(declaration.aspectRatio.aspectRatio),
           declaration.image.imageData ? 1u : 0u, (unsigned)declaration.floating.attachTo,
           declaration.custom.customData ? 1u : 0u, declaration.clip.horizontal ? 1u : 0u, declaration.clip.vertical ? 1u : 0u,
           (unsigned)declaration.border.width.betweenChildren, declaration.transition.handler ? 1u : 0u, declaration.userData ? 1u : 0u);
    printf("default ErrorData type %u static %u length %d userdata %u\n",
           (unsigned)error_data.errorType, error_data.errorText.isStaticallyAllocated ? 1u : 0u,
           (int)error_data.errorText.length, error_data.userData ? 1u : 0u);
    printf("default ErrorHandler function %u userdata %u\n", error_handler.errorHandlerFunction ? 1u : 0u, error_handler.userData ? 1u : 0u);
}

static void print_helpers(void) {
    print_axis("helper-fit-empty", CLAY_SIZING_FIT());
    print_axis("helper-fit-min", CLAY_SIZING_FIT(5.0f));
    print_axis("helper-fit-minmax", CLAY_SIZING_FIT(5.0f, 9.0f));
    print_axis("helper-grow-empty", CLAY_SIZING_GROW());
    print_axis("helper-grow-min", CLAY_SIZING_GROW(6.0f));
    print_axis("helper-grow-minmax", CLAY_SIZING_GROW(6.0f, 10.0f));
    print_axis("helper-fixed", CLAY_SIZING_FIXED(13.5f));
    print_axis("helper-percent", CLAY_SIZING_PERCENT(0.375f));

    Clay_Padding padding = CLAY_PADDING_ALL(7);
    Clay_CornerRadius radius = CLAY_CORNER_RADIUS(2.5f);
    Clay_BorderWidth outside = CLAY_BORDER_OUTSIDE(3);
    Clay_BorderWidth all = CLAY_BORDER_ALL(4);
    Clay_String literal = CLAY_STRING("macro-string");
    printf("helper Padding %u %u %u %u\n", (unsigned)padding.left, (unsigned)padding.right, (unsigned)padding.top, (unsigned)padding.bottom);
    printf("helper CornerRadius %08x %08x %08x %08x\n", f32_bits(radius.topLeft), f32_bits(radius.topRight), f32_bits(radius.bottomLeft), f32_bits(radius.bottomRight));
    print_border_width("helper-border-outside", outside);
    print_border_width("helper-border-all", all);
    printf("helper String static %u length %d bytes ", literal.isStaticallyAllocated ? 1u : 0u, (int)literal.length);
    for (int32_t index = 0; index < literal.length; ++index) printf("%02x", (unsigned)(uint8_t)literal.chars[index]);
    putchar('\n');
}

static void print_globals(void) {
    printf("global layout-default gap %u direction %u width-type %u\n",
           (unsigned)CLAY_LAYOUT_DEFAULT.childGap,
           (unsigned)CLAY_LAYOUT_DEFAULT.layoutDirection,
           (unsigned)CLAY_LAYOUT_DEFAULT.sizing.width.type);
    Clay_LayoutConfig saved_layout = CLAY_LAYOUT_DEFAULT;
    CLAY_LAYOUT_DEFAULT.childGap = 17;
    CLAY_LAYOUT_DEFAULT.layoutDirection = CLAY_TOP_TO_BOTTOM;
    CLAY_LAYOUT_DEFAULT.sizing.width = CLAY_SIZING_FIXED(23.5f);
    printf("global layout-roundtrip gap %u direction %u width-type %u min %08x max %08x\n",
           (unsigned)CLAY_LAYOUT_DEFAULT.childGap,
           (unsigned)CLAY_LAYOUT_DEFAULT.layoutDirection,
           (unsigned)CLAY_LAYOUT_DEFAULT.sizing.width.type,
           f32_bits(CLAY_LAYOUT_DEFAULT.sizing.width.size.minMax.min),
           f32_bits(CLAY_LAYOUT_DEFAULT.sizing.width.size.minMax.max));
    CLAY_LAYOUT_DEFAULT = saved_layout;

    printf("global debug-default width %u color %08x %08x %08x %08x\n",
           Clay__debugViewWidth,
           f32_bits(Clay__debugViewHighlightColor.r),
           f32_bits(Clay__debugViewHighlightColor.g),
           f32_bits(Clay__debugViewHighlightColor.b),
           f32_bits(Clay__debugViewHighlightColor.a));
    uint32_t saved_width = Clay__debugViewWidth;
    Clay_Color saved_color = Clay__debugViewHighlightColor;
    Clay__debugViewWidth = 321;
    Clay__debugViewHighlightColor = (Clay_Color){1.25f, 2.5f, 3.75f, 4.0f};
    printf("global debug-roundtrip width %u color %08x %08x %08x %08x\n",
           Clay__debugViewWidth,
           f32_bits(Clay__debugViewHighlightColor.r),
           f32_bits(Clay__debugViewHighlightColor.g),
           f32_bits(Clay__debugViewHighlightColor.b),
           f32_bits(Clay__debugViewHighlightColor.a));
    Clay__debugViewWidth = saved_width;
    Clay__debugViewHighlightColor = saved_color;
}

int main(void) {
    puts("public-values-v1 enums 19 values 86");
    if (print_enums() != 86) return 3;
    print_transition_masks();
    print_defaults();
    print_helpers();
    print_globals();

    uint32_t memory_size = Clay_MinMemorySize();
    void *memory = malloc(memory_size);
    if (!memory) return 2;
    Clay_Initialize(
        Clay_CreateArenaWithCapacityAndMemory(memory_size, memory),
        (Clay_Dimensions){320.0f, 180.0f},
        (Clay_ErrorHandler){report_error, NULL});

    char dynamic_ascii_chars[] = {'d', 'y', 'n', 'a', 'm', 'i', 'c'};
    Clay_String dynamic_ascii = {false, 7, dynamic_ascii_chars};
    char non_ascii_chars[] = {(char)0xc3, (char)0xa9};
    Clay_String non_ascii = {false, 2, non_ascii_chars};
    print_id("literal", Clay_GetElementId(CLAY_STRING("literal-id")));
    print_id("dynamic", Clay_GetElementId(dynamic_ascii));
    print_id("non-ascii", Clay_GetElementId(non_ascii));
    print_id("non-ascii-indexed", Clay_GetElementIdWithIndex(non_ascii, 7));

    Clay_BeginLayout();
    Clay_ElementId parent_id = Clay_GetElementId(CLAY_STRING("id-parent"));
    Clay__OpenElementWithId(parent_id);
    Clay__ConfigureOpenElement(fixed_box(20.0f, 20.0f));
    print_id("non-ascii-local", CLAY_SID_LOCAL(non_ascii));
    print_id("non-ascii-indexed-local", CLAY_SIDI_LOCAL(non_ascii, 9));
    Clay__CloseElement();
    (void)Clay_EndLayout(0.0f);

    puts("public-values-end");
    free(memory);
    return 0;
}
