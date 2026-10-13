//! Pure transition helpers for the native Clay port.
//!
//! The interpolation and application order follows Clay's `clay.h` at
//! commit e6cc36941ab2af5d81107617039d6f527a1c660b. The helpers in this file
//! own no engine state: a future `Context` can pass transition snapshots in
//! and apply the returned values to its internal layout element.

const std = @import("std");
const types = @import("types.zig");

/// Every property represented by `Clay_TransitionData` and handled by the
/// upstream transition implementation.
pub const supported_properties: types.TransitionProperty = @fromBackingInt(@intCast(
    @backingInt(types.TransitionProperty.bounding_box) |
        @backingInt(types.TransitionProperty.background_color) |
        @backingInt(types.TransitionProperty.overlay_color) |
        @backingInt(types.TransitionProperty.border),
));

/// Upstream currently declares this bit, but `Clay_TransitionData` has no
/// corner-radius field and neither `Clay_EaseOut` nor
/// `Clay_ApplyTransitionedPropertiesToElement` applies it. It is therefore a
/// deliberate no-op until the upstream data model gives it a value to carry.
pub const upstream_no_op_properties: types.TransitionProperty = .corner_radius;

pub fn intersects(properties: types.TransitionProperty, mask: types.TransitionProperty) bool {
    return (@backingInt(properties) & @backingInt(mask)) != 0;
}

/// Clay's `CLAY__LERP(from, to, mix)` with explicit f32 intermediates.
pub fn lerpF32(from: f32, to: f32, mix: f32) f32 {
    @setFloatMode(.strict);
    const difference: f32 = to - from;
    const scaled_difference: f32 = difference * mix;
    return from + scaled_difference;
}

fn lerpColor(from: types.Color, to: types.Color, mix: f32) types.Color {
    return .{
        .r = lerpF32(from.r, to.r, mix),
        .g = lerpF32(from.g, to.g, mix),
        .b = lerpF32(from.b, to.b, mix),
        .a = lerpF32(from.a, to.a, mix),
    };
}

fn lerpU16(from: u16, to: u16, mix: f32) u16 {
    const from_float: f32 = @floatFromInt(from);
    const to_float: f32 = @floatFromInt(to);
    const interpolated = lerpF32(from_float, to_float, mix);
    // Ordinary easing stays inside the u16 range and retains C's truncation
    // toward zero. Public helpers can nevertheless receive negative, infinite,
    // or NaN progress; make those formerly undefined C conversions
    // deterministic instead of trapping or becoming illegal behavior.
    if (std.math.isNan(interpolated)) return from;
    if (interpolated <= 0) return 0;
    if (interpolated >= @as(f32, @floatFromInt(std.math.maxInt(u16)))) {
        return std.math.maxInt(u16);
    }
    return @intFromFloat(interpolated);
}

fn lerpBorderWidth(from: types.BorderWidth, to: types.BorderWidth, mix: f32) types.BorderWidth {
    return .{
        .left = lerpU16(from.left, to.left, mix),
        .right = lerpU16(from.right, to.right, mix),
        .top = lerpU16(from.top, to.top, mix),
        .bottom = lerpU16(from.bottom, to.bottom, mix),
        .between_children = lerpU16(from.between_children, to.between_children, mix),
    };
}

/// Interpolate only the selected properties, preserving all other values from
/// `current`. Composite flags are naturally handled through their component
/// bits. `corner_radius` intentionally has no effect; see
/// `upstream_no_op_properties`.
pub fn interpolateProperties(
    current: types.TransitionData,
    initial: types.TransitionData,
    target: types.TransitionData,
    properties: types.TransitionProperty,
    mix: f32,
) types.TransitionData {
    var result = current;

    if (intersects(properties, .x)) {
        result.bounding_box.x = lerpF32(initial.bounding_box.x, target.bounding_box.x, mix);
    }
    if (intersects(properties, .y)) {
        result.bounding_box.y = lerpF32(initial.bounding_box.y, target.bounding_box.y, mix);
    }
    if (intersects(properties, .width)) {
        result.bounding_box.width = lerpF32(initial.bounding_box.width, target.bounding_box.width, mix);
    }
    if (intersects(properties, .height)) {
        result.bounding_box.height = lerpF32(initial.bounding_box.height, target.bounding_box.height, mix);
    }
    if (intersects(properties, .background_color)) {
        result.background_color = lerpColor(initial.background_color, target.background_color, mix);
    }
    if (intersects(properties, .overlay_color)) {
        result.overlay_color = lerpColor(initial.overlay_color, target.overlay_color, mix);
    }
    if (intersects(properties, .border_color)) {
        result.border_color = lerpColor(initial.border_color, target.border_color, mix);
    }
    if (intersects(properties, .border_width)) {
        result.border_width = lerpBorderWidth(initial.border_width, target.border_width, mix);
    }

    return result;
}

pub const EaseOutProgress = struct {
    ratio: f32,
    mix: f32,
    complete: bool,
};

/// Compute the same cubic ease-out progress as `Clay_EaseOut`.
pub fn easeOutProgress(elapsed_time: f32, duration: f32) EaseOutProgress {
    @setFloatMode(.strict);

    var ratio: f32 = 1.0;
    if (duration > 0.0) {
        const divided: f32 = elapsed_time / duration;
        // Spell out CLAY__MIN rather than using a language min intrinsic so
        // NaN follows the C macro's conditional-expression behavior.
        ratio = if (divided < 1.0) divided else 1.0;
    }

    const inverse: f32 = 1.0 - ratio;
    const inverse_squared: f32 = inverse * inverse;
    const inverse_cubed: f32 = inverse_squared * inverse;
    const mix: f32 = 1.0 - inverse_cubed;

    return .{
        .ratio = ratio,
        .mix = mix,
        .complete = ratio >= 1.0,
    };
}

/// Native equivalent of `Clay_EaseOut`. The transition state is deliberately
/// not branched on: upstream applies identical interpolation for entering,
/// ordinary target changes, and exiting transitions.
pub fn easeOut(arguments: types.TransitionCallbackArguments) bool {
    const progress = easeOutProgress(arguments.elapsed_time, arguments.duration);
    arguments.current.* = interpolateProperties(
        arguments.current.*,
        arguments.initial,
        arguments.target,
        arguments.properties,
        progress.mix,
    );
    return progress.complete;
}

/// Engine-independent values touched by
/// `Clay_ApplyTransitionedPropertiesToElement`.
pub const ApplicationTarget = struct {
    dimensions: types.Dimensions = .{},
    layout: types.LayoutConfig = .{},
    bounding_box: types.BoundingBox = .{},
    background_color: types.Color = .{},
    overlay_color: types.Color = .{},
    border: types.BorderElementConfig = .{},
};

/// Pure value-in/value-out equivalent of
/// `Clay_ApplyTransitionedPropertiesToElement`.
pub fn applyProperties(
    input: ApplicationTarget,
    properties: types.TransitionProperty,
    current: types.TransitionData,
    reparented: bool,
) ApplicationTarget {
    var result = input;

    if (intersects(properties, .width)) {
        if (!reparented) {
            result.dimensions.width = current.bounding_box.width;
            result.layout.sizing.width = types.fixed(current.bounding_box.width);
        } else {
            result.bounding_box.width = current.bounding_box.width;
        }
    }
    if (intersects(properties, .height)) {
        if (!reparented) {
            result.dimensions.height = current.bounding_box.height;
            result.layout.sizing.height = types.fixed(current.bounding_box.height);
        } else {
            result.bounding_box.height = current.bounding_box.height;
        }
    }
    if (intersects(properties, .x)) {
        result.bounding_box.x = current.bounding_box.x;
    }
    if (intersects(properties, .y)) {
        result.bounding_box.y = current.bounding_box.y;
    }
    if (intersects(properties, .overlay_color)) {
        result.overlay_color = current.overlay_color;
    }
    if (intersects(properties, .background_color)) {
        result.background_color = current.background_color;
    }
    if (intersects(properties, .border_color)) {
        result.border.color = current.border_color;
    }
    if (intersects(properties, .border_width)) {
        result.border.width = current.border_width;
    }

    return result;
}

pub const ChangeDetection = struct {
    old_parent_relative_position: types.Vector2 = .{},
    new_parent_relative_position: types.Vector2 = .{},
    reparented: bool = false,
    root_resized_last_frame: bool = false,
};

fn floatEqual(left: f32, right: f32) bool {
    @setFloatMode(.strict);
    const subtracted: f32 = left - right;
    return subtracted < 0.01 and subtracted > -0.01;
}

fn bitwiseEqual(comptime T: type, left: T, right: T) bool {
    return std.mem.eql(u8, std.mem.asBytes(&left), std.mem.asBytes(&right));
}

/// Detect the newly changed properties using the same comparisons and
/// position guards as Clay's transition update loop. This does not merge in
/// already-active properties; callers retain control of that lifecycle step.
pub fn changedProperties(
    configured: types.TransitionProperty,
    old_target: types.TransitionData,
    new_target: types.TransitionData,
    detection: ChangeDetection,
) types.TransitionProperty {
    var bits: u16 = @backingInt(types.TransitionProperty.none);

    if (intersects(configured, .x) and
        !floatEqual(old_target.bounding_box.x, new_target.bounding_box.x) and
        (!floatEqual(detection.old_parent_relative_position.x, detection.new_parent_relative_position.x) or detection.reparented) and
        !detection.root_resized_last_frame)
    {
        bits |= @backingInt(types.TransitionProperty.x);
    }
    if (intersects(configured, .y) and
        !floatEqual(old_target.bounding_box.y, new_target.bounding_box.y) and
        (!floatEqual(detection.old_parent_relative_position.y, detection.new_parent_relative_position.y) or detection.reparented) and
        !detection.root_resized_last_frame)
    {
        bits |= @backingInt(types.TransitionProperty.y);
    }
    if (intersects(configured, .width) and
        !floatEqual(old_target.bounding_box.width, new_target.bounding_box.width) and
        !detection.root_resized_last_frame)
    {
        bits |= @backingInt(types.TransitionProperty.width);
    }
    if (intersects(configured, .height) and
        !floatEqual(old_target.bounding_box.height, new_target.bounding_box.height) and
        !detection.root_resized_last_frame)
    {
        bits |= @backingInt(types.TransitionProperty.height);
    }
    if (intersects(configured, .background_color) and
        !bitwiseEqual(types.Color, old_target.background_color, new_target.background_color))
    {
        bits |= @backingInt(types.TransitionProperty.background_color);
    }
    if (intersects(configured, .overlay_color) and
        !bitwiseEqual(types.Color, old_target.overlay_color, new_target.overlay_color))
    {
        bits |= @backingInt(types.TransitionProperty.overlay_color);
    }
    if (intersects(configured, .border_color) and
        !bitwiseEqual(types.Color, old_target.border_color, new_target.border_color))
    {
        bits |= @backingInt(types.TransitionProperty.border_color);
    }
    if (intersects(configured, .border_width) and
        !bitwiseEqual(types.BorderWidth, old_target.border_width, new_target.border_width))
    {
        bits |= @backingInt(types.TransitionProperty.border_width);
    }

    return @fromBackingInt(@intCast(bits));
}

fn allSupportedProperties() types.TransitionProperty {
    return supported_properties.merge(.corner_radius);
}

fn expectFixed(axis: types.SizingAxis, expected: f32) !void {
    try std.testing.expectEqual(types.SizingType.fixed, axis.type);
    try std.testing.expectEqual(expected, axis.size.min_max.min);
    try std.testing.expectEqual(expected, axis.size.min_max.max);
}

test "ease out entering starts at the initial selected values" {
    const initial: types.TransitionData = .{
        .bounding_box = .{ .x = 2, .y = 4, .width = 20, .height = 40 },
        .background_color = .{ .r = 10, .g = 20, .b = 30, .a = 40 },
    };
    const target: types.TransitionData = .{
        .bounding_box = .{ .x = 10, .y = 12, .width = 60, .height = 80 },
        .background_color = .{ .r = 110, .g = 120, .b = 130, .a = 140 },
    };
    var current: types.TransitionData = .{
        .bounding_box = .{ .x = -1, .y = -2, .width = -3, .height = -4 },
        .overlay_color = .{ .r = 77 },
    };

    const complete = easeOut(.{
        .transition_state = .entering,
        .initial = initial,
        .current = &current,
        .target = target,
        .elapsed_time = 0,
        .duration = 1,
        .properties = .position,
    });

    try std.testing.expect(!complete);
    try std.testing.expectEqual(@as(f32, 2), current.bounding_box.x);
    try std.testing.expectEqual(@as(f32, 4), current.bounding_box.y);
    try std.testing.expectEqual(@as(f32, -3), current.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 77), current.overlay_color.r);
}

test "ease out target change interpolates every represented property" {
    const initial: types.TransitionData = .{
        .bounding_box = .{ .x = 2, .y = 4, .width = 20, .height = 40 },
        .background_color = .{ .r = 0, .g = 10, .b = 20, .a = 30 },
        .overlay_color = .{ .r = 40, .g = 50, .b = 60, .a = 70 },
        .border_color = .{ .r = 80, .g = 90, .b = 100, .a = 110 },
        .border_width = .{ .left = 0, .right = 10, .top = 20, .bottom = 30, .between_children = 40 },
    };
    const target: types.TransitionData = .{
        .bounding_box = .{ .x = 10, .y = 12, .width = 60, .height = 80 },
        .background_color = .{ .r = 100, .g = 110, .b = 120, .a = 130 },
        .overlay_color = .{ .r = 140, .g = 150, .b = 160, .a = 170 },
        .border_color = .{ .r = 180, .g = 190, .b = 200, .a = 210 },
        .border_width = .{ .left = 10, .right = 0, .top = 40, .bottom = 50, .between_children = 60 },
    };
    var current: types.TransitionData = .{};

    const complete = easeOut(.{
        .transition_state = .transitioning,
        .initial = initial,
        .current = &current,
        .target = target,
        .elapsed_time = 0.5,
        .duration = 1,
        .properties = allSupportedProperties(),
    });

    try std.testing.expect(!complete);
    try std.testing.expectEqual(@as(f32, 9), current.bounding_box.x);
    try std.testing.expectEqual(@as(f32, 11), current.bounding_box.y);
    try std.testing.expectEqual(@as(f32, 55), current.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 75), current.bounding_box.height);
    try std.testing.expectEqual(@as(f32, 87.5), current.background_color.r);
    try std.testing.expectEqual(@as(f32, 137.5), current.overlay_color.g);
    try std.testing.expectEqual(@as(f32, 187.5), current.border_color.b);
    try std.testing.expectEqual(@as(u16, 8), current.border_width.left);
    try std.testing.expectEqual(@as(u16, 1), current.border_width.right);
    try std.testing.expectEqual(@as(u16, 37), current.border_width.top);
    try std.testing.expectEqual(@as(u16, 47), current.border_width.bottom);
    try std.testing.expectEqual(@as(u16, 57), current.border_width.between_children);
}

test "ease out exit reaches target and reports completion" {
    const initial: types.TransitionData = .{
        .bounding_box = .{ .x = 3, .y = 6 },
        .border_width = .{ .left = 5 },
    };
    const target: types.TransitionData = .{
        .bounding_box = .{ .x = 30, .y = 60 },
        .border_width = .{ .left = 15 },
    };
    var current = initial;

    const complete = easeOut(.{
        .transition_state = .exiting,
        .initial = initial,
        .current = &current,
        .target = target,
        .elapsed_time = 2,
        .duration = 1,
        .properties = types.TransitionProperty.position.merge(.border_width),
    });

    try std.testing.expect(complete);
    try std.testing.expectEqual(@as(f32, 30), current.bounding_box.x);
    try std.testing.expectEqual(@as(f32, 60), current.bounding_box.y);
    try std.testing.expectEqual(@as(u16, 15), current.border_width.left);
}

test "zero duration completes synchronously at the target" {
    const initial: types.TransitionData = .{
        .bounding_box = .{ .width = 10 },
        .background_color = .{ .r = 5 },
    };
    const target: types.TransitionData = .{
        .bounding_box = .{ .width = 90 },
        .background_color = .{ .r = 205 },
    };
    var current = initial;

    const complete = easeOut(.{
        .transition_state = .transitioning,
        .initial = initial,
        .current = &current,
        .target = target,
        .elapsed_time = 0,
        .duration = 0,
        .properties = types.TransitionProperty.width.merge(.background_color),
    });

    try std.testing.expect(complete);
    try std.testing.expectEqual(target.bounding_box.width, current.bounding_box.width);
    try std.testing.expectEqual(target.background_color, current.background_color);
}

test "corner radius property remains the upstream no-op" {
    const initial: types.TransitionData = .{ .background_color = .{ .r = 10 } };
    const target: types.TransitionData = .{ .background_color = .{ .r = 200 } };
    var current: types.TransitionData = .{ .background_color = .{ .r = 77 } };

    const complete = easeOut(.{
        .transition_state = .transitioning,
        .initial = initial,
        .current = &current,
        .target = target,
        .elapsed_time = 1,
        .duration = 1,
        .properties = .corner_radius,
    });

    try std.testing.expect(complete);
    try std.testing.expectEqual(@as(f32, 77), current.background_color.r);
}

test "apply properties mirrors normal and reparented sizing behavior" {
    const input: ApplicationTarget = .{
        .dimensions = .{ .width = 1, .height = 2 },
        .layout = .{ .sizing = .{ .width = types.fixed(1), .height = types.fixed(2) } },
        .bounding_box = .{ .x = 3, .y = 4, .width = 5, .height = 6 },
    };
    const current: types.TransitionData = .{
        .bounding_box = .{ .x = 30, .y = 40, .width = 50, .height = 60 },
        .background_color = .{ .r = 70 },
        .overlay_color = .{ .g = 80 },
        .border_color = .{ .b = 90 },
        .border_width = .{ .left = 10 },
    };

    const applied = applyProperties(input, supported_properties, current, false);
    try std.testing.expectEqual(@as(f32, 50), applied.dimensions.width);
    try std.testing.expectEqual(@as(f32, 60), applied.dimensions.height);
    try std.testing.expectEqual(@as(f32, 5), applied.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 6), applied.bounding_box.height);
    try std.testing.expectEqual(@as(f32, 30), applied.bounding_box.x);
    try std.testing.expectEqual(@as(f32, 40), applied.bounding_box.y);
    try expectFixed(applied.layout.sizing.width, 50);
    try expectFixed(applied.layout.sizing.height, 60);
    try std.testing.expectEqual(current.background_color, applied.background_color);
    try std.testing.expectEqual(current.overlay_color, applied.overlay_color);
    try std.testing.expectEqual(current.border_color, applied.border.color);
    try std.testing.expectEqual(current.border_width, applied.border.width);

    const reparented = applyProperties(input, .dimensions, current, true);
    try std.testing.expectEqual(input.dimensions, reparented.dimensions);
    try expectFixed(reparented.layout.sizing.width, 1);
    try std.testing.expectEqual(@as(f32, 50), reparented.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 60), reparented.bounding_box.height);
}

test "changed properties follows epsilon parent and byte comparisons" {
    const old_target: types.TransitionData = .{
        .bounding_box = .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        .background_color = .{ .r = 0.0 },
        .border_width = .{ .left = 1 },
    };
    const new_target: types.TransitionData = .{
        .bounding_box = .{ .x = 20, .y = 20.005, .width = 50, .height = 60 },
        .background_color = .{ .r = -0.0 },
        .border_width = .{ .left = 2 },
    };

    const changed = changedProperties(allSupportedProperties(), old_target, new_target, .{
        .old_parent_relative_position = .{ .x = 1, .y = 2 },
        .new_parent_relative_position = .{ .x = 3, .y = 4 },
    });

    try std.testing.expect(intersects(changed, .x));
    try std.testing.expect(!intersects(changed, .y));
    try std.testing.expect(intersects(changed, .width));
    try std.testing.expect(intersects(changed, .height));
    try std.testing.expect(intersects(changed, .background_color));
    try std.testing.expect(intersects(changed, .border_width));

    const parent_only_move = changedProperties(.position, old_target, new_target, .{
        .old_parent_relative_position = .{ .x = 1, .y = 2 },
        .new_parent_relative_position = .{ .x = 1, .y = 2 },
    });
    try std.testing.expectEqual(types.TransitionProperty.none, parent_only_move);

    const root_resize = changedProperties(.bounding_box, old_target, new_target, .{
        .old_parent_relative_position = .{ .x = 1, .y = 2 },
        .new_parent_relative_position = .{ .x = 3, .y = 4 },
        .root_resized_last_frame = true,
    });
    try std.testing.expectEqual(types.TransitionProperty.none, root_resize);
}

test "border interpolation bounds negative and non-finite extrapolation" {
    var current = types.TransitionData{};
    const complete = easeOut(.{
        .transition_state = .transitioning,
        .initial = .{ .border_width = .{} },
        .current = &current,
        .target = .{ .border_width = .{ .left = std.math.maxInt(u16) } },
        .elapsed_time = -1,
        .duration = 1,
        .properties = .border_width,
    });
    try std.testing.expect(!complete);
    try std.testing.expectEqual(@as(u16, 0), current.border_width.left);

    const sentinel: u16 = 123;
    const nan_result = interpolateProperties(
        .{ .border_width = .{ .left = sentinel } },
        .{ .border_width = .{ .left = sentinel } },
        .{ .border_width = .{ .left = 456 } },
        .border_width,
        std.math.nan(f32),
    );
    try std.testing.expectEqual(sentinel, nan_result.border_width.left);
}
