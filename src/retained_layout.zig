//! Small retained layout tree for renderer-agnostic UI foundations.
//!
//! This module intentionally implements only a bounded flex and grid subset:
//! row and column containers, explicit fixed/fractional grid tracks,
//! `display: none`, absolute children, and auto/length/percentage dimensions.
//! There is no text measurement, wrapping, padding, margin, block layout, or
//! CSS parser. Layout is computed synchronously into caller-owned tree storage;
//! no scratch allocation is needed by compute.

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

pub const Display = enum { flex, grid, none };
pub const Position = enum { relative, absolute };
pub const FlexDirection = enum { row, column };
pub const Overflow = enum { visible, clip };

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

pub const GridTrackSize = GridTrack;

pub const Dimension = union(enum) {
    auto,
    length: f32,
    percent: f32,

    pub fn lengthPx(value: f32) Dimension {
        return .{ .length = value };
    }

    pub fn percentOfParent(value: f32) Dimension {
        return .{ .percent = value };
    }
};

pub const Style = struct {
    display: Display = .flex,
    position: Position = .relative,
    flex_direction: FlexDirection = .row,
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
    /// One-based explicit placement. Zero means auto-placement.
    grid_column: usize = 0,
    grid_row: usize = 0,
};

pub const Dimensions = struct {
    width: f32 = 0,
    height: f32 = 0,
};

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
};

const Node = struct {
    style: Style,
    parent: ?NodeId = null,
    children: std.ArrayList(NodeId) = .empty,
    layout: Layout = .{},
    grid_placement: ?GridPlacement = null,
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
        self.computeNode(root_id, .{}, available, null, true, null) catch |err| return err;
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
    ) Error!void {
        const node_ref = try self.nodeAt(id);
        const style_value = node_ref.style;
        if (style_value.display == .none) {
            try self.hideNode(id);
            return;
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
        const children = node_ref.children.items;
        if (children.len == 0) return;

        if (style_value.display == .grid) {
            try self.computeGrid(id, origin, size, effective_clip);
            return;
        }

        const available_main = if (style_value.flex_direction == .row) size.width else size.height;
        for (children) |child_id| {
            const child_node = try self.nodeAt(child_id);
            const child_style = child_node.style;
            child_node.flex_frozen = child_style.display == .none or child_style.position == .absolute;
            if (child_node.flex_frozen) continue;
            const main_dimension = if (style_value.flex_direction == .row) child_style.width else child_style.height;
            const basis_dimension = if (child_style.flex_basis == .auto) main_dimension else child_style.flex_basis;
            child_node.flex_base = boundedResolved(basis_dimension, available_main);
            child_node.flex_size = child_node.flex_base;
        }

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
            const free = available_main - frozen_sum - unfrozen_base;
            var total_factor: f32 = 0;
            for (children) |child_id| {
                const child_node = try self.nodeAt(child_id);
                if (child_node.flex_frozen) continue;
                total_factor += if (free >= 0)
                    child_node.style.flex_grow
                else
                    child_node.style.flex_shrink * child_node.flex_base;
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
                const factor = if (free >= 0)
                    child_node.style.flex_grow
                else
                    child_node.style.flex_shrink * child_node.flex_base;
                const raw = child_node.flex_base + free * factor / total_factor;
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
                        const factor = if (free >= 0)
                            child_node.style.flex_grow
                        else
                            child_node.style.flex_shrink * child_node.flex_base;
                        child_node.flex_size = child_node.flex_base + free * factor / total_factor;
                        child_node.flex_frozen = true;
                    }
                }
                break;
            }
        }

        var cursor: f32 = 0;
        for (children) |child_id| {
            const child_style = try self.style(child_id);
            if (child_style.display == .none) {
                try self.hideNode(child_id);
                continue;
            }
            if (child_style.position == .absolute) {
                try self.computeAbsolute(child_id, child_style, size, origin, effective_clip);
                continue;
            }

            var child_width = resolveDimension(child_style.width, size.width, 0);
            var child_height = resolveDimension(child_style.height, size.height, 0);
            if (style_value.flex_direction == .row) {
                child_width = (try self.nodeConstAt(child_id)).flex_size;
                if (child_style.height == .auto) child_height = size.height;
            } else {
                child_height = (try self.nodeConstAt(child_id)).flex_size;
                if (child_style.width == .auto) child_width = size.width;
            }
            child_width = clampDimension(child_width, child_style.min_width, child_style.max_width, size.width);
            child_height = clampDimension(child_height, child_style.min_height, child_style.max_height, size.height);
            const child_origin = if (style_value.flex_direction == .row)
                Point{ .x = origin.x + cursor, .y = origin.y }
            else
                Point{ .x = origin.x, .y = origin.y + cursor };
            try self.computeNode(child_id, child_origin, size, .{ .width = child_width, .height = child_height }, false, effective_clip);
            const child_layout = try self.readLayout(child_id);
            cursor += if (style_value.flex_direction == .row) child_layout.width else child_layout.height;
        }
    }

    fn computeGrid(self: *LayoutTree, id: NodeId, origin: Point, size: Dimensions, inherited_clip: ?ClipRect) Error!void {
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
        // Validate explicit placements before auto-placement so an automatic
        // item cannot consume a cell reserved by a later explicit item.
        for (children, 0..) |child_id, index| {
            const child_style = try self.style(child_id);
            if (child_style.display == .none or child_style.position == .absolute) continue;
            const has_column = child_style.grid_column != 0;
            const has_row = child_style.grid_row != 0;
            if (has_column != has_row or (has_column and
                (child_style.grid_column > columns.len or child_style.grid_row > rows.len)))
            {
                return error.InvalidStyle;
            }
            if (has_column) {
                for (children[0..index]) |previous_id| {
                    const previous = try self.style(previous_id);
                    if (previous.display == .none or previous.position == .absolute) continue;
                    if (previous.grid_column == child_style.grid_column and previous.grid_row == child_style.grid_row) {
                        return error.InvalidStyle;
                    }
                }
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
                try self.computeAbsolute(child_id, child_style, size, origin, inherited_clip);
                continue;
            }
            var placement: GridPlacement = undefined;
            if (child_style.grid_column != 0) {
                placement = .{ .column = child_style.grid_column - 1, .row = child_style.grid_row - 1 };
            } else {
                while (auto_cursor < cell_count) {
                    if (!(try self.gridCellOccupied(children, auto_cursor, columns.len))) break;
                    auto_cursor += 1;
                }
                if (auto_cursor >= cell_count) return error.InvalidStyle;
                placement = .{ .column = auto_cursor % columns.len, .row = auto_cursor / columns.len };
                auto_cursor += 1;
            }
            (try self.nodeAt(child_id)).grid_placement = placement;
        }

        for (children) |child_id| {
            const child_style = try self.style(child_id);
            if (child_style.display == .none or child_style.position == .absolute) continue;
            const placement = (try self.nodeConstAt(child_id)).grid_placement.?;
            const child_width = gridTrackDimension(columns, placement.column, size.width, column_gap);
            const child_height = gridTrackDimension(rows, placement.row, size.height, row_gap);
            const child_x = origin.x + gridTrackOffset(columns, placement.column, size.width, column_gap);
            const child_y = origin.y + gridTrackOffset(rows, placement.row, size.height, row_gap);
            try self.computeNode(child_id, .{ .x = child_x, .y = child_y }, size, .{
                .width = child_width,
                .height = child_height,
            }, false, inherited_clip);
        }
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
    ) Error!void {
        var width = resolveDimension(style_value.width, containing.width, 0);
        var height = resolveDimension(style_value.height, containing.height, 0);
        const left = insetValue(style_value.left, containing.width);
        const right = insetValue(style_value.right, containing.width);
        const top = insetValue(style_value.top, containing.height);
        const bottom = insetValue(style_value.bottom, containing.height);
        if (style_value.width == .auto and left != null and right != null) width = @max(containing.width - left.? - right.?, 0);
        if (style_value.height == .auto and top != null and bottom != null) height = @max(containing.height - top.? - bottom.?, 0);
        const x = parent_origin.x + (if (left) |value| value else if (right) |value| containing.width - value - width else 0);
        const y = parent_origin.y + (if (top) |value| value else if (bottom) |value| containing.height - value - height else 0);
        try self.computeNode(id, .{ .x = x, .y = y }, containing, .{ .width = width, .height = height }, false, inherited_clip);
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

fn clampFlexMain(value: f32, style: Style, direction: FlexDirection, parent_main: f32) f32 {
    return if (direction == .row)
        clampDimension(value, style.min_width, style.max_width, parent_main)
    else
        clampDimension(value, style.min_height, style.max_height, parent_main);
}

fn finite(value: f32) bool {
    return std.math.isFinite(value);
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

fn validateStyle(style: Style) Error!void {
    if (style.aspect_ratio) |ratio| {
        if (!finite(ratio) or ratio <= 0) return error.InvalidStyle;
    }
    if (!finite(style.flex_grow) or style.flex_grow < 0 or
        !finite(style.flex_shrink) or style.flex_shrink < 0)
    {
        return error.InvalidStyle;
    }
    if (!finite(style.grid_column_gap) or style.grid_column_gap < 0 or
        !finite(style.grid_row_gap) or style.grid_row_gap < 0 or
        !finite(style.grid_gap) or style.grid_gap < 0)
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
    };
}

fn resolveDimension(dimension: Dimension, parent: f32, auto_value: f32) f32 {
    return switch (dimension) {
        .auto => auto_value,
        .length => |value| value,
        .percent => |value| parent * value,
    };
}

fn insetValue(dimension: Dimension, parent: f32) ?f32 {
    return switch (dimension) {
        .auto => null,
        .length => |value| value,
        .percent => |value| parent * value,
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
    try tree.appendChild(root, child);
    try tree.compute(root, .{ .width = 100, .height = 50 });

    const expected = ClipRect{ .width = 100, .height = 50 };
    try std.testing.expectEqual(expected, (try tree.readClip(root)).?);
    try std.testing.expectEqual(expected, (try tree.readClip(child)).?);
    try std.testing.expectEqual(expected, (try tree.readLayout(child)).clip.?);
}
