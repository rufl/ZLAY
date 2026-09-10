//! Small retained layout tree for renderer-agnostic UI foundations.
//!
//! This module intentionally implements only a bounded flex subset: row and
//! column containers, `display: none`, absolute children, and auto/length/
//! percentage dimensions. There is no text measurement, wrapping, padding,
//! margin, grid, block layout, or CSS parser. Layout is computed synchronously
//! into caller-owned tree storage; no scratch allocation is needed by compute.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
    NodeCapacityExceeded,
    ChildCapacityExceeded,
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

pub const Display = enum { flex, none };
pub const Position = enum { relative, absolute };
pub const FlexDirection = enum { row, column };

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
    left: Dimension = .auto,
    right: Dimension = .auto,
    top: Dimension = .auto,
    bottom: Dimension = .auto,
    flex_grow: f32 = 0,
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
};

pub const Options = struct {
    max_nodes: usize = 256,
    max_children_per_node: usize = 64,
};

const Node = struct {
    style: Style,
    parent: ?NodeId = null,
    children: std.ArrayList(NodeId) = .empty,
    layout: Layout = .{},
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
        self.computeNode(root_id, .{}, available, null, true) catch |err| return err;
    }

    pub fn readLayout(self: *const LayoutTree, id: NodeId) Error!Layout {
        return (try self.nodeConstAt(id)).layout;
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
    ) Error!void {
        const node_ref = try self.nodeAt(id);
        const style_value = node_ref.style;
        if (style_value.display == .none) {
            self.hideNode(id) catch |err| return err;
            return;
        }

        const size: Dimensions = forced_size orelse .{
            .width = resolveDimension(style_value.width, containing.width, if (is_root) containing.width else 0),
            .height = resolveDimension(style_value.height, containing.height, if (is_root) containing.height else 0),
        };
        node_ref.layout = .{ .x = origin.x, .y = origin.y, .width = size.width, .height = size.height };
        node_ref.dirty = false;
        const children = node_ref.children.items;
        if (children.len == 0) return;

        var fixed_main: f32 = 0;
        var total_grow: f32 = 0;
        for (children) |child_id| {
            const child_style = try self.style(child_id);
            if (child_style.display == .none or child_style.position == .absolute) continue;
            const main_dimension = if (style_value.flex_direction == .row) child_style.width else child_style.height;
            if (child_style.flex_grow > 0) total_grow += child_style.flex_grow;
            fixed_main += resolveDimension(main_dimension, if (style_value.flex_direction == .row) size.width else size.height, 0);
        }
        const available_main = if (style_value.flex_direction == .row) size.width else size.height;
        const remaining = @max(available_main - fixed_main, 0);
        var cursor: f32 = 0;
        for (children) |child_id| {
            const child_style = try self.style(child_id);
            if (child_style.display == .none) {
                try self.hideNode(child_id);
                continue;
            }
            if (child_style.position == .absolute) {
                try self.computeAbsolute(child_id, child_style, size);
                continue;
            }

            const grow = if (child_style.flex_grow > 0 and total_grow > 0)
                remaining * child_style.flex_grow / total_grow
            else
                0;
            var child_width = resolveDimension(child_style.width, size.width, 0);
            var child_height = resolveDimension(child_style.height, size.height, 0);
            if (style_value.flex_direction == .row) {
                if (child_style.width == .auto) child_width = grow;
                if (child_style.height == .auto) child_height = size.height;
            } else {
                if (child_style.height == .auto) child_height = grow;
                if (child_style.width == .auto) child_width = size.width;
            }
            const child_origin = if (style_value.flex_direction == .row)
                Point{ .x = origin.x + cursor, .y = origin.y }
            else
                Point{ .x = origin.x, .y = origin.y + cursor };
            try self.computeNode(child_id, child_origin, size, .{ .width = child_width, .height = child_height }, false);
            cursor += if (style_value.flex_direction == .row) child_width else child_height;
        }
    }

    fn computeAbsolute(self: *LayoutTree, id: NodeId, style_value: Style, containing: Dimensions) Error!void {
        var width = resolveDimension(style_value.width, containing.width, 0);
        var height = resolveDimension(style_value.height, containing.height, 0);
        const left = insetValue(style_value.left, containing.width);
        const right = insetValue(style_value.right, containing.width);
        const top = insetValue(style_value.top, containing.height);
        const bottom = insetValue(style_value.bottom, containing.height);
        if (style_value.width == .auto and left != null and right != null) width = @max(containing.width - left.? - right.?, 0);
        if (style_value.height == .auto and top != null and bottom != null) height = @max(containing.height - top.? - bottom.?, 0);
        const x = if (left) |value| containing.width * 0 + value else if (right) |value| containing.width - value - width else 0;
        const y = if (top) |value| containing.height * 0 + value else if (bottom) |value| containing.height - value - height else 0;
        try self.computeNode(id, .{ .x = x, .y = y }, containing, .{ .width = width, .height = height }, false);
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

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

fn validateDimensions(value: Dimensions) Error!void {
    if (!finite(value.width) or !finite(value.height) or value.width < 0 or value.height < 0) {
        return error.InvalidDimensions;
    }
}

fn validateStyle(style: Style) Error!void {
    if (!finite(style.flex_grow) or style.flex_grow < 0) return error.InvalidStyle;
    const dimensions = [_]Dimension{ style.width, style.height, style.left, style.right, style.top, style.bottom };
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
