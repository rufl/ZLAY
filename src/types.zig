//! Public data model for the native Zig port of Clay 0.14.
//!
//! The declarations in this file correspond to the public structs, enums,
//! callbacks, configuration objects, and render commands in Clay's `clay.h`
//! at commit e6cc36941ab2af5d81107617039d6f527a1c660b. They are native Zig types:
//! none of them use C ABI layout or C calling conventions.

const std = @import("std");

const max_string_length: usize = @intCast(std.math.maxInt(i32));

fn boundedStringLength(length: usize) i32 {
    return @intCast(@min(length, max_string_length));
}

pub const String = struct {
    is_statically_allocated: bool = false,
    length: i32 = 0,
    chars: []const u8 = "",

    pub fn fromSlice(chars: []const u8) String {
        return .{
            .length = boundedStringLength(chars.len),
            .chars = chars,
        };
    }

    pub fn literal(comptime chars: []const u8) String {
        return .{
            .is_statically_allocated = true,
            .length = boundedStringLength(chars.len),
            .chars = chars,
        };
    }

    pub fn asSlice(self: String) []const u8 {
        if (self.length <= 0) return "";
        const length: usize = @min(@as(usize, @intCast(self.length)), self.chars.len);
        return self.chars[0..length];
    }
};

pub const StringSlice = struct {
    length: i32 = 0,
    chars: []const u8 = "",
    base_chars: []const u8 = "",

    pub fn fromSlice(chars: []const u8) StringSlice {
        return .{
            .length = boundedStringLength(chars.len),
            .chars = chars,
            .base_chars = chars,
        };
    }

    pub fn derive(base_chars: []const u8, offset: usize, length: usize) StringSlice {
        const end = @min(base_chars.len, offset +| length);
        const start = @min(offset, end);
        const chars = base_chars[start..end];
        return .{
            .length = boundedStringLength(chars.len),
            .chars = chars,
            .base_chars = base_chars,
        };
    }

    pub fn asSlice(self: StringSlice) []const u8 {
        if (self.length <= 0) return "";
        const length: usize = @min(@as(usize, @intCast(self.length)), self.chars.len);
        return self.chars[0..length];
    }
};

pub const Arena = struct {
    next_allocation: usize = 0,
    capacity: usize = 0,
    memory: []u8 = &.{},

    pub fn init(memory: []u8) Arena {
        return .{
            .capacity = memory.len,
            .memory = memory,
        };
    }
};

pub const Dimensions = struct {
    width: f32 = 0,
    height: f32 = 0,
};

pub const Vector2 = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
};

pub const BoundingBox = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

pub const ElementId = struct {
    id: u32 = 0,
    offset: u32 = 0,
    base_id: u32 = 0,
    string_id: String = .{},
};

pub const ElementIdArray = struct {
    capacity: i32 = 0,
    length: i32 = 0,
    internal_array: []const ElementId = &.{},

    pub fn items(self: ElementIdArray) []const ElementId {
        if (self.length <= 0) return self.internal_array[0..0];
        const length: usize = @min(@as(usize, @intCast(self.length)), self.internal_array.len);
        return self.internal_array[0..length];
    }
};

pub const CornerRadius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_left: f32 = 0,
    bottom_right: f32 = 0,

    pub fn all(radius: f32) CornerRadius {
        return .{
            .top_left = radius,
            .top_right = radius,
            .bottom_left = radius,
            .bottom_right = radius,
        };
    }
};

pub const LayoutDirection = enum(u8) {
    left_to_right = 0,
    top_to_bottom = 1,
};

pub const LayoutAlignmentX = enum(u8) {
    left = 0,
    right = 1,
    center = 2,
};

pub const LayoutAlignmentY = enum(u8) {
    top = 0,
    bottom = 1,
    center = 2,
};

pub const SizingType = enum(u8) {
    fit = 0,
    grow = 1,
    percent = 2,
    fixed = 3,
};

pub const ChildAlignment = struct {
    x: LayoutAlignmentX = .left,
    y: LayoutAlignmentY = .top,
};

pub const SizingMinMax = struct {
    min: f32 = 0,
    max: f32 = 0,
};

pub const SizingAxisSize = union {
    min_max: SizingMinMax,
    percent: f32,
};

pub const SizingAxis = struct {
    size: SizingAxisSize = .{ .min_max = .{} },
    type: SizingType = .fit,

    pub fn fit() SizingAxis {
        return .{
            .size = .{ .min_max = .{} },
            .type = .fit,
        };
    }

    pub fn fitMinMax(min: f32, max: f32) SizingAxis {
        return .{
            .size = .{ .min_max = .{ .min = min, .max = max } },
            .type = .fit,
        };
    }

    /// Equivalent to the one-argument `CLAY_SIZING_FIT(min)` form. A zero
    /// maximum retains Clay's unbounded-maximum convention.
    pub fn fitMin(min: f32) SizingAxis {
        return SizingAxis.fitMinMax(min, 0);
    }

    pub fn grow() SizingAxis {
        return .{
            .size = .{ .min_max = .{} },
            .type = .grow,
        };
    }

    pub fn growMinMax(min: f32, max: f32) SizingAxis {
        return .{
            .size = .{ .min_max = .{ .min = min, .max = max } },
            .type = .grow,
        };
    }

    /// Equivalent to the one-argument `CLAY_SIZING_GROW(min)` form.
    pub fn growMin(min: f32) SizingAxis {
        return SizingAxis.growMinMax(min, 0);
    }

    pub fn fixed(size: f32) SizingAxis {
        return .{
            .size = .{ .min_max = .{ .min = size, .max = size } },
            .type = .fixed,
        };
    }

    pub fn percent(value: f32) SizingAxis {
        return .{
            .size = .{ .percent = value },
            .type = .percent,
        };
    }
};

pub fn fit() SizingAxis {
    return SizingAxis.fit();
}

pub fn fitMinMax(min: f32, max: f32) SizingAxis {
    return SizingAxis.fitMinMax(min, max);
}

pub fn fitMin(min: f32) SizingAxis {
    return SizingAxis.fitMin(min);
}

pub fn grow() SizingAxis {
    return SizingAxis.grow();
}

pub fn growMinMax(min: f32, max: f32) SizingAxis {
    return SizingAxis.growMinMax(min, max);
}

pub fn growMin(min: f32) SizingAxis {
    return SizingAxis.growMin(min);
}

pub fn fixed(size: f32) SizingAxis {
    return SizingAxis.fixed(size);
}

pub fn percent(value: f32) SizingAxis {
    return SizingAxis.percent(value);
}

pub const Sizing = struct {
    width: SizingAxis = .{},
    height: SizingAxis = .{},
};

pub const Padding = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn all(value: u16) Padding {
        return .{
            .left = value,
            .right = value,
            .top = value,
            .bottom = value,
        };
    }
};

pub fn padding(value: u16) Padding {
    return Padding.all(value);
}

pub fn cornerRadius(radius: f32) CornerRadius {
    return CornerRadius.all(radius);
}

/// Single-evaluation value equivalent of Clay's `CLAY__MAX(x, y)` macro.
pub fn clayMax(left: anytype, right: @TypeOf(left)) @TypeOf(left) {
    return if (left > right) left else right;
}

/// Single-evaluation value equivalent of Clay's `CLAY__MIN(x, y)` macro.
pub fn clayMin(left: anytype, right: @TypeOf(left)) @TypeOf(left) {
    return if (left < right) left else right;
}

pub const LayoutConfig = struct {
    sizing: Sizing = .{},
    padding: Padding = .{},
    child_gap: u16 = 0,
    child_alignment: ChildAlignment = .{},
    layout_direction: LayoutDirection = .left_to_right,
};

pub const TextElementConfigWrapMode = enum(u8) {
    words = 0,
    newlines = 1,
    none = 2,
};

pub const TextAlignment = enum(u8) {
    left = 0,
    center = 1,
    right = 2,
};

pub const TextElementConfig = struct {
    user_data: ?*anyopaque = null,
    text_color: Color = .{},
    font_id: u16 = 0,
    font_size: u16 = 0,
    letter_spacing: u16 = 0,
    line_height: u16 = 0,
    wrap_mode: TextElementConfigWrapMode = .words,
    text_alignment: TextAlignment = .left,
};

pub const AspectRatioElementConfig = struct {
    aspect_ratio: f32 = 0,
};

pub const ImageElementConfig = struct {
    image_data: ?*anyopaque = null,
};

pub const FloatingAttachPointType = enum(u8) {
    left_top = 0,
    left_center = 1,
    left_bottom = 2,
    center_top = 3,
    center_center = 4,
    center_bottom = 5,
    right_top = 6,
    right_center = 7,
    right_bottom = 8,
};

pub const FloatingAttachPoints = struct {
    element: FloatingAttachPointType = .left_top,
    parent: FloatingAttachPointType = .left_top,
};

pub const PointerCaptureMode = enum(u8) {
    capture = 0,
    passthrough = 1,
};

pub const FloatingAttachToElement = enum(u8) {
    none = 0,
    parent = 1,
    element_with_id = 2,
    root = 3,
};

pub const FloatingClipToElement = enum(u8) {
    none = 0,
    attached_parent = 1,
};

pub const FloatingElementConfig = struct {
    offset: Vector2 = .{},
    expand: Dimensions = .{},
    parent_id: u32 = 0,
    z_index: i16 = 0,
    attach_points: FloatingAttachPoints = .{},
    pointer_capture_mode: PointerCaptureMode = .capture,
    attach_to: FloatingAttachToElement = .none,
    clip_to: FloatingClipToElement = .none,
};

pub const CustomElementConfig = struct {
    custom_data: ?*anyopaque = null,
};

pub const ClipElementConfig = struct {
    horizontal: bool = false,
    vertical: bool = false,
    child_offset: Vector2 = .{},
};

pub const BorderWidth = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,
    between_children: u16 = 0,

    pub fn outside(value: u16) BorderWidth {
        return .{
            .left = value,
            .right = value,
            .top = value,
            .bottom = value,
        };
    }

    pub fn all(value: u16) BorderWidth {
        return .{
            .left = value,
            .right = value,
            .top = value,
            .bottom = value,
            .between_children = value,
        };
    }
};

pub fn borderOutside(value: u16) BorderWidth {
    return BorderWidth.outside(value);
}

pub fn borderAll(value: u16) BorderWidth {
    return BorderWidth.all(value);
}

pub const BorderElementConfig = struct {
    color: Color = .{},
    width: BorderWidth = .{},
};

pub const TransitionData = struct {
    bounding_box: BoundingBox = .{},
    background_color: Color = .{},
    overlay_color: Color = .{},
    border_color: Color = .{},
    border_width: BorderWidth = .{},
};

pub const TransitionState = enum(u8) {
    idle = 0,
    entering = 1,
    transitioning = 2,
    exiting = 3,
};

/// Bit-mask of `TransitionData` properties affected by a transition.
pub const TransitionProperty = enum(u16) {
    none = 0,
    x = 1,
    y = 2,
    position = 3,
    width = 4,
    height = 8,
    dimensions = 12,
    bounding_box = 15,
    background_color = 16,
    overlay_color = 32,
    corner_radius = 64,
    border_color = 128,
    border_width = 256,
    border = 384,
    _,

    pub fn contains(self: TransitionProperty, property: TransitionProperty) bool {
        const bits = @backingInt(self);
        const property_bits = @backingInt(property);
        return (bits & property_bits) == property_bits;
    }

    pub fn merge(self: TransitionProperty, property: TransitionProperty) TransitionProperty {
        return @fromBackingInt(@intCast(@backingInt(self) | @backingInt(property)));
    }
};

pub const TransitionCallbackArguments = struct {
    transition_state: TransitionState = .idle,
    initial: TransitionData = .{},
    current: *TransitionData,
    target: TransitionData = .{},
    elapsed_time: f32 = 0,
    duration: f32 = 0,
    properties: TransitionProperty = .none,
};

pub const TransitionHandler = *const fn (TransitionCallbackArguments) bool;
pub const TransitionSetInitialStateFunction = *const fn (TransitionData, TransitionProperty) TransitionData;
pub const TransitionSetFinalStateFunction = *const fn (TransitionData, TransitionProperty) TransitionData;

pub const TransitionEnterTriggerType = enum(u8) {
    skip_on_first_parent_frame = 0,
    trigger_on_first_parent_frame = 1,
};

pub const TransitionExitTriggerType = enum(u8) {
    skip_when_parent_exits = 0,
    trigger_when_parent_exits = 1,
};

pub const TransitionInteractionHandlingType = enum(u8) {
    disable_interactions_while_transitioning_position = 0,
    allow_interactions_while_transitioning_position = 1,
};

pub const ExitTransitionSiblingOrdering = enum(u8) {
    underneath_siblings = 0,
    natural_order = 1,
    above_siblings = 2,
};

pub const TransitionEnterConfig = struct {
    set_initial_state: ?TransitionSetInitialStateFunction = null,
    trigger: TransitionEnterTriggerType = .skip_on_first_parent_frame,
};

pub const TransitionExitConfig = struct {
    set_final_state: ?TransitionSetFinalStateFunction = null,
    trigger: TransitionExitTriggerType = .skip_when_parent_exits,
    sibling_ordering: ExitTransitionSiblingOrdering = .underneath_siblings,
};

pub const TransitionElementConfig = struct {
    handler: ?TransitionHandler = null,
    duration: f32 = 0,
    properties: TransitionProperty = .none,
    interaction_handling: TransitionInteractionHandlingType = .disable_interactions_while_transitioning_position,
    enter: TransitionEnterConfig = .{},
    exit: TransitionExitConfig = .{},
};

pub const TextRenderData = struct {
    string_contents: StringSlice = .{},
    text_color: Color = .{},
    font_id: u16 = 0,
    font_size: u16 = 0,
    letter_spacing: u16 = 0,
    line_height: u16 = 0,
};

pub const RectangleRenderData = struct {
    background_color: Color = .{},
    corner_radius: CornerRadius = .{},
};

pub const ImageRenderData = struct {
    background_color: Color = .{},
    corner_radius: CornerRadius = .{},
    image_data: ?*anyopaque = null,
};

pub const CustomRenderData = struct {
    background_color: Color = .{},
    corner_radius: CornerRadius = .{},
    custom_data: ?*anyopaque = null,
};

pub const ClipRenderData = struct {
    horizontal: bool = false,
    vertical: bool = false,
};

pub const OverlayColorRenderData = struct {
    color: Color = .{},
};

pub const BorderRenderData = struct {
    color: Color = .{},
    corner_radius: CornerRadius = .{},
    width: BorderWidth = .{},
};

pub const RenderData = union {
    rectangle: RectangleRenderData,
    text: TextRenderData,
    image: ImageRenderData,
    custom: CustomRenderData,
    border: BorderRenderData,
    clip: ClipRenderData,
    overlay_color: OverlayColorRenderData,
};

pub const ScrollContainerData = struct {
    scroll_position: ?*Vector2 = null,
    scroll_container_dimensions: Dimensions = .{},
    content_dimensions: Dimensions = .{},
    config: ClipElementConfig = .{},
    found: bool = false,
};

pub const ElementData = struct {
    bounding_box: BoundingBox = .{},
    found: bool = false,
};

pub const RenderCommandType = enum(u8) {
    none = 0,
    rectangle = 1,
    border = 2,
    text = 3,
    image = 4,
    scissor_start = 5,
    scissor_end = 6,
    overlay_color_start = 7,
    overlay_color_end = 8,
    custom = 9,
};

pub const RenderCommand = struct {
    bounding_box: BoundingBox = .{},
    render_data: RenderData = .{ .rectangle = .{} },
    user_data: ?*anyopaque = null,
    id: u32 = 0,
    z_index: i16 = 0,
    command_type: RenderCommandType = .none,
};

pub const RenderCommandArray = struct {
    capacity: i32 = 0,
    length: i32 = 0,
    internal_array: []RenderCommand = &.{},

    pub fn items(self: RenderCommandArray) []RenderCommand {
        if (self.length <= 0) return self.internal_array[0..0];
        const length: usize = @min(@as(usize, @intCast(self.length)), self.internal_array.len);
        return self.internal_array[0..length];
    }

    pub fn get(self: *RenderCommandArray, index: i32) ?*RenderCommand {
        if (index < 0 or index >= self.length) return null;
        const array_index: usize = @intCast(index);
        if (array_index >= self.internal_array.len) return null;
        return &self.internal_array[array_index];
    }
};

pub const PointerDataInteractionState = enum(u8) {
    pressed_this_frame = 0,
    pressed = 1,
    released_this_frame = 2,
    released = 3,
};

pub const PointerData = struct {
    position: Vector2 = .{},
    state: PointerDataInteractionState = .pressed_this_frame,
};

pub const ElementDeclaration = struct {
    layout: LayoutConfig = .{},
    background_color: Color = .{},
    overlay_color: Color = .{},
    corner_radius: CornerRadius = .{},
    aspect_ratio: AspectRatioElementConfig = .{},
    image: ImageElementConfig = .{},
    floating: FloatingElementConfig = .{},
    custom: CustomElementConfig = .{},
    clip: ClipElementConfig = .{},
    border: BorderElementConfig = .{},
    transition: TransitionElementConfig = .{},
    user_data: ?*anyopaque = null,
};

pub const ErrorType = enum(u8) {
    text_measurement_function_not_provided = 0,
    arena_capacity_exceeded = 1,
    elements_capacity_exceeded = 2,
    text_measurement_capacity_exceeded = 3,
    duplicate_id = 4,
    floating_container_parent_not_found = 5,
    percentage_over_1 = 6,
    internal_error = 7,
    unbalanced_open_close = 8,
    hash_map_capacity_exceeded = 9,
};

pub const ErrorData = struct {
    error_type: ErrorType = .text_measurement_function_not_provided,
    error_text: String = .{},
    user_data: ?*anyopaque = null,
};

pub const ErrorHandlerFunction = *const fn (ErrorData) void;

pub const ErrorHandler = struct {
    error_handler_function: ?ErrorHandlerFunction = null,
    user_data: ?*anyopaque = null,
};

pub const HoverFunction = *const fn (ElementId, PointerData, ?*anyopaque) void;
pub const MeasureTextFunction = *const fn (StringSlice, *TextElementConfig, ?*anyopaque) Dimensions;
pub const QueryScrollOffsetFunction = *const fn (u32, ?*anyopaque) Vector2;

test "sizing helpers preserve Clay macro semantics" {
    const fitting = fit();
    try std.testing.expectEqual(SizingType.fit, fitting.type);
    try std.testing.expectEqual(@as(f32, 0), fitting.size.min_max.min);
    try std.testing.expectEqual(@as(f32, 0), fitting.size.min_max.max);

    const bounded = growMinMax(64, 128);
    try std.testing.expectEqual(SizingType.grow, bounded.type);
    try std.testing.expectEqual(@as(f32, 64), bounded.size.min_max.min);
    try std.testing.expectEqual(@as(f32, 128), bounded.size.min_max.max);

    const minimum_only_fit = fitMin(12);
    try std.testing.expectEqual(@as(f32, 12), minimum_only_fit.size.min_max.min);
    try std.testing.expectEqual(@as(f32, 0), minimum_only_fit.size.min_max.max);
    const minimum_only_grow = growMin(18);
    try std.testing.expectEqual(@as(f32, 18), minimum_only_grow.size.min_max.min);
    try std.testing.expectEqual(@as(f32, 0), minimum_only_grow.size.min_max.max);

    const exact = fixed(42);
    try std.testing.expectEqual(SizingType.fixed, exact.type);
    try std.testing.expectEqual(@as(f32, 42), exact.size.min_max.min);
    try std.testing.expectEqual(@as(f32, 42), exact.size.min_max.max);

    const proportional = percent(0.5);
    try std.testing.expectEqual(SizingType.percent, proportional.type);
    try std.testing.expectEqual(@as(f32, 0.5), proportional.size.percent);
}

test "min and max helpers preserve Clay conditional value semantics" {
    try std.testing.expectEqual(@as(i32, 7), clayMax(@as(i32, 3), 7));
    try std.testing.expectEqual(@as(i32, 3), clayMin(@as(i32, 3), 7));
    const nan = std.math.nan(f32);
    try std.testing.expectEqual(@as(f32, 7), clayMax(nan, 7));
    try std.testing.expectEqual(@as(f32, 7), clayMin(nan, 7));
    try std.testing.expect(std.math.isNan(clayMax(@as(f32, 7), nan)));
    try std.testing.expect(std.math.isNan(clayMin(@as(f32, 7), nan)));
}

test "uniform padding, radius, and border helpers initialize every side" {
    try std.testing.expectEqual(Padding{ .left = 8, .right = 8, .top = 8, .bottom = 8 }, padding(8));
    try std.testing.expectEqual(CornerRadius{ .top_left = 6, .top_right = 6, .bottom_left = 6, .bottom_right = 6 }, cornerRadius(6));
    try std.testing.expectEqual(BorderWidth{ .left = 2, .right = 2, .top = 2, .bottom = 2 }, borderOutside(2));
    try std.testing.expectEqual(BorderWidth{ .left = 2, .right = 2, .top = 2, .bottom = 2, .between_children = 2 }, borderAll(2));
}

test "transition properties retain their upstream bit values" {
    try std.testing.expectEqual(@as(u16, 15), @backingInt(TransitionProperty.bounding_box));
    try std.testing.expectEqual(@as(u16, 384), @backingInt(TransitionProperty.border));

    const combined = TransitionProperty.x.merge(.background_color);
    try std.testing.expect(combined.contains(.x));
    try std.testing.expect(combined.contains(.background_color));
    try std.testing.expect(!combined.contains(.y));
}

test "native strings and bounded command arrays expose safe slices" {
    const string = String.literal("clay");
    try std.testing.expect(string.is_statically_allocated);
    try std.testing.expectEqualStrings("clay", string.asSlice());

    var commands = [_]RenderCommand{ .{}, .{} };
    var array = RenderCommandArray{
        .capacity = commands.len,
        .length = 1,
        .internal_array = &commands,
    };
    try std.testing.expectEqual(@as(usize, 1), array.items().len);
    try std.testing.expect(array.get(0) != null);
    try std.testing.expect(array.get(1) == null);

    var ids = [_]ElementId{.{ .id = 7 }};
    const id_array = ElementIdArray{
        .capacity = ids.len,
        .length = ids.len,
        .internal_array = &ids,
    };
    try std.testing.expect(@typeInfo(@TypeOf(id_array.items())).pointer.attrs.@"const");
    try std.testing.expectEqual(@as(u32, 7), id_array.items()[0].id);
}

test "slice constructors clamp lengths to signed public metadata" {
    const oversized_length = max_string_length + 1;
    const oversized: []const u8 = @as([*]const u8, @ptrFromInt(4096))[0..oversized_length];

    const string = String.fromSlice(oversized);
    try std.testing.expectEqual(std.math.maxInt(i32), string.length);
    try std.testing.expectEqual(oversized_length, string.chars.len);

    const slice = StringSlice.fromSlice(oversized);
    try std.testing.expectEqual(std.math.maxInt(i32), slice.length);
    try std.testing.expectEqual(oversized_length, slice.chars.len);

    const derived = StringSlice.derive(oversized, 0, oversized_length);
    try std.testing.expectEqual(std.math.maxInt(i32), derived.length);
    try std.testing.expectEqual(oversized_length, derived.chars.len);
}
