//! Fixed-capacity retained node storage for ECS-style callers.
//!
//! `RetainedStore` borrows both slices supplied at initialization. The records
//! slice is the node table; the children slice is divided into one fixed-size
//! bucket per record. No allocator, pointer, or hidden ownership is involved.
//! IDs contain a slot index and generation, so a destroyed node cannot be
//! addressed through an older ID. Layout computation remains in
//! `retained_layout.LayoutTree`; this module only stores the retained state
//! that an ECS or renderer can own and update.

const std = @import("std");
const retained_layout = @import("retained_layout.zig");

pub const NodeId = retained_layout.NodeId;
pub const Style = retained_layout.Style;
pub const Layout = retained_layout.Layout;

pub const Error = error{
    InvalidStorage,
    NodeCapacityExceeded,
    ChildCapacityExceeded,
    StaleNodeId,
    ChildAlreadyAttached,
    ChildNotFound,
};

/// The mutable state retained for one node slot.
///
/// The store owns no copy of this type: `records` passed to `init` is the
/// backing table and remains caller-owned. `generation` and `live` are managed
/// by the store and should not be changed directly while it is in use.
pub const NodeRecord = struct {
    generation: u32 = 1,
    live: bool = false,
    style: Style = .{},
    layout: Layout = .{},
    parent: ?NodeId = null,
    child_count: usize = 0,
};

/// Optional replacement values for `update`.
pub const Update = struct {
    style: ?Style = null,
    layout: ?Layout = null,
};

pub const RetainedStore = struct {
    records: []NodeRecord,
    children_storage: []NodeId,
    children_per_node: usize,
    live_count: usize = 0,

    /// Initialize a store over caller-owned slices.
    ///
    /// The child backing slice must divide evenly among node records. For a
    /// table of `N` records and a child slice of `N * K` IDs, each node has a
    /// bounded child capacity of `K`. Empty node and child slices are valid.
    /// Initialization clears the records so an undefined caller buffer is
    /// safe to pass here.
    pub fn init(records: []NodeRecord, children_storage: []NodeId) Error!RetainedStore {
        const children_per_node = if (records.len == 0) blk: {
            if (children_storage.len != 0) return error.InvalidStorage;
            break :blk 0;
        } else blk: {
            if (children_storage.len % records.len != 0) return error.InvalidStorage;
            break :blk children_storage.len / records.len;
        };

        for (records) |*record| record.* = .{};
        return .{
            .records = records,
            .children_storage = children_storage,
            .children_per_node = children_per_node,
        };
    }

    pub fn capacity(self: *const RetainedStore) usize {
        return self.records.len;
    }

    pub fn len(self: *const RetainedStore) usize {
        return self.live_count;
    }

    pub fn childCapacity(self: *const RetainedStore) usize {
        return self.children_per_node;
    }

    /// Create a node in the first free slot and return its generational ID.
    pub fn create(self: *RetainedStore, style_value: Style) Error!NodeId {
        for (self.records, 0..) |*record, index| {
            if (record.live) continue;
            const generation = if (record.generation == 0) 1 else record.generation;
            record.* = .{
                .generation = generation,
                .live = true,
                .style = style_value,
            };
            self.live_count += 1;
            return .{ .index = @intCast(index), .generation = generation };
        }
        return error.NodeCapacityExceeded;
    }

    /// Return a value snapshot. The returned record has no borrowed pointer.
    pub fn get(self: *const RetainedStore, id: NodeId) Error!NodeRecord {
        return self.records[try self.indexFor(id)];
    }

    /// Nullable lookup convenience for callers treating a stale ID as absent.
    pub fn lookup(self: *const RetainedStore, id: NodeId) ?NodeRecord {
        const index = self.indexFor(id) catch return null;
        return self.records[index];
    }

    pub fn contains(self: *const RetainedStore, id: NodeId) bool {
        if (self.indexFor(id)) |_| return true else |_| return false;
    }

    pub fn style(self: *const RetainedStore, id: NodeId) Error!Style {
        return (try self.get(id)).style;
    }

    pub fn layout(self: *const RetainedStore, id: NodeId) Error!Layout {
        return (try self.get(id)).layout;
    }

    pub fn parent(self: *const RetainedStore, id: NodeId) Error!?NodeId {
        return (try self.get(id)).parent;
    }

    /// Return the live child prefix in the caller-owned child backing slice.
    pub fn children(self: *const RetainedStore, id: NodeId) Error![]const NodeId {
        const index = try self.indexFor(id);
        const record = self.records[index];
        return self.childBucket(index)[0..record.child_count];
    }

    pub fn childCount(self: *const RetainedStore, id: NodeId) Error!usize {
        return (try self.get(id)).child_count;
    }

    pub fn childAt(self: *const RetainedStore, id: NodeId, child_index: usize) Error!NodeId {
        const child_list = try self.children(id);
        if (child_index >= child_list.len) return error.ChildNotFound;
        return child_list[child_index];
    }

    /// Update only the fields supplied by the caller. Node identity and tree
    /// topology cannot be changed accidentally through this operation.
    pub fn update(self: *RetainedStore, id: NodeId, change: Update) Error!void {
        const record = &self.records[try self.indexFor(id)];
        if (change.style) |style_value| record.style = style_value;
        if (change.layout) |layout_value| record.layout = layout_value;
    }

    pub fn setStyle(self: *RetainedStore, id: NodeId, style_value: Style) Error!void {
        try self.update(id, .{ .style = style_value });
    }

    pub fn setLayout(self: *RetainedStore, id: NodeId, layout_value: Layout) Error!void {
        try self.update(id, .{ .layout = layout_value });
    }

    pub fn appendChild(self: *RetainedStore, parent_id: NodeId, child_id: NodeId) Error!void {
        if (sameId(parent_id, child_id)) return error.ChildAlreadyAttached;
        const parent_index = try self.indexFor(parent_id);
        const child_index = try self.indexFor(child_id);
        if (self.records[child_index].parent != null) return error.ChildAlreadyAttached;
        if (self.records[parent_index].child_count >= self.children_per_node) {
            return error.ChildCapacityExceeded;
        }

        // A detached child may not be attached below one of its descendants.
        var ancestor: ?NodeId = parent_id;
        while (ancestor) |ancestor_id| {
            if (sameId(ancestor_id, child_id)) return error.ChildAlreadyAttached;
            ancestor = self.records[try self.indexFor(ancestor_id)].parent;
        }

        const parent_record = &self.records[parent_index];
        self.childBucket(parent_index)[parent_record.child_count] = child_id;
        parent_record.child_count += 1;
        self.records[child_index].parent = parent_id;
    }

    pub fn removeChild(self: *RetainedStore, parent_id: NodeId, child_id: NodeId) Error!void {
        const parent_index = try self.indexFor(parent_id);
        const child_index = try self.indexFor(child_id);
        const parent_record = &self.records[parent_index];
        const child_list = self.childBucket(parent_index)[0..parent_record.child_count];
        var found: ?usize = null;
        for (child_list, 0..) |candidate, index| {
            if (sameId(candidate, child_id)) {
                found = index;
                break;
            }
        }
        const index = found orelse return error.ChildNotFound;
        if (self.records[child_index].parent == null or
            !sameId(self.records[child_index].parent.?, parent_id))
        {
            return error.ChildNotFound;
        }

        const last = parent_record.child_count - 1;
        if (index < last) {
            std.mem.copyForwards(
                NodeId,
                self.childBucket(parent_index)[index..last],
                self.childBucket(parent_index)[index + 1 .. parent_record.child_count],
            );
        }
        parent_record.child_count = last;
        self.records[child_index].parent = null;
    }

    /// Destroy a subtree, invalidating every ID in it.
    pub fn destroy(self: *RetainedStore, id: NodeId) Error!void {
        _ = try self.indexFor(id);
        try self.destroyInternal(id);
    }

    /// Invalidate every live ID and return the store to an empty state.
    pub fn clear(self: *RetainedStore) void {
        for (self.records) |*record| {
            if (record.live) record.generation = nextGeneration(record.generation);
            record.live = false;
            record.parent = null;
            record.child_count = 0;
        }
        self.live_count = 0;
    }

    fn destroyInternal(self: *RetainedStore, id: NodeId) Error!void {
        const index = try self.indexFor(id);
        const parent_id = self.records[index].parent;
        if (parent_id) |parent_value| try self.removeChild(parent_value, id);

        while (self.records[index].child_count != 0) {
            const last = self.records[index].child_count - 1;
            const child_id = self.childBucket(index)[last];
            try self.destroyInternal(child_id);
        }

        const record = &self.records[index];
        record.live = false;
        record.parent = null;
        record.child_count = 0;
        record.generation = nextGeneration(record.generation);
        self.live_count -= 1;
    }

    fn childBucket(self: *const RetainedStore, index: usize) []NodeId {
        const start = index * self.children_per_node;
        return self.children_storage[start .. start + self.children_per_node];
    }

    fn indexFor(self: *const RetainedStore, id: NodeId) Error!usize {
        if (id.index >= self.records.len) return error.StaleNodeId;
        const index: usize = @intCast(id.index);
        const record = self.records[index];
        if (!record.live or record.generation != id.generation) return error.StaleNodeId;
        return index;
    }

    fn sameId(left: NodeId, right: NodeId) bool {
        return left.index == right.index and left.generation == right.generation;
    }

    fn nextGeneration(generation: u32) u32 {
        return if (generation == std.math.maxInt(u32)) 1 else generation + 1;
    }
};

// `Store` is the concise spelling used by callers that only need one retained
// storage instance; the descriptive name remains the canonical declaration.
pub const Store = RetainedStore;

test "caller-owned records support create lookup and update" {
    var records: [2]NodeRecord = undefined;
    var children_storage: [4]NodeId = undefined;
    var store = try RetainedStore.init(&records, &children_storage);

    const first = try store.create(.{ .width = .{ .length = 20 } });
    const second = try store.create(.{});
    try std.testing.expectEqual(@as(usize, 2), store.len());
    try std.testing.expectEqual(@as(usize, 2), store.capacity());
    try std.testing.expectEqual(@as(usize, 2), store.childCapacity());
    try std.testing.expectEqual(@as(f32, 20), (try store.style(first)).width.length);

    const replacement = Style{ .display = .grid };
    const box = Layout{ .x = 4, .y = 5, .width = 6, .height = 7 };
    try store.update(first, .{ .style = replacement, .layout = box });
    try std.testing.expectEqual(replacement, records[first.index].style);
    try std.testing.expectEqual(box, records[first.index].layout);
    try std.testing.expectEqual(replacement, try store.style(first));
    try std.testing.expectEqual(box, try store.layout(first));
    try std.testing.expect((try store.get(second)).parent == null);
}

test "children are caller-owned and bounded" {
    var records: [3]NodeRecord = undefined;
    var children_storage: [3]NodeId = undefined;
    var store = try RetainedStore.init(&records, &children_storage);
    const parent_id = try store.create(.{});
    const first_child = try store.create(.{});
    const second_child = try store.create(.{});

    try store.appendChild(parent_id, first_child);
    try std.testing.expectEqual(first_child, children_storage[parent_id.index]);
    try std.testing.expectEqual(@as(usize, 1), (try store.children(parent_id)).len);
    try std.testing.expectError(error.ChildCapacityExceeded, store.appendChild(parent_id, second_child));
    try std.testing.expectEqual(parent_id, (try store.parent(first_child)).?);
    try store.removeChild(parent_id, first_child);
    try std.testing.expectEqual(@as(usize, 0), (try store.children(parent_id)).len);
}

test "destroyed IDs become stale and slots are reusable with new generations" {
    var records: [1]NodeRecord = undefined;
    var children_storage: [1]NodeId = undefined;
    var store = try RetainedStore.init(&records, &children_storage);
    const old_id = try store.create(.{});
    try store.destroy(old_id);
    try std.testing.expectEqual(@as(usize, 0), store.len());
    try std.testing.expectError(error.StaleNodeId, store.get(old_id));
    try std.testing.expect(store.lookup(old_id) == null);

    const new_id = try store.create(.{});
    try std.testing.expectEqual(old_id.index, new_id.index);
    try std.testing.expect(old_id.generation != new_id.generation);
}

test "node and child capacities are explicit" {
    var records: [1]NodeRecord = undefined;
    var children_storage: [1]NodeId = undefined;
    var store = try RetainedStore.init(&records, &children_storage);
    const only = try store.create(.{});
    try std.testing.expectError(error.NodeCapacityExceeded, store.create(.{}));
    try std.testing.expectError(error.StaleNodeId, store.appendChild(NodeId.invalid, only));

    var invalid_records: [2]NodeRecord = undefined;
    var invalid_children: [1]NodeId = undefined;
    try std.testing.expectError(error.InvalidStorage, RetainedStore.init(&invalid_records, &invalid_children));
}
