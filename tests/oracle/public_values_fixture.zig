const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const EnumRecord = struct {
    group: []const u8,
    name: []const u8,
    value: i32,
};

fn enumRecord(comptime group: []const u8, comptime name: []const u8, value: anytype) EnumRecord {
    return .{
        .group = group,
        .name = name,
        .value = @intCast(@intFromEnum(value)),
    };
}

const enum_records = [_]EnumRecord{
    enumRecord("LayoutDirection", "CLAY_LEFT_TO_RIGHT", zlay.LayoutDirection.left_to_right),
    enumRecord("LayoutDirection", "CLAY_TOP_TO_BOTTOM", zlay.LayoutDirection.top_to_bottom),
    enumRecord("LayoutAlignmentX", "CLAY_ALIGN_X_LEFT", zlay.LayoutAlignmentX.left),
    enumRecord("LayoutAlignmentX", "CLAY_ALIGN_X_RIGHT", zlay.LayoutAlignmentX.right),
    enumRecord("LayoutAlignmentX", "CLAY_ALIGN_X_CENTER", zlay.LayoutAlignmentX.center),
    enumRecord("LayoutAlignmentY", "CLAY_ALIGN_Y_TOP", zlay.LayoutAlignmentY.top),
    enumRecord("LayoutAlignmentY", "CLAY_ALIGN_Y_BOTTOM", zlay.LayoutAlignmentY.bottom),
    enumRecord("LayoutAlignmentY", "CLAY_ALIGN_Y_CENTER", zlay.LayoutAlignmentY.center),
    enumRecord("SizingType", "CLAY__SIZING_TYPE_FIT", zlay.SizingType.fit),
    enumRecord("SizingType", "CLAY__SIZING_TYPE_GROW", zlay.SizingType.grow),
    enumRecord("SizingType", "CLAY__SIZING_TYPE_PERCENT", zlay.SizingType.percent),
    enumRecord("SizingType", "CLAY__SIZING_TYPE_FIXED", zlay.SizingType.fixed),
    enumRecord("TextWrapMode", "CLAY_TEXT_WRAP_WORDS", zlay.TextElementConfigWrapMode.words),
    enumRecord("TextWrapMode", "CLAY_TEXT_WRAP_NEWLINES", zlay.TextElementConfigWrapMode.newlines),
    enumRecord("TextWrapMode", "CLAY_TEXT_WRAP_NONE", zlay.TextElementConfigWrapMode.none),
    enumRecord("TextAlignment", "CLAY_TEXT_ALIGN_LEFT", zlay.TextAlignment.left),
    enumRecord("TextAlignment", "CLAY_TEXT_ALIGN_CENTER", zlay.TextAlignment.center),
    enumRecord("TextAlignment", "CLAY_TEXT_ALIGN_RIGHT", zlay.TextAlignment.right),
    enumRecord("FloatingAttachPoint", "CLAY_ATTACH_POINT_LEFT_TOP", zlay.FloatingAttachPointType.left_top),
    enumRecord("FloatingAttachPoint", "CLAY_ATTACH_POINT_LEFT_CENTER", zlay.FloatingAttachPointType.left_center),
    enumRecord("FloatingAttachPoint", "CLAY_ATTACH_POINT_LEFT_BOTTOM", zlay.FloatingAttachPointType.left_bottom),
    enumRecord("FloatingAttachPoint", "CLAY_ATTACH_POINT_CENTER_TOP", zlay.FloatingAttachPointType.center_top),
    enumRecord("FloatingAttachPoint", "CLAY_ATTACH_POINT_CENTER_CENTER", zlay.FloatingAttachPointType.center_center),
    enumRecord("FloatingAttachPoint", "CLAY_ATTACH_POINT_CENTER_BOTTOM", zlay.FloatingAttachPointType.center_bottom),
    enumRecord("FloatingAttachPoint", "CLAY_ATTACH_POINT_RIGHT_TOP", zlay.FloatingAttachPointType.right_top),
    enumRecord("FloatingAttachPoint", "CLAY_ATTACH_POINT_RIGHT_CENTER", zlay.FloatingAttachPointType.right_center),
    enumRecord("FloatingAttachPoint", "CLAY_ATTACH_POINT_RIGHT_BOTTOM", zlay.FloatingAttachPointType.right_bottom),
    enumRecord("PointerCaptureMode", "CLAY_POINTER_CAPTURE_MODE_CAPTURE", zlay.PointerCaptureMode.capture),
    enumRecord("PointerCaptureMode", "CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH", zlay.PointerCaptureMode.passthrough),
    enumRecord("FloatingAttachTo", "CLAY_ATTACH_TO_NONE", zlay.FloatingAttachToElement.none),
    enumRecord("FloatingAttachTo", "CLAY_ATTACH_TO_PARENT", zlay.FloatingAttachToElement.parent),
    enumRecord("FloatingAttachTo", "CLAY_ATTACH_TO_ELEMENT_WITH_ID", zlay.FloatingAttachToElement.element_with_id),
    enumRecord("FloatingAttachTo", "CLAY_ATTACH_TO_ROOT", zlay.FloatingAttachToElement.root),
    enumRecord("FloatingClipTo", "CLAY_CLIP_TO_NONE", zlay.FloatingClipToElement.none),
    enumRecord("FloatingClipTo", "CLAY_CLIP_TO_ATTACHED_PARENT", zlay.FloatingClipToElement.attached_parent),
    enumRecord("TransitionState", "CLAY_TRANSITION_STATE_IDLE", zlay.TransitionState.idle),
    enumRecord("TransitionState", "CLAY_TRANSITION_STATE_ENTERING", zlay.TransitionState.entering),
    enumRecord("TransitionState", "CLAY_TRANSITION_STATE_TRANSITIONING", zlay.TransitionState.transitioning),
    enumRecord("TransitionState", "CLAY_TRANSITION_STATE_EXITING", zlay.TransitionState.exiting),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_NONE", zlay.TransitionProperty.none),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_X", zlay.TransitionProperty.x),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_Y", zlay.TransitionProperty.y),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_POSITION", zlay.TransitionProperty.position),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_WIDTH", zlay.TransitionProperty.width),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_HEIGHT", zlay.TransitionProperty.height),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_DIMENSIONS", zlay.TransitionProperty.dimensions),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_BOUNDING_BOX", zlay.TransitionProperty.bounding_box),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR", zlay.TransitionProperty.background_color),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR", zlay.TransitionProperty.overlay_color),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_CORNER_RADIUS", zlay.TransitionProperty.corner_radius),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_BORDER_COLOR", zlay.TransitionProperty.border_color),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_BORDER_WIDTH", zlay.TransitionProperty.border_width),
    enumRecord("TransitionProperty", "CLAY_TRANSITION_PROPERTY_BORDER", zlay.TransitionProperty.border),
    enumRecord("TransitionEnterTrigger", "CLAY_TRANSITION_ENTER_SKIP_ON_FIRST_PARENT_FRAME", zlay.TransitionEnterTriggerType.skip_on_first_parent_frame),
    enumRecord("TransitionEnterTrigger", "CLAY_TRANSITION_ENTER_TRIGGER_ON_FIRST_PARENT_FRAME", zlay.TransitionEnterTriggerType.trigger_on_first_parent_frame),
    enumRecord("TransitionExitTrigger", "CLAY_TRANSITION_EXIT_SKIP_WHEN_PARENT_EXITS", zlay.TransitionExitTriggerType.skip_when_parent_exits),
    enumRecord("TransitionExitTrigger", "CLAY_TRANSITION_EXIT_TRIGGER_WHEN_PARENT_EXITS", zlay.TransitionExitTriggerType.trigger_when_parent_exits),
    enumRecord("TransitionInteraction", "CLAY_TRANSITION_DISABLE_INTERACTIONS_WHILE_TRANSITIONING_POSITION", zlay.TransitionInteractionHandlingType.disable_interactions_while_transitioning_position),
    enumRecord("TransitionInteraction", "CLAY_TRANSITION_ALLOW_INTERACTIONS_WHILE_TRANSITIONING_POSITION", zlay.TransitionInteractionHandlingType.allow_interactions_while_transitioning_position),
    enumRecord("ExitSiblingOrdering", "CLAY_EXIT_TRANSITION_ORDERING_UNDERNEATH_SIBLINGS", zlay.ExitTransitionSiblingOrdering.underneath_siblings),
    enumRecord("ExitSiblingOrdering", "CLAY_EXIT_TRANSITION_ORDERING_NATURAL_ORDER", zlay.ExitTransitionSiblingOrdering.natural_order),
    enumRecord("ExitSiblingOrdering", "CLAY_EXIT_TRANSITION_ORDERING_ABOVE_SIBLINGS", zlay.ExitTransitionSiblingOrdering.above_siblings),
    enumRecord("RenderCommandType", "CLAY_RENDER_COMMAND_TYPE_NONE", zlay.RenderCommandType.none),
    enumRecord("RenderCommandType", "CLAY_RENDER_COMMAND_TYPE_RECTANGLE", zlay.RenderCommandType.rectangle),
    enumRecord("RenderCommandType", "CLAY_RENDER_COMMAND_TYPE_BORDER", zlay.RenderCommandType.border),
    enumRecord("RenderCommandType", "CLAY_RENDER_COMMAND_TYPE_TEXT", zlay.RenderCommandType.text),
    enumRecord("RenderCommandType", "CLAY_RENDER_COMMAND_TYPE_IMAGE", zlay.RenderCommandType.image),
    enumRecord("RenderCommandType", "CLAY_RENDER_COMMAND_TYPE_SCISSOR_START", zlay.RenderCommandType.scissor_start),
    enumRecord("RenderCommandType", "CLAY_RENDER_COMMAND_TYPE_SCISSOR_END", zlay.RenderCommandType.scissor_end),
    enumRecord("RenderCommandType", "CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START", zlay.RenderCommandType.overlay_color_start),
    enumRecord("RenderCommandType", "CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END", zlay.RenderCommandType.overlay_color_end),
    enumRecord("RenderCommandType", "CLAY_RENDER_COMMAND_TYPE_CUSTOM", zlay.RenderCommandType.custom),
    enumRecord("PointerState", "CLAY_POINTER_DATA_PRESSED_THIS_FRAME", zlay.PointerDataInteractionState.pressed_this_frame),
    enumRecord("PointerState", "CLAY_POINTER_DATA_PRESSED", zlay.PointerDataInteractionState.pressed),
    enumRecord("PointerState", "CLAY_POINTER_DATA_RELEASED_THIS_FRAME", zlay.PointerDataInteractionState.released_this_frame),
    enumRecord("PointerState", "CLAY_POINTER_DATA_RELEASED", zlay.PointerDataInteractionState.released),
    enumRecord("ErrorType", "CLAY_ERROR_TYPE_TEXT_MEASUREMENT_FUNCTION_NOT_PROVIDED", zlay.ErrorType.text_measurement_function_not_provided),
    enumRecord("ErrorType", "CLAY_ERROR_TYPE_ARENA_CAPACITY_EXCEEDED", zlay.ErrorType.arena_capacity_exceeded),
    enumRecord("ErrorType", "CLAY_ERROR_TYPE_ELEMENTS_CAPACITY_EXCEEDED", zlay.ErrorType.elements_capacity_exceeded),
    enumRecord("ErrorType", "CLAY_ERROR_TYPE_TEXT_MEASUREMENT_CAPACITY_EXCEEDED", zlay.ErrorType.text_measurement_capacity_exceeded),
    enumRecord("ErrorType", "CLAY_ERROR_TYPE_DUPLICATE_ID", zlay.ErrorType.duplicate_id),
    enumRecord("ErrorType", "CLAY_ERROR_TYPE_FLOATING_CONTAINER_PARENT_NOT_FOUND", zlay.ErrorType.floating_container_parent_not_found),
    enumRecord("ErrorType", "CLAY_ERROR_TYPE_PERCENTAGE_OVER_1", zlay.ErrorType.percentage_over_1),
    enumRecord("ErrorType", "CLAY_ERROR_TYPE_INTERNAL_ERROR", zlay.ErrorType.internal_error),
    enumRecord("ErrorType", "CLAY_ERROR_TYPE_UNBALANCED_OPEN_CLOSE", zlay.ErrorType.unbalanced_open_close),
    enumRecord("ErrorType", "CLAY_ERROR_TYPE_HASH_MAP_CAPACITY_EXCEEDED", zlay.ErrorType.hash_map_capacity_exceeded),
};

comptime {
    if (enum_records.len != 86) @compileError("public enum value matrix must contain 86 records");
}

fn f32Bits(value: f32) u32 {
    return @bitCast(value);
}

fn printAxis(out: *std.Io.Writer, label: []const u8, axis: zlay.SizingAxis) !void {
    var min_bits: u32 = 0;
    var max_bits: u32 = 0;
    var percent_bits: u32 = 0;
    if (axis.type == .percent) {
        percent_bits = f32Bits(axis.size.percent);
    } else {
        min_bits = f32Bits(axis.size.min_max.min);
        max_bits = f32Bits(axis.size.min_max.max);
    }
    try out.print("axis {s} type {d} min {x:0>8} max {x:0>8} percent {x:0>8}\n", .{
        label,
        @intFromEnum(axis.type),
        min_bits,
        max_bits,
        percent_bits,
    });
}

fn printColor(out: *std.Io.Writer, label: []const u8, color: zlay.Color) !void {
    try out.print("color {s} {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
        label,
        f32Bits(color.r),
        f32Bits(color.g),
        f32Bits(color.b),
        f32Bits(color.a),
    });
}

fn printBox(out: *std.Io.Writer, label: []const u8, box: zlay.BoundingBox) !void {
    try out.print("box {s} {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
        label,
        f32Bits(box.x),
        f32Bits(box.y),
        f32Bits(box.width),
        f32Bits(box.height),
    });
}

fn printBorderWidth(out: *std.Io.Writer, label: []const u8, width: zlay.BorderWidth) !void {
    try out.print("border-width {s} {d} {d} {d} {d} {d}\n", .{
        label,
        width.left,
        width.right,
        width.top,
        width.bottom,
        width.between_children,
    });
}

fn printId(out: *std.Io.Writer, label: []const u8, id: zlay.ElementId) !void {
    try out.print("id {s} {d} {d} {d} static {d} len {d} bytes ", .{
        label,
        id.id,
        id.offset,
        id.base_id,
        @intFromBool(id.string_id.is_statically_allocated),
        id.string_id.length,
    });
    for (id.string_id.asSlice()) |byte| try out.print("{x:0>2}", .{byte});
    try out.writeByte('\n');
}

fn printEnums(out: *std.Io.Writer) !void {
    for (enum_records) |record| {
        try out.print("enum {s} {s} {d}\n", .{ record.group, record.name, record.value });
    }
    try out.print("enum-count {d}\n", .{enum_records.len});
}

fn printTransitionMasks(out: *std.Io.Writer) !void {
    try out.print("transition-mask position {d}\n", .{@intFromEnum(zlay.TransitionProperty.position)});
    try out.print("transition-mask dimensions {d}\n", .{@intFromEnum(zlay.TransitionProperty.dimensions)});
    try out.print("transition-mask bounding-box {d}\n", .{@intFromEnum(zlay.TransitionProperty.bounding_box)});
    try out.print("transition-mask border {d}\n", .{@intFromEnum(zlay.TransitionProperty.border)});
    try out.print("transition-mask supported {d}\n", .{@as(u16, @intFromEnum(zlay.TransitionProperty.bounding_box)) |
        @intFromEnum(zlay.TransitionProperty.background_color) |
        @intFromEnum(zlay.TransitionProperty.overlay_color) |
        @intFromEnum(zlay.TransitionProperty.border)});
    try out.print("transition-mask all-declared {d}\n", .{@as(u16, @intFromEnum(zlay.TransitionProperty.bounding_box)) |
        @intFromEnum(zlay.TransitionProperty.background_color) |
        @intFromEnum(zlay.TransitionProperty.overlay_color) |
        @intFromEnum(zlay.TransitionProperty.corner_radius) |
        @intFromEnum(zlay.TransitionProperty.border)});
}

fn printDefaults(out: *std.Io.Writer) !void {
    const string = zlay.String{};
    const string_slice = zlay.StringSlice{};
    const arena = zlay.Arena{};
    const dimensions = zlay.Dimensions{};
    const vector = zlay.Vector2{};
    const color = zlay.Color{};
    const box = zlay.BoundingBox{};
    const id = zlay.ElementId{};
    const id_array = zlay.ElementIdArray{};
    const radius = zlay.CornerRadius{};
    const alignment = zlay.ChildAlignment{};
    const min_max = zlay.SizingMinMax{};
    const axis = zlay.SizingAxis{};
    const sizing = zlay.Sizing{};
    const padding_value = zlay.Padding{};
    const layout = zlay.LayoutConfig{};
    const text = zlay.TextElementConfig{};
    const aspect = zlay.AspectRatioElementConfig{};
    const image = zlay.ImageElementConfig{};
    const attach_points = zlay.FloatingAttachPoints{};
    const floating = zlay.FloatingElementConfig{};
    const custom = zlay.CustomElementConfig{};
    const clip = zlay.ClipElementConfig{};
    const border_width = zlay.BorderWidth{};
    const border = zlay.BorderElementConfig{};
    const transition_data = zlay.TransitionData{};
    var transition_current = zlay.TransitionData{};
    const transition_arguments = zlay.TransitionCallbackArguments{ .current = &transition_current };
    const transition = zlay.TransitionElementConfig{};
    const text_render = zlay.TextRenderData{};
    const rectangle_render = zlay.RectangleRenderData{};
    const image_render = zlay.ImageRenderData{};
    const custom_render = zlay.CustomRenderData{};
    const clip_render = zlay.ClipRenderData{};
    const overlay_render = zlay.OverlayColorRenderData{};
    const border_render = zlay.BorderRenderData{};
    const render_data = zlay.RenderData{ .rectangle = .{} };
    const scroll_data = zlay.ScrollContainerData{};
    const element_data = zlay.ElementData{};
    const render_command = zlay.RenderCommand{};
    const render_array = zlay.RenderCommandArray{};
    const pointer = zlay.PointerData{};
    const declaration = zlay.ElementDeclaration{};
    const error_data = zlay.ErrorData{};
    const error_handler = zlay.ErrorHandler{};

    try out.print("default String static {d} length {d}\n", .{ @intFromBool(string.is_statically_allocated), string.length });
    try out.print("default StringSlice length {d}\n", .{string_slice.length});
    try out.print("default Arena next {d} capacity {d}\n", .{ arena.next_allocation, arena.capacity });
    try out.print("default Dimensions {x:0>8} {x:0>8}\n", .{ f32Bits(dimensions.width), f32Bits(dimensions.height) });
    try out.print("default Vector2 {x:0>8} {x:0>8}\n", .{ f32Bits(vector.x), f32Bits(vector.y) });
    try printColor(out, "default-Color", color);
    try printBox(out, "default-BoundingBox", box);
    try out.print("default ElementId {d} {d} {d} static {d} length {d}\n", .{ id.id, id.offset, id.base_id, @intFromBool(id.string_id.is_statically_allocated), id.string_id.length });
    try out.print("default ElementIdArray capacity {d} length {d}\n", .{ id_array.capacity, id_array.length });
    try out.print("default CornerRadius {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{ f32Bits(radius.top_left), f32Bits(radius.top_right), f32Bits(radius.bottom_left), f32Bits(radius.bottom_right) });
    try out.print("default ChildAlignment {d} {d}\n", .{ @intFromEnum(alignment.x), @intFromEnum(alignment.y) });
    try out.print("default SizingMinMax {x:0>8} {x:0>8}\n", .{ f32Bits(min_max.min), f32Bits(min_max.max) });
    try printAxis(out, "default-SizingAxis", axis);
    try printAxis(out, "default-Sizing.width", sizing.width);
    try printAxis(out, "default-Sizing.height", sizing.height);
    try out.print("default Padding {d} {d} {d} {d}\n", .{ padding_value.left, padding_value.right, padding_value.top, padding_value.bottom });
    try printAxis(out, "default-LayoutConfig.width", layout.sizing.width);
    try printAxis(out, "default-LayoutConfig.height", layout.sizing.height);
    try out.print("default LayoutConfig padding {d} {d} {d} {d} gap {d} align {d} {d} direction {d}\n", .{
        layout.padding.left,
        layout.padding.right,
        layout.padding.top,
        layout.padding.bottom,
        layout.child_gap,
        @intFromEnum(layout.child_alignment.x),
        @intFromEnum(layout.child_alignment.y),
        @intFromEnum(layout.layout_direction),
    });
    try out.print("default TextElementConfig userdata {d} color {x:0>8} {x:0>8} {x:0>8} {x:0>8} font {d} {d} spacing {d} line {d} wrap {d} align {d}\n", .{
        @intFromBool(text.user_data != null),
        f32Bits(text.text_color.r),
        f32Bits(text.text_color.g),
        f32Bits(text.text_color.b),
        f32Bits(text.text_color.a),
        text.font_id,
        text.font_size,
        text.letter_spacing,
        text.line_height,
        @intFromEnum(text.wrap_mode),
        @intFromEnum(text.text_alignment),
    });
    try out.print("default AspectRatio {x:0>8}\n", .{f32Bits(aspect.aspect_ratio)});
    try out.print("default Image data {d}\n", .{@intFromBool(image.image_data != null)});
    try out.print("default FloatingAttachPoints {d} {d}\n", .{ @intFromEnum(attach_points.element), @intFromEnum(attach_points.parent) });
    try out.print("default Floating offset {x:0>8} {x:0>8} expand {x:0>8} {x:0>8} parent {d} z {d} points {d} {d} capture {d} attach {d} clip {d}\n", .{
        f32Bits(floating.offset.x),
        f32Bits(floating.offset.y),
        f32Bits(floating.expand.width),
        f32Bits(floating.expand.height),
        floating.parent_id,
        floating.z_index,
        @intFromEnum(floating.attach_points.element),
        @intFromEnum(floating.attach_points.parent),
        @intFromEnum(floating.pointer_capture_mode),
        @intFromEnum(floating.attach_to),
        @intFromEnum(floating.clip_to),
    });
    try out.print("default Custom data {d}\n", .{@intFromBool(custom.custom_data != null)});
    try out.print("default Clip {d} {d} offset {x:0>8} {x:0>8}\n", .{ @intFromBool(clip.horizontal), @intFromBool(clip.vertical), f32Bits(clip.child_offset.x), f32Bits(clip.child_offset.y) });
    try printBorderWidth(out, "default-BorderWidth", border_width);
    try printColor(out, "default-Border.color", border.color);
    try printBorderWidth(out, "default-Border.width", border.width);
    try printBox(out, "default-TransitionData.box", transition_data.bounding_box);
    try printColor(out, "default-TransitionData.background", transition_data.background_color);
    try printColor(out, "default-TransitionData.overlay", transition_data.overlay_color);
    try printColor(out, "default-TransitionData.border", transition_data.border_color);
    try printBorderWidth(out, "default-TransitionData.width", transition_data.border_width);
    try out.print("default TransitionCallbackArguments state {d} current {d} elapsed {x:0>8} duration {x:0>8} properties {d}\n", .{
        @intFromEnum(transition_arguments.transition_state),
        1,
        f32Bits(transition_arguments.elapsed_time),
        f32Bits(transition_arguments.duration),
        @intFromEnum(transition_arguments.properties),
    });
    try out.print("default TransitionElementConfig handler {d} duration {x:0>8} properties {d} interaction {d} enter-fn {d} enter-trigger {d} exit-fn {d} exit-trigger {d} ordering {d}\n", .{
        @intFromBool(transition.handler != null),
        f32Bits(transition.duration),
        @intFromEnum(transition.properties),
        @intFromEnum(transition.interaction_handling),
        @intFromBool(transition.enter.set_initial_state != null),
        @intFromEnum(transition.enter.trigger),
        @intFromBool(transition.exit.set_final_state != null),
        @intFromEnum(transition.exit.trigger),
        @intFromEnum(transition.exit.sibling_ordering),
    });
    try out.print("default TextRender length {d} color {x:0>8} {x:0>8} {x:0>8} {x:0>8} font {d} {d} spacing {d} line {d}\n", .{
        text_render.string_contents.length,
        f32Bits(text_render.text_color.r),
        f32Bits(text_render.text_color.g),
        f32Bits(text_render.text_color.b),
        f32Bits(text_render.text_color.a),
        text_render.font_id,
        text_render.font_size,
        text_render.letter_spacing,
        text_render.line_height,
    });
    try printColor(out, "default-RectangleRender.color", rectangle_render.background_color);
    try out.print("default RectangleRender radius {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{ f32Bits(rectangle_render.corner_radius.top_left), f32Bits(rectangle_render.corner_radius.top_right), f32Bits(rectangle_render.corner_radius.bottom_left), f32Bits(rectangle_render.corner_radius.bottom_right) });
    try out.print("default ImageRender data {d}\n", .{@intFromBool(image_render.image_data != null)});
    try out.print("default CustomRender data {d}\n", .{@intFromBool(custom_render.custom_data != null)});
    try out.print("default ClipRender {d} {d}\n", .{ @intFromBool(clip_render.horizontal), @intFromBool(clip_render.vertical) });
    try printColor(out, "default-OverlayRender.color", overlay_render.color);
    try printColor(out, "default-BorderRender.color", border_render.color);
    try printBorderWidth(out, "default-BorderRender.width", border_render.width);
    try printColor(out, "default-RenderData.rectangle", render_data.rectangle.background_color);
    try out.print("default ScrollContainer pointer {d} container {x:0>8} {x:0>8} content {x:0>8} {x:0>8} config {d} {d} found {d}\n", .{
        @intFromBool(scroll_data.scroll_position != null),
        f32Bits(scroll_data.scroll_container_dimensions.width),
        f32Bits(scroll_data.scroll_container_dimensions.height),
        f32Bits(scroll_data.content_dimensions.width),
        f32Bits(scroll_data.content_dimensions.height),
        @intFromBool(scroll_data.config.horizontal),
        @intFromBool(scroll_data.config.vertical),
        @intFromBool(scroll_data.found),
    });
    try printBox(out, "default-ElementData.box", element_data.bounding_box);
    try out.print("default ElementData found {d}\n", .{@intFromBool(element_data.found)});
    try printBox(out, "default-RenderCommand.box", render_command.bounding_box);
    try out.print("default RenderCommand userdata {d} id {d} z {d} type {d} active-rectangle-a {x:0>8}\n", .{
        @intFromBool(render_command.user_data != null),
        render_command.id,
        render_command.z_index,
        @intFromEnum(render_command.command_type),
        f32Bits(render_command.render_data.rectangle.background_color.a),
    });
    try out.print("default RenderCommandArray capacity {d} length {d}\n", .{ render_array.capacity, render_array.length });
    try out.print("default PointerData position {x:0>8} {x:0>8} state {d}\n", .{ f32Bits(pointer.position.x), f32Bits(pointer.position.y), @intFromEnum(pointer.state) });
    try out.print("default ElementDeclaration background-a {x:0>8} overlay-a {x:0>8} aspect {x:0>8} image {d} floating-attach {d} custom {d} clip {d} {d} border-between {d} transition-handler {d} userdata {d}\n", .{
        f32Bits(declaration.background_color.a),
        f32Bits(declaration.overlay_color.a),
        f32Bits(declaration.aspect_ratio.aspect_ratio),
        @intFromBool(declaration.image.image_data != null),
        @intFromEnum(declaration.floating.attach_to),
        @intFromBool(declaration.custom.custom_data != null),
        @intFromBool(declaration.clip.horizontal),
        @intFromBool(declaration.clip.vertical),
        declaration.border.width.between_children,
        @intFromBool(declaration.transition.handler != null),
        @intFromBool(declaration.user_data != null),
    });
    try out.print("default ErrorData type {d} static {d} length {d} userdata {d}\n", .{
        @intFromEnum(error_data.error_type),
        @intFromBool(error_data.error_text.is_statically_allocated),
        error_data.error_text.length,
        @intFromBool(error_data.user_data != null),
    });
    try out.print("default ErrorHandler function {d} userdata {d}\n", .{ @intFromBool(error_handler.error_handler_function != null), @intFromBool(error_handler.user_data != null) });
}

fn printHelpers(out: *std.Io.Writer) !void {
    try printAxis(out, "helper-fit-empty", zlay.fit());
    try printAxis(out, "helper-fit-min", zlay.fitMin(5));
    try printAxis(out, "helper-fit-minmax", zlay.fitMinMax(5, 9));
    try printAxis(out, "helper-grow-empty", zlay.grow());
    try printAxis(out, "helper-grow-min", zlay.growMin(6));
    try printAxis(out, "helper-grow-minmax", zlay.growMinMax(6, 10));
    try printAxis(out, "helper-fixed", zlay.fixed(13.5));
    try printAxis(out, "helper-percent", zlay.percent(0.375));

    const padding_value = zlay.padding(7);
    const radius = zlay.cornerRadius(2.5);
    const outside = zlay.borderOutside(3);
    const all = zlay.borderAll(4);
    const literal = zlay.String.literal("macro-string");
    try out.print("helper Padding {d} {d} {d} {d}\n", .{ padding_value.left, padding_value.right, padding_value.top, padding_value.bottom });
    try out.print("helper CornerRadius {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{ f32Bits(radius.top_left), f32Bits(radius.top_right), f32Bits(radius.bottom_left), f32Bits(radius.bottom_right) });
    try printBorderWidth(out, "helper-border-outside", outside);
    try printBorderWidth(out, "helper-border-all", all);
    try out.print("helper String static {d} length {d} bytes ", .{ @intFromBool(literal.is_statically_allocated), literal.length });
    for (literal.asSlice()) |byte| try out.print("{x:0>2}", .{byte});
    try out.writeByte('\n');
}

fn printGlobals(out: *std.Io.Writer, context: *zlay.Context) !void {
    try out.print("global layout-default gap {d} direction {d} width-type {d}\n", .{
        zlay.layout_default.child_gap,
        @intFromEnum(zlay.layout_default.layout_direction),
        @intFromEnum(zlay.layout_default.sizing.width.type),
    });
    const saved_layout = zlay.layout_default.*;
    defer zlay.layout_default.* = saved_layout;
    zlay.layout_default.child_gap = 17;
    zlay.layout_default.layout_direction = .top_to_bottom;
    zlay.layout_default.sizing.width = zlay.fixed(23.5);
    try out.print("global layout-roundtrip gap {d} direction {d} width-type {d} min {x:0>8} max {x:0>8}\n", .{
        zlay.layout_default.child_gap,
        @intFromEnum(zlay.layout_default.layout_direction),
        @intFromEnum(zlay.layout_default.sizing.width.type),
        f32Bits(zlay.layout_default.sizing.width.size.min_max.min),
        f32Bits(zlay.layout_default.sizing.width.size.min_max.max),
    });

    const saved_width = context.getDebugViewWidth();
    const saved_color = context.getDebugViewHighlightColor();
    defer {
        context.setDebugViewWidth(saved_width);
        context.setDebugViewHighlightColor(saved_color);
    }
    try out.print("global debug-default width {d} color {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
        context.getDebugViewWidth(),
        f32Bits(context.getDebugViewHighlightColor().r),
        f32Bits(context.getDebugViewHighlightColor().g),
        f32Bits(context.getDebugViewHighlightColor().b),
        f32Bits(context.getDebugViewHighlightColor().a),
    });
    context.setDebugViewWidth(321);
    context.setDebugViewHighlightColor(.{ .r = 1.25, .g = 2.5, .b = 3.75, .a = 4 });
    try out.print("global debug-roundtrip width {d} color {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
        context.getDebugViewWidth(),
        f32Bits(context.getDebugViewHighlightColor().r),
        f32Bits(context.getDebugViewHighlightColor().g),
        f32Bits(context.getDebugViewHighlightColor().b),
        f32Bits(context.getDebugViewHighlightColor().a),
    });
}

fn fixedBox(width: f32, height: f32) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(width),
            .height = zlay.fixed(height),
        } },
    };
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 320, .height = 180 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.writeAll("public-values-v1 enums 19 values 86\n");
    try printEnums(out);
    try printTransitionMasks(out);
    try printDefaults(out);
    try printHelpers(out);
    try printGlobals(out, &context);

    const dynamic_ascii_chars = "dynamic";
    const non_ascii_chars = "\xc3\xa9";
    const dynamic_ascii = zlay.String.fromSlice(dynamic_ascii_chars);
    const non_ascii = zlay.String.fromSlice(non_ascii_chars);
    try printId(out, "literal", context.getElementId(zlay.String.literal("literal-id")));
    try printId(out, "dynamic", context.getElementId(dynamic_ascii));
    try printId(out, "non-ascii", context.getElementId(non_ascii));
    try printId(out, "non-ascii-indexed", context.getElementIdWithIndex(non_ascii, 7));

    try context.beginLayout();
    const parent_id = context.getElementId(zlay.String.literal("id-parent"));
    try context.openElementWithIdUnconfigured(parent_id);
    try context.configureOpenElement(fixedBox(20, 20));
    try printId(out, "non-ascii-local", try context.getLocalElementId(non_ascii));
    try printId(out, "non-ascii-indexed-local", try context.getLocalElementIdWithIndex(non_ascii, 9));
    try context.closeElement();
    _ = try context.endLayout(0);

    try out.writeAll("public-values-end\n");
    try out.flush();
}
