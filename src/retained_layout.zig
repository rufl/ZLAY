//! Small retained layout tree for renderer-agnostic UI foundations.
//!
//! This module intentionally implements only a bounded flex and grid subset:
//! row and column containers, explicit fixed/fractional grid tracks,
//! `display: none`, absolute children, auto/length/percentage/stretch
//! dimensions, and finite pixel padding/margins. There is no text-specific
//! measurement, wrapping, block layout, or CSS parser. An optional caller-
//! supplied intrinsic measurement callback can provide finite dimensions for
//! auto-sized leaf nodes.
//! Layout is computed synchronously into caller-owned tree storage; no scratch
//! allocation is needed by compute.

const std = @import("std");
pub const Error = error{
    OutOfMemory,
    NodeCapacityExceeded,
    ChildCapacityExceeded,
    GridTrackCapacityExceeded,
    StaleNodeId,
    ChildAlreadyAttached,
    ChildNotFound,
    InvalidStyle,
    InvalidDimensions,
};

pub const NodeId = struct {
    index: u32,
    generation: u32,

    pub const invalid: NodeId = .{ .index = std.math.maxInt(u32), .generation = 0 };
};

pub const Display = enum { flex, grid, none, overlay };
pub const Position = enum { relative, absolute };
pub const FlexDirection = enum { row, column };
pub const FlexWrap = enum { nowrap, wrap };
pub const AlignItems = enum { stretch, flex_start, flex_end, center };
pub const AlignSelf = enum { auto, stretch, flex_start, flex_end, center };
/// A nine-position anchor used by overlay children.
pub const Alignment = enum {
    top_left,
    top_center,
    top_right,
    left,
    center,
    right,
    bottom_left,
    bottom_center,
    bottom_right,
};
pub const JustifyContent = enum { flex_start, flex_end, center, space_between, space_around, space_evenly };
pub const Overflow = enum { visible, clip };

/// Horizontal and vertical fractions for an overlay anchor.
fn alignmentFractions(alignment: Alignment) struct { x: f32, y: f32 } {
    return switch (alignment) {
        .top_left => .{ .x = 0, .y = 0 },
        .top_center => .{ .x = 0.5, .y = 0 },
        .top_right => .{ .x = 1, .y = 0 },
        .left => .{ .x = 0, .y = 0.5 },
        .center => .{ .x = 0.5, .y = 0.5 },
        .right => .{ .x = 1, .y = 0.5 },
        .bottom_left => .{ .x = 0, .y = 1 },
        .bottom_center => .{ .x = 0.5, .y = 1 },
        .bottom_right => .{ .x = 1, .y = 1 },
    };
}

/// A renderer-neutral visible region for a laid out node and its descendants.
/// A null clip means no ancestor or node requested clipping.
pub const ClipRect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

fn aspectRatioDimension(width: f32, height: f32, ratio: f32, width_auto: bool, height_auto: bool) Dimensions {
    if (width_auto and !height_auto) {
        const resolved_width = height * ratio;
        return .{ .width = if (finite(resolved_width)) resolved_width else std.math.floatMax(f32), .height = height };
    }
    if (height_auto and !width_auto) {
        const resolved_height = width / ratio;
        return .{ .width = width, .height = if (finite(resolved_height)) resolved_height else std.math.floatMax(f32) };
    }
    return .{ .width = width, .height = height };
}

/// One explicit grid track. `fixed` is pixels; `fr` receives a share of the
/// space left after fixed tracks and gaps.
pub const GridTrack = union(enum) {
    fixed: f32,
    fr: f32,

    pub fn fixedPx(value: f32) GridTrack {
        return .{ .fixed = value };
    }

    pub fn fractional(value: f32) GridTrack {
        return .{ .fr = value };
    }
};
pub const Dimension = union(enum) {
    auto,
    length: f32,
    percent: f32,
    /// A positive weight receiving a share of the parent's remaining space.
    stretch: f32,

    pub fn lengthPx(value: f32) Dimension {
        return .{ .length = value };
    }

    pub fn percentOfParent(value: f32) Dimension {
        return .{ .percent = value };
    }

    pub fn stretchFactor(value: f32) Dimension {
        return .{ .stretch = value };
    }
};
/// Four-sided spacing around a node. Values are finite, non-negative pixels.
pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(value: f32) Edges {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
};

pub const Style = struct {
    display: Display = .flex,
    position: Position = .relative,
    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    align_items: AlignItems = .flex_start,
    align_self: AlignSelf = .auto,
    /// Anchor used when this node is a relative child of an overlay parent.
    alignment: Alignment = .top_left,
    justify_content: JustifyContent = .flex_start,
    width: Dimension = .auto,
    height: Dimension = .auto,
    min_width: Dimension = .{ .length = 0 },
    max_width: Dimension = .auto,
    min_height: Dimension = .{ .length = 0 },
    max_height: Dimension = .auto,
    left: Dimension = .auto,
    right: Dimension = .auto,
    top: Dimension = .auto,
    bottom: Dimension = .auto,
    padding: Edges = .{},
    margin: Edges = .{},
    flex_grow: f32 = 0,
    /// Zero preserves the original no-shrink behavior; set nonzero for flex shrinking.
    flex_shrink: f32 = 0,
    flex_basis: Dimension = .auto,
    aspect_ratio: ?f32 = null,
    overflow: Overflow = .visible,
    grid_columns: []const GridTrack = &.{},
    grid_rows: []const GridTrack = &.{},
    grid_column_gap: f32 = 0,
    grid_row_gap: f32 = 0,
    grid_gap: f32 = 0,
    /// Minimum spacing between flex items and between wrapped lines.
    flex_gap: f32 = 0,
    /// One-based explicit placement. Zero means auto-placement.
    grid_column: usize = 0,
    grid_row: usize = 0,
    /// Number of explicit or automatically placed tracks occupied by a child.
    grid_column_span: usize = 1,
    grid_row_span: usize = 1,
};

pub const Dimensions = struct {
    width: f32 = 0,
    height: f32 = 0,
};

/// Supplies intrinsic dimensions for an auto-sized leaf. `available` is the
/// containing block's size at the leaf's layout position.
pub const IntrinsicMeasureFunction = *const fn (NodeId, Dimensions, ?*anyopaque) Dimensions;

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Layout = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    clip: ?ClipRect = null,
};

pub const Options = struct {
    max_nodes: usize = 256,
    max_children_per_node: usize = 64,
    max_grid_tracks: usize = 16,
};
const GridPlacement = struct {
    column: usize,
    row: usize,
    column_span: usize,
    row_span: usize,
};

const Node = struct {
    style: Style,
    parent: ?NodeId = null,
    children: std.ArrayList(NodeId) = .empty,
    layout: Layout = .{},
    grid_placement: ?GridPlacement = null,
    intrinsic_measurement: ?Dimensions = null,
    flex_base: f32 = 0,
    flex_size: f32 = 0,
    flex_frozen: bool = false,
    dirty: bool = true,
};

const Slot = struct {
    generation: u32 = 1,
    node: ?Node = null,
};

pub const LayoutTree = struct {
    allocator: std.mem.Allocator,
    options: Options,
    slots: std.ArrayList(Slot) = .empty,
    live_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) LayoutTree {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *LayoutTree) void {
        for (self.slots.items) |*slot_entry| {
            if (slot_entry.node) |*node_entry| node_entry.children.deinit(self.allocator);
        }
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *LayoutTree, style_value: Style) Error!NodeId {
        try validateStyle(style_value);
        try validateGridCapacity(style_value, self.options);
        var slot_index: usize = 0;
        while (slot_index < self.slots.items.len) : (slot_index += 1) {
            if (self.slots.items[slot_index].node == null) break;
        }
        if (slot_index == self.slots.items.len) {
            if (self.slots.items.len >= self.options.max_nodes) return error.NodeCapacityExceeded;
            self.slots.append(self.allocator, .{}) catch return error.OutOfMemory;
        }
        const slot_entry = &self.slots.items[slot_index];
        slot_entry.node = .{ .style = style_value };
        self.live_count += 1;
        return .{ .index = @intCast(slot_index), .generation = slot_entry.generation };
    }

    pub fn destroy(self: *LayoutTree, id: NodeId) Error!void {
        _ = try self.nodeAt(id);
        try self.destroyInternal(id);
    }

    pub fn style(self: *const LayoutTree, id: NodeId) Error!Style {
        return (try self.nodeConstAt(id)).style;
    }

    pub fn setStyle(self: *LayoutTree, id: NodeId, new_style: Style) Error!void {
        try validateStyle(new_style);
        try validateGridCapacity(new_style, self.options);
        const node_ref = try self.nodeAt(id);
        node_ref.style = new_style;
        self.markDirty(id);
    }

    pub fn parent(self: *const LayoutTree, id: NodeId) Error!?NodeId {
        return (try self.nodeConstAt(id)).parent;
    }

    pub fn childCount(self: *const LayoutTree, id: NodeId) Error!usize {
        return (try self.nodeConstAt(id)).children.items.len;
    }

    pub fn childAt(self: *const LayoutTree, id: NodeId, index: usize) Error!NodeId {
        const children = (try self.nodeConstAt(id)).children.items;
        if (index >= children.len) return error.ChildNotFound;
        return children[index];
    }

    pub fn appendChild(self: *LayoutTree, parent_id: NodeId, child_id: NodeId) Error!void {
        if (parent_id.index == child_id.index and parent_id.generation == child_id.generation) {
            return error.ChildAlreadyAttached;
        }
        const parent_node = try self.nodeAt(parent_id);
        const child_node = try self.nodeAt(child_id);
        if (child_node.parent != null) return error.ChildAlreadyAttached;
        if (parent_node.children.items.len >= self.options.max_children_per_node) {
            return error.ChildCapacityExceeded;
        }

        // A detached child may still contain descendants; reject attaching it
        // below one of those descendants, which would create a cycle.
        var ancestor: ?NodeId = parent_id;
        while (ancestor) |current| {
            if (current.index == child_id.index and current.generation == child_id.generation) {
                return error.ChildAlreadyAttached;
            }
            ancestor = (try self.nodeConstAt(current)).parent;
        }

        parent_node.children.ensureTotalCapacity(self.allocator, parent_node.children.items.len + 1) catch {
            return error.OutOfMemory;
        };
        parent_node.children.appendAssumeCapacity(child_id);
        child_node.parent = parent_id;
        self.markDirty(parent_id);
    }

    pub fn removeChild(self: *LayoutTree, parent_id: NodeId, child_id: NodeId) Error!void {
        const parent_node = try self.nodeAt(parent_id);
        const child_node = try self.nodeAt(child_id);
        var index: ?usize = null;
        for (parent_node.children.items, 0..) |candidate, candidate_index| {
            if (sameId(candidate, child_id)) {
                index = candidate_index;
                break;
            }
        }
        _ = parent_node.children.orderedRemove(index orelse return error.ChildNotFound);
        child_node.parent = null;
        self.markDirty(parent_id);
    }

    pub fn isDirty(self: *const LayoutTree, id: NodeId) Error!bool {
        return (try self.nodeConstAt(id)).dirty;
    }

    pub fn markDirty(self: *LayoutTree, id: NodeId) void {
        var current: ?NodeId = id;
        while (current) |node_id| {
            const node_ref = self.nodeAt(node_id) catch return;
            node_ref.dirty = true;
            current = node_ref.parent;
        }
    }

    pub fn compute(self: *LayoutTree, root_id: NodeId, available: Dimensions) Error!void {
        try validateDimensions(available);
        _ = try self.nodeAt(root_id);
        self.computeNode(root_id, .{}, available, null, true, null, null, null) catch |err| return err;
    }

    /// Compute layout using caller-supplied intrinsic dimensions for leaf nodes
    /// whose width or height is `auto`. Results must contain finite,
    /// non-negative dimensions.
    pub fn computeWithMeasure(
        self: *LayoutTree,
        root_id: NodeId,
        available: Dimensions,
        measure: IntrinsicMeasureFunction,
        user_data: ?*anyopaque,
    ) Error!void {
        try validateDimensions(available);
        _ = try self.nodeAt(root_id);
        self.computeNode(root_id, .{}, available, null, true, null, measure, user_data) catch |err| return err;
    }

    pub fn readLayout(self: *const LayoutTree, id: NodeId) Error!Layout {
        return (try self.nodeConstAt(id)).layout;
    }

    /// Returns the renderer-neutral clip region effective for this node.
    pub fn readClip(self: *const LayoutTree, id: NodeId) Error!?ClipRect {
        return (try self.nodeConstAt(id)).layout.clip;
    }

    pub fn getLayout(self: *const LayoutTree, id: NodeId) Error!Layout {
        return self.readLayout(id);
    }

    fn destroyInternal(self: *LayoutTree, id: NodeId) Error!void {
        const parent_id = (try self.nodeConstAt(id)).parent;
        if (parent_id) |parent_id_value| {
            const parent_node = try self.nodeAt(parent_id_value);
            var index: ?usize = null;
            for (parent_node.children.items, 0..) |candidate, candidate_index| {
                if (sameId(candidate, id)) {
                    index = candidate_index;
                    break;
                }
            }
            _ = parent_node.children.orderedRemove(index orelse return error.ChildNotFound);
            self.markDirty(parent_id_value);
        }

        while (true) {
            const child = blk: {
                const node_ref = try self.nodeConstAt(id);
                if (node_ref.children.items.len == 0) break :blk null;
                break :blk node_ref.children.items[node_ref.children.items.len - 1];
            };
            if (child) |child_id| {
                try self.destroyInternal(child_id);
            } else break;
        }

        const slot_ref = try self.slotAt(id);
        if (slot_ref.node) |*node_entry| node_entry.children.deinit(self.allocator);
        slot_ref.node = null;
        slot_ref.generation = if (slot_ref.generation == std.math.maxInt(u32)) 1 else slot_ref.generation + 1;
        self.live_count -= 1;
    }

    fn computeNode(
        self: *LayoutTree,
        id: NodeId,
        origin: Point,
        containing: Dimensions,
        forced_size: ?Dimensions,
        is_root: bool,
        inherited_clip: ?ClipRect,
        measure: ?IntrinsicMeasureFunction,
        measure_user_data: ?*anyopaque,
    ) Error!void {
        const node_ref = try self.nodeAt(id);
        const style_value = node_ref.style;
        if (style_value.display == .none) {
            try self.hideNode(id);
            return;
        }

        const children = node_ref.children.items;
        const supplied_measurement = node_ref.intrinsic_measurement;
        node_ref.intrinsic_measurement = null;
        var intrinsic_measurement = supplied_measurement;
        if (intrinsic_measurement == null and measure != null and children.len == 0 and
            (style_value.width == .auto or style_value.height == .auto))
        {
            const measured = measure.?(id, containing, measure_user_data);
            try validateDimensions(measured);
            intrinsic_measurement = measured;
        }

        var size: Dimensions = forced_size orelse .{
            .width = resolveDimension(style_value.width, containing.width, if (is_root) containing.width else 0),
            .height = resolveDimension(style_value.height, containing.height, if (is_root) containing.height else 0),
        };
        if (style_value.aspect_ratio) |ratio| {
            size = aspectRatioDimension(
                size.width,
                size.height,
                ratio,
                style_value.width == .auto,
                style_value.height == .auto,
            );
        }
        if (forced_size == null) {
            if (intrinsic_measurement) |measured| {
                if (style_value.width == .auto) size.width = measured.width;
                if (style_value.height == .auto) size.height = measured.height;
            }
        }
        size.width = clampDimension(size.width, style_value.min_width, style_value.max_width, containing.width);
        size.height = clampDimension(size.height, style_value.min_height, style_value.max_height, containing.height);

        const effective_clip = clipForNode(style_value.overflow, inherited_clip, origin, size);
        node_ref.layout = .{
            .x = origin.x,
            .y = origin.y,
            .width = size.width,
            .height = size.height,
            .clip = effective_clip,
        };
        node_ref.dirty = false;
        if (children.len == 0) return;

        const content_origin = Point{
            .x = boundedAdd(origin.x, style_value.padding.left),
            .y = boundedAdd(origin.y, style_value.padding.top),
        };
        const content_size = Dimensions{
            .width = @max(size.width - horizontalEdges(style_value.padding), 0),
            .height = @max(size.height - verticalEdges(style_value.padding), 0),
        };

        if (style_value.display == .grid) {
            try self.computeGrid(id, content_origin, content_size, effective_clip, measure, measure_user_data);
            return;
        }
        if (style_value.display == .overlay) {
            try self.computeOverlay(id, content_origin, content_size, effective_clip, measure, measure_user_data);
            return;
        }

        const available_main = if (style_value.flex_direction == .row) content_size.width else content_size.height;
        for (children) |child_id| {
            const child_node = try self.nodeAt(child_id);
            const child_style = child_node.style;
            child_node.flex_frozen = child_style.display == .none or child_style.position == .absolute;
            child_node.intrinsic_measurement = null;
            if (!child_node.flex_frozen and measure != null and child_node.children.items.len == 0 and
                (child_style.width == .auto or child_style.height == .auto))
            {
                const measured = measure.?(child_id, content_size, measure_user_data);
                try validateDimensions(measured);
                child_node.intrinsic_measurement = measured;
            }
            if (child_node.flex_frozen) continue;
            child_node.flex_base = boundedAdd(
                flexBaseDimension(
                    child_style,
                    style_value.flex_direction,
                    available_main,
                    if (style_value.flex_direction == .row) content_size.height else content_size.width,
                    child_node.intrinsic_measurement,
                ),
                marginAlongAxis(child_style.margin, style_value.flex_direction),
            );
            child_node.flex_size = child_node.flex_base;
        }
        if (style_value.flex_wrap == .wrap) {
            try self.computeFlexWrap(
                id,
                content_origin,
                content_size,
                effective_clip,
                measure,
                measure_user_data,
            );
            return;
        }
        var flow_children: usize = 0;
        for (children) |child_id| {
            const child_style = (try self.nodeConstAt(child_id)).style;
            if (child_style.display != .none and child_style.position != .absolute) flow_children += 1;
        }
        const flex_gap_total = if (flow_children > 1)
            style_value.flex_gap * @as(f32, @floatFromInt(flow_children - 1))
        else
            0;

        var iterations: usize = 0;
        while (iterations <= children.len) : (iterations += 1) {
            var frozen_sum: f32 = 0;
            var unfrozen_base: f32 = 0;
            for (children) |child_id| {
                const child_node = try self.nodeAt(child_id);
                if (child_node.flex_frozen) {
                    frozen_sum += child_node.flex_size;
                } else {
                    unfrozen_base += child_node.flex_base;
                }
            }
            const free = available_main - flex_gap_total - frozen_sum - unfrozen_base;
            var total_factor: f32 = 0;
            for (children) |child_id| {
                const child_node = try self.nodeAt(child_id);
                if (child_node.flex_frozen) continue;
                total_factor += flexMainFactor(child_node.style, style_value.flex_direction, free, child_node.flex_base);
            }
            if (total_factor == 0) {
                for (children) |child_id| {
                    const child_node = try self.nodeAt(child_id);
                    if (!child_node.flex_frozen) {
                        child_node.flex_size = clampFlexMain(child_node.flex_base, child_node.style, style_value.flex_direction, available_main);
                        child_node.flex_frozen = true;
                    }
                }
                break;
            }

            var froze_any = false;
            for (children) |child_id| {
                const child_node = try self.nodeAt(child_id);
                if (child_node.flex_frozen) continue;
                const factor = flexMainFactor(child_node.style, style_value.flex_direction, free, child_node.flex_base);
                const raw = child_node.flex_base + weightedShare(free, factor, total_factor);
                child_node.flex_size = clampFlexMain(raw, child_node.style, style_value.flex_direction, available_main);
                if (child_node.flex_size != raw) {
                    child_node.flex_frozen = true;
                    froze_any = true;
                }
            }
            if (!froze_any) {
                for (children) |child_id| {
                    const child_node = try self.nodeAt(child_id);
                    if (!child_node.flex_frozen) {
                        const factor = flexMainFactor(child_node.style, style_value.flex_direction, free, child_node.flex_base);
                        child_node.flex_size = child_node.flex_base + weightedShare(free, factor, total_factor);
                        child_node.flex_frozen = true;
                    }
                }
                break;
            }
        }

        var flow_count: usize = 0;
        var occupied_main: f32 = 0;
        for (children) |child_id| {
            const child_style = (try self.nodeConstAt(child_id)).style;
            if (child_style.display == .none or child_style.position == .absolute) continue;
            flow_count += 1;
            occupied_main = boundedAdd(occupied_main, (try self.nodeConstAt(child_id)).flex_size);
        }
        const free_space = @max(boundedSubtract(available_main, boundedAdd(occupied_main, flex_gap_total)), 0);
        const justify_leading = justifyLeading(style_value.justify_content, free_space, flow_count);
        const justify_gap = boundedAdd(style_value.flex_gap, justifyGap(style_value.justify_content, free_space, flow_count));

        var cursor: f32 = justify_leading;
        for (children) |child_id| {
            const child_style = try self.style(child_id);
            if (child_style.display == .none) {
                try self.hideNode(child_id);
                continue;
            }
            if (child_style.position == .absolute) {
                try self.computeAbsolute(child_id, child_style, content_size, content_origin, effective_clip, measure, measure_user_data);
                continue;
            }

            const child_node = try self.nodeConstAt(child_id);
            const child_measurement = child_node.intrinsic_measurement;
            const main_margin = marginAlongAxis(child_style.margin, style_value.flex_direction);
            const cross_margin = marginAcrossAxis(child_style.margin, style_value.flex_direction);
            const child_align = resolveAlign(child_style.align_self, style_value.align_items);
            const cross_available = if (style_value.flex_direction == .row) content_size.height else content_size.width;
            var child_width = resolveDimension(child_style.width, content_size.width, 0);
            var child_height = resolveDimension(child_style.height, content_size.height, 0);
            if (style_value.flex_direction == .row) {
                child_width = boundedSubtract(child_node.flex_size, main_margin);
                if (child_style.height == .auto) {
                    child_height = if (child_align == .stretch)
                        boundedSubtract(cross_available, cross_margin)
                    else if (child_measurement) |measured|
                        measured.height
                    else
                        boundedSubtract(content_size.height, cross_margin);
                }
            } else {
                child_height = boundedSubtract(child_node.flex_size, main_margin);
                if (child_style.width == .auto) {
                    child_width = if (child_align == .stretch)
                        boundedSubtract(cross_available, cross_margin)
                    else if (child_measurement) |measured|
                        measured.width
                    else
                        boundedSubtract(content_size.width, cross_margin);
                }
            }
            child_width = clampDimension(child_width, child_style.min_width, child_style.max_width, content_size.width);
            child_height = clampDimension(child_height, child_style.min_height, child_style.max_height, content_size.height);
            const cross_size = if (style_value.flex_direction == .row) child_height else child_width;
            const cross_offset = crossAxisOffset(
                child_align,
                cross_available,
                cross_size,
                child_style.margin,
                style_value.flex_direction,
            );
            const child_origin = if (style_value.flex_direction == .row)
                Point{
                    .x = boundedAdd(boundedAdd(content_origin.x, cursor), child_style.margin.left),
                    .y = boundedAdd(content_origin.y, cross_offset),
                }
            else
                Point{
                    .x = boundedAdd(content_origin.x, cross_offset),
                    .y = boundedAdd(boundedAdd(content_origin.y, cursor), child_style.margin.top),
                };
            try self.computeNode(
                child_id,
                child_origin,
                content_size,
                .{ .width = child_width, .height = child_height },
                false,
                effective_clip,
                measure,
                measure_user_data,
            );
            const child_layout = try self.readLayout(child_id);
            cursor = boundedAdd(cursor, boundedAdd(
                if (style_value.flex_direction == .row) child_layout.width else child_layout.height,
                boundedAdd(main_margin, justify_gap),
            ));
        }
    }
    fn computeFlexWrap(
        self: *LayoutTree,
        id: NodeId,
        content_origin: Point,
        content_size: Dimensions,
        inherited_clip: ?ClipRect,
        measure: ?IntrinsicMeasureFunction,
        measure_user_data: ?*anyopaque,
    ) Error!void {
        const node = try self.nodeConstAt(id);
        const style_value = node.style;
        const children = node.children.items;
        const direction = style_value.flex_direction;
        const available_main = if (direction == .row) content_size.width else content_size.height;
        const cross_parent = if (direction == .row) content_size.height else content_size.width;
        var line_start: usize = 0;
        var cross_cursor: f32 = 0;

        while (line_start < children.len) {
            const child_style = (try self.nodeConstAt(children[line_start])).style;
            if (child_style.display == .none) {
                try self.hideNode(children[line_start]);
                line_start += 1;
                continue;
            }
            if (child_style.position == .absolute) {
                try self.computeAbsolute(
                    children[line_start],
                    child_style,
                    content_size,
                    content_origin,
                    inherited_clip,
                    measure,
                    measure_user_data,
                );
                line_start += 1;
                continue;
            }

            const line_end = try self.flexLineEnd(children, line_start, available_main, style_value.flex_gap);
            try self.resolveFlexLine(children, line_start, line_end, available_main, style_value.flex_gap, direction);
            const line_cross = try self.flexLineCrossSize(
                children,
                line_start,
                line_end,
                cross_parent,
                direction,
            );
            var flow_count: usize = 0;
            var occupied_main: f32 = 0;
            for (children[line_start..line_end]) |child_id| {
                const item_style = (try self.nodeConstAt(child_id)).style;
                if (item_style.display == .none or item_style.position == .absolute) continue;
                flow_count += 1;
                occupied_main = boundedAdd(occupied_main, (try self.nodeConstAt(child_id)).flex_size);
            }
            const total_gap = if (flow_count > 1)
                style_value.flex_gap * @as(f32, @floatFromInt(flow_count - 1))
            else
                0;
            const free_space = @max(boundedSubtract(available_main, boundedAdd(occupied_main, total_gap)), 0);
            const justify_leading = justifyLeading(style_value.justify_content, free_space, flow_count);
            const justify_gap = boundedAdd(style_value.flex_gap, justifyGap(style_value.justify_content, free_space, flow_count));
            var cursor = justify_leading;
            for (children[line_start..line_end]) |child_id| {
                const item_style = try self.style(child_id);
                if (item_style.display == .none) {
                    try self.hideNode(child_id);
                    continue;
                }
                if (item_style.position == .absolute) {
                    try self.computeAbsolute(
                        child_id,
                        item_style,
                        content_size,
                        content_origin,
                        inherited_clip,
                        measure,
                        measure_user_data,
                    );
                    continue;
                }
                try self.computeFlexWrapChild(
                    child_id,
                    item_style,
                    content_origin,
                    content_size,
                    inherited_clip,
                    direction,
                    cross_cursor,
                    line_cross,
                    cursor,

                    measure,
                    measure_user_data,
                    style_value.align_items,
                );
                const child_layout = try self.readLayout(child_id);
                const main_margin = marginAlongAxis(item_style.margin, direction);
                cursor = boundedAdd(cursor, boundedAdd(
                    if (direction == .row) child_layout.width else child_layout.height,
                    boundedAdd(main_margin, justify_gap),
                ));
            }
            cross_cursor = boundedAdd(cross_cursor, boundedAdd(line_cross, style_value.flex_gap));
            line_start = line_end;
        }
    }

    fn flexLineEnd(
        self: *LayoutTree,
        children: []const NodeId,
        start: usize,
        available_main: f32,
        gap: f32,
    ) Error!usize {
        var end = start;
        var occupied: f32 = 0;
        var count: usize = 0;
        while (end < children.len) : (end += 1) {
            const item_style = (try self.nodeConstAt(children[end])).style;
            if (item_style.display == .none or item_style.position == .absolute) continue;
            const item_size = (try self.nodeConstAt(children[end])).flex_base;
            const needed = if (count == 0) item_size else boundedAdd(gap, item_size);
            if (count != 0 and boundedAdd(occupied, needed) > available_main) break;
            occupied = boundedAdd(occupied, needed);
            count += 1;
        }
        return end;
    }

    fn resolveFlexLine(
        self: *LayoutTree,
        children: []const NodeId,
        start: usize,
        end: usize,
        available_main: f32,
        gap: f32,
        direction: FlexDirection,
    ) Error!void {
        var flow_count: usize = 0;
        for (children[start..end]) |child_id| {
            const item_style = (try self.nodeConstAt(child_id)).style;
            if (item_style.display == .none or item_style.position == .absolute) continue;
            const item_node = try self.nodeAt(child_id);
            item_node.flex_frozen = false;
            item_node.flex_size = item_node.flex_base;
            flow_count += 1;
        }
        var iterations: usize = 0;
        while (iterations <= flow_count) : (iterations += 1) {
            var frozen_sum: f32 = 0;
            var unfrozen_base: f32 = 0;
            var unfrozen_count: usize = 0;
            for (children[start..end]) |child_id| {
                const item_node = try self.nodeConstAt(child_id);
                const item_style = item_node.style;
                if (item_style.display == .none or item_style.position == .absolute) continue;
                if (item_node.flex_frozen) {
                    frozen_sum = boundedAdd(frozen_sum, item_node.flex_size);
                } else {
                    unfrozen_base = boundedAdd(unfrozen_base, item_node.flex_base);
                    unfrozen_count += 1;
                }
            }
            const gap_total = if (flow_count > 1)
                gap * @as(f32, @floatFromInt(flow_count - 1))
            else
                0;
            const free = boundedSubtract(available_main, boundedAdd(boundedAdd(frozen_sum, unfrozen_base), gap_total));
            var total_factor: f32 = 0;
            for (children[start..end]) |child_id| {
                const item_node = try self.nodeConstAt(child_id);
                const item_style = item_node.style;
                if (item_style.display == .none or item_style.position == .absolute or item_node.flex_frozen) continue;
                total_factor = boundedAdd(total_factor, flexMainFactor(item_style, direction, free, item_node.flex_base));
            }
            if (unfrozen_count == 0 or total_factor == 0) {
                for (children[start..end]) |child_id| {
                    const item_node = try self.nodeAt(child_id);
                    const item_style = item_node.style;
                    if (item_style.display == .none or item_style.position == .absolute or item_node.flex_frozen) continue;
                    item_node.flex_size = clampFlexMain(item_node.flex_base, item_style, direction, available_main);
                    item_node.flex_frozen = true;
                }
                break;
            }
            var froze_any = false;
            for (children[start..end]) |child_id| {
                const item_node = try self.nodeAt(child_id);
                const item_style = item_node.style;
                if (item_style.display == .none or item_style.position == .absolute or item_node.flex_frozen) continue;
                const factor = flexMainFactor(item_style, direction, free, item_node.flex_base);
                const raw = boundedAdd(item_node.flex_base, weightedShare(free, factor, total_factor));
                item_node.flex_size = clampFlexMain(raw, item_style, direction, available_main);
                if (item_node.flex_size != raw) {
                    item_node.flex_frozen = true;
                    froze_any = true;
                }
            }
            if (!froze_any) {
                for (children[start..end]) |child_id| {
                    const item_node = try self.nodeAt(child_id);
                    const item_style = item_node.style;
                    if (item_style.display == .none or item_style.position == .absolute or item_node.flex_frozen) continue;
                    const factor = flexMainFactor(item_style, direction, free, item_node.flex_base);
                    item_node.flex_size = boundedAdd(item_node.flex_base, weightedShare(free, factor, total_factor));
                    item_node.flex_frozen = true;
                }
                break;
            }
        }
    }

    fn flexLineCrossSize(
        self: *LayoutTree,
        children: []const NodeId,
        start: usize,
        end: usize,
        cross_parent: f32,
        direction: FlexDirection,
    ) Error!f32 {
        var result: f32 = 0;
        for (children[start..end]) |child_id| {
            const item_node = try self.nodeConstAt(child_id);
            const item_style = item_node.style;
            if (item_style.display == .none or item_style.position == .absolute) continue;
            const measurement = item_node.intrinsic_measurement;
            const dimension = if (direction == .row) item_style.height else item_style.width;
            var cross_size = resolveDimension(dimension, cross_parent, 0);
            if (dimension == .auto) {
                if (measurement) |measured| {
                    cross_size = if (direction == .row) measured.height else measured.width;
                }
            }
            cross_size = clampDimension(
                cross_size,
                if (direction == .row) item_style.min_height else item_style.min_width,
                if (direction == .row) item_style.max_height else item_style.max_width,
                cross_parent,
            );
            result = @max(result, boundedAdd(cross_size, marginAcrossAxis(item_style.margin, direction)));
        }

        return result;
    }

    fn computeFlexWrapChild(
        self: *LayoutTree,
        child_id: NodeId,
        child_style: Style,
        content_origin: Point,
        content_size: Dimensions,
        inherited_clip: ?ClipRect,
        direction: FlexDirection,
        cross_cursor: f32,
        line_cross: f32,
        cursor: f32,
        measure: ?IntrinsicMeasureFunction,
        measure_user_data: ?*anyopaque,
        container_align: AlignItems,
    ) Error!void {
        const child_node = try self.nodeConstAt(child_id);
        const measurement = child_node.intrinsic_measurement;
        const main_margin = marginAlongAxis(child_style.margin, direction);
        const cross_margin = marginAcrossAxis(child_style.margin, direction);
        const child_align = resolveAlign(child_style.align_self, container_align);
        var child_width = resolveDimension(child_style.width, content_size.width, 0);
        var child_height = resolveDimension(child_style.height, content_size.height, 0);
        if (direction == .row) {
            child_width = boundedSubtract(child_node.flex_size, main_margin);
            if (child_style.height == .auto) {
                child_height = if (child_align == .stretch)
                    boundedSubtract(line_cross, cross_margin)
                else if (measurement) |measured|
                    measured.height
                else
                    boundedSubtract(line_cross, cross_margin);
            }
        } else {
            child_height = boundedSubtract(child_node.flex_size, main_margin);
            if (child_style.width == .auto) {
                child_width = if (child_align == .stretch)
                    boundedSubtract(line_cross, cross_margin)
                else if (measurement) |measured|
                    measured.width
                else
                    boundedSubtract(line_cross, cross_margin);
            }
        }
        child_width = clampDimension(child_width, child_style.min_width, child_style.max_width, content_size.width);
        child_height = clampDimension(child_height, child_style.min_height, child_style.max_height, content_size.height);
        const cross_size = if (direction == .row) child_height else child_width;
        const cross_offset = crossAxisOffset(
            child_align,
            line_cross,
            cross_size,
            child_style.margin,
            direction,
        );
        const child_origin = if (direction == .row)
            Point{
                .x = boundedAdd(boundedAdd(content_origin.x, cursor), child_style.margin.left),
                .y = boundedAdd(boundedAdd(content_origin.y, cross_cursor), cross_offset),
            }
        else
            Point{
                .x = boundedAdd(boundedAdd(content_origin.x, cross_cursor), cross_offset),
                .y = boundedAdd(boundedAdd(content_origin.y, cursor), child_style.margin.top),
            };
        try self.computeNode(
            child_id,
            child_origin,
            content_size,
            .{ .width = child_width, .height = child_height },
            false,
            inherited_clip,
            measure,
            measure_user_data,
        );
    }

    fn computeOverlay(
        self: *LayoutTree,
        id: NodeId,
        origin: Point,
        size: Dimensions,
        inherited_clip: ?ClipRect,
        measure: ?IntrinsicMeasureFunction,
        measure_user_data: ?*anyopaque,
    ) Error!void {
        const children = (try self.nodeConstAt(id)).children.items;
        for (children) |child_id| {
            const child_style = try self.style(child_id);
            if (child_style.display == .none) {
                try self.hideNode(child_id);
                continue;
            }
            if (child_style.position == .absolute) {
                // Overlay only changes relative-child placement. Keep absolute
                // offsets relative to the same padded content box as flex.
                try self.computeAbsolute(
                    child_id,
                    child_style,
                    size,
                    origin,
                    inherited_clip,
                    measure,
                    measure_user_data,
                );
                continue;
            }

            const child_node = try self.nodeAt(child_id);
            child_node.intrinsic_measurement = null;
            if (measure != null and child_node.children.items.len == 0 and
                (child_style.width == .auto or child_style.height == .auto))
            {
                const measured = measure.?(child_id, size, measure_user_data);
                try validateDimensions(measured);
                child_node.intrinsic_measurement = measured;
            }

            var child_size = Dimensions{
                .width = resolveDimension(child_style.width, size.width, 0),
                .height = resolveDimension(child_style.height, size.height, 0),
            };
            if (child_node.intrinsic_measurement) |measured| {
                if (child_style.width == .auto) child_size.width = measured.width;
                if (child_style.height == .auto) child_size.height = measured.height;
            }
            child_size.width = clampDimension(
                child_size.width,
                child_style.min_width,
                child_style.max_width,
                size.width,
            );
            child_size.height = clampDimension(
                child_size.height,
                child_style.min_height,
                child_style.max_height,
                size.height,
            );

            const fractions = alignmentFractions(child_style.alignment);
            const horizontal_margin = horizontalEdges(child_style.margin);
            const vertical_margin = verticalEdges(child_style.margin);
            const free_width = @max(
                boundedSubtract(size.width, boundedAdd(child_size.width, horizontal_margin)),
                0,
            );
            const free_height = @max(
                boundedSubtract(size.height, boundedAdd(child_size.height, vertical_margin)),
                0,
            );
            const child_origin = Point{
                .x = boundedAdd(
                    origin.x,
                    boundedAdd(child_style.margin.left, free_width * fractions.x),
                ),
                .y = boundedAdd(
                    origin.y,
                    boundedAdd(child_style.margin.top, free_height * fractions.y),
                ),
            };
            try self.computeNode(
                child_id,
                child_origin,
                size,
                child_size,
                false,
                inherited_clip,
                measure,
                measure_user_data,
            );
        }
    }

    fn computeGrid(
        self: *LayoutTree,
        id: NodeId,
        origin: Point,
        size: Dimensions,
        inherited_clip: ?ClipRect,
        measure: ?IntrinsicMeasureFunction,
        measure_user_data: ?*anyopaque,
    ) Error!void {
        const node_ref = try self.nodeAt(id);
        const style_value = node_ref.style;
        const columns = style_value.grid_columns;
        const rows = style_value.grid_rows;
        const column_gap = effectiveGap(style_value.grid_column_gap, style_value.grid_gap);
        const row_gap = effectiveGap(style_value.grid_row_gap, style_value.grid_gap);
        const children = node_ref.children.items;

        for (children) |child_id| {
            (try self.nodeAt(child_id)).grid_placement = null;
        }
        // Assign and validate explicit placements before auto-placement so an
        // automatic item cannot consume a cell reserved by a later item.
        for (children) |child_id| {
            const child_style = try self.style(child_id);
            if (child_style.display == .none or child_style.position == .absolute) continue;
            const has_column = child_style.grid_column != 0;
            const has_row = child_style.grid_row != 0;
            if (has_column != has_row) return error.InvalidStyle;
            if (has_column) {
                if (child_style.grid_column > columns.len or child_style.grid_row > rows.len) {
                    return error.InvalidStyle;
                }
                const column = child_style.grid_column - 1;
                const row = child_style.grid_row - 1;
                if (child_style.grid_column_span > columns.len - column or
                    child_style.grid_row_span > rows.len - row)
                {
                    return error.InvalidStyle;
                }
                (try self.nodeAt(child_id)).grid_placement = .{
                    .column = column,
                    .row = row,
                    .column_span = child_style.grid_column_span,
                    .row_span = child_style.grid_row_span,
                };
            }
        }
        for (children, 0..) |child_id, index| {
            const placement = (try self.nodeConstAt(child_id)).grid_placement orelse continue;
            for (children[0..index]) |previous_id| {
                const previous = (try self.nodeConstAt(previous_id)).grid_placement orelse continue;
                if (gridPlacementsOverlap(placement, previous)) return error.InvalidStyle;
            }
        }

        var auto_cursor: usize = 0;
        const cell_count = columns.len * rows.len;
        for (children) |child_id| {
            const child_style = try self.style(child_id);
            if (child_style.display == .none) {
                try self.hideNode(child_id);
                continue;
            }
            if (child_style.position == .absolute) {
                try self.computeAbsolute(child_id, child_style, size, origin, inherited_clip, measure, measure_user_data);
                continue;
            }
            const child_node = try self.nodeAt(child_id);
            child_node.intrinsic_measurement = null;
            if (measure != null and child_node.children.items.len == 0 and
                (child_style.width == .auto or child_style.height == .auto))
            {
                const measured = measure.?(child_id, size, measure_user_data);
                try validateDimensions(measured);
                child_node.intrinsic_measurement = measured;
            }
            var placement = child_node.grid_placement;
            if (placement == null) {
                while (auto_cursor < cell_count) : (auto_cursor += 1) {
                    const candidate = GridPlacement{
                        .column = auto_cursor % columns.len,
                        .row = auto_cursor / columns.len,
                        .column_span = child_style.grid_column_span,
                        .row_span = child_style.grid_row_span,
                    };
                    if (candidate.column + candidate.column_span > columns.len or
                        candidate.row + candidate.row_span > rows.len)
                    {
                        continue;
                    }
                    if (!(try self.gridRegionOccupied(children, candidate))) {
                        placement = candidate;
                        break;
                    }
                }
                if (placement == null) return error.InvalidStyle;
                (try self.nodeAt(child_id)).grid_placement = placement;
                auto_cursor += 1;
            }

            const resolved_placement = placement.?;
            var child_width = gridTrackSpanDimension(
                columns,
                resolved_placement.column,
                resolved_placement.column_span,
                size.width,
                column_gap,
            );
            var child_height = gridTrackSpanDimension(
                rows,
                resolved_placement.row,
                resolved_placement.row_span,
                size.height,
                row_gap,
            );
            if (child_node.intrinsic_measurement) |measured| {
                if (child_style.width == .auto) child_width = measured.width;
                if (child_style.height == .auto) child_height = measured.height;
            } else {
                child_width = boundedSubtract(child_width, horizontalEdges(child_style.margin));
                child_height = boundedSubtract(child_height, verticalEdges(child_style.margin));
            }
            const child_x = boundedAdd(
                boundedAdd(origin.x, gridTrackOffset(columns, resolved_placement.column, size.width, column_gap)),
                child_style.margin.left,
            );
            const child_y = boundedAdd(
                boundedAdd(origin.y, gridTrackOffset(rows, resolved_placement.row, size.height, row_gap)),
                child_style.margin.top,
            );
            try self.computeNode(
                child_id,
                .{ .x = child_x, .y = child_y },
                size,
                .{ .width = child_width, .height = child_height },
                false,
                inherited_clip,
                measure,
                measure_user_data,
            );
        }
    }

    fn gridRegionOccupied(self: *LayoutTree, children: []const NodeId, candidate: GridPlacement) Error!bool {
        for (children) |child_id| {
            const child_node = try self.nodeConstAt(child_id);
            if (child_node.style.display == .none or child_node.style.position == .absolute) continue;
            const placement = child_node.grid_placement orelse continue;
            if (gridPlacementsOverlap(candidate, placement)) return true;
        }
        return false;
    }

    fn gridCellOccupied(self: *LayoutTree, children: []const NodeId, cell: usize, column_count: usize) Error!bool {
        for (children) |child_id| {
            const child_node = try self.nodeConstAt(child_id);
            if (child_node.style.display == .none or child_node.style.position == .absolute) continue;
            const occupied = if (child_node.style.grid_column != 0)
                (child_node.style.grid_column - 1) + (child_node.style.grid_row - 1) * column_count == cell
            else if (child_node.grid_placement) |placement|
                placement.column + placement.row * column_count == cell
            else
                false;
            if (occupied) return true;
        }
        return false;
    }
    fn computeAbsolute(
        self: *LayoutTree,
        id: NodeId,
        style_value: Style,
        containing: Dimensions,
        parent_origin: Point,
        inherited_clip: ?ClipRect,
        measure: ?IntrinsicMeasureFunction,
        measure_user_data: ?*anyopaque,
    ) Error!void {
        var width = resolveDimension(style_value.width, containing.width, 0);
        var height = resolveDimension(style_value.height, containing.height, 0);
        const left = insetValue(style_value.left, containing.width);
        const right = insetValue(style_value.right, containing.width);
        const top = insetValue(style_value.top, containing.height);
        const bottom = insetValue(style_value.bottom, containing.height);
        if (style_value.width == .stretch) {
            width = boundedSubtract(
                containing.width,
                boundedAdd(left orelse 0, right orelse 0),
            );
        }
        if (style_value.height == .stretch) {
            height = boundedSubtract(
                containing.height,
                boundedAdd(top orelse 0, bottom orelse 0),
            );
        }
        const node_ref = try self.nodeAt(id);
        node_ref.intrinsic_measurement = null;
        if (measure != null and node_ref.children.items.len == 0 and
            (style_value.width == .auto or style_value.height == .auto))
        {
            const measured = measure.?(id, containing, measure_user_data);
            try validateDimensions(measured);
            node_ref.intrinsic_measurement = measured;
            if (style_value.width == .auto) width = measured.width;
            if (style_value.height == .auto) height = measured.height;
        }
        const x_offset = if (left) |value|
            boundedAdd(value, style_value.margin.left)
        else if (right) |value|
            boundedSubtract(
                boundedSubtract(containing.width, value),
                boundedAdd(width, style_value.margin.right),
            )
        else
            style_value.margin.left;
        const y_offset = if (top) |value|
            boundedAdd(value, style_value.margin.top)
        else if (bottom) |value|
            boundedSubtract(
                boundedSubtract(containing.height, value),
                boundedAdd(height, style_value.margin.bottom),
            )
        else
            style_value.margin.top;
        try self.computeNode(
            id,
            .{ .x = boundedAdd(parent_origin.x, x_offset), .y = boundedAdd(parent_origin.y, y_offset) },
            containing,
            .{ .width = width, .height = height },
            false,
            inherited_clip,
            measure,
            measure_user_data,
        );
    }

    fn hideNode(self: *LayoutTree, id: NodeId) Error!void {
        const node_ref = try self.nodeAt(id);
        node_ref.layout = .{};
        node_ref.dirty = false;
        for (node_ref.children.items) |child| try self.hideNode(child);
    }

    fn nodeAt(self: *LayoutTree, id: NodeId) Error!*Node {
        const slot_ref = try self.slotAt(id);
        return &(slot_ref.node orelse return error.StaleNodeId);
    }

    fn nodeConstAt(self: *const LayoutTree, id: NodeId) Error!*const Node {
        const slot_ref = try self.slotConstAt(id);
        return &(slot_ref.node orelse return error.StaleNodeId);
    }

    fn slotAt(self: *LayoutTree, id: NodeId) Error!*Slot {
        if (@as(usize, id.index) >= self.slots.items.len) return error.StaleNodeId;
        const slot_ref = &self.slots.items[@as(usize, id.index)];
        if (slot_ref.node == null or slot_ref.generation != id.generation) return error.StaleNodeId;
        return slot_ref;
    }

    fn slotConstAt(self: *const LayoutTree, id: NodeId) Error!*const Slot {
        if (@as(usize, id.index) >= self.slots.items.len) return error.StaleNodeId;
        const slot_ref = &self.slots.items[@as(usize, id.index)];
        if (slot_ref.node == null or slot_ref.generation != id.generation) return error.StaleNodeId;
        return slot_ref;
    }
};

fn sameId(left: NodeId, right: NodeId) bool {
    return left.index == right.index and left.generation == right.generation;
}
fn horizontalEdges(edges: Edges) f32 {
    return boundedAdd(edges.left, edges.right);
}

fn verticalEdges(edges: Edges) f32 {
    return boundedAdd(edges.top, edges.bottom);
}

fn marginAlongAxis(edges: Edges, direction: FlexDirection) f32 {
    return if (direction == .row) horizontalEdges(edges) else verticalEdges(edges);
}

fn marginAcrossAxis(edges: Edges, direction: FlexDirection) f32 {
    return if (direction == .row) verticalEdges(edges) else horizontalEdges(edges);
}
fn resolveAlign(value: AlignSelf, parent: AlignItems) AlignItems {
    return switch (value) {
        .auto => parent,
        .stretch => .stretch,
        .flex_start => .flex_start,
        .flex_end => .flex_end,
        .center => .center,
    };
}

fn crossAxisOffset(
    alignment: AlignItems,
    available: f32,
    child_size: f32,
    edges: Edges,
    direction: FlexDirection,
) f32 {
    const margin_before = if (direction == .row) edges.top else edges.left;
    const margin_after = if (direction == .row) edges.bottom else edges.right;
    const margin_box = boundedAdd(child_size, boundedAdd(margin_before, margin_after));
    const free = @max(boundedSubtract(available, margin_box), 0);
    const alignment_offset = switch (alignment) {
        .flex_end => free,
        .center => free / 2,
        .flex_start, .stretch => 0,
    };
    return boundedAdd(alignment_offset, margin_before);
}

fn justifyLeading(justify: JustifyContent, free: f32, count: usize) f32 {
    if (count == 0) return 0;
    const count_float = @as(f32, @floatFromInt(count));
    return switch (justify) {
        .flex_start, .space_between => 0,
        .flex_end => free,
        .center => free / 2,
        .space_around => free / count_float / 2,
        .space_evenly => free / (count_float + 1),
    };
}

fn justifyGap(justify: JustifyContent, free: f32, count: usize) f32 {
    if (count == 0 or (count < 2 and justify == .space_between)) return 0;
    const count_float = @as(f32, @floatFromInt(count));
    return switch (justify) {
        .space_between => free / @as(f32, @floatFromInt(count - 1)),
        .space_around => free / count_float,
        .space_evenly => free / (count_float + 1),
        .flex_start, .flex_end, .center => 0,
    };
}

fn clampFlexMain(value: f32, style: Style, direction: FlexDirection, parent_main: f32) f32 {
    const margin = marginAlongAxis(style.margin, direction);
    const box_value = boundedSubtract(value, margin);
    const clamped = if (direction == .row)
        clampDimension(box_value, style.min_width, style.max_width, parent_main)
    else
        clampDimension(box_value, style.min_height, style.max_height, parent_main);
    return boundedAdd(clamped, margin);
}

fn boundedSubtract(left: f32, right: f32) f32 {
    return boundedCoordinate(left - right);
}

fn clampDimension(value: f32, min_dimension: Dimension, max_dimension: Dimension, parent: f32) f32 {
    var result = if (finite(value)) @max(value, 0) else std.math.floatMax(f32);
    if (max_dimension != .auto) {
        result = @min(result, boundedResolved(max_dimension, parent));
    }
    if (min_dimension != .auto) {
        result = @max(result, boundedResolved(min_dimension, parent));
    }
    return result;
}

fn boundedResolved(dimension: Dimension, parent: f32) f32 {
    const resolved = resolveDimension(dimension, parent, 0);
    return if (finite(resolved)) @max(resolved, 0) else std.math.floatMax(f32);
}

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

fn flexBaseDimension(
    style: Style,
    direction: FlexDirection,
    main_parent: f32,
    cross_parent: f32,
    intrinsic_measurement: ?Dimensions,
) f32 {
    const main_dimension = if (direction == .row) style.width else style.height;
    if (style.flex_basis != .auto) {
        return switch (style.flex_basis) {
            .stretch => 0,
            else => boundedResolved(style.flex_basis, main_parent),
        };
    }
    if (style.aspect_ratio) |ratio| {
        const cross_dimension = if (direction == .row) style.height else style.width;
        if (main_dimension == .auto and cross_dimension != .auto) {
            const cross = boundedResolved(cross_dimension, cross_parent);
            const resolved = if (direction == .row) cross * ratio else cross / ratio;
            return if (finite(resolved)) @max(resolved, 0) else std.math.floatMax(f32);
        }
    }
    if (intrinsic_measurement) |measured| {
        if (main_dimension == .auto) return if (direction == .row) measured.width else measured.height;
    }
    return switch (main_dimension) {
        .stretch => 0,
        else => boundedResolved(main_dimension, main_parent),
    };
}

fn flexMainDimension(style: Style, direction: FlexDirection) Dimension {
    return if (direction == .row) style.width else style.height;
}

fn flexMainFactor(style: Style, direction: FlexDirection, free: f32, base: f32) f32 {
    const main_dimension = if (style.flex_basis != .auto) style.flex_basis else flexMainDimension(style, direction);
    if (free >= 0) {
        return switch (main_dimension) {
            .stretch => |factor| factor,
            else => style.flex_grow,
        };
    }
    return switch (main_dimension) {
        .stretch => 0,
        else => style.flex_shrink * base,
    };
}

fn weightedShare(available: f32, factor: f32, total: f32) f32 {
    if (available == 0 or factor <= 0 or total <= 0) return 0;
    const result = (available / total) * factor;
    return if (finite(result)) result else std.math.floatMax(f32);
}

fn effectiveGap(specific: f32, shared: f32) f32 {
    return if (specific != 0) specific else shared;
}

fn gridTrackDimension(tracks: []const GridTrack, index: usize, available: f32, gap: f32) f32 {
    const total_gap = gap * @as(f32, @floatFromInt(tracks.len - 1));
    const usable = @max(available - total_gap, 0);
    var fixed: f32 = 0;
    var fractions: f32 = 0;
    for (tracks) |track| switch (track) {
        .fixed => |value| fixed += value,
        .fr => |value| fractions += value,
    };
    return switch (tracks[index]) {
        .fixed => |value| value,
        .fr => |value| if (fractions > 0) @max(usable - fixed, 0) * value / fractions else 0,
    };
}

fn gridTrackSpanDimension(tracks: []const GridTrack, start: usize, span: usize, available: f32, gap: f32) f32 {
    var total: f32 = 0;
    for (0..span) |offset| {
        total += gridTrackDimension(tracks, start + offset, available, gap);
    }
    if (span > 1) total += gap * @as(f32, @floatFromInt(span - 1));
    return total;
}

fn gridPlacementsOverlap(left: GridPlacement, right: GridPlacement) bool {
    return left.column < right.column + right.column_span and
        right.column < left.column + left.column_span and
        left.row < right.row + right.row_span and
        right.row < left.row + left.row_span;
}

fn gridTrackOffset(tracks: []const GridTrack, index: usize, available: f32, gap: f32) f32 {
    var offset: f32 = 0;
    for (0..index) |track_index| {
        offset += gridTrackDimension(tracks, track_index, available, gap) + gap;
    }
    return offset;
}

fn validateGridCapacity(style: Style, options: Options) Error!void {
    if (style.display != .grid) return;
    if (style.grid_columns.len == 0 or style.grid_rows.len == 0) return error.InvalidStyle;
    if (style.grid_columns.len > options.max_grid_tracks or style.grid_rows.len > options.max_grid_tracks) {
        return error.GridTrackCapacityExceeded;
    }
}

fn validateDimensions(value: Dimensions) Error!void {
    if (!finite(value.width) or !finite(value.height) or value.width < 0 or value.height < 0) {
        return error.InvalidDimensions;
    }
}

fn validateEdges(edges: Edges) Error!void {
    if (!finite(edges.top) or edges.top < 0 or
        !finite(edges.right) or edges.right < 0 or
        !finite(edges.bottom) or edges.bottom < 0 or
        !finite(edges.left) or edges.left < 0)
    {
        return error.InvalidStyle;
    }
}

fn validateStyle(style: Style) Error!void {
    try validateEdges(style.padding);
    try validateEdges(style.margin);
    if (@intFromEnum(style.flex_wrap) >= 2 or
        @intFromEnum(style.align_items) >= 4 or
        @intFromEnum(style.align_self) >= 5 or
        @intFromEnum(style.alignment) >= 9 or
        @intFromEnum(style.justify_content) >= 6)
    {
        return error.InvalidStyle;
    }
    if (style.aspect_ratio) |ratio| {
        if (!finite(ratio) or ratio <= 0) return error.InvalidStyle;
    }
    if (!finite(style.flex_grow) or style.flex_grow < 0 or
        !finite(style.flex_shrink) or style.flex_shrink < 0)
    {
        return error.InvalidStyle;
    }
    if ((style.grid_column == 0) != (style.grid_row == 0) or
        style.grid_column_span == 0 or style.grid_row_span == 0)
    {
        return error.InvalidStyle;
    }
    if (!finite(style.grid_column_gap) or style.grid_column_gap < 0 or
        !finite(style.grid_row_gap) or style.grid_row_gap < 0 or
        !finite(style.grid_gap) or style.grid_gap < 0 or
        !finite(style.flex_gap) or style.flex_gap < 0)
    {
        return error.InvalidStyle;
    }
    for (style.grid_columns) |track| switch (track) {
        .fixed => |value| if (!finite(value) or value < 0) return error.InvalidStyle,
        .fr => |value| if (!finite(value) or value <= 0) return error.InvalidStyle,
    };
    for (style.grid_rows) |track| switch (track) {
        .fixed => |value| if (!finite(value) or value < 0) return error.InvalidStyle,
        .fr => |value| if (!finite(value) or value <= 0) return error.InvalidStyle,
    };
    if ((style.grid_column == 0) != (style.grid_row == 0)) return error.InvalidStyle;
    const dimensions = [_]Dimension{
        style.width,
        style.height,
        style.min_width,
        style.max_width,
        style.min_height,
        style.max_height,
        style.flex_basis,
        style.left,
        style.right,
        style.top,
        style.bottom,
    };
    for (dimensions) |dimension| switch (dimension) {
        .auto => {},
        .length => |value| if (!finite(value) or value < 0) return error.InvalidStyle,
        .percent => |value| if (!finite(value) or value < 0) return error.InvalidStyle,
        .stretch => |factor| if (!finite(factor) or factor <= 0) return error.InvalidStyle,
    };
}

const IntrinsicProbe = struct {
    calls: usize = 0,
    dimensions: Dimensions = .{ .width = 23, .height = 19 },
};

fn measureIntrinsic(_: NodeId, _: Dimensions, user_data: ?*anyopaque) Dimensions {
    const probe: *IntrinsicProbe = @ptrCast(@alignCast(user_data.?));
    probe.calls += 1;
    return probe.dimensions;
}

fn measureInvalidIntrinsic(_: NodeId, _: Dimensions, _: ?*anyopaque) Dimensions {
    return .{ .width = std.math.nan(f32), .height = 10 };
}

fn resolveDimension(dimension: Dimension, parent: f32, auto_value: f32) f32 {
    return switch (dimension) {
        .auto => auto_value,
        .length => |value| value,
        .percent => |value| parent * value,
        // Outside a flex distribution pass, stretch fills the available axis.
        .stretch => parent,
    };
}

fn insetValue(dimension: Dimension, parent: f32) ?f32 {
    return switch (dimension) {
        .auto => null,
        .length => |value| value,
        .percent => |value| parent * value,
        // Stretch is a size, not an inset.
        .stretch => null,
    };
}
fn clipForNode(overflow: Overflow, inherited: ?ClipRect, origin: Point, size: Dimensions) ?ClipRect {
    if (overflow == .visible) return inherited;
    return intersectClip(inherited, .{
        .x = boundedCoordinate(origin.x),
        .y = boundedCoordinate(origin.y),
        .width = size.width,
        .height = size.height,
    });
}

fn intersectClip(inherited: ?ClipRect, own: ClipRect) ClipRect {
    const parent = inherited orelse return own;
    const left = @max(parent.x, own.x);
    const top = @max(parent.y, own.y);
    const right = @min(boundedAdd(parent.x, parent.width), boundedAdd(own.x, own.width));
    const bottom = @min(boundedAdd(parent.y, parent.height), boundedAdd(own.y, own.height));
    return .{
        .x = left,
        .y = top,
        .width = @max(right - left, 0),
        .height = @max(bottom - top, 0),
    };
}

fn boundedCoordinate(value: f32) f32 {
    if (finite(value)) return value;
    if (std.math.isNan(value)) return 0;
    return if (value < 0) -std.math.floatMax(f32) else std.math.floatMax(f32);
}

fn boundedAdd(left: f32, right: f32) f32 {
    return boundedCoordinate(left + right);
}

test "intrinsic measurement sizes auto leaf dimensions" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 80 } });
    const child = try tree.create(.{});
    try tree.appendChild(root, child);

    var probe = IntrinsicProbe{};
    try tree.computeWithMeasure(root, .{ .width = 100, .height = 80 }, measureIntrinsic, &probe);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(Layout{ .width = 23, .height = 19 }, try tree.readLayout(child));
}

test "intrinsic measurement rejects non-finite dimensions" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 2 });
    defer tree.deinit();
    const leaf = try tree.create(.{});
    try std.testing.expectError(
        error.InvalidDimensions,
        tree.computeWithMeasure(leaf, .{ .width = 100, .height = 80 }, measureInvalidIntrinsic, null),
    );
}

test "retained tree mutates children and propagates dirty state" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4, .max_children_per_node = 2 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 50 } });
    const child = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 10 } });
    try tree.appendChild(root, child);
    try tree.compute(root, .{ .width = 100, .height = 50 });
    try std.testing.expect(!(try tree.isDirty(root)));
    try tree.setStyle(child, .{ .width = .{ .length = 20 }, .height = .{ .length = 10 } });
    try std.testing.expect(try tree.isDirty(child));
    try std.testing.expect(try tree.isDirty(root));
    try tree.removeChild(root, child);
    try std.testing.expectEqual(@as(usize, 0), try tree.childCount(root));
}

test "row and column flex layout resolve basic sizes" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const row = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 20 } });
    const first = try tree.create(.{ .width = .{ .length = 30 }, .height = .{ .length = 10 } });
    const second = try tree.create(.{ .width = .{ .length = 20 }, .height = .{ .length = 8 } });
    try tree.appendChild(row, first);
    try tree.appendChild(row, second);
    try tree.compute(row, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(Layout{ .width = 30, .height = 10 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .x = 30, .width = 20, .height = 8 }, try tree.readLayout(second));

    const column = try tree.create(.{ .flex_direction = .column, .width = .{ .length = 40 }, .height = .{ .length = 100 } });
    const item = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 25 } });
    try tree.appendChild(column, item);
    try tree.compute(column, .{ .width = 40, .height = 100 });
    try std.testing.expectEqual(Layout{ .width = 10, .height = 25 }, try tree.readLayout(item));
}

test "none and absolute children have deterministic boxes" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 80 } });
    const hidden = try tree.create(.{ .display = .none, .width = .{ .length = 30 }, .height = .{ .length = 20 } });
    const absolute = try tree.create(.{
        .position = .absolute,
        .width = .{ .length = 10 },
        .height = .{ .length = 12 },
        .left = .{ .length = 7 },
        .top = .{ .length = 9 },
    });
    try tree.appendChild(root, hidden);
    try tree.appendChild(root, absolute);
    try tree.compute(root, .{ .width = 100, .height = 80 });
    try std.testing.expectEqual(Layout{}, try tree.readLayout(hidden));
    try std.testing.expectEqual(Layout{ .x = 7, .y = 9, .width = 10, .height = 12 }, try tree.readLayout(absolute));
}

test "stale ids and bounded capacity are explicit errors" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 1, .max_children_per_node = 1 });
    defer tree.deinit();
    const root = try tree.create(.{});
    try std.testing.expectError(error.NodeCapacityExceeded, tree.create(.{}));
    try tree.destroy(root);
    try std.testing.expectError(error.StaleNodeId, tree.readLayout(root));
    const reused = try tree.create(.{});
    try std.testing.expect(reused.generation != root.generation);
    try std.testing.expectError(error.StaleNodeId, tree.readLayout(root));
}

test "allocation failure and child capacity leave mutation unchanged" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 3, .max_children_per_node = 1 });
    defer tree.deinit();
    const root = try tree.create(.{});
    const first = try tree.create(.{});
    const second = try tree.create(.{});
    try tree.appendChild(root, first);
    try std.testing.expectError(error.ChildCapacityExceeded, tree.appendChild(root, second));
    try std.testing.expectEqual(@as(usize, 1), try tree.childCount(root));
    try std.testing.expectError(error.NodeCapacityExceeded, tree.create(.{}));
    try std.testing.expectEqual(@as(usize, 3), tree.live_count);
}
test "grid fixed and fractional tracks place explicit and automatic children" {
    const columns = [_]GridTrack{ .{ .fixed = 30 }, .{ .fr = 1 } };
    const rows = [_]GridTrack{ .{ .fixed = 10 }, .{ .fr = 1 } };
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 100 },
        .height = .{ .length = 80 },
        .grid_columns = &columns,
        .grid_rows = &rows,
        .grid_gap = 5,
    });
    const explicit_a = try tree.create(.{ .grid_column = 2, .grid_row = 1 });
    const explicit_b = try tree.create(.{ .grid_column = 1, .grid_row = 2 });
    const automatic = try tree.create(.{});
    try tree.appendChild(root, explicit_a);
    try tree.appendChild(root, explicit_b);
    try tree.appendChild(root, automatic);
    try tree.compute(root, .{ .width = 100, .height = 80 });
    try std.testing.expectEqual(Layout{ .x = 35, .width = 65, .height = 10 }, try tree.readLayout(explicit_a));
    try std.testing.expectEqual(Layout{ .y = 15, .width = 30, .height = 65 }, try tree.readLayout(explicit_b));
    try std.testing.expectEqual(Layout{ .width = 30, .height = 10 }, try tree.readLayout(automatic));
}

test "grid excludes none and absolute children from placement" {
    const tracks = [_]GridTrack{.{ .fixed = 40 }};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 40 },
        .height = .{ .length = 40 },
        .grid_columns = &tracks,
        .grid_rows = &tracks,
    });
    const hidden = try tree.create(.{ .display = .none });
    const absolute = try tree.create(.{ .position = .absolute, .width = .{ .length = 5 }, .height = .{ .length = 6 }, .left = .{ .length = 3 }, .top = .{ .length = 4 } });
    const item = try tree.create(.{});
    try tree.appendChild(root, hidden);
    try tree.appendChild(root, absolute);
    try tree.appendChild(root, item);
    try tree.compute(root, .{ .width = 40, .height = 40 });
    try std.testing.expectEqual(Layout{}, try tree.readLayout(hidden));
    try std.testing.expectEqual(Layout{ .x = 3, .y = 4, .width = 5, .height = 6 }, try tree.readLayout(absolute));
    try std.testing.expectEqual(Layout{ .width = 40, .height = 40 }, try tree.readLayout(item));
}

test "grid rejects invalid tracks and bounded track capacity" {
    const one = [_]GridTrack{.{ .fixed = 10 }};
    const two = [_]GridTrack{ .{ .fixed = 10 }, .{ .fr = 1 } };
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4, .max_grid_tracks = 1 });
    defer tree.deinit();
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .display = .grid, .grid_columns = &one }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .display = .grid, .grid_columns = &one, .grid_rows = &[_]GridTrack{.{ .fr = 0 }} }));
    try std.testing.expectError(error.GridTrackCapacityExceeded, tree.create(.{ .display = .grid, .grid_columns = &two, .grid_rows = &one }));
}
test "flex basis distributes growth and explicit shrink without negatives" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 10 } });
    const first = try tree.create(.{
        .flex_basis = .{ .length = 10 },
        .flex_grow = 1,
        .flex_shrink = 1,
        .height = .{ .length = 10 },
    });
    const second = try tree.create(.{
        .flex_basis = .{ .length = 20 },
        .flex_grow = 3,
        .flex_shrink = 1,
        .height = .{ .length = 10 },
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.compute(root, .{ .width = 100, .height = 10 });
    try std.testing.expectEqual(@as(f32, 27.5), (try tree.readLayout(first)).width);
    try std.testing.expectEqual(@as(f32, 72.5), (try tree.readLayout(second)).width);

    try tree.setStyle(first, .{
        .flex_basis = .{ .length = 80 },
        .flex_shrink = 1,
        .height = .{ .length = 10 },
    });
    try tree.setStyle(second, .{
        .flex_basis = .{ .length = 80 },
        .flex_shrink = 1,
        .height = .{ .length = 10 },
    });
    try tree.compute(root, .{ .width = 100, .height = 10 });
    try std.testing.expectEqual(@as(f32, 50), (try tree.readLayout(first)).width);
    try std.testing.expectEqual(@as(f32, 50), (try tree.readLayout(second)).width);
}

test "flex min and max dimensions clamp and redistribute free space" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 10 } });
    const capped = try tree.create(.{
        .flex_basis = .{ .length = 20 },
        .flex_grow = 1,
        .max_width = .{ .length = 30 },
        .height = .{ .length = 10 },
    });
    const flexible = try tree.create(.{
        .flex_basis = .{ .length = 20 },
        .flex_grow = 1,
        .height = .{ .length = 10 },
    });
    try tree.appendChild(root, capped);
    try tree.appendChild(root, flexible);
    try tree.compute(root, .{ .width = 100, .height = 10 });
    try std.testing.expectEqual(@as(f32, 30), (try tree.readLayout(capped)).width);
    try std.testing.expectEqual(@as(f32, 70), (try tree.readLayout(flexible)).width);

    try tree.setStyle(capped, .{
        .flex_basis = .{ .length = 80 },
        .flex_shrink = 1,
        .min_width = .{ .length = 70 },
        .height = .{ .length = 10 },
    });
    try tree.setStyle(flexible, .{
        .flex_basis = .{ .length = 80 },
        .flex_shrink = 1,
        .height = .{ .length = 10 },
    });
    try tree.compute(root, .{ .width = 100, .height = 10 });
    try std.testing.expectEqual(@as(f32, 70), (try tree.readLayout(capped)).width);
    try std.testing.expectEqual(@as(f32, 30), (try tree.readLayout(flexible)).width);
}

test "dimension constraints and flex factors reject invalid styles" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .min_width = .{ .length = -1 } }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .max_height = .{ .percent = std.math.nan(f32) } }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .flex_shrink = std.math.inf(f32) }));

    const root = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
        .min_width = .{ .length = 40 },
        .max_width = .{ .length = 50 },
    });
    try tree.compute(root, .{ .width = 100, .height = 10 });
    try std.testing.expectEqual(@as(f32, 40), (try tree.readLayout(root)).width);
}
test "aspect ratio fills one missing dimension and preserves explicit dimensions" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();

    const width_driven = try tree.create(.{
        .width = .{ .length = 80 },
        .aspect_ratio = 2,
    });
    try tree.compute(width_driven, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(Layout{ .width = 80, .height = 40 }, try tree.readLayout(width_driven));

    const height_driven = try tree.create(.{
        .height = .{ .length = 30 },
        .aspect_ratio = 2,
    });
    try tree.compute(height_driven, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(Layout{ .width = 60, .height = 30 }, try tree.readLayout(height_driven));

    const explicit = try tree.create(.{
        .width = .{ .length = 40 },
        .height = .{ .length = 30 },
        .aspect_ratio = 9,
    });
    try tree.compute(explicit, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(Layout{ .width = 40, .height = 30 }, try tree.readLayout(explicit));
    const bounded = try tree.create(.{
        .height = .{ .length = 2 },
        .aspect_ratio = std.math.floatMax(f32),
    });
    try tree.compute(bounded, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(std.math.floatMax(f32), (try tree.readLayout(bounded)).width);
}

test "aspect ratio accepts only finite positive values" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .aspect_ratio = 0 }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .aspect_ratio = -1 }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .aspect_ratio = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .aspect_ratio = std.math.nan(f32) }));
}

test "clip overflow exposes effective bounded regions to descendants" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 50 },
        .overflow = .clip,
    });
    const child = try tree.create(.{
        .width = .{ .length = 200 },
        .height = .{ .length = 80 },
    });
    const offset = try tree.create(.{
        .position = .absolute,
        .width = .{ .length = 50 },
        .height = .{ .length = 10 },
        .left = .{ .length = 80 },
        .overflow = .clip,
    });
    try tree.appendChild(root, child);
    try tree.appendChild(root, offset);
    try tree.compute(root, .{ .width = 100, .height = 50 });

    const expected = ClipRect{ .width = 100, .height = 50 };
    try std.testing.expectEqual(expected, (try tree.readClip(root)).?);
    try std.testing.expectEqual(expected, (try tree.readClip(child)).?);
    try std.testing.expectEqual(expected, (try tree.readLayout(child)).clip.?);
    try std.testing.expectEqual(ClipRect{ .x = 80, .width = 20, .height = 10 }, (try tree.readClip(offset)).?);
}

test "padding offsets flex children and reduces available content" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 50 },
        .padding = .{ .left = 7, .right = 13, .top = 5, .bottom = 9 },
    });
    const child = try tree.create(.{
        .width = .{ .length = 80 },
        .height = .{ .length = 20 },
    });
    try tree.appendChild(root, child);
    try tree.compute(root, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(Layout{ .width = 100, .height = 50 }, try tree.readLayout(root));
    try std.testing.expectEqual(
        Layout{ .x = 7, .y = 5, .width = 80, .height = 20 },
        try tree.readLayout(child),
    );
}

test "overlay aligns relative children independently within padded content" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .overlay,
        .width = .{ .length = 100 },
        .height = .{ .length = 80 },
        .padding = .{ .left = 10, .right = 20, .top = 5, .bottom = 15 },
    });
    const centered = try tree.create(.{
        .alignment = .center,
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    });
    const overlap = try tree.create(.{
        .alignment = .center,
        .width = .{ .length = 8 },
        .height = .{ .length = 6 },
    });
    const corner = try tree.create(.{
        .alignment = .top_right,
        .width = .{ .length = 15 },
        .height = .{ .length = 12 },
    });
    const absolute = try tree.create(.{
        .position = .absolute,
        .width = .{ .length = 7 },
        .height = .{ .length = 9 },
        .left = .{ .length = 3 },
        .top = .{ .length = 4 },
    });
    try tree.appendChild(root, centered);
    try tree.appendChild(root, overlap);
    try tree.appendChild(root, corner);
    try tree.appendChild(root, absolute);
    try tree.compute(root, .{ .width = 100, .height = 80 });

    try std.testing.expectEqual(
        Layout{ .x = 35, .y = 30, .width = 20, .height = 10 },
        try tree.readLayout(centered),
    );
    try std.testing.expectEqual(
        Layout{ .x = 41, .y = 32, .width = 8, .height = 6 },
        try tree.readLayout(overlap),
    );
    try std.testing.expectEqual(
        Layout{ .x = 65, .y = 5, .width = 15, .height = 12 },
        try tree.readLayout(corner),
    );
    try std.testing.expectEqual(
        Layout{ .x = 13, .y = 9, .width = 7, .height = 9 },
        try tree.readLayout(absolute),
    );
}

test "flex margins contribute spacing without changing child boxes" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 20 } });
    const first = try tree.create(.{
        .width = .{ .length = 10 },
        .height = .{ .length = 8 },
        .margin = .{ .right = 5 },
    });
    const second = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 8 },
        .margin = .{ .left = 3, .top = 2 },
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.compute(root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(Layout{ .width = 10, .height = 8 }, try tree.readLayout(first));
    try std.testing.expectEqual(
        Layout{ .x = 18, .y = 2, .width = 20, .height = 8 },
        try tree.readLayout(second),
    );
}

test "edges reject non-finite and negative spacing" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    try std.testing.expectError(
        error.InvalidStyle,
        tree.create(.{ .padding = .{ .left = -1 } }),
    );
    try std.testing.expectError(
        error.InvalidStyle,
        tree.create(.{ .margin = .{ .top = std.math.inf(f32) } }),
    );
}

test "flex cross-axis alignment honors container and item overrides" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
        .align_items = .center,
    });
    const centered = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    });
    const ended = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
        .align_self = .flex_end,
    });
    try tree.appendChild(root, centered);
    try tree.appendChild(root, ended);
    try tree.compute(root, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(f32, 45), (try tree.readLayout(centered)).y);
    try std.testing.expectEqual(@as(f32, 90), (try tree.readLayout(ended)).y);
}

test "flex justification distributes positive main-axis free space" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
        .justify_content = .space_between,
    });
    const first = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 10 } });
    const second = try tree.create(.{ .width = .{ .length = 20 }, .height = .{ .length = 10 } });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.compute(root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(f32, 0), (try tree.readLayout(first)).x);
    try std.testing.expectEqual(@as(f32, 80), (try tree.readLayout(second)).x);

    try tree.setStyle(root, .{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
        .justify_content = .center,
    });
    try tree.compute(root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(f32, 35), (try tree.readLayout(first)).x);
    try std.testing.expectEqual(@as(f32, 45), (try tree.readLayout(second)).x);
}
test "wrapped row forms bounded lines and places cross axis" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .flex_wrap = .wrap,
        .width = .{ .length = 50 },
        .height = .{ .length = 40 },
    });
    const first = try tree.create(.{ .width = .{ .length = 30 }, .height = .{ .length = 10 } });
    const second = try tree.create(.{ .width = .{ .length = 30 }, .height = .{ .length = 10 } });
    const third = try tree.create(.{ .width = .{ .length = 20 }, .height = .{ .length = 10 } });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.appendChild(root, third);
    try tree.compute(root, .{ .width = 50, .height = 40 });
    try std.testing.expectEqual(Layout{ .width = 30, .height = 10 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .y = 10, .width = 30, .height = 10 }, try tree.readLayout(second));
    try std.testing.expectEqual(Layout{ .x = 30, .y = 10, .width = 20, .height = 10 }, try tree.readLayout(third));
}

test "wrapped column forms bounded lines and places cross axis" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .flex_direction = .column,
        .flex_wrap = .wrap,
        .width = .{ .length = 40 },
        .height = .{ .length = 50 },
    });
    const first = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 30 } });
    const second = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 30 } });
    const third = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 20 } });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.appendChild(root, third);
    try tree.compute(root, .{ .width = 40, .height = 50 });
    try std.testing.expectEqual(Layout{ .width = 10, .height = 30 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .x = 10, .width = 10, .height = 30 }, try tree.readLayout(second));
    try std.testing.expectEqual(Layout{ .x = 10, .y = 30, .width = 10, .height = 20 }, try tree.readLayout(third));
}

test "wrapped flex gap separates main and cross axes" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .flex_wrap = .wrap,
        .flex_gap = 5,
        .width = .{ .length = 60 },
        .height = .{ .length = 50 },
    });
    const first = try tree.create(.{ .width = .{ .length = 30 }, .height = .{ .length = 10 } });
    const second = try tree.create(.{ .width = .{ .length = 30 }, .height = .{ .length = 10 } });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.compute(root, .{ .width = 60, .height = 50 });
    try std.testing.expectEqual(Layout{ .width = 30, .height = 10 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .y = 15, .width = 30, .height = 10 }, try tree.readLayout(second));
}

test "flex wrapping rejects invalid bounded values" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .flex_gap = -1 }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .flex_gap = std.math.inf(f32) }));
}

test "stretch dimensions divide remaining flex space by weight" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 20 } });
    const fixed = try tree.create(.{ .width = .{ .length = 20 }, .height = .{ .length = 10 } });
    const one = try tree.create(.{ .width = .{ .stretch = 1 }, .height = .{ .length = 10 } });
    const three = try tree.create(.{ .width = .{ .stretch = 3 }, .height = .{ .length = 10 } });
    try tree.appendChild(root, fixed);
    try tree.appendChild(root, one);
    try tree.appendChild(root, three);
    try tree.compute(root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(f32, 20), (try tree.readLayout(fixed)).width);
    try std.testing.expectEqual(@as(f32, 20), (try tree.readLayout(one)).width);
    try std.testing.expectEqual(@as(f32, 60), (try tree.readLayout(three)).width);
}

test "stretch dimensions fill bounded grid overlay and absolute space" {
    const columns = [_]GridTrack{.{ .fixed = 100 }};
    const rows = [_]GridTrack{.{ .fixed = 40 }};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 12 });
    defer tree.deinit();

    const grid = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 100 },
        .height = .{ .length = 40 },
        .grid_columns = &columns,
        .grid_rows = &rows,
    });
    const grid_child = try tree.create(.{ .width = .{ .stretch = 2 }, .height = .{ .stretch = 4 } });
    try tree.appendChild(grid, grid_child);
    try tree.compute(grid, .{ .width = 100, .height = 40 });
    try std.testing.expectEqual(@as(f32, 100), (try tree.readLayout(grid_child)).width);
    try std.testing.expectEqual(@as(f32, 40), (try tree.readLayout(grid_child)).height);

    const overlay = try tree.create(.{
        .display = .overlay,
        .width = .{ .length = 80 },
        .height = .{ .length = 50 },
    });
    const overlay_child = try tree.create(.{ .width = .{ .stretch = 1 }, .height = .{ .stretch = 1 } });
    try tree.appendChild(overlay, overlay_child);
    try tree.compute(overlay, .{ .width = 80, .height = 50 });
    try std.testing.expectEqual(@as(f32, 80), (try tree.readLayout(overlay_child)).width);
    try std.testing.expectEqual(@as(f32, 50), (try tree.readLayout(overlay_child)).height);

    const absolute_parent = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 60 } });
    const absolute = try tree.create(.{
        .position = .absolute,
        .width = .{ .stretch = 1 },
        .height = .{ .stretch = 1 },
        .left = .{ .length = 7 },
        .right = .{ .length = 13 },
        .top = .{ .length = 5 },
        .bottom = .{ .length = 15 },
    });
    try tree.appendChild(absolute_parent, absolute);
    try tree.compute(absolute_parent, .{ .width = 100, .height = 60 });
    try std.testing.expectEqual(
        Layout{ .x = 7, .y = 5, .width = 80, .height = 40 },
        try tree.readLayout(absolute),
    );
}

test "stretch dimensions require finite positive factors" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .width = .{ .stretch = 0 } }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .height = .{ .stretch = -1 } }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .flex_basis = .{ .stretch = std.math.nan(f32) } }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .left = .{ .stretch = std.math.inf(f32) } }));
}
