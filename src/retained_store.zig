//! Fixed-capacity retained node storage for ECS-style callers.
//!
//! `RetainedStore` borrows both slices supplied at initialization. The records
//! slice is the node table; the children slice is divided into one fixed-size
//! bucket per record. No allocator, pointer, or hidden ownership is involved.
//! IDs contain a slot index and generation, so a destroyed node cannot be
//! addressed through an older ID. `StoreSolver` mirrors topology into the
//! retained layout engine and writes computed boxes back into this storage.

const std = @import("std");
const retained_layout = @import("retained_layout.zig");

pub const NodeId = retained_layout.NodeId;
pub const Style = retained_layout.Style;
pub const Layout = retained_layout.Layout;
pub const Dimensions = retained_layout.Dimensions;
pub const LayoutOptions = retained_layout.Options;
pub const LayoutError = retained_layout.Error;

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
/// backing table and remains caller-owned. `generation`, `live`, and
/// `style_revision` are managed by the store and must not be changed directly.
/// Styles must be changed through `setStyle` or `update` so persistent solvers
/// observe the mutation.
pub const NodeRecord = struct {
    generation: u32 = 1,
    live: bool = false,
    style: Style = .{},
    style_revision: u64 = 1,
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
        if (change.style) |style_value| {
            record.style = style_value;
            record.style_revision = nextRevision(record.style_revision);
        }
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
        const outer_parent = (try self.get(id)).parent;
        if (outer_parent) |parent_id| try self.removeChild(parent_id, id);

        var current = id;
        while (true) {
            const index = try self.indexFor(current);
            if (self.records[index].child_count != 0) {
                const last = self.records[index].child_count - 1;
                current = self.childBucket(index)[last];
                continue;
            }

            const parent_id = self.records[index].parent;
            if (parent_id) |parent_value| try self.removeChild(parent_value, current);
            const finished = sameId(current, id);
            const record = &self.records[index];
            record.live = false;
            record.parent = null;
            record.child_count = 0;
            record.generation = nextGeneration(record.generation);
            self.live_count -= 1;
            if (finished) break;
            current = parent_id orelse return error.ChildNotFound;
        }
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

    fn nextRevision(revision: u64) u64 {
        return if (revision == std.math.maxInt(u64)) 1 else revision + 1;
    }
};

// `Store` is the concise spelling used by callers that only need one retained
// storage instance; the descriptive name remains the canonical declaration.
pub const Store = RetainedStore;

/// Persistent solver bridge for caller-owned `RetainedStore` records.
///
/// `mirror_ids` is caller-owned mapping storage with one entry per record.
/// The internal layout tree, style revisions, topology, and traversal scratch
/// persist across computes. Stable records are not copied or marked dirty;
/// changed parent lists alone are rebuilt. Results are written by one bounded
/// traversal of the requested store subtree.
pub const StoreSolver = struct {
    const SyncState = struct {
        generation: u32 = 0,
        style_revision: u64 = 0,
    };

    pub const SyncStats = struct {
        style_updates: usize = 0,
        rebuilt_parents: usize = 0,
        written_nodes: usize = 0,
    };

    allocator: std.mem.Allocator,
    tree: retained_layout.LayoutTree,
    mirror_ids: []NodeId,
    sync_states: []SyncState,
    index_scratch: []usize,
    stats: SyncStats = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        mirror_ids: []NodeId,
        options: LayoutOptions,
    ) LayoutError!StoreSolver {
        const sync_states = allocator.alloc(SyncState, mirror_ids.len) catch return error.OutOfMemory;
        errdefer allocator.free(sync_states);
        @memset(sync_states, .{});
        const index_scratch = allocator.alloc(usize, mirror_ids.len) catch return error.OutOfMemory;
        errdefer allocator.free(index_scratch);

        var normalized = options;
        normalized.max_nodes = mirror_ids.len;
        var result = StoreSolver{
            .allocator = allocator,
            .tree = retained_layout.LayoutTree.init(allocator, normalized),
            .mirror_ids = mirror_ids,
            .sync_states = sync_states,
            .index_scratch = index_scratch,
        };
        errdefer result.tree.deinit();
        for (mirror_ids) |*mirror_id| {
            mirror_id.* = try result.tree.create(.{ .display = .none });
        }
        return result;
    }

    pub fn deinit(self: *StoreSolver) void {
        self.tree.deinit();
        self.allocator.free(self.index_scratch);
        self.allocator.free(self.sync_states);
        self.* = undefined;
    }

    pub fn lastSyncStats(self: *const StoreSolver) SyncStats {
        return self.stats;
    }

    pub fn compute(
        self: *StoreSolver,
        store: *RetainedStore,
        root_id: NodeId,
        available: Dimensions,
    ) (Error || LayoutError)!void {
        if (store.records.len != self.mirror_ids.len) return error.InvalidStorage;
        const root_index = try store.indexFor(root_id);
        self.stats = .{};

        try self.syncStyles(store);
        try self.syncTopology(store);
        try self.tree.computeDirtySubtree(self.mirror_ids[root_index], available);
        try self.writeSubtree(store, root_index);
    }

    fn syncStyles(self: *StoreSolver, store: *const RetainedStore) LayoutError!void {
        for (store.records, 0..) |record, index| {
            const state = &self.sync_states[index];
            if (!record.live) {
                if (state.generation != 0) {
                    try self.tree.setStyle(self.mirror_ids[index], .{ .display = .none });
                    state.* = .{};
                    self.stats.style_updates += 1;
                }
                continue;
            }
            if (state.generation == record.generation and
                state.style_revision == record.style_revision)
            {
                continue;
            }
            try self.tree.setStyle(self.mirror_ids[index], record.style);
            state.* = .{
                .generation = record.generation,
                .style_revision = record.style_revision,
            };
            self.stats.style_updates += 1;
        }
    }

    fn syncTopology(self: *StoreSolver, store: *const RetainedStore) (Error || LayoutError)!void {
        var changed_count: usize = 0;
        for (store.records, 0..) |record, index| {
            if (try self.topologyMatches(store, record, index)) continue;
            self.index_scratch[changed_count] = index;
            changed_count += 1;
        }

        for (self.index_scratch[0..changed_count]) |index| {
            const mirror_parent = self.mirror_ids[index];
            while (try self.tree.childCount(mirror_parent) != 0) {
                const last = try self.tree.childCount(mirror_parent) - 1;
                try self.tree.removeChild(
                    mirror_parent,
                    try self.tree.childAt(mirror_parent, last),
                );
            }
        }
        for (self.index_scratch[0..changed_count]) |index| {
            const record = store.records[index];
            if (!record.live) continue;
            for (store.childBucket(index)[0..record.child_count]) |child_id| {
                const child_index = try store.indexFor(child_id);
                try self.tree.appendChild(self.mirror_ids[index], self.mirror_ids[child_index]);
            }
        }
        self.stats.rebuilt_parents = changed_count;
    }

    fn topologyMatches(
        self: *const StoreSolver,
        store: *const RetainedStore,
        record: NodeRecord,
        index: usize,
    ) (Error || LayoutError)!bool {
        const desired_count = if (record.live) record.child_count else 0;
        if (try self.tree.childCount(self.mirror_ids[index]) != desired_count) return false;
        if (!record.live) return true;
        for (store.childBucket(index)[0..record.child_count], 0..) |child_id, child_index| {
            const store_child_index = try store.indexFor(child_id);
            const mirror_child = try self.tree.childAt(self.mirror_ids[index], child_index);
            if (!RetainedStore.sameId(mirror_child, self.mirror_ids[store_child_index])) return false;
        }
        return true;
    }

    fn writeSubtree(
        self: *StoreSolver,
        store: *RetainedStore,
        root_index: usize,
    ) (Error || LayoutError)!void {
        var stack_count: usize = 1;
        self.index_scratch[0] = root_index;
        while (stack_count != 0) {
            stack_count -= 1;
            const index = self.index_scratch[stack_count];
            store.records[index].layout = try self.tree.readLayout(self.mirror_ids[index]);
            self.stats.written_nodes += 1;
            const record = store.records[index];
            for (store.childBucket(index)[0..record.child_count]) |child_id| {
                const child_index = try store.indexFor(child_id);
                self.index_scratch[stack_count] = child_index;
                stack_count += 1;
            }
        }
    }
};

test "store solver writes layouts back from caller-owned topology" {
    var records: [4]NodeRecord = undefined;
    var children_storage: [16]NodeId = undefined;
    var store = try RetainedStore.init(&records, &children_storage);
    const root = try store.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 50 },
    });
    const first = try store.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    });
    const second = try store.create(.{
        .width = .{ .length = 30 },
        .height = .{ .length = 12 },
    });
    const unrelated = try store.create(.{});
    try store.appendChild(root, first);
    try store.appendChild(root, second);
    try store.setLayout(unrelated, .{ .x = 777 });

    var mirror_ids: [4]NodeId = undefined;
    var solver = try StoreSolver.init(
        std.testing.allocator,
        &mirror_ids,
        .{ .max_children_per_node = 4 },
    );
    defer solver.deinit();
    try solver.compute(&store, root, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(StoreSolver.SyncStats{
        .style_updates = 4,
        .rebuilt_parents = 1,
        .written_nodes = 3,
    }, solver.lastSyncStats());
    try std.testing.expectEqual(Layout{ .width = 100, .height = 50 }, try store.layout(root));
    try std.testing.expectEqual(Layout{ .width = 20, .height = 10 }, try store.layout(first));
    try std.testing.expectEqual(Layout{ .x = 20, .width = 30, .height = 12 }, try store.layout(second));
    try std.testing.expectEqual(@as(f32, 777), (try store.layout(unrelated)).x);

    try solver.compute(&store, root, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(StoreSolver.SyncStats{
        .written_nodes = 3,
    }, solver.lastSyncStats());

    try store.setStyle(root, .{
        .width = .{ .length = 100 },
        .height = .{ .length = 50 },
        .flex_direction = .column,
    });
    try solver.compute(&store, root, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(StoreSolver.SyncStats{
        .style_updates = 1,
        .written_nodes = 3,
    }, solver.lastSyncStats());
    try std.testing.expectEqual(Layout{ .y = 10, .width = 30, .height = 12 }, try store.layout(second));
}

test "store solver rebuilds only changed parent topology" {
    var records: [4]NodeRecord = undefined;
    var children_storage: [16]NodeId = undefined;
    var store = try RetainedStore.init(&records, &children_storage);
    const root = try store.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
    });
    const left = try store.create(.{
        .width = .{ .length = 40 },
        .height = .{ .length = 20 },
    });
    const right = try store.create(.{
        .width = .{ .length = 40 },
        .height = .{ .length = 20 },
    });
    const item = try store.create(.{
        .width = .{ .length = 10 },
        .height = .{ .length = 10 },
    });
    try store.appendChild(root, left);
    try store.appendChild(root, right);
    try store.appendChild(left, item);

    var mirror_ids: [4]NodeId = undefined;
    var solver = try StoreSolver.init(
        std.testing.allocator,
        &mirror_ids,
        .{ .max_children_per_node = 4 },
    );
    defer solver.deinit();
    try solver.compute(&store, root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(f32, 0), (try store.layout(item)).x);
    try std.testing.expectEqual(@as(usize, 2), solver.lastSyncStats().rebuilt_parents);

    try store.removeChild(left, item);
    try store.appendChild(right, item);
    try solver.compute(&store, root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(f32, 40), (try store.layout(item)).x);
    try std.testing.expectEqual(StoreSolver.SyncStats{
        .rebuilt_parents = 2,
        .written_nodes = 4,
    }, solver.lastSyncStats());
}

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
