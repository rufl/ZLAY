//! Pure state and presentation helpers for Clay's built-in debug inspector.
//!
//! The inspector itself is declared into the live layout tree from
//! `Clay_EndLayout`, so its element emission belongs in `Context`. This module
//! contains the parts that do not need access to Context's private frame
//! storage: pinned colors and dimensions, element-list traversal, selection
//! and collapse interaction decoding, hover-row calculation, and the display
//! names used by the configuration pane.

const std = @import("std");
const types = @import("types.zig");
const layout = @import("layout.zig");
const hashes = @import("hash.zig");

pub const default_view_width: u32 = 400;
pub const row_height: i32 = 30;
pub const outer_padding: i32 = 10;
pub const indent_width: i32 = 16;
pub const details_height: i32 = 300;
pub const warning_capacity: usize = 100;

pub const color_1 = types.Color{ .r = 58, .g = 56, .b = 52, .a = 255 };
pub const color_2 = types.Color{ .r = 62, .g = 60, .b = 58, .a = 255 };
pub const color_3 = types.Color{ .r = 141, .g = 133, .b = 135, .a = 255 };
pub const color_4 = types.Color{ .r = 238, .g = 226, .b = 231, .a = 255 };
pub const selected_row_color = types.Color{ .r = 102, .g = 80, .b = 78, .a = 255 };
pub const default_highlight_color = types.Color{ .r = 168, .g = 66, .b = 28, .a = 100 };

pub const ConfigType = enum(u8) {
    background_color,
    overlay_color,
    corner_radius,
    text,
    aspect,
    image,
    floating,
    clip,
    border,
    custom,
};

pub const ConfigLabel = struct {
    label: types.String,
    color: types.Color,
};

/// Exact label text and colors from `Clay__DebugGetElementConfigTypeLabel`.
pub fn configLabel(config_type: ConfigType) ConfigLabel {
    return switch (config_type) {
        .background_color => .{ .label = types.String.literal("Background"), .color = .{ .r = 243, .g = 134, .b = 48, .a = 255 } },
        .overlay_color => .{ .label = types.String.literal("Overlay"), .color = .{ .r = 142, .g = 129, .b = 206, .a = 255 } },
        .corner_radius => .{ .label = types.String.literal("Radius"), .color = .{ .r = 239, .g = 148, .b = 157, .a = 255 } },
        .text => .{ .label = types.String.literal("Text"), .color = .{ .r = 105, .g = 210, .b = 231, .a = 255 } },
        .aspect => .{ .label = types.String.literal("Aspect"), .color = .{ .r = 101, .g = 149, .b = 194, .a = 255 } },
        .image => .{ .label = types.String.literal("Image"), .color = .{ .r = 121, .g = 189, .b = 154, .a = 255 } },
        .floating => .{ .label = types.String.literal("Floating"), .color = .{ .r = 250, .g = 105, .b = 0, .a = 255 } },
        .clip => .{ .label = types.String.literal("Scroll"), .color = .{ .r = 242, .g = 196, .b = 90, .a = 255 } },
        .border => .{ .label = types.String.literal("Border"), .color = .{ .r = 108, .g = 91, .b = 123, .a = 255 } },
        .custom => .{ .label = types.String.literal("Custom"), .color = .{ .r = 11, .g = 72, .b = 107, .a = 255 } },
    };
}

fn bitwiseEqual(comptime T: type, left: T, right: T) bool {
    return std.mem.eql(u8, std.mem.asBytes(&left), std.mem.asBytes(&right));
}

pub fn borderHasAnyWidth(border: types.BorderElementConfig) bool {
    return border.width.left > 0 or border.width.right > 0 or
        border.width.top > 0 or border.width.bottom > 0 or
        border.width.between_children > 0;
}

/// Return the badges emitted on an element-list row, in pinned declaration
/// order. Text rows expose only the Text badge because their node config is a
/// different union arm upstream.
pub fn elementConfigTypes(node: layout.Node, output: *[10]ConfigType) []const ConfigType {
    var length: usize = 0;
    if (node.is_text) {
        output[0] = .text;
        return output[0..1];
    }

    const config = node.config;
    if (config.background_color.a > 0) {
        output[length] = .background_color;
        length += 1;
    }
    if (config.overlay_color.a > 0) {
        output[length] = .overlay_color;
        length += 1;
    }
    if (!bitwiseEqual(types.CornerRadius, config.corner_radius, .{})) {
        output[length] = .corner_radius;
        length += 1;
    }
    if (config.aspect_ratio.aspect_ratio != 0) {
        output[length] = .aspect;
        length += 1;
    }
    if (config.image.image_data != null) {
        output[length] = .image;
        length += 1;
    }
    if (config.floating.attach_to != .none) {
        output[length] = .floating;
        length += 1;
    }
    if (config.clip.horizontal or config.clip.vertical) {
        output[length] = .clip;
        length += 1;
    }
    if (borderHasAnyWidth(config.border)) {
        output[length] = .border;
        length += 1;
    }
    if (config.custom.custom_data != null) {
        output[length] = .custom;
        length += 1;
    }
    return output[0..length];
}

pub const HighlightInput = struct {
    pointer: types.Vector2,
    layout_dimensions: types.Dimensions,
    view_width: f32 = @floatFromInt(default_view_width),
    details_pane_height: f32 = @floatFromInt(details_height),
    scroll_position: ?types.Vector2 = null,
    external_scroll_handling_enabled: bool = false,
};

/// Convert the pointer position to the debug-list row using the same strict
/// bounds, scroll treatment, truncation, and header-row subtraction as Clay.
pub fn highlightedRow(input: HighlightInput) i32 {
    if (!std.math.isFinite(input.pointer.x) or
        !std.math.isFinite(input.pointer.y) or
        !std.math.isFinite(input.layout_dimensions.width) or
        !std.math.isFinite(input.layout_dimensions.height) or
        !std.math.isFinite(input.view_width) or
        !std.math.isFinite(input.details_pane_height) or
        input.view_width < 0 or
        input.details_pane_height < 0)
    {
        return -1;
    }
    var scroll_y_offset: f32 = 0;
    var pointer_in_debug_view = input.pointer.y <
        input.layout_dimensions.height - input.details_pane_height;
    if (input.scroll_position) |position| {
        if (!std.math.isFinite(position.y)) return -1;
        if (!input.external_scroll_handling_enabled) {
            scroll_y_offset = position.y;
        } else {
            pointer_in_debug_view = input.pointer.y + position.y <
                input.layout_dimensions.height - input.details_pane_height;
        }
    }
    if (!pointer_in_debug_view) return -1;
    if (input.pointer.x < input.layout_dimensions.width - input.view_width) return -1;

    const row_float = (input.pointer.y - scroll_y_offset) / @as(f32, @floatFromInt(row_height));
    const minimum: f32 = @floatFromInt(std.math.minInt(i32));
    const maximum: f32 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(row_float) or row_float <= minimum or row_float >= maximum) return -1;
    return @as(i32, @intFromFloat(row_float)) - 1;
}

pub fn rowColor(index: i32, selected_row_index: i32, highlighted_row: i32) types.Color {
    var result = if ((index & 1) == 0) color_2 else color_1;
    if (index == selected_row_index) result = selected_row_color;
    if (index == highlighted_row) {
        result.r *= 1.25;
        result.g *= 1.25;
        result.b *= 1.25;
    }
    return result;
}

pub fn contentWidth(layout_width: f32, debug_enabled: bool, view_width: u32) f32 {
    if (!debug_enabled) return layout_width;
    return @max(layout_width - effectiveViewWidth(layout_width, view_width), 0);
}

pub fn effectiveViewWidth(layout_width: f32, configured_width: u32) f32 {
    if (!std.math.isFinite(layout_width) or layout_width <= 0) return 0;
    return @min(layout_width, @as(f32, @floatFromInt(configured_width)));
}

pub fn effectiveDetailsHeight(layout_height: f32) f32 {
    if (!std.math.isFinite(layout_height) or layout_height <= 0) return 0;
    const minimum_list_height: f32 = @floatFromInt(row_height * 2 + 2);
    return @min(
        @as(f32, @floatFromInt(details_height)),
        @max(layout_height - minimum_list_height, 0),
    );
}

pub fn isOffscreen(box: types.BoundingBox, dimensions: types.Dimensions, culling_enabled: bool) bool {
    if (!culling_enabled) return false;
    return box.x > dimensions.width or box.y > dimensions.height or
        box.x + box.width < 0 or box.y + box.height < 0;
}

pub const RawTextPreview = struct {
    text: []const u8,
    truncated: bool,
};

pub fn rawTextPreview(text: types.String) RawTextPreview {
    const bytes = text.asSlice();
    const length = @min(bytes.len, 40);
    return .{ .text = bytes[0..length], .truncated = bytes.len > 40 };
}

pub const ElementDebugData = struct {
    collision: bool = false,
    collapsed: bool = false,
};

pub const Warning = struct {
    base_message: types.String = .{},
    dynamic_message: types.String = .{},
};

pub const CollapseLookup = struct {
    context: ?*const anyopaque = null,
    function: ?*const fn (?*const anyopaque, u32) bool = null,

    pub fn contains(self: CollapseLookup, element_id: u32) bool {
        const function = self.function orelse return false;
        return function(self.context, element_id);
    }
};

pub const RowKind = enum {
    root_separator,
    element,
    text_contents,
};

pub const Row = struct {
    kind: RowKind,
    row_index: i32,
    root_index: usize,
    depth: usize,
    element_index: ?usize = null,
    element_id: u32 = 0,
};

pub const ListResult = struct {
    row_count: i32 = 0,
    // Upstream zero-initializes this field, so row zero is painted selected
    // even before a valid element has been selected.
    selected_element_row_index: i32 = 0,
    selected_element_id: u32 = 0,
    highlighted_element_id: u32 = 0,
};

pub const TraversalEntry = struct {
    element_index: usize,
    depth: usize,
};

/// Build the logical rows emitted by `Clay__RenderDebugLayoutElementsList`.
/// The caller owns reusable row and DFS buffers so warmed inspector frames do
/// not require allocations.
pub fn collectRows(
    allocator: std.mem.Allocator,
    nodes: []const layout.Node,
    child_indices: []const usize,
    roots: []const layout.Root,
    initial_roots_length: usize,
    collapsed: CollapseLookup,
    selected_element_id: u32,
    highlighted_row: i32,
    pointer_state: types.PointerDataInteractionState,
    rows: *std.ArrayList(Row),
    scratch: *std.ArrayList(TraversalEntry),
) !ListResult {
    rows.clearRetainingCapacity();
    scratch.clearRetainingCapacity();
    var result = ListResult{ .selected_element_id = selected_element_id };
    const root_count = @min(initial_roots_length, roots.len);

    for (roots[0..root_count], 0..) |root, root_index| {
        if (root_index > 0) {
            try rows.append(allocator, .{
                .kind = .root_separator,
                .row_index = result.row_count,
                .root_index = root_index,
                .depth = 0,
            });
            result.row_count += 1;
        }

        try scratch.append(allocator, .{ .element_index = root.element_index, .depth = 0 });
        while (scratch.items.len > 0) {
            const entry = scratch.items[scratch.items.len - 1];
            scratch.items.len -= 1;
            const node = nodes[entry.element_index];
            if (node.exiting) continue;

            if (highlighted_row == result.row_count) {
                if (pointer_state == .pressed_this_frame) result.selected_element_id = node.element_id.id;
                result.highlighted_element_id = node.element_id.id;
            }
            if (result.selected_element_id == node.element_id.id) {
                result.selected_element_row_index = result.row_count;
            }

            try rows.append(allocator, .{
                .kind = .element,
                .row_index = result.row_count,
                .root_index = root_index,
                .depth = entry.depth,
                .element_index = entry.element_index,
                .element_id = node.element_id.id,
            });
            result.row_count += 1;

            if (node.is_text) {
                try rows.append(allocator, .{
                    .kind = .text_contents,
                    .row_index = result.row_count,
                    .root_index = root_index,
                    .depth = entry.depth + 1,
                    .element_index = entry.element_index,
                    .element_id = node.element_id.id,
                });
                result.row_count += 1;
                continue;
            }
            if (collapsed.contains(node.element_id.id)) continue;

            const children = node.children(child_indices);
            var child_offset = children.len;
            while (child_offset > 0) {
                child_offset -= 1;
                try scratch.append(allocator, .{
                    .element_index = children[child_offset],
                    .depth = entry.depth + 1,
                });
            }
        }
    }
    return result;
}

pub fn collapseButtonBaseId() u32 {
    return hashes.string(types.String.literal("Clay__DebugView_CollapseElement"), 0).base_id;
}

pub fn closeButtonLookupId() u32 {
    return hashes.string(types.String.literal("Clay__DebugViewTopHeaderCloseButtonOuter"), 0).id;
}

/// Decode the last collapse button under the pointer. Indexed collapse IDs
/// carry the inspected element's ID in `offset`.
pub fn collapseTarget(pointer_state: types.PointerDataInteractionState, pointer_over_ids: []const types.ElementId) ?u32 {
    if (pointer_state != .pressed_this_frame) return null;
    const base_id = collapseButtonBaseId();
    var index = pointer_over_ids.len;
    while (index > 0) {
        index -= 1;
        const element_id = pointer_over_ids[index];
        if (element_id.base_id == base_id) return element_id.offset;
    }
    return null;
}

pub fn closeRequested(pointer_state: types.PointerDataInteractionState, pointer_over_ids: []const types.ElementId) bool {
    if (pointer_state != .pressed_this_frame) return false;
    const close_id = closeButtonLookupId();
    for (pointer_over_ids) |element_id| if (element_id.id == close_id) return true;
    return false;
}

pub fn sizingTypeName(sizing_type: types.SizingType) []const u8 {
    return switch (sizing_type) {
        .grow => "GROW",
        .fit => "FIT",
        .percent => "PERCENT",
        .fixed => "FIXED",
    };
}

pub fn layoutDirectionName(direction: types.LayoutDirection) []const u8 {
    return if (direction == .top_to_bottom) "TOP_TO_BOTTOM" else "LEFT_TO_RIGHT";
}

pub fn alignmentXName(alignment: types.LayoutAlignmentX) []const u8 {
    return switch (alignment) {
        .left => "LEFT",
        .center => "CENTER",
        .right => "RIGHT",
    };
}

pub fn alignmentYName(alignment: types.LayoutAlignmentY) []const u8 {
    return switch (alignment) {
        .top => "TOP",
        .center => "CENTER",
        .bottom => "BOTTOM",
    };
}

pub fn wrapModeName(mode: types.TextElementConfigWrapMode) []const u8 {
    return switch (mode) {
        .words => "WORDS",
        .none => "NONE",
        .newlines => "NEWLINES",
    };
}

pub fn textAlignmentName(alignment: types.TextAlignment) []const u8 {
    return switch (alignment) {
        .left => "LEFT",
        .center => "CENTER",
        .right => "RIGHT",
    };
}

pub fn attachPointName(point: types.FloatingAttachPointType) []const u8 {
    return switch (point) {
        .left_top => "LEFT_TOP",
        .left_center => "LEFT_CENTER",
        .left_bottom => "LEFT_BOTTOM",
        .center_top => "CENTER_TOP",
        .center_center => "CENTER_CENTER",
        .center_bottom => "CENTER_BOTTOM",
        .right_top => "RIGHT_TOP",
        .right_center => "RIGHT_CENTER",
        .right_bottom => "RIGHT_BOTTOM",
    };
}

/// The pinned inspector calls capture mode "NONE" rather than "CAPTURE".
pub fn pointerCaptureModeName(mode: types.PointerCaptureMode) []const u8 {
    return if (mode == .passthrough) "PASSTHROUGH" else "NONE";
}

pub fn attachToName(attach_to: types.FloatingAttachToElement) []const u8 {
    return switch (attach_to) {
        .none => "NONE",
        .parent => "PARENT",
        .element_with_id => "ELEMENT_WITH_ID",
        .root => "ROOT",
    };
}

pub fn clipToName(clip_to: types.FloatingClipToElement) []const u8 {
    return if (clip_to == .none) "NONE" else "ATTACHED_PARENT";
}

test "debug constants and config labels match the pinned inspector" {
    try std.testing.expectEqual(@as(u32, 400), default_view_width);
    try std.testing.expectEqual(@as(i32, 30), row_height);
    try std.testing.expectEqualStrings("Background", configLabel(.background_color).label.asSlice());
    try std.testing.expectEqual(types.Color{ .r = 105, .g = 210, .b = 231, .a = 255 }, configLabel(.text).color);
    try std.testing.expectEqualStrings("Scroll", configLabel(.clip).label.asSlice());
}

test "element badges preserve pinned declaration order and bitwise radius detection" {
    var image_marker: u8 = 0;
    var custom_marker: u8 = 0;
    const node = layout.Node{ .config = .{
        .background_color = .{ .a = 1 },
        .overlay_color = .{ .a = 1 },
        .corner_radius = .{ .top_left = 1 },
        .aspect_ratio = .{ .aspect_ratio = 1 },
        .image = .{ .image_data = &image_marker },
        .floating = .{ .attach_to = .root },
        .clip = .{ .vertical = true },
        .border = .{ .width = .{ .left = 1 } },
        .custom = .{ .custom_data = &custom_marker },
    } };
    var badges: [10]ConfigType = undefined;
    try std.testing.expectEqualSlices(ConfigType, &.{
        .background_color,
        .overlay_color,
        .corner_radius,
        .aspect,
        .image,
        .floating,
        .clip,
        .border,
        .custom,
    }, elementConfigTypes(node, &badges));

    var negative_zero = layout.Node{};
    negative_zero.config.corner_radius.top_left = -0.0;
    try std.testing.expectEqualSlices(ConfigType, &.{.corner_radius}, elementConfigTypes(negative_zero, &badges));

    const text_node = layout.Node{ .is_text = true, .config = node.config };
    try std.testing.expectEqualSlices(ConfigType, &.{.text}, elementConfigTypes(text_node, &badges));
}

test "highlighted row follows internal and external scroll formulas" {
    const base = HighlightInput{
        .pointer = .{ .x = 650, .y = 65 },
        .layout_dimensions = .{ .width = 1000, .height = 600 },
        .scroll_position = .{ .y = -30 },
    };
    try std.testing.expectEqual(@as(i32, 2), highlightedRow(base));

    var external = base;
    external.external_scroll_handling_enabled = true;
    try std.testing.expectEqual(@as(i32, 1), highlightedRow(external));

    var outside_x = base;
    outside_x.pointer.x = 599;
    try std.testing.expectEqual(@as(i32, -1), highlightedRow(outside_x));

    var details = base;
    details.pointer.y = 300;
    try std.testing.expectEqual(@as(i32, -1), highlightedRow(details));
}

test "highlighted row rejects non-finite and out-of-range coordinates" {
    const base = HighlightInput{
        .pointer = .{ .x = 900, .y = -1.0e20 },
        .layout_dimensions = .{ .width = 1000, .height = 600 },
    };
    try std.testing.expectEqual(@as(i32, -1), highlightedRow(base));

    var non_finite = base;
    non_finite.pointer.y = std.math.nan(f32);
    try std.testing.expectEqual(@as(i32, -1), highlightedRow(non_finite));

    non_finite.pointer = .{ .x = 900, .y = 60 };
    non_finite.scroll_position = .{ .y = std.math.inf(f32) };
    try std.testing.expectEqual(@as(i32, -1), highlightedRow(non_finite));

    non_finite.scroll_position = null;
    non_finite.details_pane_height = std.math.nan(f32);
    try std.testing.expectEqual(@as(i32, -1), highlightedRow(non_finite));
}

test "row colors apply selection before hover brightening" {
    try std.testing.expectEqual(color_2, rowColor(0, 4, -1));
    try std.testing.expectEqual(color_1, rowColor(1, 4, -1));
    try std.testing.expectEqual(selected_row_color, rowColor(4, 4, -1));
    try std.testing.expectEqual(types.Color{ .r = 127.5, .g = 100, .b = 97.5, .a = 255 }, rowColor(4, 4, 4));
}

const TestCollapseSet = struct {
    ids: []const u32,

    fn lookup(raw_context: ?*const anyopaque, element_id: u32) bool {
        const self: *const TestCollapseSet = @ptrCast(@alignCast(raw_context.?));
        return std.mem.indexOfScalar(u32, self.ids, element_id) != null;
    }
};

test "logical rows are preorder with text rows and root separators" {
    const ids = [_]types.ElementId{
        hashes.number(0, 0),
        hashes.number(1, 0),
        hashes.number(2, 0),
        hashes.number(3, 0),
    };
    const nodes = [_]layout.Node{
        .{ .element_id = ids[0], .children_start = 0, .children_len = 2 },
        .{ .element_id = ids[1], .parent_index = 0 },
        .{ .element_id = ids[2], .parent_index = 0, .is_text = true },
        .{ .element_id = ids[3] },
    };
    const children = [_]usize{ 1, 2 };
    const roots = [_]layout.Root{ .{ .element_index = 0 }, .{ .element_index = 3 } };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(std.testing.allocator);
    var scratch: std.ArrayList(TraversalEntry) = .empty;
    defer scratch.deinit(std.testing.allocator);

    const result = try collectRows(
        std.testing.allocator,
        &nodes,
        &children,
        &roots,
        roots.len,
        .{},
        ids[2].id,
        1,
        .pressed_this_frame,
        &rows,
        &scratch,
    );
    try std.testing.expectEqual(@as(i32, 6), result.row_count);
    try std.testing.expectEqualSlices(RowKind, &.{ .element, .element, .element, .text_contents, .root_separator, .element }, &.{
        rows.items[0].kind,
        rows.items[1].kind,
        rows.items[2].kind,
        rows.items[3].kind,
        rows.items[4].kind,
        rows.items[5].kind,
    });
    try std.testing.expectEqual(ids[1].id, result.highlighted_element_id);
    try std.testing.expectEqual(ids[1].id, result.selected_element_id);
    try std.testing.expectEqual(@as(i32, 1), result.selected_element_row_index);
}

test "collapsed nodes suppress descendants and exiting roots still leave separators" {
    const root_id = hashes.number(10, 0);
    const child_id = hashes.number(11, 0);
    const exiting_id = hashes.number(12, 0);
    const nodes = [_]layout.Node{
        .{ .element_id = root_id, .children_start = 0, .children_len = 1 },
        .{ .element_id = child_id, .parent_index = 0 },
        .{ .element_id = exiting_id, .exiting = true },
    };
    const children = [_]usize{1};
    const roots = [_]layout.Root{ .{ .element_index = 0 }, .{ .element_index = 2 } };
    const collapsed_set = TestCollapseSet{ .ids = &.{root_id.id} };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(std.testing.allocator);
    var scratch: std.ArrayList(TraversalEntry) = .empty;
    defer scratch.deinit(std.testing.allocator);

    const result = try collectRows(
        std.testing.allocator,
        &nodes,
        &children,
        &roots,
        roots.len,
        .{ .context = &collapsed_set, .function = TestCollapseSet.lookup },
        0,
        -1,
        .released,
        &rows,
        &scratch,
    );
    try std.testing.expectEqual(@as(i32, 2), result.row_count);
    try std.testing.expectEqual(RowKind.element, rows.items[0].kind);
    try std.testing.expectEqual(RowKind.root_separator, rows.items[1].kind);
}

test "collapse interaction chooses the last indexed button under the pointer" {
    const first = hashes.stringWithOffset(types.String.literal("Clay__DebugView_CollapseElement"), 101, 0);
    const second = hashes.stringWithOffset(types.String.literal("Clay__DebugView_CollapseElement"), 202, 0);
    try std.testing.expectEqual(@as(?u32, 202), collapseTarget(.pressed_this_frame, &.{ first, second }));
    try std.testing.expectEqual(@as(?u32, null), collapseTarget(.pressed, &.{ first, second }));
}

test "raw text preview truncates at forty bytes" {
    const short = rawTextPreview(types.String.fromSlice("hello"));
    try std.testing.expectEqualStrings("hello", short.text);
    try std.testing.expect(!short.truncated);

    const long = rawTextPreview(types.String.fromSlice("0123456789012345678901234567890123456789extra"));
    try std.testing.expectEqual(@as(usize, 40), long.text.len);
    try std.testing.expect(long.truncated);
}

test "configuration pane enum names preserve pinned spellings" {
    try std.testing.expectEqualStrings("GROW", sizingTypeName(.grow));
    try std.testing.expectEqualStrings("TOP_TO_BOTTOM", layoutDirectionName(.top_to_bottom));
    try std.testing.expectEqualStrings("RIGHT", alignmentXName(.right));
    try std.testing.expectEqualStrings("BOTTOM", alignmentYName(.bottom));
    try std.testing.expectEqualStrings("NEWLINES", wrapModeName(.newlines));
    try std.testing.expectEqualStrings("CENTER", textAlignmentName(.center));
    try std.testing.expectEqualStrings("RIGHT_BOTTOM", attachPointName(.right_bottom));
    try std.testing.expectEqualStrings("NONE", pointerCaptureModeName(.capture));
    try std.testing.expectEqualStrings("PASSTHROUGH", pointerCaptureModeName(.passthrough));
    try std.testing.expectEqualStrings("ELEMENT_WITH_ID", attachToName(.element_with_id));
    try std.testing.expectEqualStrings("ATTACHED_PARENT", clipToName(.attached_parent));
}

test "debug dimensions stay usable in viewports smaller than the inspector defaults" {
    try std.testing.expectEqual(@as(f32, 600), contentWidth(1000, true, 400));
    try std.testing.expectEqual(@as(f32, 0), contentWidth(300, true, 400));
    try std.testing.expectEqual(@as(f32, 300), effectiveViewWidth(300, 400));
    try std.testing.expectEqual(@as(f32, 118), effectiveDetailsHeight(180));
    try std.testing.expectEqual(@as(f32, 0), effectiveDetailsHeight(40));
    try std.testing.expect(!isOffscreen(.{ .x = 100, .y = 100 }, .{ .width = 100, .height = 100 }, true));
    try std.testing.expect(isOffscreen(.{ .x = 100.01, .y = 0 }, .{ .width = 100, .height = 100 }, true));
    try std.testing.expect(!isOffscreen(.{ .x = 101, .y = 0 }, .{ .width = 100, .height = 100 }, false));
}
