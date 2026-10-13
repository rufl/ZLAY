//! Small retained layout tree for renderer-agnostic UI foundations.
//!
//! This module intentionally implements a bounded flex and grid subset:
//! row/column flex containers, explicit and implicit grid tracks, sparse/dense
//! grid auto-placement, `display: none`, opposing-inset absolute sizing,
//! intrinsic and explicit content sizing, finite typed gaps, padding, margins,
//! and aligned overlay/grid children with auto margins. There is no
//! text-specific measurement, block layout, or CSS parser. An optional
//! caller-supplied intrinsic measurement callback provides
//! finite dimensions for content-sized leaf nodes.
//! Layout is computed synchronously into caller-owned tree storage; no scratch
//! allocation is needed by compute.

const std = @import("std");
pub const Error = error{
    OutOfMemory,
    NodeCapacityExceeded,
    ChildCapacityExceeded,
    GridTrackCapacityExceeded,
    TreeDepthExceeded,
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
pub const FlexDirection = enum { row, row_reverse, column, column_reverse };
pub const Direction = enum { ltr, rtl };
pub const FlexWrap = enum { nowrap, wrap, wrap_reverse };
/// Sparse or hole-backfilling dense automatic placement by row or column.
pub const GridAutoFlow = enum { row, column, row_dense, column_dense };
pub const AlignItems = enum { stretch, flex_start, flex_end, center, baseline };
pub const AlignSelf = enum { auto, stretch, flex_start, flex_end, center, baseline };
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
pub const AlignContent = enum { stretch, flex_start, flex_end, center, space_between, space_around, space_evenly };
pub const Overflow = enum { visible, clip };
pub const HitTestBehavior = enum { enabled, children_only, disabled };

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

fn alignmentHorizontalFraction(alignment: Alignment, direction: Direction) f32 {
    const fraction = alignmentFractions(alignment).x;
    return if (direction == .rtl) 1 - fraction else fraction;
}

fn flexIsRow(direction: FlexDirection) bool {
    return direction == .row or direction == .row_reverse;
}

fn flexIsReverse(direction: FlexDirection) bool {
    return direction == .row_reverse or direction == .column_reverse;
}

fn effectiveRowDirection(direction: FlexDirection, text_direction: Direction) Direction {
    if (!flexIsReverse(direction)) return text_direction;
    return if (text_direction == .ltr) .rtl else .ltr;
}

fn gridFlowIsRow(flow: GridAutoFlow) bool {
    return flow == .row or flow == .row_dense;
}

fn gridFlowIsDense(flow: GridAutoFlow) bool {
    return flow == .row_dense or flow == .column_dense;
}

fn gridAxisOffset(free_space: f32, before_auto: bool, after_auto: bool, alignment: f32) f32 {
    if (before_auto and after_auto) return free_space * 0.5;
    if (before_auto) return free_space;
    if (after_auto) return 0;
    return free_space * alignment;
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

/// One explicit grid track. `fixed` is pixels; `auto` uses bounded intrinsic
/// child dimensions when available; `fr` receives a share of the space left
/// after fixed/auto tracks and gaps; `minmax` is a unit-weight flexible track
/// clamped to its finite bounds.
pub const GridTrackBounds = struct {
    min: f32,
    max: f32,
};
pub const GridTrack = union(enum) {
    fixed: f32,
    auto,
    fr: f32,
    bounded: GridTrackBounds,

    pub fn fixedPx(value: f32) GridTrack {
        return .{ .fixed = value };
    }

    pub fn autoSized() GridTrack {
        return .auto;
    }

    pub fn fractional(value: f32) GridTrack {
        return .{ .fr = value };
    }

    /// Creates a unit-weight flexible track with an inclusive finite range.
    /// Invalid bounds are rejected before a track can be used in a Style.
    pub fn minmax(minimum: f32, maximum: f32) Error!GridTrack {
        if (!finite(minimum) or !finite(maximum) or minimum < 0 or maximum < minimum) {
            return error.InvalidStyle;
        }
        return .{ .bounded = .{ .min = minimum, .max = maximum } };
    }
};
pub const Dimension = union(enum) {
    min_content,
    max_content,
    fit_content,
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
/// A flex gap specification. `fixed` accepts finite negative overlap;
/// `percent` is a non-negative fraction of the containing content axis;
/// `stretch` receives the remaining axis space.
pub const Gap = union(enum) {
    fixed: f32,
    percent: f32,
    stretch: f32,

    pub fn fixedPx(value: f32) Gap {
        return .{ .fixed = value };
    }

    pub fn percentOfParent(value: f32) Gap {
        return .{ .percent = value };
    }

    pub fn stretchFactor(value: f32) Gap {
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

/// A responsive edge length. Percentages are fractions of the containing axis.
pub const EdgeSize = union(enum) {
    fixed: f32,
    percent: f32,

    pub fn fixedPx(value: f32) EdgeSize {
        return .{ .fixed = value };
    }

    pub fn percentOfParent(value: f32) EdgeSize {
        return .{ .percent = value };
    }
};

/// Optional per-edge overrides for the fixed `padding` or `margin` fallback.
pub const ResponsiveEdges = struct {
    top: ?EdgeSize = null,
    right: ?EdgeSize = null,
    bottom: ?EdgeSize = null,
    left: ?EdgeSize = null,

    pub fn all(value: EdgeSize) ResponsiveEdges {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
};
pub const AutoEdges = struct {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
};

pub const Style = struct {
    display: Display = .flex,
    position: Position = .relative,
    flex_direction: FlexDirection = .row,
    direction: Direction = .ltr,
    flex_wrap: FlexWrap = .nowrap,
    align_items: AlignItems = .flex_start,
    align_self: AlignSelf = .auto,
    /// Higher values win overlapping retained hit tests; ties prefer depth.
    hit_test_priority: i32 = 0,
    /// Controls whether this node itself can be returned by `hitTest`.
    hit_test_behavior: HitTestBehavior = .enabled,
    /// Lower values participate earlier in layout; equal values preserve insertion order.
    order: i32 = 0,
    /// Logical anchor used by relative children of overlay and grid parents.
    /// Horizontal start/end positions follow the parent's text direction.
    alignment: Alignment = .top_left,
    justify_content: JustifyContent = .flex_start,
    align_content: AlignContent = .flex_start,
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
    /// Responsive edge overrides resolved against the containing width/height.
    padding_spec: ?ResponsiveEdges = null,
    margin_spec: ?ResponsiveEdges = null,
    auto_margin: AutoEdges = .{},
    /// Baseline offset from the node's top edge. Null uses its bottom edge.
    baseline: ?f32 = null,
    flex_grow: f32 = 0,
    /// Zero preserves the original no-shrink behavior; set nonzero for flex shrinking.
    flex_shrink: f32 = 0,
    flex_basis: Dimension = .auto,
    aspect_ratio: ?f32 = null,
    overflow: Overflow = .visible,
    /// Caller-controlled content translation for clipped scroll containers.
    scroll_offset: Point = .{},
    grid_columns: []const GridTrack = &.{},
    grid_rows: []const GridTrack = &.{},
    grid_column_gap: f32 = 0,
    grid_row_gap: f32 = 0,
    grid_gap: f32 = 0,
    grid_auto_flow: GridAutoFlow = .row,
    grid_auto_columns: GridTrack = .auto,
    grid_auto_rows: GridTrack = .auto,
    /// Minimum spacing between flex items and between wrapped lines.
    flex_gap: f32 = 0,
    /// Optional typed flex gap. When set, this takes precedence over `flex_gap`.
    flex_gap_spec: ?Gap = null,
    /// Optional lower and upper bounds for the typed flex gap.
    min_flex_gap_spec: ?Gap = null,
    max_flex_gap_spec: ?Gap = null,
    /// Axis-specific typed gaps. These override `flex_gap_spec` for flex
    /// containers and the corresponding numeric grid gap for grids.
    column_gap_spec: ?Gap = null,
    row_gap_spec: ?Gap = null,
    min_column_gap_spec: ?Gap = null,
    max_column_gap_spec: ?Gap = null,
    min_row_gap_spec: ?Gap = null,
    max_row_gap_spec: ?Gap = null,
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

/// Supplies one intrinsic minimum, preferred, and maximum size for an auto-sized leaf.
pub const IntrinsicDimensions = struct {
    min: Dimensions = .{},
    preferred: Dimensions = .{},
    max: Dimensions = .{},
};

/// Supplies intrinsic dimensions for an auto-sized leaf. `available` is the
/// containing block's size at the leaf's layout position.
pub const IntrinsicMeasureFunction = *const fn (NodeId, Dimensions, ?*anyopaque) Dimensions;

/// Supplies intrinsic size tiers for an auto-sized leaf. Each axis must satisfy
/// `min <= preferred <= max`.
pub const IntrinsicMeasureTiersFunction = *const fn (NodeId, Dimensions, ?*anyopaque) IntrinsicDimensions;

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

/// Hard ceiling for allocation-free grid track scratch.
pub const max_supported_grid_tracks: usize = 256;
/// Hard ceiling for recursive layout descent. Hidden-node and destruction
/// traversals are iterative and do not consume call-stack depth.
pub const max_supported_tree_depth: usize = 256;

pub const Options = struct {
    max_nodes: usize = 256,
    max_children_per_node: usize = 64,
    max_depth: usize = max_supported_tree_depth,
    max_grid_tracks: usize = 16,
};
const GridPlacement = struct {
    column: usize,
    row: usize,
    column_span: usize,
    row_span: usize,
};
const GridTrackCounts = struct {
    columns: usize,
    rows: usize,
};

const Node = struct {
    style: Style,
    parent: ?NodeId = null,
    children: std.ArrayList(NodeId) = .empty,
    layout: Layout = .{},
    grid_placement: ?GridPlacement = null,
    intrinsic_measurement: ?Dimensions = null,
    intrinsic_tiers: ?IntrinsicDimensions = null,
    flex_base: f32 = 0,
    flex_size: f32 = 0,
    flex_frozen: bool = false,
    dirty: bool = true,
    has_computed_layout: bool = false,
    last_origin: Point = .{},
    last_containing: Dimensions = .{},
    last_forced_size: ?Dimensions = null,
    last_is_root: bool = false,
    last_inherited_clip: ?ClipRect = null,
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
    incremental: bool = false,

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

    /// Updates only the scroll translation and invalidates dependent layout.
    pub fn setScrollOffset(self: *LayoutTree, id: NodeId, offset: Point) Error!void {
        if (!finite(offset.x) or offset.x < 0 or !finite(offset.y) or offset.y < 0) {
            return error.InvalidStyle;
        }
        const node_ref = try self.nodeAt(id);
        node_ref.style.scroll_offset = offset;
        self.markDirty(id);
    }

    pub fn setHitTestBehavior(self: *LayoutTree, id: NodeId, behavior: HitTestBehavior) Error!void {
        if (@backingInt(behavior) >= 3) return error.InvalidStyle;
        const node_ref = try self.nodeAt(id);
        node_ref.style.hit_test_behavior = behavior;
        self.markDirty(id);
    }

    pub fn setHitTestPriority(self: *LayoutTree, id: NodeId, priority: i32) Error!void {
        const node_ref = try self.nodeAt(id);
        node_ref.style.hit_test_priority = priority;
        self.markDirty(id);
    }

    pub fn setOrder(self: *LayoutTree, id: NodeId, order: i32) Error!void {
        const node_ref = try self.nodeAt(id);
        node_ref.style.order = order;
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
        try self.computeInternal(root_id, available, false, null, null);
    }

    /// Recomputes only dirty branches whose cached inputs remain valid.
    ///
    /// Dirty state propagates to ancestors, so dependency-bearing containers
    /// are revisited. Clean siblings are skipped when their origin, containing
    /// dimensions, forced size, root status, and inherited clip are unchanged.
    /// A changed dependency invalidates that cache and recomputes the sibling.
    pub fn computeDirty(self: *LayoutTree, dirty_id: NodeId, available: Dimensions) Error!void {
        const root_id = try self.topmostAncestor(dirty_id);
        try self.computeInternal(root_id, available, true, null, null);
    }

    /// Recomputes a caller-selected subtree while preserving clean cached
    /// descendants whose layout inputs are unchanged.
    pub fn computeDirtySubtree(
        self: *LayoutTree,
        root_id: NodeId,
        available: Dimensions,
    ) Error!void {
        try self.computeInternal(root_id, available, true, null, null);
    }

    /// Dirty-subtree recomputation with intrinsic leaf measurement.
    pub fn computeDirtyWithMeasure(
        self: *LayoutTree,
        dirty_id: NodeId,
        available: Dimensions,
        measure: IntrinsicMeasureFunction,
        user_data: ?*anyopaque,
    ) Error!void {
        const root_id = try self.topmostAncestor(dirty_id);
        try self.computeInternal(root_id, available, true, measure, user_data);
    }

    /// Compute layout using caller-supplied intrinsic minimum, preferred, and
    /// maximum dimensions for auto-sized leaf nodes.
    pub fn computeWithMeasureTiers(
        self: *LayoutTree,
        root_id: NodeId,
        available: Dimensions,
        measure: IntrinsicMeasureTiersFunction,
        user_data: ?*anyopaque,
    ) Error!void {
        try validateDimensions(available);
        _ = try self.nodeAt(root_id);
        var adapter = TierMeasureAdapter{
            .tree = self,
            .measure = measure,
            .user_data = user_data,
        };
        self.computeNode(root_id, .{}, available, null, true, null, measureIntrinsicTiers, &adapter) catch |err| return err;
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
        try self.computeInternal(root_id, available, false, measure, user_data);
    }

    pub fn readLayout(self: *const LayoutTree, id: NodeId) Error!Layout {
        return (try self.nodeConstAt(id)).layout;
    }

    /// Returns the deepest visible descendant of `root_id` containing `point`.
    /// Node traversal is allocation-free; ancestor clips are already folded into
    /// each computed layout's `clip` rectangle.
    pub fn hitTest(self: *const LayoutTree, root_id: NodeId, point: Point) Error!?NodeId {
        _ = try self.nodeConstAt(root_id);
        var result: ?NodeId = null;
        var result_depth: usize = 0;
        var result_priority: i32 = std.math.minInt(i32);
        var slot_index: usize = 0;
        while (slot_index < self.slots.items.len) : (slot_index += 1) {
            const slot_entry = self.slots.items[slot_index];
            const node = slot_entry.node orelse continue;
            const candidate = NodeId{ .index = @intCast(slot_index), .generation = slot_entry.generation };
            if (node.style.display == .none or
                node.style.hit_test_behavior != .enabled or
                !containsLayoutPoint(node.layout, point) or
                !isDescendantOf(self, candidate, root_id))
            {
                continue;
            }
            const depth = depthFrom(self, candidate, root_id) catch continue;
            const better = if (result == null)
                true
            else if (node.style.hit_test_priority != result_priority)
                node.style.hit_test_priority > result_priority
            else if (depth != result_depth)
                depth > result_depth
            else
                isPaintedAfter(self, candidate, result.?);
            if (better) {
                result = candidate;
                result_depth = depth;
                result_priority = node.style.hit_test_priority;
            }
        }
        return result;
    }

    /// Returns the renderer-neutral clip region effective for this node.
    pub fn readClip(self: *const LayoutTree, id: NodeId) Error!?ClipRect {
        return (try self.nodeConstAt(id)).layout.clip;
    }

    pub fn getLayout(self: *const LayoutTree, id: NodeId) Error!Layout {
        return self.readLayout(id);
    }

    fn topmostAncestor(self: *const LayoutTree, id: NodeId) Error!NodeId {
        var root_id = id;
        while ((try self.nodeConstAt(root_id)).parent) |parent_id| {
            root_id = parent_id;
        }
        return root_id;
    }

    fn computeInternal(
        self: *LayoutTree,
        root_id: NodeId,
        available: Dimensions,
        incremental: bool,
        measure: ?IntrinsicMeasureFunction,
        measure_user_data: ?*anyopaque,
    ) Error!void {
        try validateDimensions(available);
        _ = try self.nodeAt(root_id);
        const previous_incremental = self.incremental;
        self.incremental = incremental;
        defer self.incremental = previous_incremental;
        try self.computeNode(
            root_id,
            .{},
            available,
            null,
            true,
            null,
            measure,
            measure_user_data,
        );
    }

    fn destroyInternal(self: *LayoutTree, id: NodeId) Error!void {
        const outer_parent = (try self.nodeConstAt(id)).parent;
        if (outer_parent) |parent_id| {
            const parent_node = try self.nodeAt(parent_id);
            var index: ?usize = null;
            for (parent_node.children.items, 0..) |candidate, candidate_index| {
                if (sameId(candidate, id)) {
                    index = candidate_index;
                    break;
                }
            }
            _ = parent_node.children.orderedRemove(index orelse return error.ChildNotFound);
            self.markDirty(parent_id);
            (try self.nodeAt(id)).parent = null;
        }

        var current = id;
        while (true) {
            const child = blk: {
                const node_ref = try self.nodeConstAt(current);
                if (node_ref.children.items.len == 0) break :blk null;
                break :blk node_ref.children.items[node_ref.children.items.len - 1];
            };
            if (child) |child_id| {
                current = child_id;
                continue;
            }

            const parent_id = (try self.nodeConstAt(current)).parent;
            if (parent_id) |parent_id_value| {
                const parent_node = try self.nodeAt(parent_id_value);
                var index: ?usize = null;
                for (parent_node.children.items, 0..) |candidate, candidate_index| {
                    if (sameId(candidate, current)) {
                        index = candidate_index;
                        break;
                    }
                }
                _ = parent_node.children.orderedRemove(index orelse return error.ChildNotFound);
            }

            const finished = sameId(current, id);
            const slot_ref = try self.slotAt(current);
            if (slot_ref.node) |*node_entry| node_entry.children.deinit(self.allocator);
            slot_ref.node = null;
            slot_ref.generation = if (slot_ref.generation == std.math.maxInt(u32)) 1 else slot_ref.generation + 1;
            self.live_count -= 1;
            if (finished) break;
            current = parent_id orelse return error.ChildNotFound;
        }
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
        try self.validateComputeDepth(id);
        const node_ref = try self.nodeAt(id);
        const style_value = resolvedSpacingStyle(node_ref.style, containing);
        const positioned_origin = if (!is_root and style_value.position == .relative)
            relativePositionOrigin(origin, style_value, containing)
        else
            origin;
        if (self.incremental and
            !node_ref.dirty and
            node_ref.has_computed_layout and
            std.meta.eql(node_ref.last_origin, positioned_origin) and
            std.meta.eql(node_ref.last_containing, containing) and
            std.meta.eql(node_ref.last_forced_size, forced_size) and
            node_ref.last_is_root == is_root and
            std.meta.eql(node_ref.last_inherited_clip, inherited_clip))
        {
            return;
        }
        node_ref.has_computed_layout = true;
        node_ref.last_origin = positioned_origin;
        node_ref.last_containing = containing;
        node_ref.last_forced_size = forced_size;
        node_ref.last_is_root = is_root;
        node_ref.last_inherited_clip = inherited_clip;
        if (style_value.display == .none) {
            try self.hideNode(id);
            return;
        }

        try sortChildrenByOrder(self, node_ref);
        const children = node_ref.children.items;
        const supplied_measurement = node_ref.intrinsic_measurement;
        const supplied_tiers = node_ref.intrinsic_tiers;
        node_ref.intrinsic_measurement = null;
        node_ref.intrinsic_tiers = null;
        var intrinsic_measurement = supplied_measurement;
        var intrinsic_tiers = supplied_tiers;
        if (intrinsic_measurement == null and measure != null and children.len == 0 and
            (needsIntrinsicMeasurement(style_value.width) or needsIntrinsicMeasurement(style_value.height)))
        {
            const measured = measure.?(id, containing, measure_user_data);
            try validateDimensions(measured);
            intrinsic_measurement = measured;
            intrinsic_tiers = node_ref.intrinsic_tiers;
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
                needsIntrinsicMeasurement(style_value.width),
                needsIntrinsicMeasurement(style_value.height),
            );
        }
        if (forced_size == null) {
            if (intrinsic_measurement) |measured| {
                size.width = resolveContentDimension(
                    style_value.width,
                    containing.width,
                    size.width,
                    measured,
                    intrinsic_tiers,
                    true,
                );
                size.height = resolveContentDimension(
                    style_value.height,
                    containing.height,
                    size.height,
                    measured,
                    intrinsic_tiers,
                    false,
                );
            }
        }
        size.width = clampDimensionWithIntrinsic(
            size.width,
            style_value.min_width,
            style_value.max_width,
            containing.width,
            intrinsic_tiers,
            forced_size == null and needsIntrinsicMeasurement(style_value.width),
            true,
        );
        size.height = clampDimensionWithIntrinsic(
            size.height,
            style_value.min_height,
            style_value.max_height,
            containing.height,
            intrinsic_tiers,
            forced_size == null and needsIntrinsicMeasurement(style_value.height),
            false,
        );

        const effective_clip = clipForNode(style_value.overflow, inherited_clip, positioned_origin, size);
        node_ref.layout = .{
            .x = positioned_origin.x,
            .y = positioned_origin.y,
            .width = size.width,
            .height = size.height,
            .clip = effective_clip,
        };
        node_ref.dirty = false;
        if (children.len == 0) return;

        const content_origin = Point{
            .x = boundedSubtract(boundedAdd(positioned_origin.x, style_value.padding.left), style_value.scroll_offset.x),
            .y = boundedSubtract(boundedAdd(positioned_origin.y, style_value.padding.top), style_value.scroll_offset.y),
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

        const available_main = if (flexIsRow(style_value.flex_direction)) content_size.width else content_size.height;
        for (children) |child_id| {
            const child_node = try self.nodeAt(child_id);
            const child_style = resolvedSpacingStyle(child_node.style, content_size);
            child_node.flex_frozen = child_style.display == .none or child_style.position == .absolute;
            if (!child_node.flex_frozen and
                (needsIntrinsicMeasurement(child_style.width) or needsIntrinsicMeasurement(child_style.height)))
            {
                if (child_node.children.items.len != 0) {
                    child_node.intrinsic_measurement = try self.preferredNodeSize(
                        child_id,
                        content_size,
                        measure,
                        measure_user_data,
                    );
                } else if (child_node.intrinsic_measurement == null and measure != null) {
                    const measured = measure.?(child_id, content_size, measure_user_data);
                    try validateDimensions(measured);
                    child_node.intrinsic_measurement = measured;
                }
            }
            if (child_node.flex_frozen) continue;
            child_node.flex_base = boundedAdd(
                flexBaseDimension(
                    child_style,
                    style_value.flex_direction,
                    available_main,
                    if (flexIsRow(style_value.flex_direction)) content_size.height else content_size.width,
                    child_node.intrinsic_measurement,
                    child_node.intrinsic_tiers,
                ),
                mainMargin(child_style, style_value.flex_direction),
            );
            child_node.flex_size = child_node.flex_base;
        }
        var flow_count: usize = 0;
        var flow_base: f32 = 0;
        for (children) |child_id| {
            const child_style = resolvedSpacingStyle((try self.nodeConstAt(child_id)).style, content_size);
            if (child_style.display != .none and child_style.position != .absolute) {
                flow_count += 1;
                flow_base = boundedAdd(flow_base, (try self.nodeConstAt(child_id)).flex_base);
            }
        }
        const flex_gap = resolveFlexMainGap(
            style_value,
            available_main,
            flow_base,
            flow_count,
        );
        const flex_gap_total = if (flow_count > 1)
            flex_gap * @as(f32, @floatFromInt(flow_count - 1))
        else
            0;
        if (style_value.flex_wrap != .nowrap) {
            try self.computeFlexWrap(
                id,
                content_origin,
                content_size,
                effective_clip,
                measure,
                measure_user_data,
                flex_gap,
            );
            return;
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
                        child_node.flex_size = clampFlexMain(
                            child_node.flex_base,
                            child_node.style,
                            style_value.flex_direction,
                            available_main,
                            child_node.intrinsic_tiers,
                        );
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
                child_node.flex_size = clampFlexMain(
                    raw,
                    child_node.style,
                    style_value.flex_direction,
                    available_main,
                    child_node.intrinsic_tiers,
                );
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

        var occupied_main: f32 = 0;
        var auto_margin_count: usize = 0;
        for (children) |child_id| {
            const child_style = resolvedSpacingStyle((try self.nodeConstAt(child_id)).style, content_size);
            if (child_style.display == .none or child_style.position == .absolute) continue;
            occupied_main = boundedAdd(occupied_main, (try self.nodeConstAt(child_id)).flex_size);
            auto_margin_count += autoMainMarginCount(child_style, style_value.flex_direction);
        }
        const free_space = @max(boundedSubtract(available_main, boundedAdd(occupied_main, flex_gap_total)), 0);
        const auto_margin_share = if (auto_margin_count == 0)
            0
        else
            free_space / @as(f32, @floatFromInt(auto_margin_count));
        const justify_leading = if (auto_margin_count == 0)
            justifyLeading(style_value.justify_content, free_space, flow_count)
        else
            0;
        const justify_gap = boundedAdd(
            flex_gap,
            if (auto_margin_count == 0) justifyGap(style_value.justify_content, free_space, flow_count) else 0,
        );

        var cursor: f32 = justify_leading;
        const cross_available = if (flexIsRow(style_value.flex_direction)) content_size.height else content_size.width;
        const line_baseline = try self.flexLineBaseline(
            children,
            0,
            children.len,
            content_size,
            style_value.flex_direction,
            style_value.align_items,
        );
        for (children) |child_id| {
            const child_style = resolvedSpacingStyle(try self.style(child_id), content_size);
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
            const resolved_margin = resolvedMainMarginEdges(
                child_style,
                style_value.flex_direction,
                auto_margin_share,
            );
            const box_main_margin = mainMargin(child_style, style_value.flex_direction);
            const resolved_main_margin = marginAlongAxis(resolved_margin, style_value.flex_direction);
            const cross_margin = crossMargin(child_style, style_value.flex_direction);
            const child_align = resolveAlign(child_style.align_self, style_value.align_items);
            var child_width = resolveDimension(child_style.width, content_size.width, 0);
            var child_height = resolveDimension(child_style.height, content_size.height, 0);
            if (flexIsRow(style_value.flex_direction)) {
                child_width = boundedSubtract(child_node.flex_size, box_main_margin);
                if (child_style.height == .auto) {
                    child_height = if (child_align == .stretch)
                        boundedSubtract(cross_available, cross_margin)
                    else if (child_measurement) |measured|
                        measured.height
                    else
                        boundedSubtract(content_size.height, cross_margin);
                }
            } else {
                child_height = boundedSubtract(child_node.flex_size, box_main_margin);
                if (child_style.width == .auto) {
                    child_width = if (child_align == .stretch)
                        boundedSubtract(cross_available, cross_margin)
                    else if (child_measurement) |measured|
                        measured.width
                    else
                        boundedSubtract(content_size.width, cross_margin);
                }
            }
            child_width = clampDimensionWithIntrinsic(
                child_width,
                child_style.min_width,
                child_style.max_width,
                content_size.width,
                child_node.intrinsic_tiers,
                child_style.width == .auto,
                true,
            );
            if (try self.remeasureLeafAtWidth(
                child_id,
                child_style,
                child_width,
                content_size,
                measure,
                measure_user_data,
            )) |remeasured| {
                child_height = remeasured.height;
            }
            child_height = clampDimensionWithIntrinsic(
                child_height,
                child_style.min_height,
                child_style.max_height,
                content_size.height,
                child_node.intrinsic_tiers,
                child_style.height == .auto,
                false,
            );
            const cross_size = if (flexIsRow(style_value.flex_direction)) child_height else child_width;
            const cross_offset = crossAxisOffset(
                child_align,
                cross_available,
                cross_size,
                child_style,
                style_value.flex_direction,
                line_baseline,
            );
            const child_origin = if (flexIsRow(style_value.flex_direction))
                Point{
                    .x = rowChildX(
                        content_origin.x,
                        content_size.width,
                        cursor,
                        child_width,
                        resolved_margin,
                        effectiveRowDirection(style_value.flex_direction, style_value.direction),
                    ),
                    .y = boundedAdd(content_origin.y, cross_offset),
                }
            else
                Point{
                    .x = boundedAdd(content_origin.x, cross_offset),
                    .y = columnChildY(
                        content_origin.y,
                        content_size.height,
                        cursor,
                        child_height,
                        resolved_margin,
                        flexIsReverse(style_value.flex_direction),
                    ),
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
                if (flexIsRow(style_value.flex_direction)) child_layout.width else child_layout.height,
                boundedAdd(resolved_main_margin, justify_gap),
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
        gap: f32,
    ) Error!void {
        const node = try self.nodeConstAt(id);
        const style_value = node.style;
        const children = node.children.items;
        const direction = style_value.flex_direction;
        const available_main = if (flexIsRow(direction)) content_size.width else content_size.height;
        const cross_parent = if (flexIsRow(direction)) content_size.height else content_size.width;
        var line_start: usize = 0;
        var line_count: usize = 0;
        var occupied_cross: f32 = 0;
        var scan_start: usize = 0;
        while (scan_start < children.len) {
            const scan_style = resolvedSpacingStyle((try self.nodeConstAt(children[scan_start])).style, content_size);
            if (scan_style.display == .none or scan_style.position == .absolute) {
                scan_start += 1;
                continue;
            }
            const scan_end = try self.flexLineEnd(children, scan_start, available_main, gap);
            try self.resolveFlexLine(children, scan_start, scan_end, available_main, gap, direction, content_size);
            occupied_cross = boundedAdd(
                occupied_cross,
                try self.flexLineCrossSize(children, scan_start, scan_end, content_size, direction, style_value.align_items),
            );
            line_count += 1;
            scan_start = scan_end;
        }
        const cross_gap = resolveFlexCrossGap(
            style_value,
            cross_parent,
            occupied_cross,
            line_count,
        );
        const total_cross_gap = cross_gap * @as(f32, @floatFromInt(line_count -| 1));
        const free_cross = @max(
            boundedSubtract(cross_parent, boundedAdd(occupied_cross, total_cross_gap)),
            0,
        );
        var cross_cursor = alignContentLeading(style_value.align_content, free_cross, line_count);
        const distributed_cross_gap = boundedAdd(
            cross_gap,
            alignContentGap(style_value.align_content, free_cross, line_count),
        );
        const stretched_line_cross = if (style_value.align_content == .stretch and line_count != 0)
            free_cross / @as(f32, @floatFromInt(line_count))
        else
            0;

        while (line_start < children.len) {
            const child_style = resolvedSpacingStyle((try self.nodeConstAt(children[line_start])).style, content_size);
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

            const line_end = try self.flexLineEnd(children, line_start, available_main, gap);
            try self.resolveFlexLine(children, line_start, line_end, available_main, gap, direction, content_size);
            var line_cross = try self.flexLineCrossSize(
                children,
                line_start,
                line_end,
                content_size,
                direction,
                style_value.align_items,
            );
            line_cross = boundedAdd(line_cross, stretched_line_cross);
            var flow_count: usize = 0;
            var occupied_main: f32 = 0;
            var line_auto_margin_count: usize = 0;
            for (children[line_start..line_end]) |child_id| {
                const item_style = resolvedSpacingStyle((try self.nodeConstAt(child_id)).style, content_size);
                if (item_style.display == .none or item_style.position == .absolute) continue;
                flow_count += 1;
                occupied_main = boundedAdd(occupied_main, (try self.nodeConstAt(child_id)).flex_size);
                line_auto_margin_count += autoMainMarginCount(item_style, direction);
            }
            const total_gap = if (flow_count > 1)
                gap * @as(f32, @floatFromInt(flow_count - 1))
            else
                0;
            const free_space = @max(boundedSubtract(available_main, boundedAdd(occupied_main, total_gap)), 0);
            const line_auto_margin_share = if (line_auto_margin_count == 0)
                0
            else
                free_space / @as(f32, @floatFromInt(line_auto_margin_count));
            const justify_leading = if (line_auto_margin_count == 0)
                justifyLeading(style_value.justify_content, free_space, flow_count)
            else
                0;
            const justify_gap = boundedAdd(
                gap,
                if (line_auto_margin_count == 0) justifyGap(style_value.justify_content, free_space, flow_count) else 0,
            );
            const line_baseline = try self.flexLineBaseline(
                children,
                line_start,
                line_end,
                content_size,
                direction,
                style_value.align_items,
            );
            const line_cross_origin = if (style_value.flex_wrap == .wrap_reverse)
                @max(boundedSubtract(cross_parent, boundedAdd(cross_cursor, line_cross)), 0)
            else
                cross_cursor;
            var cursor = justify_leading;
            for (children[line_start..line_end]) |child_id| {
                const item_style = resolvedSpacingStyle(try self.style(child_id), content_size);
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
                    effectiveRowDirection(direction, style_value.direction),
                    line_cross_origin,
                    line_cross,
                    cursor,
                    measure,
                    measure_user_data,
                    style_value.align_items,
                    line_auto_margin_share,
                    line_baseline,
                );
                const child_layout = try self.readLayout(child_id);
                const main_margin = mainMargin(item_style, direction) +
                    @as(f32, @floatFromInt(autoMainMarginCount(item_style, direction))) * line_auto_margin_share;
                cursor = boundedAdd(cursor, boundedAdd(
                    if (flexIsRow(direction)) child_layout.width else child_layout.height,
                    boundedAdd(main_margin, justify_gap),
                ));
            }
            cross_cursor = boundedAdd(cross_cursor, boundedAdd(line_cross, distributed_cross_gap));
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
        containing: Dimensions,
    ) Error!void {
        var flow_count: usize = 0;
        for (children[start..end]) |child_id| {
            const item_style = resolvedSpacingStyle((try self.nodeConstAt(child_id)).style, containing);
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
                const item_style = resolvedSpacingStyle(item_node.style, containing);
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
                const item_style = resolvedSpacingStyle(item_node.style, containing);
                if (item_style.display == .none or item_style.position == .absolute or item_node.flex_frozen) continue;
                total_factor = boundedAdd(total_factor, flexMainFactor(item_style, direction, free, item_node.flex_base));
            }
            if (unfrozen_count == 0 or total_factor == 0) {
                for (children[start..end]) |child_id| {
                    const item_node = try self.nodeAt(child_id);
                    const item_style = resolvedSpacingStyle(item_node.style, containing);
                    if (item_style.display == .none or item_style.position == .absolute or item_node.flex_frozen) continue;
                    item_node.flex_size = clampFlexMain(
                        item_node.flex_base,
                        item_style,
                        direction,
                        available_main,
                        item_node.intrinsic_tiers,
                    );
                    item_node.flex_frozen = true;
                }
                break;
            }
            var froze_any = false;
            for (children[start..end]) |child_id| {
                const item_node = try self.nodeAt(child_id);
                const item_style = resolvedSpacingStyle(item_node.style, containing);
                if (item_style.display == .none or item_style.position == .absolute or item_node.flex_frozen) continue;
                const factor = flexMainFactor(item_style, direction, free, item_node.flex_base);
                const raw = boundedAdd(item_node.flex_base, weightedShare(free, factor, total_factor));
                item_node.flex_size = clampFlexMain(
                    raw,
                    item_style,
                    direction,
                    available_main,
                    item_node.intrinsic_tiers,
                );
                if (item_node.flex_size != raw) {
                    item_node.flex_frozen = true;
                    froze_any = true;
                }
            }
            if (!froze_any) {
                for (children[start..end]) |child_id| {
                    const item_node = try self.nodeAt(child_id);
                    const item_style = resolvedSpacingStyle(item_node.style, containing);
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
        containing: Dimensions,
        direction: FlexDirection,
        container_align: AlignItems,
    ) Error!f32 {
        const cross_parent = if (flexIsRow(direction)) containing.height else containing.width;
        var result: f32 = 0;
        var line_baseline: f32 = 0;
        var line_descent: f32 = 0;
        for (children[start..end]) |child_id| {
            const item_node = try self.nodeConstAt(child_id);
            const item_style = resolvedSpacingStyle(item_node.style, containing);
            if (item_style.display == .none or item_style.position == .absolute) continue;
            const measurement = item_node.intrinsic_measurement;
            const dimension = if (flexIsRow(direction)) item_style.height else item_style.width;
            var cross_size = resolveDimension(dimension, cross_parent, 0);
            if (dimension == .auto) {
                if (measurement) |measured| {
                    cross_size = if (flexIsRow(direction)) measured.height else measured.width;
                }
            }
            cross_size = clampDimensionWithIntrinsic(
                cross_size,
                if (flexIsRow(direction)) item_style.min_height else item_style.min_width,
                if (flexIsRow(direction)) item_style.max_height else item_style.max_width,
                cross_parent,
                item_node.intrinsic_tiers,
                dimension == .auto,
                !flexIsRow(direction),
            );
            if (flexIsRow(direction) and resolveAlign(item_style.align_self, container_align) == .baseline) {
                const before = if (item_style.auto_margin.top) 0 else item_style.margin.top;
                const after = if (item_style.auto_margin.bottom) 0 else item_style.margin.bottom;
                const item_baseline = baselineOffset(item_style, cross_size);
                line_baseline = @max(line_baseline, boundedAdd(before, item_baseline));
                line_descent = @max(line_descent, boundedAdd(after, boundedSubtract(cross_size, item_baseline)));
            } else {
                result = @max(result, boundedAdd(cross_size, crossMargin(item_style, direction)));
            }
        }
        return @max(result, boundedAdd(line_baseline, line_descent));
    }

    fn flexLineBaseline(
        self: *LayoutTree,
        children: []const NodeId,
        start: usize,
        end: usize,
        containing: Dimensions,
        direction: FlexDirection,
        container_align: AlignItems,
    ) Error!?f32 {
        const cross_parent = containing.height;
        if (!flexIsRow(direction)) return null;
        var found = false;
        var result: f32 = 0;
        for (children[start..end]) |child_id| {
            const item_node = try self.nodeConstAt(child_id);
            const item_style = resolvedSpacingStyle(item_node.style, containing);
            if (item_style.display == .none or item_style.position == .absolute or
                resolveAlign(item_style.align_self, container_align) != .baseline)
            {
                continue;
            }
            const measurement = item_node.intrinsic_measurement;
            var height = resolveDimension(item_style.height, cross_parent, 0);
            if (item_style.height == .auto and measurement != null) height = measurement.?.height;
            height = clampDimensionWithIntrinsic(
                height,
                item_style.min_height,
                item_style.max_height,
                cross_parent,
                item_node.intrinsic_tiers,
                item_style.height == .auto,
                false,
            );
            const margin_top = if (item_style.auto_margin.top) 0 else item_style.margin.top;
            result = @max(result, boundedAdd(margin_top, baselineOffset(item_style, height)));
            found = true;
        }
        return if (found) result else null;
    }

    fn computeFlexWrapChild(
        self: *LayoutTree,
        child_id: NodeId,
        child_style: Style,
        content_origin: Point,
        content_size: Dimensions,
        inherited_clip: ?ClipRect,
        direction: FlexDirection,
        layout_direction: Direction,
        cross_cursor: f32,
        line_cross: f32,
        cursor: f32,
        measure: ?IntrinsicMeasureFunction,
        measure_user_data: ?*anyopaque,
        container_align: AlignItems,
        auto_margin_share: f32,
        line_baseline: ?f32,
    ) Error!void {
        const child_node = try self.nodeConstAt(child_id);
        const measurement = child_node.intrinsic_measurement;
        const resolved_margin = resolvedMainMarginEdges(child_style, direction, auto_margin_share);
        const main_margin = mainMargin(child_style, direction);
        const cross_margin = crossMargin(child_style, direction);
        const child_align = resolveAlign(child_style.align_self, container_align);
        var child_width = resolveDimension(child_style.width, content_size.width, 0);
        var child_height = resolveDimension(child_style.height, content_size.height, 0);
        if (flexIsRow(direction)) {
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
        child_width = clampDimensionWithIntrinsic(
            child_width,
            child_style.min_width,
            child_style.max_width,
            content_size.width,
            child_node.intrinsic_tiers,
            child_style.width == .auto,
            true,
        );
        if (try self.remeasureLeafAtWidth(
            child_id,
            child_style,
            child_width,
            content_size,
            measure,
            measure_user_data,
        )) |remeasured| {
            child_height = remeasured.height;
        }
        child_height = clampDimensionWithIntrinsic(
            child_height,
            child_style.min_height,
            child_style.max_height,
            content_size.height,
            child_node.intrinsic_tiers,
            child_style.height == .auto,
            false,
        );
        const cross_size = if (flexIsRow(direction)) child_height else child_width;
        const cross_offset = crossAxisOffset(
            child_align,
            line_cross,
            cross_size,
            child_style,
            direction,
            line_baseline,
        );
        const child_origin = if (flexIsRow(direction))
            Point{
                .x = rowChildX(
                    content_origin.x,
                    content_size.width,
                    cursor,
                    child_width,
                    resolved_margin,
                    layout_direction,
                ),
                .y = boundedAdd(boundedAdd(content_origin.y, cross_cursor), cross_offset),
            }
        else
            Point{
                .x = boundedAdd(boundedAdd(content_origin.x, cross_cursor), cross_offset),
                .y = columnChildY(
                    content_origin.y,
                    content_size.height,
                    cursor,
                    child_height,
                    resolved_margin,
                    flexIsReverse(direction),
                ),
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
        const node_style = (try self.nodeConstAt(id)).style;
        const children = (try self.nodeConstAt(id)).children.items;
        const direction = node_style.direction;
        for (children) |child_id| {
            const child_style = resolvedSpacingStyle(try self.style(child_id), size);
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
            if (needsIntrinsicMeasurement(child_style.width) or needsIntrinsicMeasurement(child_style.height)) {
                if (child_node.children.items.len != 0) {
                    child_node.intrinsic_measurement = try self.preferredNodeSize(
                        child_id,
                        size,
                        measure,
                        measure_user_data,
                    );
                } else if (child_node.intrinsic_measurement == null and measure != null) {
                    const measured = measure.?(child_id, size, measure_user_data);
                    try validateDimensions(measured);
                    child_node.intrinsic_measurement = measured;
                }
            }

            var child_size = Dimensions{
                .width = resolveDimension(child_style.width, size.width, 0),
                .height = resolveDimension(child_style.height, size.height, 0),
            };
            if (child_node.intrinsic_measurement) |measured| {
                child_size.width = resolveContentDimension(
                    child_style.width,
                    size.width,
                    child_size.width,
                    measured,
                    child_node.intrinsic_tiers,
                    true,
                );
                child_size.height = resolveContentDimension(
                    child_style.height,
                    size.height,
                    child_size.height,
                    measured,
                    child_node.intrinsic_tiers,
                    false,
                );
            }
            child_size.width = clampDimensionWithIntrinsic(
                child_size.width,
                child_style.min_width,
                child_style.max_width,
                size.width,
                child_node.intrinsic_tiers,
                needsIntrinsicMeasurement(child_style.width),
                true,
            );
            if (try self.remeasureLeafAtWidth(
                child_id,
                child_style,
                child_size.width,
                size,
                measure,
                measure_user_data,
            )) |remeasured| {
                child_size.height = remeasured.height;
            }
            child_size.height = clampDimensionWithIntrinsic(
                child_size.height,
                child_style.min_height,
                child_style.max_height,
                size.height,
                child_node.intrinsic_tiers,
                needsIntrinsicMeasurement(child_style.height),
                false,
            );

            const fractions = alignmentFractions(child_style.alignment);
            const horizontal_fraction = alignmentHorizontalFraction(child_style.alignment, direction);
            const margin_left = if (child_style.auto_margin.left) 0 else child_style.margin.left;
            const margin_right = if (child_style.auto_margin.right) 0 else child_style.margin.right;
            const margin_top = if (child_style.auto_margin.top) 0 else child_style.margin.top;
            const margin_bottom = if (child_style.auto_margin.bottom) 0 else child_style.margin.bottom;
            const free_width = @max(
                boundedSubtract(size.width, boundedAdd(child_size.width, boundedAdd(margin_left, margin_right))),
                0,
            );
            const free_height = @max(
                boundedSubtract(size.height, boundedAdd(child_size.height, boundedAdd(margin_top, margin_bottom))),
                0,
            );
            const child_origin = Point{
                .x = boundedAdd(
                    origin.x,
                    boundedAdd(margin_left, gridAxisOffset(
                        free_width,
                        child_style.auto_margin.left,
                        child_style.auto_margin.right,
                        horizontal_fraction,
                    )),
                ),
                .y = boundedAdd(
                    origin.y,
                    boundedAdd(margin_top, gridAxisOffset(
                        free_height,
                        child_style.auto_margin.top,
                        child_style.auto_margin.bottom,
                        fractions.y,
                    )),
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

    fn prepareGridTracks(
        self: *LayoutTree,
        style_value: Style,
        children: []const NodeId,
        column_storage: *[max_supported_grid_tracks]GridTrack,
        row_storage: *[max_supported_grid_tracks]GridTrack,
    ) Error!GridTrackCounts {
        const track_limit = @min(self.options.max_grid_tracks, max_supported_grid_tracks);
        var column_count = style_value.grid_columns.len;
        var row_count = style_value.grid_rows.len;
        @memcpy(column_storage[0..column_count], style_value.grid_columns);
        @memcpy(row_storage[0..row_count], style_value.grid_rows);

        for (children) |child_id| {
            (try self.nodeAt(child_id)).grid_placement = null;
            const child_style = try self.style(child_id);
            if (child_style.display == .none or child_style.position == .absolute) continue;
            if (child_style.grid_column != 0) {
                const required = child_style.grid_column - 1 + child_style.grid_column_span;
                while (column_count < required) {
                    try appendImplicitTrack(
                        column_storage,
                        &column_count,
                        style_value.grid_auto_columns,
                        track_limit,
                    );
                }
            }
            if (child_style.grid_row != 0) {
                const required = child_style.grid_row - 1 + child_style.grid_row_span;
                while (row_count < required) {
                    try appendImplicitTrack(
                        row_storage,
                        &row_count,
                        style_value.grid_auto_rows,
                        track_limit,
                    );
                }
            }
            if (child_style.grid_column != 0 and child_style.grid_row != 0) {
                (try self.nodeAt(child_id)).grid_placement = .{
                    .column = child_style.grid_column - 1,
                    .row = child_style.grid_row - 1,
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
        for (children) |child_id| {
            const child_style = try self.style(child_id);
            if (child_style.display == .none or child_style.position == .absolute) continue;
            if ((try self.nodeConstAt(child_id)).grid_placement != null) continue;
            if (gridFlowIsDense(style_value.grid_auto_flow)) auto_cursor = 0;
            var placement: ?GridPlacement = null;
            var search: usize = 0;
            while (placement == null) {
                var candidate: GridPlacement = undefined;
                if (child_style.grid_row != 0) {
                    while (search + child_style.grid_column_span > column_count) {
                        try appendImplicitTrack(
                            column_storage,
                            &column_count,
                            style_value.grid_auto_columns,
                            track_limit,
                        );
                    }
                    candidate = .{
                        .column = search,
                        .row = child_style.grid_row - 1,
                        .column_span = child_style.grid_column_span,
                        .row_span = child_style.grid_row_span,
                    };
                    search += 1;
                } else if (child_style.grid_column != 0) {
                    while (search + child_style.grid_row_span > row_count) {
                        try appendImplicitTrack(
                            row_storage,
                            &row_count,
                            style_value.grid_auto_rows,
                            track_limit,
                        );
                    }
                    candidate = .{
                        .column = child_style.grid_column - 1,
                        .row = search,
                        .column_span = child_style.grid_column_span,
                        .row_span = child_style.grid_row_span,
                    };
                    search += 1;
                } else {
                    while (auto_cursor >= column_count * row_count) {
                        if (gridFlowIsRow(style_value.grid_auto_flow)) {
                            try appendImplicitTrack(
                                row_storage,
                                &row_count,
                                style_value.grid_auto_rows,
                                track_limit,
                            );
                        } else {
                            try appendImplicitTrack(
                                column_storage,
                                &column_count,
                                style_value.grid_auto_columns,
                                track_limit,
                            );
                        }
                    }
                    candidate = if (gridFlowIsRow(style_value.grid_auto_flow))
                        .{
                            .column = auto_cursor % column_count,
                            .row = auto_cursor / column_count,
                            .column_span = child_style.grid_column_span,
                            .row_span = child_style.grid_row_span,
                        }
                    else
                        .{
                            .column = auto_cursor / row_count,
                            .row = auto_cursor % row_count,
                            .column_span = child_style.grid_column_span,
                            .row_span = child_style.grid_row_span,
                        };
                    auto_cursor += 1;
                }
                if (candidate.column + candidate.column_span > column_count or
                    candidate.row + candidate.row_span > row_count)
                {
                    continue;
                }
                if (!(try self.gridRegionOccupied(children, candidate))) placement = candidate;
            }
            (try self.nodeAt(child_id)).grid_placement = placement;
        }
        return .{ .columns = column_count, .rows = row_count };
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
        const children = node_ref.children.items;
        var column_storage: [max_supported_grid_tracks]GridTrack = undefined;
        var row_storage: [max_supported_grid_tracks]GridTrack = undefined;
        const track_counts = try self.prepareGridTracks(
            style_value,
            children,
            &column_storage,
            &row_storage,
        );
        const columns = column_storage[0..track_counts.columns];
        const rows = row_storage[0..track_counts.rows];
        const column_gap = resolveGridGap(style_value, .column, size.width, columns);
        const row_gap = resolveGridGap(style_value, .row, size.height, rows);
        // Measure after placement so auto tracks can use all available
        // intrinsic contributions, including children auto-placed later.
        for (children) |child_id| {
            const child_style = resolvedSpacingStyle(try self.style(child_id), size);
            if (child_style.display == .none) {
                try self.hideNode(child_id);
                continue;
            }
            if (child_style.position == .absolute) {
                try self.computeAbsolute(child_id, child_style, size, origin, inherited_clip, measure, measure_user_data);
                continue;
            }
            const child_node = try self.nodeAt(child_id);
            if (needsIntrinsicMeasurement(child_style.width) or needsIntrinsicMeasurement(child_style.height)) {
                if (child_node.children.items.len != 0) {
                    child_node.intrinsic_measurement = try self.preferredNodeSize(
                        child_id,
                        size,
                        measure,
                        measure_user_data,
                    );
                } else if (child_node.intrinsic_measurement == null and measure != null) {
                    const measured = measure.?(child_id, size, measure_user_data);
                    try validateDimensions(measured);
                    child_node.intrinsic_measurement = measured;
                }
            }
        }
        for (children) |child_id| {
            const child_style = resolvedSpacingStyle(try self.style(child_id), size);
            if (child_style.display == .none or child_style.position == .absolute) continue;
            const child_node = try self.nodeAt(child_id);
            const resolved_placement = child_node.grid_placement.?;
            const cell_width = try self.gridTrackSpanDimension(
                columns,
                resolved_placement.column,
                resolved_placement.column_span,
                size.width,
                column_gap,
                children,
                true,
            );
            const cell_height = try self.gridTrackSpanDimension(
                rows,
                resolved_placement.row,
                resolved_placement.row_span,
                size.height,
                row_gap,
                children,
                false,
            );
            const margin_left = if (child_style.auto_margin.left) 0 else child_style.margin.left;
            const margin_right = if (child_style.auto_margin.right) 0 else child_style.margin.right;
            const margin_top = if (child_style.auto_margin.top) 0 else child_style.margin.top;
            const margin_bottom = if (child_style.auto_margin.bottom) 0 else child_style.margin.bottom;
            const available_width = boundedSubtract(cell_width, boundedAdd(margin_left, margin_right));
            const available_height = boundedSubtract(cell_height, boundedAdd(margin_top, margin_bottom));
            var child_width = resolveDimension(child_style.width, cell_width, available_width);
            var child_height = resolveDimension(child_style.height, cell_height, available_height);
            if (child_node.intrinsic_measurement) |measured| {
                child_width = resolveContentDimension(
                    child_style.width,
                    cell_width,
                    child_width,
                    measured,
                    child_node.intrinsic_tiers,
                    true,
                );
                child_height = resolveContentDimension(
                    child_style.height,
                    cell_height,
                    child_height,
                    measured,
                    child_node.intrinsic_tiers,
                    false,
                );
            }
            child_width = clampDimensionWithIntrinsic(
                child_width,
                child_style.min_width,
                child_style.max_width,
                cell_width,
                child_node.intrinsic_tiers,
                needsIntrinsicMeasurement(child_style.width),
                true,
            );
            if (try self.remeasureLeafAtWidth(
                child_id,
                child_style,
                child_width,
                .{ .width = cell_width, .height = cell_height },
                measure,
                measure_user_data,
            )) |remeasured| {
                child_height = remeasured.height;
            }
            child_height = clampDimensionWithIntrinsic(
                child_height,
                child_style.min_height,
                child_style.max_height,
                cell_height,
                child_node.intrinsic_tiers,
                needsIntrinsicMeasurement(child_style.height),
                false,
            );
            const column_offset = try self.gridTrackOffset(
                columns,
                resolved_placement.column,
                size.width,
                column_gap,
                children,
                true,
            );
            const row_offset = try self.gridTrackOffset(
                rows,
                resolved_placement.row,
                size.height,
                row_gap,
                children,
                false,
            );
            const cell_x = if (style_value.direction == .rtl)
                boundedAdd(origin.x, @max(boundedSubtract(boundedSubtract(size.width, column_offset), cell_width), 0))
            else
                boundedAdd(origin.x, column_offset);
            const alignment = alignmentFractions(child_style.alignment);
            const horizontal_alignment = alignmentHorizontalFraction(child_style.alignment, style_value.direction);
            const child_x = boundedAdd(
                boundedAdd(cell_x, margin_left),
                gridAxisOffset(
                    boundedSubtract(available_width, child_width),
                    child_style.auto_margin.left,
                    child_style.auto_margin.right,
                    horizontal_alignment,
                ),
            );
            const child_y = boundedAdd(
                boundedAdd(boundedAdd(origin.y, row_offset), margin_top),
                gridAxisOffset(
                    boundedSubtract(available_height, child_height),
                    child_style.auto_margin.top,
                    child_style.auto_margin.bottom,
                    alignment.y,
                ),
            );
            const preserved_measurement = child_node.intrinsic_measurement;
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
            // Later siblings still need earlier intrinsic contributions when
            // their track offsets are resolved.
            if (preserved_measurement) |measured| {
                (try self.nodeAt(child_id)).intrinsic_measurement = measured;
            }
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
    fn intrinsicGridTrackSize(
        self: *const LayoutTree,
        tracks: []const GridTrack,
        gap: f32,
        children: []const NodeId,
        horizontal: bool,
        available: f32,
    ) Error!f32 {
        var total: f32 = 0;
        for (tracks, 0..) |track, index| {
            total = boundedAdd(total, switch (track) {
                .fixed => |value| value,
                .bounded => |bounds| bounds.min,
                .auto => try self.gridTrackAutoSize(
                    tracks,
                    index,
                    available,
                    gap,
                    children,
                    horizontal,
                ),
                .fr => 0,
            });
        }
        if (tracks.len > 1) {
            total = boundedAdd(total, gap * @as(f32, @floatFromInt(tracks.len - 1)));
        }
        return total;
    }

    fn gridTrackDimension(
        self: *const LayoutTree,
        tracks: []const GridTrack,
        index: usize,
        available: f32,
        gap: f32,
        children: []const NodeId,
        horizontal: bool,
    ) Error!f32 {
        const total_gap = if (tracks.len > 1)
            gap * @as(f32, @floatFromInt(tracks.len - 1))
        else
            0;
        const usable = @max(boundedSubtract(available, total_gap), 0);
        var fixed: f32 = 0;
        var auto: f32 = 0;
        var fractions: f32 = 0;
        var bounded_count: f32 = 0;
        for (tracks, 0..) |track, track_index| {
            switch (track) {
                .fixed => |value| fixed = boundedAdd(fixed, value),
                .auto => auto = boundedAdd(auto, try self.gridTrackAutoSize(
                    tracks,
                    track_index,
                    available,
                    gap,
                    children,
                    horizontal,
                )),
                .fr => |value| fractions = boundedAdd(fractions, value),
                .bounded => bounded_count += 1,
            }
        }
        const remaining = @max(boundedSubtract(usable, boundedAdd(fixed, auto)), 0);
        if (bounded_count == 0) {
            return switch (tracks[index]) {
                .fixed => |value| value,
                .auto => try self.gridTrackAutoSize(tracks, index, available, gap, children, horizontal),
                .fr => |value| weightedShare(
                    boundedSubtract(usable, boundedAdd(fixed, auto)),
                    value,
                    fractions,
                ),
                .bounded => unreachable,
            };
        }

        // Grid track counts are bounded by Options; this fixed scratch keeps
        // resolution allocation-free while allowing custom capacities well
        // beyond the default.
        var frozen: [256]bool = @splat(false);
        var newly_frozen: [256]bool = @splat(false);
        var frozen_values: [256]f32 = undefined;
        var frozen_sum: f32 = 0;
        var active_weight = boundedAdd(fractions, bounded_count);
        var iteration: usize = 0;
        while (iteration < tracks.len) : (iteration += 1) {
            const free = @max(boundedSubtract(remaining, frozen_sum), 0);
            var froze_any = false;
            for (tracks, 0..) |track, track_index| {
                if (frozen[track_index]) continue;
                switch (track) {
                    .bounded => |bounds| {
                        const share = weightedShare(free, 1, active_weight);
                        if (share < bounds.min) {
                            newly_frozen[track_index] = true;
                            frozen_values[track_index] = bounds.min;
                            froze_any = true;
                        } else if (share > bounds.max) {
                            newly_frozen[track_index] = true;
                            frozen_values[track_index] = bounds.max;
                            froze_any = true;
                        }
                    },
                    else => {},
                }
            }
            if (!froze_any) break;
            for (tracks, 0..) |_, track_index| {
                if (!newly_frozen[track_index]) continue;
                newly_frozen[track_index] = false;
                frozen[track_index] = true;
                frozen_sum = boundedAdd(frozen_sum, frozen_values[track_index]);
                active_weight = boundedSubtract(active_weight, 1);
            }
        }

        return switch (tracks[index]) {
            .fixed => |value| value,
            .auto => try self.gridTrackAutoSize(tracks, index, available, gap, children, horizontal),
            .fr => |value| weightedShare(
                @max(boundedSubtract(remaining, frozen_sum), 0),
                value,
                active_weight,
            ),
            .bounded => |bounds| if (frozen[index])
                frozen_values[index]
            else
                @min(@max(weightedShare(
                    @max(boundedSubtract(remaining, frozen_sum), 0),
                    1,
                    active_weight,
                ), bounds.min), bounds.max),
        };
    }

    fn gridTrackAutoSize(
        self: *const LayoutTree,
        tracks: []const GridTrack,
        index: usize,
        available: f32,
        gap: f32,
        children: []const NodeId,
        horizontal: bool,
    ) Error!f32 {
        var result: f32 = 0;
        for (children) |child_id| {
            const child = try self.nodeConstAt(child_id);
            if (child.style.display == .none or child.style.position == .absolute) continue;
            const placement = child.grid_placement orelse continue;
            const start = if (horizontal) placement.column else placement.row;
            const span = if (horizontal) placement.column_span else placement.row_span;
            if (index < start or index >= start + span) continue;
            const dimension = if (horizontal) child.style.width else child.style.height;
            const measured: Dimensions = child.intrinsic_measurement orelse .{};
            var desired = intrinsicResolvedDimension(
                dimension,
                available,
                if (horizontal) measured.width else measured.height,
            );
            desired = clampDimensionWithIntrinsic(
                desired,
                if (horizontal) child.style.min_width else child.style.min_height,
                if (horizontal) child.style.max_width else child.style.max_height,
                available,
                child.intrinsic_tiers,
                needsIntrinsicMeasurement(dimension),
                horizontal,
            );
            const resolved_margin = resolvedEdges(
                child.style.margin,
                child.style.margin_spec,
                if (horizontal)
                    Dimensions{ .width = available, .height = 0 }
                else
                    Dimensions{ .width = 0, .height = available },
            );
            const margins = if (horizontal)
                horizontalEdges(resolved_margin)
            else
                verticalEdges(resolved_margin);
            desired = @min(boundedAdd(desired, margins), @max(available, 0));
            var fixed_span: f32 = 0;
            var auto_count: usize = 0;
            for (0..span) |offset| {
                switch (tracks[start + offset]) {
                    .fixed => |value| fixed_span = boundedAdd(fixed_span, value),
                    .bounded => |bounds| fixed_span = boundedAdd(fixed_span, bounds.min),
                    .auto => auto_count += 1,
                    .fr => {},
                }
            }
            if (auto_count == 0) continue;
            const span_gap = if (span > 1)
                gap * @as(f32, @floatFromInt(span - 1))
            else
                0;
            const remaining = @max(
                boundedSubtract(boundedSubtract(desired, fixed_span), span_gap),
                0,
            );
            const contribution = remaining / @as(f32, @floatFromInt(auto_count));
            if (finite(contribution)) result = @max(result, contribution);
        }
        return boundedCoordinate(result);
    }
    fn gridTrackSpanDimension(
        self: *const LayoutTree,
        tracks: []const GridTrack,
        start: usize,
        span: usize,
        available: f32,
        gap: f32,
        children: []const NodeId,
        horizontal: bool,
    ) Error!f32 {
        var total: f32 = 0;
        for (0..span) |offset| {
            total = boundedAdd(total, try self.gridTrackDimension(
                tracks,
                start + offset,
                available,
                gap,
                children,
                horizontal,
            ));
        }
        if (span > 1) total = boundedAdd(total, gap * @as(f32, @floatFromInt(span - 1)));
        return total;
    }

    fn gridTrackOffset(
        self: *const LayoutTree,
        tracks: []const GridTrack,
        index: usize,
        available: f32,
        gap: f32,
        children: []const NodeId,
        horizontal: bool,
    ) Error!f32 {
        var offset: f32 = 0;
        for (0..index) |track_index| {
            offset = boundedAdd(offset, boundedAdd(
                try self.gridTrackDimension(tracks, track_index, available, gap, children, horizontal),
                gap,
            ));
        }
        return offset;
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
        const left = insetValue(style_value.left, containing.width);
        const right = insetValue(style_value.right, containing.width);
        const top = insetValue(style_value.top, containing.height);
        const bottom = insetValue(style_value.bottom, containing.height);
        const margin_left = if (style_value.auto_margin.left) 0 else style_value.margin.left;
        const margin_right = if (style_value.auto_margin.right) 0 else style_value.margin.right;
        const margin_top = if (style_value.auto_margin.top) 0 else style_value.margin.top;
        const margin_bottom = if (style_value.auto_margin.bottom) 0 else style_value.margin.bottom;
        const width_from_insets = style_value.width == .auto and left != null and right != null;
        const height_from_insets = style_value.height == .auto and top != null and bottom != null;
        var width = resolveDimension(style_value.width, containing.width, 0);
        var height = resolveDimension(style_value.height, containing.height, 0);
        if (width_from_insets or style_value.width == .stretch) {
            width = boundedSubtract(
                containing.width,
                boundedAdd(
                    boundedAdd(left orelse 0, right orelse 0),
                    boundedAdd(margin_left, margin_right),
                ),
            );
        }
        if (height_from_insets or style_value.height == .stretch) {
            height = boundedSubtract(
                containing.height,
                boundedAdd(
                    boundedAdd(top orelse 0, bottom orelse 0),
                    boundedAdd(margin_top, margin_bottom),
                ),
            );
        }
        const node_ref = try self.nodeAt(id);
        if (needsIntrinsicMeasurement(style_value.width) or needsIntrinsicMeasurement(style_value.height)) {
            const measured = if (node_ref.children.items.len != 0)
                try self.preferredNodeSize(id, containing, measure, measure_user_data)
            else if (node_ref.intrinsic_measurement) |cached|
                cached
            else if (measure) |measure_fn| blk: {
                const value = measure_fn(id, containing, measure_user_data);
                try validateDimensions(value);
                node_ref.intrinsic_measurement = value;
                break :blk value;
            } else null;
            if (measured) |value| {
                if (!width_from_insets) {
                    width = resolveContentDimension(
                        style_value.width,
                        containing.width,
                        width,
                        value,
                        node_ref.intrinsic_tiers,
                        true,
                    );
                }
                if (!height_from_insets) {
                    height = resolveContentDimension(
                        style_value.height,
                        containing.height,
                        height,
                        value,
                        node_ref.intrinsic_tiers,
                        false,
                    );
                }
            }
        }
        width = clampDimensionWithIntrinsic(
            width,
            style_value.min_width,
            style_value.max_width,
            containing.width,
            node_ref.intrinsic_tiers,
            needsIntrinsicMeasurement(style_value.width) and !width_from_insets,
            true,
        );
        if (try self.remeasureLeafAtWidth(
            id,
            style_value,
            width,
            containing,
            measure,
            measure_user_data,
        )) |remeasured| {
            height = remeasured.height;
        }
        height = clampDimensionWithIntrinsic(
            height,
            style_value.min_height,
            style_value.max_height,
            containing.height,
            node_ref.intrinsic_tiers,
            needsIntrinsicMeasurement(style_value.height) and !height_from_insets,
            false,
        );
        const horizontal_free = if (left != null and right != null)
            boundedSubtract(
                containing.width,
                boundedAdd(
                    boundedAdd(left.?, right.?),
                    boundedAdd(width, boundedAdd(margin_left, margin_right)),
                ),
            )
        else
            0;
        const vertical_free = if (top != null and bottom != null)
            boundedSubtract(
                containing.height,
                boundedAdd(
                    boundedAdd(top.?, bottom.?),
                    boundedAdd(height, boundedAdd(margin_top, margin_bottom)),
                ),
            )
        else
            0;
        const x_offset = if (left) |value|
            boundedAdd(
                value,
                boundedAdd(margin_left, gridAxisOffset(
                    horizontal_free,
                    style_value.auto_margin.left,
                    style_value.auto_margin.right,
                    0,
                )),
            )
        else if (right) |value|
            boundedSubtract(
                boundedSubtract(containing.width, value),
                boundedAdd(width, margin_right),
            )
        else
            margin_left;
        const y_offset = if (top) |value|
            boundedAdd(
                value,
                boundedAdd(margin_top, gridAxisOffset(
                    vertical_free,
                    style_value.auto_margin.top,
                    style_value.auto_margin.bottom,
                    0,
                )),
            )
        else if (bottom) |value|
            boundedSubtract(
                boundedSubtract(containing.height, value),
                boundedAdd(height, margin_bottom),
            )
        else
            margin_top;
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

    fn remeasureLeafAtWidth(
        self: *LayoutTree,
        id: NodeId,
        style_value: Style,
        width: f32,
        available: Dimensions,
        measure: ?IntrinsicMeasureFunction,
        measure_user_data: ?*anyopaque,
    ) Error!?Dimensions {
        if (style_value.height != .auto or measure == null) return null;
        const node_ref = try self.nodeAt(id);
        if (node_ref.children.items.len != 0) return null;
        const previous = node_ref.intrinsic_measurement orelse return null;
        if (width >= previous.width) return null;

        const remeasured = measure.?(
            id,
            .{ .width = width, .height = available.height },
            measure_user_data,
        );
        try validateDimensions(remeasured);
        node_ref.intrinsic_measurement = remeasured;
        return remeasured;
    }

    fn preferredNodeSize(
        self: *LayoutTree,
        id: NodeId,
        containing: Dimensions,
        measure: ?IntrinsicMeasureFunction,
        measure_user_data: ?*anyopaque,
    ) Error!Dimensions {
        try self.validateComputeDepth(id);
        const node = try self.nodeConstAt(id);
        const style_value = resolvedSpacingStyle(node.style, containing);
        if (style_value.display == .none) return .{};
        const children = node.children.items;

        var content = Dimensions{};
        var flow_count: usize = 0;
        if (children.len == 0) {
            if (measure != null and
                (style_value.width == .auto or style_value.height == .auto))
            {
                const measured = measure.?(id, containing, measure_user_data);
                try validateDimensions(measured);
                (try self.nodeAt(id)).intrinsic_measurement = measured;
                content = measured;
            }
        } else {
            for (children) |child_id| {
                const child_style = resolvedSpacingStyle(try self.style(child_id), containing);
                if (child_style.display == .none or child_style.position == .absolute) continue;
                const child_size = try self.preferredNodeSize(
                    child_id,
                    containing,
                    measure,
                    measure_user_data,
                );
                const outer_width = boundedAdd(child_size.width, horizontalEdges(child_style.margin));
                const outer_height = boundedAdd(child_size.height, verticalEdges(child_style.margin));
                flow_count += 1;
                switch (style_value.display) {
                    .flex => if (flexIsRow(style_value.flex_direction)) {
                        content.width = boundedAdd(content.width, outer_width);
                        content.height = @max(content.height, outer_height);
                    } else {
                        content.width = @max(content.width, outer_width);
                        content.height = boundedAdd(content.height, outer_height);
                    },
                    .overlay => {
                        content.width = @max(content.width, outer_width);
                        content.height = @max(content.height, outer_height);
                    },
                    .grid => (try self.nodeAt(child_id)).intrinsic_measurement = child_size,
                    .none => unreachable,
                }
            }

            if (style_value.display == .flex and flow_count > 1) {
                const main_content = if (flexIsRow(style_value.flex_direction))
                    content.width
                else
                    content.height;
                const parent_main = if (flexIsRow(style_value.flex_direction))
                    containing.width
                else
                    containing.height;
                const gap = resolveFlexMainGap(style_value, parent_main, main_content, flow_count);
                const total_gap = gap * @as(f32, @floatFromInt(flow_count - 1));
                if (flexIsRow(style_value.flex_direction)) {
                    content.width = boundedAdd(content.width, total_gap);
                } else {
                    content.height = boundedAdd(content.height, total_gap);
                }
            }
            if (style_value.display == .grid) {
                var column_storage: [max_supported_grid_tracks]GridTrack = undefined;
                var row_storage: [max_supported_grid_tracks]GridTrack = undefined;
                const track_counts = try self.prepareGridTracks(
                    style_value,
                    children,
                    &column_storage,
                    &row_storage,
                );
                const columns = column_storage[0..track_counts.columns];
                const rows = row_storage[0..track_counts.rows];
                const column_gap = resolveGridGap(style_value, .column, containing.width, columns);
                const row_gap = resolveGridGap(style_value, .row, containing.height, rows);
                content.width = try self.intrinsicGridTrackSize(
                    columns,
                    column_gap,
                    children,
                    true,
                    containing.width,
                );
                content.height = try self.intrinsicGridTrackSize(
                    rows,
                    row_gap,
                    children,
                    false,
                    containing.height,
                );
            }
        }

        const auto_width = boundedAdd(content.width, horizontalEdges(style_value.padding));
        const auto_height = boundedAdd(content.height, verticalEdges(style_value.padding));
        var result = Dimensions{
            .width = intrinsicResolvedDimension(style_value.width, containing.width, auto_width),
            .height = intrinsicResolvedDimension(style_value.height, containing.height, auto_height),
        };
        if (style_value.aspect_ratio) |ratio| {
            result = aspectRatioDimension(
                result.width,
                result.height,
                ratio,
                style_value.width == .auto,
                style_value.height == .auto,
            );
        }
        result.width = clampDimensionWithIntrinsic(
            result.width,
            style_value.min_width,
            style_value.max_width,
            containing.width,
            (try self.nodeConstAt(id)).intrinsic_tiers,
            style_value.width == .auto,
            true,
        );
        result.height = clampDimensionWithIntrinsic(
            result.height,
            style_value.min_height,
            style_value.max_height,
            containing.height,
            (try self.nodeConstAt(id)).intrinsic_tiers,
            style_value.height == .auto,
            false,
        );
        (try self.nodeAt(id)).intrinsic_measurement = result;
        return result;
    }

    fn hideNode(self: *LayoutTree, id: NodeId) Error!void {
        var current: ?NodeId = id;
        while (current) |node_id| {
            const node_ref = try self.nodeAt(node_id);
            node_ref.layout = .{};
            node_ref.dirty = false;
            current = try self.nextPreorderNode(id, node_id);
        }
    }

    fn nextPreorderNode(self: *const LayoutTree, root: NodeId, current: NodeId) Error!?NodeId {
        const current_node = try self.nodeConstAt(current);
        if (current_node.children.items.len != 0) return current_node.children.items[0];

        var cursor = current;
        while (!sameId(cursor, root)) {
            const parent_id = (try self.nodeConstAt(cursor)).parent orelse return error.ChildNotFound;
            const siblings = (try self.nodeConstAt(parent_id)).children.items;
            var index: ?usize = null;
            for (siblings, 0..) |sibling, sibling_index| {
                if (sameId(sibling, cursor)) {
                    index = sibling_index;
                    break;
                }
            }
            const sibling_index = index orelse return error.ChildNotFound;
            if (sibling_index + 1 < siblings.len) return siblings[sibling_index + 1];
            cursor = parent_id;
        }
        return null;
    }

    fn validateComputeDepth(self: *const LayoutTree, id: NodeId) Error!void {
        const limit = @min(self.options.max_depth, max_supported_tree_depth);
        var depth: usize = 1;
        if (limit == 0) return error.TreeDepthExceeded;
        var current = id;
        while ((try self.nodeConstAt(current)).parent) |parent_id| {
            if (depth >= limit) return error.TreeDepthExceeded;
            depth += 1;
            current = parent_id;
        }
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

const TierMeasureAdapter = struct {
    tree: *LayoutTree,
    measure: IntrinsicMeasureTiersFunction,
    user_data: ?*anyopaque,
};

fn measureIntrinsicTiers(id: NodeId, available: Dimensions, user_data: ?*anyopaque) Dimensions {
    const adapter: *TierMeasureAdapter = @ptrCast(@alignCast(user_data.?));
    const tiers = adapter.measure(id, available, adapter.user_data);
    if (validateIntrinsicDimensions(tiers)) |_| {
        const node = adapter.tree.nodeAt(id) catch return .{ .width = std.math.nan(f32), .height = std.math.nan(f32) };
        node.intrinsic_tiers = tiers;
        return tiers.preferred;
    } else |_| {
        return .{ .width = std.math.nan(f32), .height = std.math.nan(f32) };
    }
}

fn sameId(left: NodeId, right: NodeId) bool {
    return left.index == right.index and left.generation == right.generation;
}
fn horizontalEdges(edges: Edges) f32 {
    return boundedAdd(edges.left, edges.right);
}

fn resolveEdgeSize(value: ?EdgeSize, fallback: f32, parent: f32) f32 {
    const spec = value orelse return fallback;
    return switch (spec) {
        .fixed => |fixed| fixed,
        .percent => |percent| boundedCoordinate(parent * percent),
    };
}

fn resolvedEdges(fallback: Edges, spec: ?ResponsiveEdges, containing: Dimensions) Edges {
    const values = spec orelse return fallback;
    return .{
        .top = resolveEdgeSize(values.top, fallback.top, containing.height),
        .right = resolveEdgeSize(values.right, fallback.right, containing.width),
        .bottom = resolveEdgeSize(values.bottom, fallback.bottom, containing.height),
        .left = resolveEdgeSize(values.left, fallback.left, containing.width),
    };
}

fn resolvedSpacingStyle(style: Style, containing: Dimensions) Style {
    var result = style;
    result.padding = resolvedEdges(style.padding, style.padding_spec, containing);
    result.margin = resolvedEdges(style.margin, style.margin_spec, containing);
    return result;
}

fn containsLayoutPoint(layout: Layout, point: Point) bool {
    if (point.x < layout.x or point.y < layout.y) return false;
    return point.x < boundedAdd(layout.x, layout.width) and
        point.y < boundedAdd(layout.y, layout.height) and
        if (layout.clip) |clip|
            point.x >= clip.x and point.y >= clip.y and
                point.x < boundedAdd(clip.x, clip.width) and
                point.y < boundedAdd(clip.y, clip.height)
        else
            true;
}

fn sortChildrenByOrder(self: *LayoutTree, node: *Node) Error!void {
    var index: usize = 1;
    while (index < node.children.items.len) : (index += 1) {
        const key = node.children.items[index];
        const key_order = (try self.nodeConstAt(key)).style.order;
        var position = index;
        while (position > 0) {
            const previous = node.children.items[position - 1];
            if ((try self.nodeConstAt(previous)).style.order <= key_order) break;
            node.children.items[position] = previous;
            position -= 1;
        }
        node.children.items[position] = key;
    }
}
fn isDescendantOf(self: *const LayoutTree, candidate: NodeId, root: NodeId) bool {
    var current = candidate;
    var steps: usize = 0;
    while (steps <= max_supported_tree_depth) : (steps += 1) {
        if (sameId(current, root)) return true;
        const node = self.nodeConstAt(current) catch return false;
        current = node.parent orelse return false;
    }
    return false;
}

fn depthFrom(self: *const LayoutTree, candidate: NodeId, root: NodeId) Error!usize {
    var current = candidate;
    var depth: usize = 0;
    while (depth <= max_supported_tree_depth) : (depth += 1) {
        if (sameId(current, root)) return depth;
        current = (try self.nodeConstAt(current)).parent orelse return error.ChildNotFound;
    }
    return error.TreeDepthExceeded;
}

fn isPaintedAfter(self: *const LayoutTree, candidate: NodeId, previous: NodeId) bool {
    var left = candidate;
    var right = previous;
    var steps: usize = 0;
    while (steps <= max_supported_tree_depth) : (steps += 1) {
        const left_parent = (self.nodeConstAt(left) catch return false).parent orelse return false;
        const right_parent = (self.nodeConstAt(right) catch return false).parent orelse return false;
        if (sameId(left_parent, right_parent)) {
            const siblings = self.nodeConstAt(left_parent) catch return false;
            var left_index: ?usize = null;
            var right_index: ?usize = null;
            for (siblings.children.items, 0..) |sibling, index| {
                if (sameId(sibling, left)) left_index = index;
                if (sameId(sibling, right)) right_index = index;
            }
            return (left_index orelse return false) > (right_index orelse return false);
        }
        left = left_parent;
        right = right_parent;
    }
    return false;
}
fn verticalEdges(edges: Edges) f32 {
    return boundedAdd(edges.top, edges.bottom);
}

fn marginAlongAxis(edges: Edges, direction: FlexDirection) f32 {
    return if (flexIsRow(direction)) horizontalEdges(edges) else verticalEdges(edges);
}

fn marginAcrossAxis(edges: Edges, direction: FlexDirection) f32 {
    return if (flexIsRow(direction)) verticalEdges(edges) else horizontalEdges(edges);
}

fn mainMargin(style: Style, direction: FlexDirection) f32 {
    const before = if (flexIsRow(direction))
        (if (style.auto_margin.left) 0 else style.margin.left)
    else
        (if (style.auto_margin.top) 0 else style.margin.top);
    const after = if (flexIsRow(direction))
        (if (style.auto_margin.right) 0 else style.margin.right)
    else
        (if (style.auto_margin.bottom) 0 else style.margin.bottom);
    return boundedAdd(before, after);
}

fn crossMargin(style: Style, direction: FlexDirection) f32 {
    const before = if (flexIsRow(direction))
        (if (style.auto_margin.top) 0 else style.margin.top)
    else
        (if (style.auto_margin.left) 0 else style.margin.left);
    const after = if (flexIsRow(direction))
        (if (style.auto_margin.bottom) 0 else style.margin.bottom)
    else
        (if (style.auto_margin.right) 0 else style.margin.right);
    return boundedAdd(before, after);
}

fn autoMainMarginCount(style: Style, direction: FlexDirection) usize {
    if (flexIsRow(direction)) {
        return @intFromBool(style.auto_margin.left) + @intFromBool(style.auto_margin.right);
    }
    return @intFromBool(style.auto_margin.top) + @intFromBool(style.auto_margin.bottom);
}

fn resolvedMainMarginEdges(style: Style, direction: FlexDirection, share: f32) Edges {
    var result = style.margin;
    if (flexIsRow(direction)) {
        if (style.auto_margin.left) result.left = share;
        if (style.auto_margin.right) result.right = share;
    } else {
        if (style.auto_margin.top) result.top = share;
        if (style.auto_margin.bottom) result.bottom = share;
    }
    return result;
}
fn resolveAlign(value: AlignSelf, parent: AlignItems) AlignItems {
    return switch (value) {
        .auto => parent,
        .stretch => .stretch,
        .flex_start => .flex_start,
        .flex_end => .flex_end,
        .center => .center,
        .baseline => .baseline,
    };
}

fn rowChildX(
    origin_x: f32,
    content_width: f32,
    cursor: f32,
    child_width: f32,
    margin: Edges,
    direction: Direction,
) f32 {
    if (direction == .rtl) {
        return boundedAdd(
            origin_x,
            boundedSubtract(
                boundedSubtract(content_width, cursor),
                boundedAdd(child_width, margin.right),
            ),
        );
    }
    return boundedAdd(origin_x, boundedAdd(cursor, margin.left));
}
fn columnChildY(
    origin_y: f32,
    content_height: f32,
    cursor: f32,
    child_height: f32,
    margin: Edges,
    reverse: bool,
) f32 {
    if (reverse) {
        return boundedAdd(
            origin_y,
            boundedSubtract(
                boundedSubtract(content_height, cursor),
                boundedAdd(child_height, margin.bottom),
            ),
        );
    }
    return boundedAdd(origin_y, boundedAdd(cursor, margin.top));
}

fn crossAxisOffset(
    alignment: AlignItems,
    available: f32,
    child_size: f32,
    style: Style,
    direction: FlexDirection,
    line_baseline: ?f32,
) f32 {
    const before_auto = if (flexIsRow(direction)) style.auto_margin.top else style.auto_margin.left;
    const after_auto = if (flexIsRow(direction)) style.auto_margin.bottom else style.auto_margin.right;
    const margin_before = if (before_auto)
        0
    else if (flexIsRow(direction))
        style.margin.top
    else
        style.margin.left;
    const margin_after = if (after_auto)
        0
    else if (flexIsRow(direction))
        style.margin.bottom
    else
        style.margin.right;
    const margin_box = boundedAdd(child_size, boundedAdd(margin_before, margin_after));
    const free = @max(boundedSubtract(available, margin_box), 0);
    if (before_auto and after_auto) return boundedAdd(margin_before, free / 2);
    if (before_auto) return boundedAdd(margin_before, free);
    if (after_auto) return margin_before;
    if (alignment == .baseline and flexIsRow(direction) and line_baseline != null) {
        return @max(boundedSubtract(line_baseline.?, baselineOffset(style, child_size)), 0);
    }
    const alignment_offset = switch (alignment) {
        .flex_end => free,
        .center => free / 2,
        .flex_start, .stretch, .baseline => 0,
    };
    return boundedAdd(alignment_offset, margin_before);
}

fn baselineOffset(style: Style, height: f32) f32 {
    return @min(style.baseline orelse height, height);
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

fn alignContentLeading(alignment: AlignContent, free: f32, count: usize) f32 {
    if (count == 0) return 0;
    const count_float = @as(f32, @floatFromInt(count));
    return switch (alignment) {
        .stretch, .flex_start, .space_between => 0,
        .flex_end => free,
        .center => free / 2,
        .space_around => free / count_float / 2,
        .space_evenly => free / (count_float + 1),
    };
}

fn alignContentGap(alignment: AlignContent, free: f32, count: usize) f32 {
    if (count == 0 or (count < 2 and alignment == .space_between)) return 0;
    const count_float = @as(f32, @floatFromInt(count));
    return switch (alignment) {
        .space_between => free / @as(f32, @floatFromInt(count - 1)),
        .space_around => free / count_float,
        .space_evenly => free / (count_float + 1),
        .stretch, .flex_start, .flex_end, .center => 0,
    };
}

fn clampFlexMain(
    value: f32,
    style: Style,
    direction: FlexDirection,
    parent_main: f32,
    intrinsic_tiers: ?IntrinsicDimensions,
) f32 {
    const margin = mainMargin(style, direction);
    const box_value = boundedSubtract(value, margin);
    const clamped = if (flexIsRow(direction))
        clampDimensionWithIntrinsic(box_value, style.min_width, style.max_width, parent_main, intrinsic_tiers, style.width == .auto, true)
    else
        clampDimensionWithIntrinsic(box_value, style.min_height, style.max_height, parent_main, intrinsic_tiers, style.height == .auto, false);
    return boundedAdd(clamped, margin);
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

fn clampDimensionWithIntrinsic(
    value: f32,
    min_dimension: Dimension,
    max_dimension: Dimension,
    parent: f32,
    intrinsic_tiers: ?IntrinsicDimensions,
    use_intrinsic: bool,
    horizontal: bool,
) f32 {
    var result = clampDimension(value, min_dimension, max_dimension, parent);
    if (use_intrinsic) {
        if (intrinsic_tiers) |tiers| {
            const min_value = if (horizontal) tiers.min.width else tiers.min.height;
            const max_value = if (horizontal) tiers.max.width else tiers.max.height;
            result = @min(result, max_value);
            result = @max(result, min_value);
        }
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
    intrinsic_tiers: ?IntrinsicDimensions,
) f32 {
    const main_dimension = if (flexIsRow(direction)) style.width else style.height;
    const basis = if (style.flex_basis != .auto) style.flex_basis else main_dimension;
    if (intrinsic_measurement) |measured| {
        if (needsIntrinsicMeasurement(basis)) {
            return resolveContentDimension(
                basis,
                main_parent,
                if (flexIsRow(direction)) measured.width else measured.height,
                measured,
                intrinsic_tiers,
                flexIsRow(direction),
            );
        }
    }
    if (style.flex_basis != .auto) {
        return switch (style.flex_basis) {
            .stretch => 0,
            else => boundedResolved(style.flex_basis, main_parent),
        };
    }
    if (style.aspect_ratio) |ratio| {
        const cross_dimension = if (flexIsRow(direction)) style.height else style.width;
        if (main_dimension == .auto and cross_dimension != .auto) {
            const cross = boundedResolved(cross_dimension, cross_parent);
            const resolved = if (flexIsRow(direction)) cross * ratio else cross / ratio;
            return if (finite(resolved)) @max(resolved, 0) else std.math.floatMax(f32);
        }
    }
    return switch (main_dimension) {
        .stretch => 0,
        else => boundedResolved(main_dimension, main_parent),
    };
}

fn flexMainDimension(style: Style, direction: FlexDirection) Dimension {
    return if (flexIsRow(direction)) style.width else style.height;
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
    if (!finite(available) or !finite(factor) or !finite(total) or available == 0 or factor <= 0 or total <= 0) return 0;
    const result = (available / total) * factor;
    return if (finite(result)) result else 0;
}

const GapAxis = enum {
    column,
    row,
};
fn effectiveGap(specific: f32, shared: f32) f32 {
    return if (specific != 0) specific else shared;
}

fn axisGapSpec(style: Style, axis: GapAxis) ?Gap {
    return switch (axis) {
        .column => style.column_gap_spec,
        .row => style.row_gap_spec,
    };
}

fn axisMinGapSpec(style: Style, axis: GapAxis) ?Gap {
    return switch (axis) {
        .column => style.min_column_gap_spec,
        .row => style.min_row_gap_spec,
    };
}

fn axisMaxGapSpec(style: Style, axis: GapAxis) ?Gap {
    return switch (axis) {
        .column => style.max_column_gap_spec,
        .row => style.max_row_gap_spec,
    };
}

fn resolveTypedGap(
    spec: ?Gap,
    minimum: ?Gap,
    maximum: ?Gap,
    fallback: f32,
    parent: f32,
    occupied: f32,
    item_count: usize,
) f32 {
    const gap_spec = spec orelse return fallback;
    const gap_count = item_count -| 1;
    const remaining = @max(boundedSubtract(parent, occupied), 0);
    var result = resolveGapValue(gap_spec, parent, remaining, gap_count);
    if (minimum) |value| {
        result = @max(result, resolveGapValue(value, parent, remaining, gap_count));
    }
    if (maximum) |value| {
        result = @min(result, resolveGapValue(value, parent, remaining, gap_count));
    }
    return if (finite(result)) result else std.math.floatMax(f32);
}

fn resolveFlexMainGap(style: Style, parent: f32, occupied: f32, item_count: usize) f32 {
    const axis: GapAxis = if (flexIsRow(style.flex_direction)) .column else .row;
    return resolveTypedGap(
        axisGapSpec(style, axis) orelse style.flex_gap_spec,
        axisMinGapSpec(style, axis) orelse style.min_flex_gap_spec,
        axisMaxGapSpec(style, axis) orelse style.max_flex_gap_spec,
        style.flex_gap,
        parent,
        occupied,
        item_count,
    );
}

fn resolveFlexCrossGap(style: Style, parent: f32, occupied: f32, line_count: usize) f32 {
    const axis: GapAxis = if (flexIsRow(style.flex_direction)) .row else .column;
    return resolveTypedGap(
        axisGapSpec(style, axis) orelse style.flex_gap_spec,
        axisMinGapSpec(style, axis) orelse style.min_flex_gap_spec,
        axisMaxGapSpec(style, axis) orelse style.max_flex_gap_spec,
        style.flex_gap,
        parent,
        occupied,
        line_count,
    );
}

fn resolveGridGap(style: Style, axis: GapAxis, parent: f32, tracks: []const GridTrack) f32 {
    const fallback = switch (axis) {
        .column => effectiveGap(style.grid_column_gap, style.grid_gap),
        .row => effectiveGap(style.grid_row_gap, style.grid_gap),
    };
    return resolveTypedGap(
        axisGapSpec(style, axis),
        axisMinGapSpec(style, axis),
        axisMaxGapSpec(style, axis),
        fallback,
        parent,
        intrinsicGridTracks(tracks, 0),
        tracks.len,
    );
}

fn resolveGapValue(spec: Gap, parent: f32, remaining: f32, gap_count: usize) f32 {
    return switch (spec) {
        .fixed => |value| value,
        .percent => |value| boundedCoordinate(parent * value),
        .stretch => |factor| blk: {
            _ = factor;
            if (gap_count == 0) break :blk 0;
            break :blk boundedCoordinate(remaining / @as(f32, @floatFromInt(gap_count)));
        },
    };
}

fn gridPlacementsOverlap(left: GridPlacement, right: GridPlacement) bool {
    return left.column < right.column + right.column_span and
        right.column < left.column + left.column_span and
        left.row < right.row + right.row_span and
        right.row < left.row + left.row_span;
}

fn appendImplicitTrack(
    storage: *[max_supported_grid_tracks]GridTrack,
    count: *usize,
    track: GridTrack,
    limit: usize,
) Error!void {
    if (count.* >= limit) return error.GridTrackCapacityExceeded;
    storage[count.*] = track;
    count.* += 1;
}

fn validateGridTrack(track: GridTrack) Error!void {
    switch (track) {
        .fixed => |value| if (!finite(value) or value < 0) return error.InvalidStyle,
        .auto => {},
        .fr => |value| if (!finite(value) or value <= 0) return error.InvalidStyle,
        .bounded => |bounds| if (!finite(bounds.min) or !finite(bounds.max) or bounds.min < 0 or bounds.max < bounds.min) return error.InvalidStyle,
    }
}

fn validateGridCapacity(style: Style, options: Options) Error!void {
    if (style.display != .grid) return;
    if (style.grid_columns.len == 0 or style.grid_rows.len == 0) return error.InvalidStyle;
    const configured_limit = @min(options.max_grid_tracks, max_supported_grid_tracks);
    if (style.grid_columns.len > configured_limit or style.grid_rows.len > configured_limit) {
        return error.GridTrackCapacityExceeded;
    }
}

fn validateDimensions(value: Dimensions) Error!void {
    if (!finite(value.width) or !finite(value.height) or value.width < 0 or value.height < 0) {
        return error.InvalidDimensions;
    }
}
fn intrinsicResolvedDimension(dimension: Dimension, parent: f32, auto_value: f32) f32 {
    return switch (dimension) {
        .auto, .min_content, .max_content, .fit_content => auto_value,
        .length => |value| value,
        .percent => |value| boundedCoordinate(parent * value),
        // Stretch has no intrinsic contribution; the parent distributes it.
        .stretch => 0,
    };
}

fn intrinsicGridTracks(tracks: []const GridTrack, gap: f32) f32 {
    var total: f32 = 0;
    for (tracks) |track| {
        total = boundedAdd(total, switch (track) {
            .fixed => |value| value,
            .bounded => |bounds| bounds.min,
            .auto, .fr => 0,
        });
    }
    if (tracks.len > 1) {
        total = boundedAdd(total, gap * @as(f32, @floatFromInt(tracks.len - 1)));
    }
    return total;
}

fn validateIntrinsicDimensions(value: IntrinsicDimensions) Error!void {
    try validateDimensions(value.min);
    try validateDimensions(value.preferred);
    try validateDimensions(value.max);
    if (value.min.width > value.preferred.width or value.preferred.width > value.max.width or
        value.min.height > value.preferred.height or value.preferred.height > value.max.height)
    {
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

fn validateGapSpec(spec: ?Gap) Error!void {
    if (spec) |gap| switch (gap) {
        .fixed => |value| if (!finite(value)) return error.InvalidStyle,
        .percent => |value| if (!finite(value) or value < 0) return error.InvalidStyle,
        .stretch => |factor| if (!finite(factor) or factor <= 0) return error.InvalidStyle,
    };
}

fn validateEdgeSize(value: ?EdgeSize) Error!void {
    if (value) |size| switch (size) {
        .fixed, .percent => |amount| if (!finite(amount) or amount < 0) return error.InvalidStyle,
    };
}

fn validateResponsiveEdges(spec: ?ResponsiveEdges) Error!void {
    const edges = spec orelse return;
    try validateEdgeSize(edges.top);
    try validateEdgeSize(edges.right);
    try validateEdgeSize(edges.bottom);
    try validateEdgeSize(edges.left);
}

fn validateStyle(style: Style) Error!void {
    try validateEdges(style.padding);
    try validateEdges(style.margin);
    try validateResponsiveEdges(style.padding_spec);
    try validateResponsiveEdges(style.margin_spec);
    try validateGapSpec(style.flex_gap_spec);
    try validateGapSpec(style.column_gap_spec);
    try validateGapSpec(style.row_gap_spec);
    try validateGapSpec(style.min_column_gap_spec);
    try validateGapSpec(style.max_column_gap_spec);
    try validateGapSpec(style.min_row_gap_spec);
    try validateGapSpec(style.max_row_gap_spec);
    try validateGapSpec(style.min_flex_gap_spec);
    try validateGapSpec(style.max_flex_gap_spec);
    if (@backingInt(style.flex_direction) >= 4 or
        @backingInt(style.hit_test_behavior) >= 3 or
        @backingInt(style.direction) >= 2 or
        @backingInt(style.grid_auto_flow) >= 4 or
        @backingInt(style.flex_wrap) >= 3 or
        @backingInt(style.align_items) >= 5 or
        @backingInt(style.align_self) >= 6 or
        @backingInt(style.alignment) >= 9 or
        @backingInt(style.justify_content) >= 6 or
        @backingInt(style.align_content) >= 7)
    {
        return error.InvalidStyle;
    }
    if (!finite(style.scroll_offset.x) or style.scroll_offset.x < 0 or
        !finite(style.scroll_offset.y) or style.scroll_offset.y < 0)
    {
        return error.InvalidStyle;
    }
    if (style.aspect_ratio) |ratio| {
        if (!finite(ratio) or ratio <= 0) return error.InvalidStyle;
    }
    if (style.baseline) |baseline| {
        if (!finite(baseline) or baseline < 0) return error.InvalidStyle;
    }
    if (!finite(style.flex_grow) or style.flex_grow < 0 or
        !finite(style.flex_shrink) or style.flex_shrink < 0)
    {
        return error.InvalidStyle;
    }
    if (style.grid_column_span == 0 or style.grid_row_span == 0) {
        return error.InvalidStyle;
    }
    if (!finite(style.grid_column_gap) or style.grid_column_gap < 0 or
        !finite(style.grid_row_gap) or style.grid_row_gap < 0 or
        !finite(style.grid_gap) or style.grid_gap < 0 or
        !finite(style.flex_gap) or style.flex_gap < 0)
    {
        return error.InvalidStyle;
    }
    for (style.grid_columns) |track| try validateGridTrack(track);
    for (style.grid_rows) |track| try validateGridTrack(track);
    try validateGridTrack(style.grid_auto_columns);
    try validateGridTrack(style.grid_auto_rows);
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
        .auto, .min_content, .max_content, .fit_content => {},
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

const WrappingIntrinsicProbe = struct {
    calls: usize = 0,
    last_width: f32 = 0,
};

fn measureWrappingIntrinsic(_: NodeId, available: Dimensions, user_data: ?*anyopaque) Dimensions {
    const probe: *WrappingIntrinsicProbe = @ptrCast(@alignCast(user_data.?));
    probe.calls += 1;
    probe.last_width = available.width;
    return if (available.width < 80)
        .{ .width = available.width, .height = 30 }
    else
        .{ .width = 80, .height = 10 };
}

fn measureInvalidIntrinsic(_: NodeId, _: Dimensions, _: ?*anyopaque) Dimensions {
    return .{ .width = std.math.nan(f32), .height = 10 };
}

const IntrinsicTierProbe = struct {
    calls: usize = 0,
    tiers: IntrinsicDimensions = .{
        .min = .{ .width = 10, .height = 8 },
        .preferred = .{ .width = 23, .height = 19 },
        .max = .{ .width = 50, .height = 40 },
    },
};

fn measureIntrinsicTiersForTest(_: NodeId, _: Dimensions, user_data: ?*anyopaque) IntrinsicDimensions {
    const probe: *IntrinsicTierProbe = @ptrCast(@alignCast(user_data.?));
    probe.calls += 1;
    return probe.tiers;
}

fn measureInvalidIntrinsicTiers(_: NodeId, _: Dimensions, _: ?*anyopaque) IntrinsicDimensions {
    return .{
        .min = .{ .width = 30, .height = 0 },
        .preferred = .{ .width = 20, .height = 10 },
        .max = .{ .width = 40, .height = 20 },
    };
}

fn measureNegativeIntrinsicTier(_: NodeId, _: Dimensions, _: ?*anyopaque) IntrinsicDimensions {
    return .{
        .min = .{ .width = -1, .height = 0 },
        .preferred = .{ .width = 20, .height = 10 },
        .max = .{ .width = 40, .height = 20 },
    };
}

fn resolveDimension(dimension: Dimension, parent: f32, auto_value: f32) f32 {
    return switch (dimension) {
        .auto, .min_content, .max_content, .fit_content => auto_value,
        .length => |value| value,
        .percent => |value| parent * value,
        // Outside a flex distribution pass, stretch fills the available axis.
        .stretch => parent,
    };
}

fn needsIntrinsicMeasurement(dimension: Dimension) bool {
    return switch (dimension) {
        .auto, .min_content, .max_content, .fit_content => true,
        .length, .percent, .stretch => false,
    };
}

fn resolveContentDimension(
    dimension: Dimension,
    parent: f32,
    fallback: f32,
    measurement: Dimensions,
    tiers: ?IntrinsicDimensions,
    horizontal: bool,
) f32 {
    const preferred = if (horizontal) measurement.width else measurement.height;
    const minimum = if (tiers) |values|
        (if (horizontal) values.min.width else values.min.height)
    else
        preferred;
    const maximum = if (tiers) |values|
        (if (horizontal) values.max.width else values.max.height)
    else
        preferred;
    return switch (dimension) {
        .auto => preferred,
        .min_content => minimum,
        .max_content => maximum,
        .fit_content => @min(maximum, @max(minimum, parent)),
        .length, .percent, .stretch => fallback,
    };
}

fn insetValue(dimension: Dimension, parent: f32) ?f32 {
    return switch (dimension) {
        .auto, .min_content, .max_content, .fit_content => null,
        .length => |value| value,
        .percent => |value| parent * value,
        // Stretch is a size, not an inset.
        .stretch => null,
    };
}

fn relativePositionOrigin(origin: Point, style: Style, containing: Dimensions) Point {
    const left = insetValue(style.left, containing.width);
    const right = insetValue(style.right, containing.width);
    const top = insetValue(style.top, containing.height);
    const bottom = insetValue(style.bottom, containing.height);
    const x_offset = if (style.direction == .rtl)
        if (right) |value| -value else left orelse 0
    else
        left orelse if (right) |value| -value else 0;
    const y_offset = top orelse if (bottom) |value| -value else 0;
    return .{
        .x = boundedAdd(origin.x, x_offset),
        .y = boundedAdd(origin.y, y_offset),
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

fn boundedSubtract(left: f32, right: f32) f32 {
    return boundedCoordinate(left - right);
}

test "intrinsic tier measurement uses preferred auto size" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 80 } });
    const child = try tree.create(.{});
    try tree.appendChild(root, child);

    var probe = IntrinsicTierProbe{};
    try tree.computeWithMeasureTiers(root, .{ .width = 100, .height = 80 }, measureIntrinsicTiersForTest, &probe);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(Layout{ .width = 23, .height = 19 }, try tree.readLayout(child));
}

test "content sizing keywords select intrinsic tiers" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 5 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
        .align_items = .flex_start,
    });
    const minimum = try tree.create(.{ .width = .min_content, .height = .{ .length = 10 } });
    const maximum = try tree.create(.{ .width = .max_content, .height = .{ .length = 10 } });
    const fitted = try tree.create(.{ .width = .fit_content, .height = .{ .length = 10 } });
    try tree.appendChild(root, minimum);
    try tree.appendChild(root, maximum);
    try tree.appendChild(root, fitted);

    var probe = IntrinsicTierProbe{};
    try tree.computeWithMeasureTiers(root, .{ .width = 100, .height = 20 }, measureIntrinsicTiersForTest, &probe);
    try std.testing.expectEqual(@as(f32, 10), (try tree.readLayout(minimum)).width);
    try std.testing.expectEqual(@as(f32, 50), (try tree.readLayout(maximum)).width);
    try std.testing.expectEqual(@as(f32, 50), (try tree.readLayout(fitted)).width);
}

test "intrinsic tier measurement clamps flex size to min and max" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 80 } });
    const child = try tree.create(.{ .flex_grow = 1, .flex_shrink = 1 });
    try tree.appendChild(root, child);

    var probe = IntrinsicTierProbe{
        .tiers = .{
            .min = .{ .width = 10, .height = 8 },
            .preferred = .{ .width = 23, .height = 19 },
            .max = .{ .width = 30, .height = 40 },
        },
    };
    try tree.computeWithMeasureTiers(root, .{ .width = 100, .height = 80 }, measureIntrinsicTiersForTest, &probe);
    try std.testing.expectEqual(Layout{ .width = 30, .height = 19 }, try tree.readLayout(child));

    try tree.setStyle(root, .{ .width = .{ .length = 5 }, .height = .{ .length = 80 } });
    probe.tiers.min.width = 10;
    probe.tiers.preferred.width = 23;
    probe.tiers.max.width = 50;
    try tree.computeWithMeasureTiers(root, .{ .width = 5, .height = 80 }, measureIntrinsicTiersForTest, &probe);
    try std.testing.expectEqual(@as(f32, 10), (try tree.readLayout(child)).width);
}

test "intrinsic tier measurement rejects invalid values and ordering" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 2 });
    defer tree.deinit();
    const leaf = try tree.create(.{});
    try std.testing.expectError(
        error.InvalidDimensions,
        tree.computeWithMeasureTiers(leaf, .{ .width = 100, .height = 80 }, measureInvalidIntrinsicTiers, null),
    );
    try std.testing.expectError(
        error.InvalidDimensions,
        tree.computeWithMeasureTiers(leaf, .{ .width = 100, .height = 80 }, measureNegativeIntrinsicTier, null),
    );
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

test "intrinsic leaf remeasures height after flex shrink narrows width" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 80 },
        .align_items = .flex_start,
    });
    const fixed = try tree.create(.{
        .width = .{ .length = 60 },
        .height = .{ .length = 10 },
    });
    const wrapping = try tree.create(.{ .flex_shrink = 1 });
    try tree.appendChild(root, fixed);
    try tree.appendChild(root, wrapping);

    var probe = WrappingIntrinsicProbe{};
    try tree.computeWithMeasure(root, .{ .width = 100, .height = 80 }, measureWrappingIntrinsic, &probe);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(@as(f32, 40), probe.last_width);
    try std.testing.expectEqual(Layout{ .x = 60, .width = 40, .height = 30 }, try tree.readLayout(wrapping));
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

test "auto flex containers hug child content and padding" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 50 },
        .align_items = .flex_start,
    });
    const container = try tree.create(.{
        .flex_direction = .column,
        .padding = Edges.all(2),
        .flex_gap = 5,
    });
    const first = try tree.create(.{
        .width = .{ .length = 30 },
        .height = .{ .length = 10 },
    });
    const second = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 12 },
    });
    try tree.appendChild(root, container);
    try tree.appendChild(container, first);
    try tree.appendChild(container, second);

    try tree.compute(root, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(
        Layout{ .width = 34, .height = 31 },
        try tree.readLayout(container),
    );
    try std.testing.expectEqual(Layout{ .x = 2, .y = 2, .width = 30, .height = 10 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .x = 2, .y = 17, .width = 20, .height = 12 }, try tree.readLayout(second));
}
test "computeDirty computes an uninitialized tree from a descendant" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 50 } });
    const child = try tree.create(.{ .width = .{ .length = 24 }, .height = .{ .length = 12 } });
    try tree.appendChild(root, child);

    try tree.computeDirty(child, .{ .width = 100, .height = 50 });

    try std.testing.expectEqual(Layout{ .width = 100, .height = 50 }, try tree.readLayout(root));
    try std.testing.expectEqual(Layout{ .width = 24, .height = 12 }, try tree.readLayout(child));
    try std.testing.expect(!(try tree.isDirty(root)));
    try std.testing.expect(!(try tree.isDirty(child)));
}

test "computeDirty matches full compute after descendant style mutation" {
    var full_tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer full_tree.deinit();
    var dirty_tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer dirty_tree.deinit();

    const root_style = Style{ .width = .{ .length = 120 }, .height = .{ .length = 60 } };
    const container_style = Style{ .width = .{ .length = 40 }, .height = .{ .length = 30 } };
    const leaf_style = Style{ .width = .{ .length = 10 }, .height = .{ .length = 10 } };
    const sibling_style = Style{ .width = .{ .length = 20 }, .height = .{ .length = 15 } };
    const changed_style = Style{ .width = .{ .length = 30 }, .height = .{ .length = 10 } };

    const full_root = try full_tree.create(root_style);
    const full_container = try full_tree.create(container_style);
    const full_leaf = try full_tree.create(leaf_style);
    const full_sibling = try full_tree.create(sibling_style);
    try full_tree.appendChild(full_root, full_container);
    try full_tree.appendChild(full_container, full_leaf);
    try full_tree.appendChild(full_root, full_sibling);

    const dirty_root = try dirty_tree.create(root_style);
    const dirty_container = try dirty_tree.create(container_style);
    const dirty_leaf = try dirty_tree.create(leaf_style);
    const dirty_sibling = try dirty_tree.create(sibling_style);
    try dirty_tree.appendChild(dirty_root, dirty_container);
    try dirty_tree.appendChild(dirty_container, dirty_leaf);
    try dirty_tree.appendChild(dirty_root, dirty_sibling);

    const available = Dimensions{ .width = 120, .height = 60 };
    try full_tree.compute(full_root, available);
    try dirty_tree.compute(dirty_root, available);
    try full_tree.setStyle(full_leaf, changed_style);
    try dirty_tree.setStyle(dirty_leaf, changed_style);

    try full_tree.compute(full_root, available);
    try dirty_tree.computeDirty(dirty_leaf, available);

    try std.testing.expectEqual(try full_tree.readLayout(full_root), try dirty_tree.readLayout(dirty_root));
    try std.testing.expectEqual(try full_tree.readLayout(full_container), try dirty_tree.readLayout(dirty_container));
    try std.testing.expectEqual(try full_tree.readLayout(full_leaf), try dirty_tree.readLayout(dirty_leaf));
    try std.testing.expectEqual(try full_tree.readLayout(full_sibling), try dirty_tree.readLayout(dirty_sibling));
}

test "computeDirty skips stable siblings and revisits changed dependencies" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 50 } });
    const branch = try tree.create(.{ .width = .{ .length = 40 }, .height = .{ .length = 20 } });
    const leaf = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 10 } });
    const sibling = try tree.create(.{ .width = .{ .length = 20 }, .height = .{ .length = 20 } });
    try tree.appendChild(root, branch);
    try tree.appendChild(branch, leaf);
    try tree.appendChild(root, sibling);
    try tree.compute(root, .{ .width = 100, .height = 50 });

    try tree.setStyle(leaf, .{ .width = .{ .length = 10 }, .height = .{ .length = 15 } });
    (try tree.nodeAt(sibling)).layout.height = 777;
    try tree.computeDirty(leaf, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(@as(f32, 777), (try tree.readLayout(sibling)).height);
    try std.testing.expectEqual(@as(f32, 15), (try tree.readLayout(leaf)).height);

    try tree.setStyle(branch, .{ .width = .{ .length = 60 }, .height = .{ .length = 20 } });
    try tree.computeDirty(branch, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(Layout{ .x = 60, .width = 20, .height = 20 }, try tree.readLayout(sibling));
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

test "reverse flex directions mirror their main axis" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const row = try tree.create(.{
        .flex_direction = .row_reverse,
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
    });
    const row_first = try tree.create(.{ .width = .{ .length = 30 }, .height = .{ .length = 10 } });
    const row_second = try tree.create(.{ .width = .{ .length = 20 }, .height = .{ .length = 10 } });
    try tree.appendChild(row, row_first);
    try tree.appendChild(row, row_second);
    try tree.compute(row, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(Layout{ .x = 70, .width = 30, .height = 10 }, try tree.readLayout(row_first));
    try std.testing.expectEqual(Layout{ .x = 50, .width = 20, .height = 10 }, try tree.readLayout(row_second));

    const column = try tree.create(.{
        .flex_direction = .column_reverse,
        .width = .{ .length = 20 },
        .height = .{ .length = 100 },
    });
    const column_first = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 30 } });
    const column_second = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 20 } });
    try tree.appendChild(column, column_first);
    try tree.appendChild(column, column_second);
    try tree.compute(column, .{ .width = 20, .height = 100 });
    try std.testing.expectEqual(Layout{ .y = 70, .width = 10, .height = 30 }, try tree.readLayout(column_first));
    try std.testing.expectEqual(Layout{ .y = 50, .width = 10, .height = 20 }, try tree.readLayout(column_second));
}

test "relative insets offset boxes without changing flex flow" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 40 } });
    const first = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
        .left = .{ .percent = 0.1 },
        .top = .{ .length = 4 },
    });
    const second = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
        .right = .{ .length = 5 },
        .bottom = .{ .length = 3 },
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.compute(root, .{ .width = 100, .height = 40 });
    try std.testing.expectEqual(Layout{ .x = 10, .y = 4, .width = 20, .height = 10 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .x = 15, .y = -3, .width = 20, .height = 10 }, try tree.readLayout(second));
}

test "rtl row direction mirrors child placement while absolute insets stay physical" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .direction = .rtl,
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
    });
    const first = try tree.create(.{ .width = .{ .length = 30 }, .height = .{ .length = 10 } });
    const second = try tree.create(.{ .width = .{ .length = 20 }, .height = .{ .length = 10 } });
    const absolute = try tree.create(.{
        .position = .absolute,
        .width = .{ .length = 10 },
        .height = .{ .length = 10 },
        .left = .{ .length = 7 },
        .right = .{ .length = 13 },
        .top = .{ .length = 2 },
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.appendChild(root, absolute);
    try tree.compute(root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(Layout{ .x = 70, .width = 30, .height = 10 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .x = 50, .width = 20, .height = 10 }, try tree.readLayout(second));
    try std.testing.expectEqual(Layout{ .x = 7, .y = 2, .width = 10, .height = 10 }, try tree.readLayout(absolute));
}
test "relative offsets apply to grid and overlay children" {
    const tracks = [_]GridTrack{GridTrack.fixedPx(40)};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const grid = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 40 },
        .height = .{ .length = 40 },
        .grid_columns = &tracks,
        .grid_rows = &tracks,
    });
    const grid_child = try tree.create(.{
        .width = .{ .length = 10 },
        .height = .{ .length = 10 },
        .left = .{ .length = 3 },
        .bottom = .{ .length = 4 },
    });
    try tree.appendChild(grid, grid_child);
    try tree.compute(grid, .{ .width = 40, .height = 40 });
    try std.testing.expectEqual(Layout{ .x = 3, .y = -4, .width = 10, .height = 10 }, try tree.readLayout(grid_child));

    const overlay = try tree.create(.{
        .display = .overlay,
        .width = .{ .length = 40 },
        .height = .{ .length = 40 },
    });
    const overlay_child = try tree.create(.{
        .width = .{ .length = 10 },
        .height = .{ .length = 10 },
        .alignment = .center,
        .top = .{ .length = 5 },
    });
    try tree.appendChild(overlay, overlay_child);
    try tree.compute(overlay, .{ .width = 40, .height = 40 });
    try std.testing.expectEqual(Layout{ .x = 15, .y = 20, .width = 10, .height = 10 }, try tree.readLayout(overlay_child));
}

test "retained hit testing honors ancestry clips and deepest child" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 5 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
        .overflow = .clip,
    });
    const child = try tree.create(.{
        .width = .{ .length = 80 },
        .height = .{ .length = 80 },
        .left = .{ .length = 30 },
        .top = .{ .length = 30 },
    });
    try tree.appendChild(root, child);
    try tree.compute(root, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 90, .y = 90 })).?);
    try std.testing.expectEqual(root, (try tree.hitTest(root, .{ .x = 10, .y = 10 })).?);
    try std.testing.expect((try tree.hitTest(root, .{ .x = 105, .y = 50 })) == null);
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
test "retained hit-test priority selects overlapping sibling" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .overlay,
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    });
    const low = try tree.create(.{
        .width = .{ .length = 50 },
        .height = .{ .length = 50 },
        .hit_test_priority = 1,
        .order = 1,
    });
    const high = try tree.create(.{
        .width = .{ .length = 50 },
        .height = .{ .length = 50 },
        .hit_test_priority = 1,
        .order = 2,
    });
    try tree.appendChild(root, low);
    try tree.appendChild(root, high);
    try tree.compute(root, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(high, (try tree.hitTest(root, .{ .x = 10, .y = 10 })).?);
}

test "retained interaction mutators update hit testing and ordering" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .overlay,
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    });
    const first = try tree.create(.{ .width = .{ .length = 50 }, .height = .{ .length = 50 } });
    const second = try tree.create(.{ .width = .{ .length = 50 }, .height = .{ .length = 50 } });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.compute(root, .{ .width = 100, .height = 100 });
    try tree.setHitTestBehavior(second, .disabled);
    try tree.setHitTestPriority(first, 4);
    try tree.setOrder(first, 2);
    try std.testing.expect(try tree.isDirty(root));
    try tree.computeDirty(root, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(first, (try tree.hitTest(root, .{ .x = 10, .y = 10 })).?);
}

test "retained hit-test behavior filters self without hiding descendants" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 5 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .overlay,
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
        .hit_test_behavior = .children_only,
    });
    const disabled = try tree.create(.{
        .width = .{ .length = 40 },
        .height = .{ .length = 40 },
        .hit_test_behavior = .disabled,
        .hit_test_priority = 10,
    });
    const enabled = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
        .hit_test_priority = 1,
    });
    try tree.appendChild(root, disabled);
    try tree.appendChild(disabled, enabled);
    try tree.compute(root, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(enabled, (try tree.hitTest(root, .{ .x = 5, .y = 5 })).?);
}

test "retained scroll offset translates flow content within clip" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 3 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .overflow = .clip,
        .scroll_offset = .{ .y = 20 },
        .hit_test_behavior = .children_only,
    });
    const child = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 80 },
    });
    try tree.appendChild(root, child);
    try tree.compute(root, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(@as(f32, -20), (try tree.readLayout(child)).y);
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 5, .y = 5 })).?);
    try std.testing.expect((try tree.hitTest(root, .{ .x = 5, .y = 65 })) == null);
}

test "retained scroll setter invalidates and recomputes descendants" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 3 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 50 },
    });
    const child = try tree.create(.{ .width = .{ .length = 20 }, .height = .{ .length = 20 } });
    try tree.appendChild(root, child);
    try tree.compute(root, .{ .width = 100, .height = 50 });
    try tree.setScrollOffset(root, .{ .y = 12 });
    try std.testing.expect(try tree.isDirty(root));
    try tree.computeDirty(root, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(@as(f32, -12), (try tree.readLayout(child)).y);
    try std.testing.expectError(error.InvalidStyle, tree.setScrollOffset(root, .{ .x = -1 }));
}

test "retained flex order preserves stable ties" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 5 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 20 } });
    const late = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 10 }, .order = 2 });
    const first = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 10 }, .order = -1 });
    const tie = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 10 }, .order = -1 });
    try tree.appendChild(root, late);
    try tree.appendChild(root, first);
    try tree.appendChild(root, tie);
    try tree.compute(root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(f32, 0), (try tree.readLayout(first)).x);
    try std.testing.expectEqual(@as(f32, 10), (try tree.readLayout(tie)).x);
    try std.testing.expectEqual(@as(f32, 20), (try tree.readLayout(late)).x);
}

test "absolute opposing insets intrinsic sizes and auto margins resolve together" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 5 });
    defer tree.deinit();
    const root = try tree.create(.{ .width = .{ .length = 200 }, .height = .{ .length = 100 } });
    const inset_fill = try tree.create(.{
        .position = .absolute,
        .left = .{ .length = 10 },
        .right = .{ .length = 20 },
        .top = .{ .length = 5 },
        .bottom = .{ .length = 15 },
    });
    const centered = try tree.create(.{
        .position = .absolute,
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
        .left = .{ .length = 10 },
        .right = .{ .length = 10 },
        .top = .{ .length = 5 },
        .bottom = .{ .length = 5 },
        .auto_margin = .{ .top = true, .right = true, .bottom = true, .left = true },
    });
    const intrinsic = try tree.create(.{
        .position = .absolute,
        .width = .max_content,
        .height = .min_content,
    });
    try tree.appendChild(root, inset_fill);
    try tree.appendChild(root, centered);
    try tree.appendChild(root, intrinsic);
    var probe = IntrinsicTierProbe{ .tiers = .{
        .min = .{ .width = 10, .height = 8 },
        .preferred = .{ .width = 30, .height = 20 },
        .max = .{ .width = 60, .height = 40 },
    } };

    try tree.computeWithMeasureTiers(root, .{ .width = 200, .height = 100 }, measureIntrinsicTiersForTest, &probe);
    try std.testing.expectEqual(Layout{ .x = 10, .y = 5, .width = 170, .height = 80 }, try tree.readLayout(inset_fill));
    try std.testing.expectEqual(Layout{ .x = 90, .y = 45, .width = 20, .height = 10 }, try tree.readLayout(centered));
    try std.testing.expectEqual(Layout{ .width = 60, .height = 8 }, try tree.readLayout(intrinsic));
}

test "overlay intrinsic sizing and auto margins share alignment space" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .overlay,
        .width = .{ .length = 100 },
        .height = .{ .length = 80 },
    });
    const intrinsic = try tree.create(.{
        .width = .max_content,
        .height = .min_content,
        .alignment = .bottom_right,
    });
    const centered = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
        .auto_margin = .{ .top = true, .right = true, .bottom = true, .left = true },
    });
    try tree.appendChild(root, intrinsic);
    try tree.appendChild(root, centered);
    var probe = IntrinsicTierProbe{ .tiers = .{
        .min = .{ .width = 10, .height = 8 },
        .preferred = .{ .width = 30, .height = 20 },
        .max = .{ .width = 60, .height = 40 },
    } };

    try tree.computeWithMeasureTiers(root, .{ .width = 100, .height = 80 }, measureIntrinsicTiersForTest, &probe);
    try std.testing.expectEqual(Layout{ .x = 40, .y = 72, .width = 60, .height = 8 }, try tree.readLayout(intrinsic));
    try std.testing.expectEqual(Layout{ .x = 40, .y = 35, .width = 20, .height = 10 }, try tree.readLayout(centered));
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

test "deep retained trees fail layout safely and destroy iteratively" {
    var tree = LayoutTree.init(std.testing.allocator, .{
        .max_nodes = max_supported_tree_depth + 1,
        .max_children_per_node = 1,
        .max_depth = max_supported_tree_depth + 1,
    });
    defer tree.deinit();

    var ids: [max_supported_tree_depth + 1]NodeId = undefined;
    for (&ids) |*id| id.* = try tree.create(.{});
    for (ids[0 .. ids.len - 1], ids[1..]) |parent_id, child_id| {
        try tree.appendChild(parent_id, child_id);
    }

    try std.testing.expectError(
        error.TreeDepthExceeded,
        tree.compute(ids[0], .{ .width = 100, .height = 100 }),
    );

    try tree.setStyle(ids[0], .{ .display = .none });
    try tree.compute(ids[0], .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(Layout{}, try tree.readLayout(ids[ids.len - 1]));

    try tree.destroy(ids[0]);
    try std.testing.expectError(error.StaleNodeId, tree.readLayout(ids[ids.len - 1]));
    try std.testing.expectEqual(@as(usize, 0), tree.live_count);
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

test "rtl grid maps logical columns from the right edge" {
    const columns = [_]GridTrack{ GridTrack.fixedPx(20), GridTrack.fixedPx(30) };
    const rows = [_]GridTrack{GridTrack.fixedPx(10)};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .grid,
        .direction = .rtl,
        .width = .{ .length = 50 },
        .height = .{ .length = 10 },
        .grid_columns = &columns,
        .grid_rows = &rows,
    });
    const first = try tree.create(.{});
    const second = try tree.create(.{ .width = .{ .length = 10 }, .alignment = .top_left });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);

    try tree.compute(root, .{ .width = 50, .height = 10 });
    try std.testing.expectEqual(Layout{ .x = 30, .width = 20, .height = 10 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .x = 20, .width = 10, .height = 10 }, try tree.readLayout(second));
}

test "auto-sized grid includes implicit tracks in intrinsic size" {
    const columns = [_]GridTrack{GridTrack.fixedPx(20)};
    const rows = [_]GridTrack{GridTrack.fixedPx(10)};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4, .max_grid_tracks = 4 });
    defer tree.deinit();

    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    });
    const grid = try tree.create(.{
        .display = .grid,
        .grid_columns = &columns,
        .grid_rows = &rows,
        .grid_auto_rows = GridTrack.fixedPx(15),
    });
    const first = try tree.create(.{ .width = .{ .stretch = 1 }, .height = .{ .stretch = 1 } });
    const second = try tree.create(.{ .width = .{ .stretch = 1 }, .height = .{ .stretch = 1 } });
    try tree.appendChild(root, grid);
    try tree.appendChild(grid, first);
    try tree.appendChild(grid, second);

    try tree.compute(root, .{ .width = 100, .height = 100 });

    try std.testing.expectEqual(Layout{ .width = 20, .height = 25 }, try tree.readLayout(grid));
    try std.testing.expectEqual(Layout{ .width = 20, .height = 10 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .y = 10, .width = 20, .height = 15 }, try tree.readLayout(second));
}

test "grid auto flow grows implicit rows and columns" {
    const two_columns = [_]GridTrack{ GridTrack.fixedPx(20), GridTrack.fixedPx(20) };
    const one_row = [_]GridTrack{GridTrack.fixedPx(10)};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 10, .max_grid_tracks = 8 });
    defer tree.deinit();
    const row_root = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 40 },
        .height = .{ .length = 25 },
        .grid_columns = &two_columns,
        .grid_rows = &one_row,
        .grid_auto_rows = GridTrack.fixedPx(15),
    });
    const row_first = try tree.create(.{});
    const row_second = try tree.create(.{});
    const row_third = try tree.create(.{});
    try tree.appendChild(row_root, row_first);
    try tree.appendChild(row_root, row_second);
    try tree.appendChild(row_root, row_third);
    try tree.compute(row_root, .{ .width = 40, .height = 25 });
    try std.testing.expectEqual(Layout{ .y = 10, .width = 20, .height = 15 }, try tree.readLayout(row_third));

    const one_column = [_]GridTrack{GridTrack.fixedPx(20)};
    const two_rows = [_]GridTrack{ GridTrack.fixedPx(10), GridTrack.fixedPx(10) };
    const column_root = try tree.create(.{
        .display = .grid,
        .grid_auto_flow = .column,
        .width = .{ .length = 50 },
        .height = .{ .length = 20 },
        .grid_columns = &one_column,
        .grid_rows = &two_rows,
        .grid_auto_columns = GridTrack.fixedPx(30),
    });
    const column_first = try tree.create(.{});
    const column_second = try tree.create(.{});
    const column_third = try tree.create(.{});
    try tree.appendChild(column_root, column_first);
    try tree.appendChild(column_root, column_second);
    try tree.appendChild(column_root, column_third);
    try tree.compute(column_root, .{ .width = 50, .height = 20 });
    try std.testing.expectEqual(Layout{ .x = 20, .width = 30, .height = 10 }, try tree.readLayout(column_third));
}

test "dense grid flow backfills holes left by spanning items" {
    const columns = [_]GridTrack{ GridTrack.fixedPx(10), GridTrack.fixedPx(10), GridTrack.fixedPx(10) };
    const rows = [_]GridTrack{GridTrack.fixedPx(10)};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 10, .max_grid_tracks = 4 });
    defer tree.deinit();

    const sparse = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 30 },
        .height = .{ .length = 20 },
        .grid_columns = &columns,
        .grid_rows = &rows,
        .grid_auto_rows = GridTrack.fixedPx(10),
    });
    const sparse_explicit = try tree.create(.{ .grid_column = 2, .grid_row = 1 });
    const sparse_wide = try tree.create(.{ .grid_column_span = 2 });
    const sparse_small = try tree.create(.{});
    try tree.appendChild(sparse, sparse_explicit);
    try tree.appendChild(sparse, sparse_wide);
    try tree.appendChild(sparse, sparse_small);
    try tree.compute(sparse, .{ .width = 30, .height = 20 });
    try std.testing.expectEqual(Layout{ .x = 20, .y = 10, .width = 10, .height = 10 }, try tree.readLayout(sparse_small));

    const dense = try tree.create(.{
        .display = .grid,
        .grid_auto_flow = .row_dense,
        .width = .{ .length = 30 },
        .height = .{ .length = 20 },
        .grid_columns = &columns,
        .grid_rows = &rows,
        .grid_auto_rows = GridTrack.fixedPx(10),
    });
    const dense_explicit = try tree.create(.{ .grid_column = 2, .grid_row = 1 });
    const dense_wide = try tree.create(.{ .grid_column_span = 2 });
    const dense_small = try tree.create(.{});
    try tree.appendChild(dense, dense_explicit);
    try tree.appendChild(dense, dense_wide);
    try tree.appendChild(dense, dense_small);
    try tree.compute(dense, .{ .width = 30, .height = 20 });
    try std.testing.expectEqual(Layout{ .width = 10, .height = 10 }, try tree.readLayout(dense_small));
}

test "grid items honor explicit sizes alignment and auto margins" {
    const columns = [_]GridTrack{ GridTrack.fixedPx(100), GridTrack.fixedPx(100) };
    const rows = [_]GridTrack{ GridTrack.fixedPx(40), GridTrack.fixedPx(40) };
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 5 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 200 },
        .height = .{ .length = 80 },
        .grid_columns = &columns,
        .grid_rows = &rows,
    });
    const centered = try tree.create(.{
        .grid_column = 1,
        .grid_row = 1,
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
        .alignment = .center,
    });
    const percentage = try tree.create(.{
        .grid_column = 2,
        .grid_row = 1,
        .width = .{ .percent = 0.5 },
        .height = .{ .length = 20 },
        .alignment = .bottom_right,
    });
    const pushed = try tree.create(.{
        .grid_column = 1,
        .grid_row = 2,
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
        .auto_margin = .{ .left = true },
    });
    try tree.appendChild(root, centered);
    try tree.appendChild(root, percentage);
    try tree.appendChild(root, pushed);

    try tree.compute(root, .{ .width = 200, .height = 80 });
    try std.testing.expectEqual(Layout{ .x = 40, .y = 15, .width = 20, .height = 10 }, try tree.readLayout(centered));
    try std.testing.expectEqual(Layout{ .x = 150, .y = 20, .width = 50, .height = 20 }, try tree.readLayout(percentage));
    try std.testing.expectEqual(Layout{ .x = 80, .y = 40, .width = 20, .height = 10 }, try tree.readLayout(pushed));
}

test "grid auto tracks use intrinsic child dimensions before fr space" {
    const columns = [_]GridTrack{ .auto, .{ .fr = 1 } };
    const rows = [_]GridTrack{ .auto, .{ .fr = 1 } };
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
    const intrinsic = try tree.create(.{ .grid_column = 1, .grid_row = 1 });
    const fractional = try tree.create(.{
        .grid_column = 2,
        .grid_row = 2,
        .width = .{ .stretch = 1 },
        .height = .{ .stretch = 1 },
    });
    try tree.appendChild(root, intrinsic);
    try tree.appendChild(root, fractional);
    var probe = IntrinsicProbe{ .dimensions = .{ .width = 30, .height = 12 } };
    try tree.computeWithMeasure(root, .{ .width = 100, .height = 80 }, measureIntrinsic, &probe);
    try std.testing.expectEqual(Layout{ .width = 30, .height = 12 }, try tree.readLayout(intrinsic));
    try std.testing.expectEqual(Layout{ .x = 35, .y = 17, .width = 65, .height = 63 }, try tree.readLayout(fractional));
}

test "grid mixed fixed auto and fractional tracks stay finite without intrinsic data" {
    const columns = [_]GridTrack{ .{ .fixed = 20 }, .auto, .{ .fr = 1 } };
    const rows = [_]GridTrack{.{ .fixed = 40 }};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 100 },
        .height = .{ .length = 40 },
        .grid_columns = &columns,
        .grid_rows = &rows,
        .grid_gap = 5,
    });
    const first = try tree.create(.{ .grid_column = 1, .grid_row = 1, .width = .{ .stretch = 1 } });
    const second = try tree.create(.{ .grid_column = 2, .grid_row = 1, .width = .{ .stretch = 1 } });
    const third = try tree.create(.{ .grid_column = 3, .grid_row = 1, .width = .{ .stretch = 1 } });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.appendChild(root, third);
    try tree.compute(root, .{ .width = 100, .height = 40 });
    const first_layout = try tree.readLayout(first);
    const second_layout = try tree.readLayout(second);
    const third_layout = try tree.readLayout(third);
    try std.testing.expect(std.math.isFinite(first_layout.width));
    try std.testing.expect(std.math.isFinite(second_layout.width));
    try std.testing.expect(std.math.isFinite(third_layout.width));
    try std.testing.expectEqual(@as(f32, 70), third_layout.width);
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
    const too_many: [max_supported_grid_tracks + 1]GridTrack = @splat(.{ .fixed = 1 });
    var oversized_tree = LayoutTree.init(std.testing.allocator, .{
        .max_nodes = 1,
        .max_grid_tracks = max_supported_grid_tracks + 1,
    });
    defer oversized_tree.deinit();
    try std.testing.expectError(error.GridTrackCapacityExceeded, oversized_tree.create(.{
        .display = .grid,
        .grid_columns = &too_many,
        .grid_rows = &one,
    }));
}
test "grid minmax clamps bounds and redistributes fractional space" {
    const bounded = try GridTrack.minmax(80, 100);
    const columns = [_]GridTrack{ bounded, .{ .fr = 1 } };
    const rows = [_]GridTrack{.{ .fixed = 10 }};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 100 },
        .height = .{ .length = 10 },
        .grid_columns = &columns,
        .grid_rows = &rows,
    });
    const first = try tree.create(.{ .grid_column = 1, .grid_row = 1, .width = .{ .stretch = 1 } });
    const second = try tree.create(.{ .grid_column = 2, .grid_row = 1, .width = .{ .stretch = 1 } });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.compute(root, .{ .width = 100, .height = 10 });
    try std.testing.expectEqual(@as(f32, 80), (try tree.readLayout(first)).width);
    try std.testing.expectEqual(@as(f32, 20), (try tree.readLayout(second)).width);

    try tree.setStyle(root, .{
        .display = .grid,
        .width = .{ .length = 220 },
        .height = .{ .length = 10 },
        .grid_columns = &columns,
        .grid_rows = &rows,
    });
    try tree.compute(root, .{ .width = 220, .height = 10 });
    try std.testing.expectEqual(@as(f32, 100), (try tree.readLayout(first)).width);
    try std.testing.expectEqual(@as(f32, 120), (try tree.readLayout(second)).width);
}

test "grid minmax rejects invalid finite bounds and ordering" {
    try std.testing.expectError(error.InvalidStyle, GridTrack.minmax(20, 10));
    try std.testing.expectError(error.InvalidStyle, GridTrack.minmax(-1, 10));
    try std.testing.expectError(error.InvalidStyle, GridTrack.minmax(0, std.math.inf(f32)));
    const invalid = [_]GridTrack{.{ .bounded = .{ .min = 30, .max = 20 } }};
    const rows = [_]GridTrack{.{ .fixed = 10 }};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    try std.testing.expectError(error.InvalidStyle, tree.create(.{
        .display = .grid,
        .grid_columns = &invalid,
        .grid_rows = &rows,
    }));
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

test "rtl overlay alignment mirrors horizontal anchors within padded content" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .overlay,
        .direction = .rtl,
        .width = .{ .length = 100 },
        .height = .{ .length = 80 },
        .padding = .{ .left = 10, .right = 20 },
    });
    const start = try tree.create(.{
        .alignment = .top_left,
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    });
    const end = try tree.create(.{
        .alignment = .top_right,
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
    });
    const centered = try tree.create(.{
        .alignment = .center,
        .width = .{ .length = 10 },
        .height = .{ .length = 10 },
    });
    try tree.appendChild(root, start);
    try tree.appendChild(root, end);
    try tree.appendChild(root, centered);
    try tree.compute(root, .{ .width = 100, .height = 80 });
    try std.testing.expectEqual(Layout{ .x = 60, .width = 20, .height = 10 }, try tree.readLayout(start));
    try std.testing.expectEqual(Layout{ .x = 10, .width = 20, .height = 10 }, try tree.readLayout(end));
    try std.testing.expectEqual(Layout{ .x = 40, .y = 35, .width = 10, .height = 10 }, try tree.readLayout(centered));
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

test "flex auto margins absorb remaining main and cross space" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    });
    const first = try tree.create(.{
        .width = .{ .length = 10 },
        .height = .{ .length = 10 },
    });
    const second = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 20 },
        .auto_margin = .{ .left = true, .top = true, .bottom = true },
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);

    try tree.compute(root, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(Layout{ .x = 80, .y = 40, .width = 20, .height = 20 }, try tree.readLayout(second));
}

test "row flex baseline alignment uses explicit offsets" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 50 },
        .align_items = .baseline,
    });
    const first = try tree.create(.{
        .width = .{ .length = 10 },
        .height = .{ .length = 20 },
        .baseline = 15,
    });
    const second = try tree.create(.{
        .width = .{ .length = 10 },
        .height = .{ .length = 10 },
        .baseline = 5,
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);

    try tree.compute(root, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(@as(f32, 0), (try tree.readLayout(first)).y);
    try std.testing.expectEqual(@as(f32, 10), (try tree.readLayout(second)).y);
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

test "typed flex gaps resolve percentages, stretch, and bounds" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
        .flex_gap_spec = Gap.percentOfParent(0.1),
    });
    const first = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 10 } });
    const second = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 10 } });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.compute(root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(f32, 20), (try tree.readLayout(second)).x);

    try tree.setStyle(root, .{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
        .flex_gap_spec = Gap.stretchFactor(1),
    });
    try tree.compute(root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(f32, 90), (try tree.readLayout(second)).x);

    try tree.setStyle(root, .{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
        .flex_gap_spec = Gap.percentOfParent(0.1),
        .min_flex_gap_spec = Gap.fixedPx(25),
        .max_flex_gap_spec = Gap.fixedPx(30),
    });
    try tree.compute(root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(f32, 35), (try tree.readLayout(second)).x);
}

test "negative fixed gaps honor typed bounds" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 20 },
        .flex_gap_spec = Gap.fixedPx(-10),
        .min_flex_gap_spec = Gap.fixedPx(-4),
    });
    const first = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 10 } });
    const second = try tree.create(.{ .width = .{ .length = 10 }, .height = .{ .length = 10 } });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);
    try tree.compute(root, .{ .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(f32, 6), (try tree.readLayout(second)).x);
}

test "responsive padding and margins follow containing axes" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 200 },
        .height = .{ .length = 100 },
        .padding_spec = ResponsiveEdges.all(EdgeSize.percentOfParent(0.1)),
    });
    const child = try tree.create(.{
        .width = .{ .length = 20 },
        .height = .{ .length = 10 },
        .margin_spec = .{
            .left = EdgeSize.percentOfParent(0.1),
            .top = EdgeSize.percentOfParent(0.25),
        },
    });
    try tree.appendChild(root, child);
    try tree.compute(root, .{ .width = 200, .height = 100 });
    try std.testing.expectEqual(Layout{ .x = 36, .y = 30, .width = 20, .height = 10 }, try tree.readLayout(child));

    try tree.setStyle(root, .{
        .width = .{ .length = 100 },
        .height = .{ .length = 50 },
        .padding_spec = ResponsiveEdges.all(EdgeSize.percentOfParent(0.1)),
    });
    try tree.compute(root, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(Layout{ .x = 18, .y = 15, .width = 20, .height = 10 }, try tree.readLayout(child));
}

test "axis-specific typed gaps resolve flex wrapping and grid tracks" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 12 });
    defer tree.deinit();

    const flex_root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
        .flex_wrap = .wrap,
        .column_gap_spec = Gap.percentOfParent(0.1),
        .row_gap_spec = Gap.percentOfParent(0.2),
    });
    const flex_first = try tree.create(.{ .width = .{ .length = 45 }, .height = .{ .length = 10 } });
    const flex_second = try tree.create(.{ .width = .{ .length = 45 }, .height = .{ .length = 10 } });
    const flex_third = try tree.create(.{ .width = .{ .length = 45 }, .height = .{ .length = 10 } });
    try tree.appendChild(flex_root, flex_first);
    try tree.appendChild(flex_root, flex_second);
    try tree.appendChild(flex_root, flex_third);
    try tree.compute(flex_root, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(f32, 55), (try tree.readLayout(flex_second)).x);
    try std.testing.expectEqual(@as(f32, 30), (try tree.readLayout(flex_third)).y);

    const tracks = [_]GridTrack{ GridTrack.fixedPx(40), GridTrack.fixedPx(40) };
    const grid_root = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
        .grid_columns = &tracks,
        .grid_rows = &tracks,
        .column_gap_spec = Gap.percentOfParent(0.1),
        .row_gap_spec = Gap.fixedPx(5),
    });
    const grid_first = try tree.create(.{});
    const grid_second = try tree.create(.{});
    const grid_third = try tree.create(.{});
    try tree.appendChild(grid_root, grid_first);
    try tree.appendChild(grid_root, grid_second);
    try tree.appendChild(grid_root, grid_third);
    try tree.compute(grid_root, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(f32, 50), (try tree.readLayout(grid_second)).x);
    try std.testing.expectEqual(@as(f32, 45), (try tree.readLayout(grid_third)).y);
}

test "typed spacing rejects invalid values" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .flex_gap_spec = Gap.percentOfParent(std.math.inf(f32)) }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .min_flex_gap_spec = Gap.percentOfParent(-0.1) }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{ .max_flex_gap_spec = Gap.stretchFactor(0) }));
    try std.testing.expectError(error.InvalidStyle, tree.create(.{
        .padding_spec = .{ .left = EdgeSize.percentOfParent(-0.1) },
    }));
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

test "wrapped lines honor align content distribution" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .flex_wrap = .wrap,
        .width = .{ .length = 50 },
        .height = .{ .length = 100 },
        .align_content = .center,
    });
    const first = try tree.create(.{ .width = .{ .length = 30 }, .height = .{ .length = 10 } });
    const second = try tree.create(.{ .width = .{ .length = 30 }, .height = .{ .length = 10 } });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);

    try tree.compute(root, .{ .width = 50, .height = 100 });
    try std.testing.expectEqual(@as(f32, 40), (try tree.readLayout(first)).y);
    try std.testing.expectEqual(@as(f32, 50), (try tree.readLayout(second)).y);

    try tree.setStyle(root, .{
        .flex_wrap = .wrap,
        .width = .{ .length = 50 },
        .height = .{ .length = 100 },
        .align_content = .space_between,
    });
    try tree.compute(root, .{ .width = 50, .height = 100 });
    try std.testing.expectEqual(@as(f32, 0), (try tree.readLayout(first)).y);
    try std.testing.expectEqual(@as(f32, 90), (try tree.readLayout(second)).y);
}

test "reverse wrapping stacks lines from the opposite cross edge" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 8 });
    defer tree.deinit();
    const root = try tree.create(.{
        .flex_wrap = .wrap_reverse,
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
    try std.testing.expectEqual(Layout{ .y = 30, .width = 30, .height = 10 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .y = 20, .width = 30, .height = 10 }, try tree.readLayout(second));
    try std.testing.expectEqual(Layout{ .x = 30, .y = 20, .width = 20, .height = 10 }, try tree.readLayout(third));
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
