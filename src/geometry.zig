//! Pure geometry and final-layout helpers for the native Clay port.
//!
//! The arithmetic and edge comparisons in this file follow Clay's `clay.h`
//! at commit e6cc36941ab2af5d81107617039d6f527a1c660b. These helpers own no
//! engine state, so the future context and traversal layers can reuse them
//! without depending on allocation, hashing, or render-command generation.

const std = @import("std");
const types = @import("types.zig");

/// Native equivalent of `Clay__PointIsInsideRect`. All four edges are
/// inclusive, matching Clay's pointer hit-testing behavior.
pub fn pointIsInsideRect(point: types.Vector2, rect: types.BoundingBox) bool {
    @setFloatMode(.strict);
    return point.x >= rect.x and
        point.x <= rect.x + rect.width and
        point.y >= rect.y and
        point.y <= rect.y + rect.height;
}

/// Native equivalent of `Clay__ElementIsOffscreen`, with the two context
/// values made explicit. A box touching a viewport edge is still onscreen.
pub fn elementIsOffscreen(
    bounding_box: types.BoundingBox,
    viewport: types.Dimensions,
    disable_culling: bool,
) bool {
    @setFloatMode(.strict);
    if (disable_culling) return false;

    return bounding_box.x > viewport.width or
        bounding_box.y > viewport.height or
        bounding_box.x + bounding_box.width < 0 or
        bounding_box.y + bounding_box.height < 0;
}

/// Return whether two ordinary Clay bounding boxes overlap. Edge-only contact
/// counts as an intersection, consistently with inclusive pointer hit tests
/// and viewport culling.
pub fn boundingBoxesIntersect(left: types.BoundingBox, right: types.BoundingBox) bool {
    @setFloatMode(.strict);
    return left.x <= right.x + right.width and
        left.x + left.width >= right.x and
        left.y <= right.y + right.height and
        left.y + left.height >= right.y;
}

/// Return the overlapping box. An edge-only intersection is represented by a
/// box with zero width or height rather than `null`.
pub fn boundingBoxIntersection(
    left: types.BoundingBox,
    right: types.BoundingBox,
) ?types.BoundingBox {
    @setFloatMode(.strict);
    if (!boundingBoxesIntersect(left, right)) return null;

    const intersection_left = if (left.x > right.x) left.x else right.x;
    const intersection_top = if (left.y > right.y) left.y else right.y;
    const left_right = left.x + left.width;
    const right_right = right.x + right.width;
    const intersection_right = if (left_right < right_right) left_right else right_right;
    const left_bottom = left.y + left.height;
    const right_bottom = right.y + right.height;
    const intersection_bottom = if (left_bottom < right_bottom) left_bottom else right_bottom;

    return .{
        .x = intersection_left,
        .y = intersection_top,
        .width = intersection_right - intersection_left,
        .height = intersection_bottom - intersection_top,
    };
}

/// Test an element box against an optional clip box. No clip means the element
/// passes; edge contact passes because Clay's rectangle edges are inclusive.
pub fn boundingBoxPassesClip(
    element_box: types.BoundingBox,
    clip_box: ?types.BoundingBox,
) bool {
    const clip = clip_box orelse return true;
    return boundingBoxesIntersect(element_box, clip);
}

/// Pure form of the pointer-over rectangle and clip predicate in
/// `Clay_SetPointerState`. External scroll handling deliberately bypasses the
/// clip hit test, but never bypasses the element hit test.
pub fn pointPassesClip(
    point: types.Vector2,
    element_box: types.BoundingBox,
    clip_box: ?types.BoundingBox,
    external_scroll_handling_enabled: bool,
) bool {
    if (!pointIsInsideRect(point, element_box)) return false;
    const clip = clip_box orelse return true;
    return pointIsInsideRect(point, clip) or external_scroll_handling_enabled;
}

/// Native equivalent of `Clay__BorderHasAnyWidth` at the value level.
pub fn borderWidthHasAny(width: types.BorderWidth) bool {
    return width.between_children > 0 or
        width.left > 0 or
        width.right > 0 or
        width.top > 0 or
        width.bottom > 0;
}

/// Native equivalent of `Clay__BorderHasAnyWidth` for a complete border
/// configuration.
pub fn borderHasAnyWidth(config: types.BorderElementConfig) bool {
    return borderWidthHasAny(config.width);
}

fn attachPointX(bounding_box: types.BoundingBox, point: types.FloatingAttachPointType) f32 {
    @setFloatMode(.strict);
    return switch (point) {
        .left_top, .left_center, .left_bottom => bounding_box.x,
        .center_top, .center_center, .center_bottom => bounding_box.x + bounding_box.width / 2,
        .right_top, .right_center, .right_bottom => bounding_box.x + bounding_box.width,
    };
}

fn attachPointY(bounding_box: types.BoundingBox, point: types.FloatingAttachPointType) f32 {
    @setFloatMode(.strict);
    return switch (point) {
        .left_top, .center_top, .right_top => bounding_box.y,
        .left_center, .center_center, .right_center => bounding_box.y + bounding_box.height / 2,
        .left_bottom, .center_bottom, .right_bottom => bounding_box.y + bounding_box.height,
    };
}

/// Resolve any of Clay's nine attachment points within a bounding box.
pub fn attachPoint(
    bounding_box: types.BoundingBox,
    point: types.FloatingAttachPointType,
) types.Vector2 {
    return .{
        .x = attachPointX(bounding_box, point),
        .y = attachPointY(bounding_box, point),
    };
}

/// Calculate a floating tree root's position from its parent and attachment
/// configuration. As upstream does, unattached roots and attached roots whose
/// parent cannot be found remain at the default origin, without applying the
/// configured offset.
pub fn floatingRootPosition(
    parent_box: ?types.BoundingBox,
    root_dimensions: types.Dimensions,
    config: types.FloatingElementConfig,
) types.Vector2 {
    @setFloatMode(.strict);
    if (config.attach_to == .none) return .{};
    const parent = parent_box orelse return .{};

    var target = attachPoint(parent, config.attach_points.parent);
    const root_box: types.BoundingBox = .{
        .width = root_dimensions.width,
        .height = root_dimensions.height,
    };
    const root_attach = attachPoint(root_box, config.attach_points.element);
    target.x -= root_attach.x;
    target.y -= root_attach.y;
    target.x += config.offset.x;
    target.y += config.offset.y;
    return target;
}

/// Apply the external-scroll correction used for floating roots attached to a
/// clip element. Callers represent a missing, offscreen, or otherwise inactive
/// clip element with `null`, mirroring the guard around the upstream block.
pub fn adjustFloatingRootForExternalScroll(
    root_position: types.Vector2,
    clip_config: ?types.ClipElementConfig,
    external_scroll_handling_enabled: bool,
) types.Vector2 {
    @setFloatMode(.strict);
    var result = root_position;
    if (!external_scroll_handling_enabled) return result;
    const clip = clip_config orelse return result;

    if (clip.horizontal) result.x += clip.child_offset.x;
    if (clip.vertical) result.y += clip.child_offset.y;
    return result;
}

/// Expand a floating box equally in both directions on each axis.
pub fn expandFloatingBoundingBox(
    bounding_box: types.BoundingBox,
    expand: types.Dimensions,
) types.BoundingBox {
    @setFloatMode(.strict);
    var result = bounding_box;
    result.x -= expand.width;
    result.width += expand.width * 2;
    result.y -= expand.height;
    result.height += expand.height * 2;
    return result;
}

/// Build the box used by final layout for a floating root. Expansion is
/// conditional only on `attach_to != none`, just as in Clay; it still occurs
/// if attachment lookup failed and the supplied root position is the origin.
pub fn floatingBoundingBox(
    root_position: types.Vector2,
    root_dimensions: types.Dimensions,
    config: types.FloatingElementConfig,
) types.BoundingBox {
    const bounding_box: types.BoundingBox = .{
        .x = root_position.x,
        .y = root_position.y,
        .width = root_dimensions.width,
        .height = root_dimensions.height,
    };
    if (config.attach_to == .none) return bounding_box;
    return expandFloatingBoundingBox(bounding_box, config.expand);
}

/// The geometry needed from a child during final-layout positioning.
pub const ChildGeometry = struct {
    dimensions: types.Dimensions = .{},
    exiting: bool = false,
};

/// The result of Clay's content measurement and on-axis alignment block.
pub const ContentGeometry = struct {
    content_size: types.Dimensions = .{},
    next_child_offset: types.Vector2 = .{},
};

fn maxLikeClay(left: f32, right: f32) f32 {
    return if (left > right) left else right;
}

fn horizontalPadding(padding: types.Padding) f32 {
    const total: u32 = @as(u32, padding.left) + @as(u32, padding.right);
    return @floatFromInt(total);
}

fn verticalPadding(padding: types.Padding) f32 {
    const total: u32 = @as(u32, padding.top) + @as(u32, padding.bottom);
    return @floatFromInt(total);
}

fn gapSize(child_count: usize, child_gap: u16) f32 {
    const gap_count = child_count -| 1;
    const total: u128 = @as(u128, gap_count) * @as(u128, child_gap);
    return @floatFromInt(total);
}

/// Measure child content exactly as final layout does. Exiting children do not
/// contribute dimensions. The gap count nevertheless uses the complete child
/// count, including exiting children, matching the current upstream behavior.
pub fn contentSize(
    children: []const ChildGeometry,
    direction: types.LayoutDirection,
    child_gap: u16,
) types.Dimensions {
    @setFloatMode(.strict);
    var result: types.Dimensions = .{};

    switch (direction) {
        .left_to_right => {
            for (children) |child| {
                if (child.exiting) continue;
                result.width += child.dimensions.width;
                result.height = maxLikeClay(result.height, child.dimensions.height);
            }
            result.width += gapSize(children.len, child_gap);
        },
        .top_to_bottom => {
            for (children) |child| {
                if (child.exiting) continue;
                result.width = maxLikeClay(result.width, child.dimensions.width);
                result.height += child.dimensions.height;
            }
            result.height += gapSize(children.len, child_gap);
        },
    }

    return result;
}

/// Measure content and apply the parent's alignment on the layout axis. The
/// returned offset begins at the configured left/top padding. Negative on-axis
/// extra space is clamped to zero after alignment, matching `CLAY__MAX`.
pub fn contentAndOnAxisOffset(
    parent_dimensions: types.Dimensions,
    config: types.LayoutConfig,
    children: []const ChildGeometry,
) ContentGeometry {
    @setFloatMode(.strict);
    const content = contentSize(children, config.layout_direction, config.child_gap);
    var next_child_offset: types.Vector2 = .{
        .x = @floatFromInt(config.padding.left),
        .y = @floatFromInt(config.padding.top),
    };

    switch (config.layout_direction) {
        .left_to_right => {
            var extra_space = parent_dimensions.width - horizontalPadding(config.padding) - content.width;
            switch (config.child_alignment.x) {
                .left => extra_space = 0,
                .center => extra_space /= 2,
                .right => {},
            }
            extra_space = maxLikeClay(0, extra_space);
            next_child_offset.x += extra_space;
        },
        .top_to_bottom => {
            var extra_space = parent_dimensions.height - verticalPadding(config.padding) - content.height;
            switch (config.child_alignment.y) {
                .top => extra_space = 0,
                .center => extra_space /= 2,
                .bottom => {},
            }
            extra_space = maxLikeClay(0, extra_space);
            next_child_offset.y += extra_space;
        },
    }

    return .{
        .content_size = content,
        .next_child_offset = next_child_offset,
    };
}

/// Apply alignment on the axis perpendicular to layout. Clay resets that axis
/// to its leading padding for every child. Unlike on-axis extra space, negative
/// cross-axis whitespace is intentionally not clamped.
pub fn crossAxisAlignedOffset(
    current_offset: types.Vector2,
    parent_dimensions: types.Dimensions,
    child_dimensions: types.Dimensions,
    config: types.LayoutConfig,
) types.Vector2 {
    @setFloatMode(.strict);
    var result = current_offset;

    switch (config.layout_direction) {
        .left_to_right => {
            result.y = @floatFromInt(config.padding.top);
            const whitespace = parent_dimensions.height - verticalPadding(config.padding) - child_dimensions.height;
            switch (config.child_alignment.y) {
                .top => {},
                .center => result.y += whitespace / 2,
                .bottom => result.y += whitespace,
            }
        },
        .top_to_bottom => {
            result.x = @floatFromInt(config.padding.left);
            const whitespace = parent_dimensions.width - horizontalPadding(config.padding) - child_dimensions.width;
            switch (config.child_alignment.x) {
                .left => {},
                .center => result.x += whitespace / 2,
                .right => result.x += whitespace,
            }
        },
    }

    return result;
}

/// Position a child from its parent's final box, current layout offset, and
/// the scroll-container offset selected by the caller.
pub fn childPosition(
    parent_box: types.BoundingBox,
    child_offset: types.Vector2,
    scroll_offset: types.Vector2,
) types.Vector2 {
    @setFloatMode(.strict);
    return .{
        .x = parent_box.x + child_offset.x + scroll_offset.x,
        .y = parent_box.y + child_offset.y + scroll_offset.y,
    };
}

/// Advance the parent traversal offset after positioning one child. Exiting
/// children leave the offset unchanged.
pub fn advanceChildOffset(
    current_offset: types.Vector2,
    child: ChildGeometry,
    direction: types.LayoutDirection,
    child_gap: u16,
) types.Vector2 {
    @setFloatMode(.strict);
    if (child.exiting) return current_offset;

    var result = current_offset;
    const gap: f32 = @floatFromInt(child_gap);
    switch (direction) {
        .left_to_right => result.x += child.dimensions.width + gap,
        .top_to_bottom => result.y += child.dimensions.height + gap,
    }
    return result;
}

/// Add parent padding to the measured child content size, as stored for a
/// scroll container after final layout.
pub fn paddedContentSize(content_size: types.Dimensions, padding: types.Padding) types.Dimensions {
    @setFloatMode(.strict);
    return .{
        .width = content_size.width + horizontalPadding(padding),
        .height = content_size.height + verticalPadding(padding),
    };
}

fn expectVectorEqual(expected: types.Vector2, actual: types.Vector2) !void {
    try std.testing.expectEqual(expected.x, actual.x);
    try std.testing.expectEqual(expected.y, actual.y);
}

fn expectDimensionsEqual(expected: types.Dimensions, actual: types.Dimensions) !void {
    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
}

fn expectBoundingBoxEqual(expected: types.BoundingBox, actual: types.BoundingBox) !void {
    try std.testing.expectEqual(expected.x, actual.x);
    try std.testing.expectEqual(expected.y, actual.y);
    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
}

test "point-in-rect includes every edge and rejects points just outside" {
    const rect: types.BoundingBox = .{ .x = 10, .y = 20, .width = 30, .height = 40 };
    const inside = [_]types.Vector2{
        .{ .x = 10, .y = 20 },
        .{ .x = 40, .y = 20 },
        .{ .x = 10, .y = 60 },
        .{ .x = 40, .y = 60 },
        .{ .x = 25, .y = 40 },
    };
    for (inside) |point| try std.testing.expect(pointIsInsideRect(point, rect));

    const outside = [_]types.Vector2{
        .{ .x = 9.999, .y = 40 },
        .{ .x = 40.001, .y = 40 },
        .{ .x = 25, .y = 19.999 },
        .{ .x = 25, .y = 60.001 },
    };
    for (outside) |point| try std.testing.expect(!pointIsInsideRect(point, rect));
}

test "viewport culling preserves edge contact and obeys the disable flag" {
    const viewport: types.Dimensions = .{ .width = 100, .height = 80 };

    try std.testing.expect(!elementIsOffscreen(.{ .x = 100, .y = 20, .width = 10, .height = 10 }, viewport, false));
    try std.testing.expect(!elementIsOffscreen(.{ .x = -10, .y = 20, .width = 10, .height = 10 }, viewport, false));
    try std.testing.expect(!elementIsOffscreen(.{ .x = 20, .y = 80, .width = 10, .height = 10 }, viewport, false));
    try std.testing.expect(!elementIsOffscreen(.{ .x = 20, .y = -10, .width = 10, .height = 10 }, viewport, false));

    try std.testing.expect(elementIsOffscreen(.{ .x = 100.001, .y = 20, .width = 10, .height = 10 }, viewport, false));
    try std.testing.expect(elementIsOffscreen(.{ .x = -10.001, .y = 20, .width = 10, .height = 10 }, viewport, false));
    try std.testing.expect(elementIsOffscreen(.{ .x = 20, .y = 80.001, .width = 10, .height = 10 }, viewport, false));
    try std.testing.expect(elementIsOffscreen(.{ .x = 20, .y = -10.001, .width = 10, .height = 10 }, viewport, false));

    try std.testing.expect(!elementIsOffscreen(.{ .x = 1000, .y = 1000, .width = 1, .height = 1 }, viewport, true));
}

test "bounding-box intersection and clip checks include touching edges" {
    const left: types.BoundingBox = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const touching: types.BoundingBox = .{ .x = 10, .y = 2, .width = 5, .height = 4 };
    const separate: types.BoundingBox = .{ .x = 10.001, .y = 2, .width = 5, .height = 4 };

    try std.testing.expect(boundingBoxesIntersect(left, touching));
    try expectBoundingBoxEqual(
        .{ .x = 10, .y = 2, .width = 0, .height = 4 },
        boundingBoxIntersection(left, touching).?,
    );
    try std.testing.expect(!boundingBoxesIntersect(left, separate));
    try std.testing.expect(boundingBoxIntersection(left, separate) == null);
    try std.testing.expect(boundingBoxPassesClip(left, null));
    try std.testing.expect(boundingBoxPassesClip(left, touching));
    try std.testing.expect(!boundingBoxPassesClip(left, separate));
}

test "pointer clip checks match Clay external-scroll bypass behavior" {
    const element: types.BoundingBox = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    const clip: types.BoundingBox = .{ .x = 10, .y = 10, .width = 20, .height = 20 };

    try std.testing.expect(pointPassesClip(.{ .x = 5, .y = 5 }, element, null, false));
    try std.testing.expect(!pointPassesClip(.{ .x = 5, .y = 5 }, element, clip, false));
    try std.testing.expect(pointPassesClip(.{ .x = 10, .y = 10 }, element, clip, false));
    try std.testing.expect(pointPassesClip(.{ .x = 5, .y = 5 }, element, clip, true));
    try std.testing.expect(!pointPassesClip(.{ .x = 25, .y = 25 }, element, clip, true));
}

test "border width presence checks every side and between-children width" {
    try std.testing.expect(!borderWidthHasAny(.{}));
    try std.testing.expect(borderWidthHasAny(.{ .left = 1 }));
    try std.testing.expect(borderWidthHasAny(.{ .right = 1 }));
    try std.testing.expect(borderWidthHasAny(.{ .top = 1 }));
    try std.testing.expect(borderWidthHasAny(.{ .bottom = 1 }));
    try std.testing.expect(borderWidthHasAny(.{ .between_children = 1 }));
    try std.testing.expect(borderHasAnyWidth(.{ .width = .{ .between_children = 2 } }));
}

test "all 9 by 9 floating attachment combinations resolve independently" {
    const points = [_]types.FloatingAttachPointType{
        .left_top,
        .left_center,
        .left_bottom,
        .center_top,
        .center_center,
        .center_bottom,
        .right_top,
        .right_center,
        .right_bottom,
    };
    const fractions = [_]types.Vector2{
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 0.5 },
        .{ .x = 0, .y = 1 },
        .{ .x = 0.5, .y = 0 },
        .{ .x = 0.5, .y = 0.5 },
        .{ .x = 0.5, .y = 1 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 0.5 },
        .{ .x = 1, .y = 1 },
    };
    const parent: types.BoundingBox = .{ .x = 100, .y = 200, .width = 80, .height = 60 };
    const root: types.Dimensions = .{ .width = 20, .height = 10 };

    for (points, fractions) |parent_point, parent_fraction| {
        for (points, fractions) |element_point, element_fraction| {
            const config: types.FloatingElementConfig = .{
                .attach_to = .parent,
                .offset = .{ .x = 3, .y = -4 },
                .attach_points = .{
                    .parent = parent_point,
                    .element = element_point,
                },
            };
            const expected: types.Vector2 = .{
                .x = parent.x + parent_fraction.x * parent.width - element_fraction.x * root.width + 3,
                .y = parent.y + parent_fraction.y * parent.height - element_fraction.y * root.height - 4,
            };
            try expectVectorEqual(expected, floatingRootPosition(parent, root, config));
        }
    }
}

test "floating roots preserve origin fallback, external offsets, and expand semantics" {
    const parent: types.BoundingBox = .{ .x = 20, .y = 30, .width = 40, .height = 50 };
    const dimensions: types.Dimensions = .{ .width = 30, .height = 40 };

    const unattached: types.FloatingElementConfig = .{
        .offset = .{ .x = 99, .y = 99 },
        .expand = .{ .width = 2, .height = 3 },
    };
    try expectVectorEqual(.{}, floatingRootPosition(parent, dimensions, unattached));
    try expectBoundingBoxEqual(
        .{ .width = 30, .height = 40 },
        floatingBoundingBox(.{}, dimensions, unattached),
    );

    const attached: types.FloatingElementConfig = .{
        .attach_to = .parent,
        .offset = .{ .x = 99, .y = 99 },
        .expand = .{ .width = 2, .height = 3 },
    };
    const missing_parent_position = floatingRootPosition(null, dimensions, attached);
    try expectVectorEqual(.{}, missing_parent_position);
    try expectBoundingBoxEqual(
        .{ .x = -2, .y = -3, .width = 34, .height = 46 },
        floatingBoundingBox(missing_parent_position, dimensions, attached),
    );
    try expectBoundingBoxEqual(
        .{ .x = 8, .y = 17, .width = 34, .height = 46 },
        floatingBoundingBox(.{ .x = 10, .y = 20 }, dimensions, attached),
    );

    const clip: types.ClipElementConfig = .{
        .horizontal = true,
        .vertical = false,
        .child_offset = .{ .x = -7, .y = 13 },
    };
    try expectVectorEqual(
        .{ .x = 10, .y = 20 },
        adjustFloatingRootForExternalScroll(.{ .x = 10, .y = 20 }, clip, false),
    );
    try expectVectorEqual(
        .{ .x = 3, .y = 20 },
        adjustFloatingRootForExternalScroll(.{ .x = 10, .y = 20 }, clip, true),
    );
    try expectVectorEqual(
        .{ .x = 10, .y = 20 },
        adjustFloatingRootForExternalScroll(.{ .x = 10, .y = 20 }, null, true),
    );
}

const two_children = [_]ChildGeometry{
    .{ .dimensions = .{ .width = 10, .height = 20 } },
    .{ .dimensions = .{ .width = 30, .height = 15 } },
};

const test_padding: types.Padding = .{ .left = 2, .right = 3, .top = 4, .bottom = 5 };

test "content gap totals cannot overflow native word size" {
    const total = gapSize(std.math.maxInt(usize), std.math.maxInt(u16));
    try std.testing.expect(std.math.isFinite(total));
    try std.testing.expect(total > 0);
}

test "left-to-right content and alignment offsets match final layout" {
    const parent: types.Dimensions = .{ .width = 100, .height = 50 };
    try expectDimensionsEqual(.{ .width = 45, .height = 20 }, contentSize(&two_children, .left_to_right, 5));

    const alignments = [_]types.LayoutAlignmentX{ .left, .center, .right };
    const expected_x = [_]f32{ 2, 27, 52 };
    for (alignments, expected_x) |alignment, x| {
        const geometry = contentAndOnAxisOffset(parent, .{
            .padding = test_padding,
            .child_gap = 5,
            .child_alignment = .{ .x = alignment },
            .layout_direction = .left_to_right,
        }, &two_children);
        try expectDimensionsEqual(.{ .width = 45, .height = 20 }, geometry.content_size);
        try expectVectorEqual(.{ .x = x, .y = 4 }, geometry.next_child_offset);
    }

    const y_alignments = [_]types.LayoutAlignmentY{ .top, .center, .bottom };
    const expected_y = [_]f32{ 4, 14.5, 25 };
    for (y_alignments, expected_y) |alignment, y| {
        const offset = crossAxisAlignedOffset(
            .{ .x = 27, .y = 999 },
            parent,
            two_children[0].dimensions,
            .{
                .padding = test_padding,
                .child_alignment = .{ .y = alignment },
                .layout_direction = .left_to_right,
            },
        );
        try expectVectorEqual(.{ .x = 27, .y = y }, offset);
    }
}

test "top-to-bottom content and alignment offsets match final layout" {
    const parent: types.Dimensions = .{ .width = 100, .height = 50 };
    try expectDimensionsEqual(.{ .width = 30, .height = 40 }, contentSize(&two_children, .top_to_bottom, 5));

    const alignments = [_]types.LayoutAlignmentY{ .top, .center, .bottom };
    const expected_y = [_]f32{ 4, 4.5, 5 };
    for (alignments, expected_y) |alignment, y| {
        const geometry = contentAndOnAxisOffset(parent, .{
            .padding = test_padding,
            .child_gap = 5,
            .child_alignment = .{ .y = alignment },
            .layout_direction = .top_to_bottom,
        }, &two_children);
        try expectDimensionsEqual(.{ .width = 30, .height = 40 }, geometry.content_size);
        try expectVectorEqual(.{ .x = 2, .y = y }, geometry.next_child_offset);
    }

    const x_alignments = [_]types.LayoutAlignmentX{ .left, .center, .right };
    const expected_x = [_]f32{ 2, 44.5, 87 };
    for (x_alignments, expected_x) |alignment, x| {
        const offset = crossAxisAlignedOffset(
            .{ .x = 999, .y = 4.5 },
            parent,
            two_children[0].dimensions,
            .{
                .padding = test_padding,
                .child_alignment = .{ .x = alignment },
                .layout_direction = .top_to_bottom,
            },
        );
        try expectVectorEqual(.{ .x = x, .y = 4.5 }, offset);
    }
}

test "alignment preserves on-axis clamp and negative cross-axis whitespace" {
    const on_axis = contentAndOnAxisOffset(
        .{ .width = 20, .height = 50 },
        .{
            .padding = test_padding,
            .child_gap = 5,
            .child_alignment = .{ .x = .right },
            .layout_direction = .left_to_right,
        },
        &two_children,
    );
    try expectVectorEqual(.{ .x = 2, .y = 4 }, on_axis.next_child_offset);

    const cross_axis = crossAxisAlignedOffset(
        .{ .x = 2, .y = 999 },
        .{ .width = 20, .height = 10 },
        two_children[0].dimensions,
        .{
            .padding = test_padding,
            .child_alignment = .{ .y = .bottom },
            .layout_direction = .left_to_right,
        },
    );
    try expectVectorEqual(.{ .x = 2, .y = -15 }, cross_axis);
}

test "exiting children skip dimensions but retain gaps and offset position" {
    const children = [_]ChildGeometry{
        .{ .dimensions = .{ .width = 10, .height = 20 } },
        .{ .dimensions = .{ .width = 100, .height = 200 }, .exiting = true },
        .{ .dimensions = .{ .width = 30, .height = 15 } },
    };

    try expectDimensionsEqual(.{ .width = 50, .height = 20 }, contentSize(&children, .left_to_right, 5));
    try expectDimensionsEqual(.{ .width = 30, .height = 45 }, contentSize(&children, .top_to_bottom, 5));
    try expectDimensionsEqual(.{}, contentSize(&.{}, .left_to_right, 5));

    const start: types.Vector2 = .{ .x = 2, .y = 4 };
    try expectVectorEqual(start, advanceChildOffset(start, children[1], .left_to_right, 5));
    try expectVectorEqual(.{ .x = 17, .y = 4 }, advanceChildOffset(start, children[0], .left_to_right, 5));
    try expectVectorEqual(.{ .x = 2, .y = 29 }, advanceChildOffset(start, children[0], .top_to_bottom, 5));
}

test "padded content size and child position preserve upstream addition order" {
    try expectDimensionsEqual(
        .{ .width = 50, .height = 29 },
        paddedContentSize(.{ .width = 45, .height = 20 }, test_padding),
    );
    try expectVectorEqual(
        .{ .x = 124, .y = 219.5 },
        childPosition(
            .{ .x = 100, .y = 200, .width = 100, .height = 50 },
            .{ .x = 27, .y = 14.5 },
            .{ .x = -3, .y = 5 },
        ),
    );
}
