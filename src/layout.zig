//! Core two-axis sizing primitives.
//!
//! This file follows the intrinsic sizing and breadth-first distribution
//! sections of the pinned Clay header. Tree construction, text measurement,
//! command generation, interaction, and persistence live in `Context`.

const std = @import("std");
const types = @import("types.zig");

pub const epsilon: f32 = 0.01;

const HeightTraversalState = enum(u2) {
    unseen,
    active,
    complete,
};

pub const Node = struct {
    element_id: types.ElementId = .{},
    config: types.ElementDeclaration = .{},
    text_config: types.TextElementConfig = .{},
    dimensions: types.Dimensions = .{},
    min_dimensions: types.Dimensions = .{},
    bounding_box: types.BoundingBox = .{},
    bounding_box_valid: bool = false,
    children_start: usize = 0,
    children_len: usize = 0,
    floating_children_count: usize = 0,
    parent_index: ?usize = null,
    clip_element_id: u32 = 0,
    /// Exact frame-local source of `clip_element_id`. Duplicate IDs make an ID
    /// lookup ambiguous, so render/hit traversal uses this index when present.
    clip_node_index: ?usize = null,
    text_index: ?usize = null,
    on_hover: ?types.HoverFunction = null,
    hover_user_data: ?*anyopaque = null,
    configured: bool = false,
    is_text: bool = false,
    exiting: bool = false,
    height_traversal_cursor: usize = 0,
    height_traversal_state: HeightTraversalState = .unseen,
    height_has_parent_edge: bool = false,
    height_is_root: bool = false,
    /// Clay's percent sizing shares storage with `minMax`: the percentage is
    /// the first float and the aspect pass may write the otherwise inactive
    /// maximum float. Zig tracks the active union field in safety builds, so
    /// retain that second C-union value explicitly instead of reading an
    /// inactive `SizingAxisSize.min_max` field.
    percent_height_max: f32 = 0,

    pub fn children(self: Node, child_indices: []const usize) []const usize {
        const end = @min(child_indices.len, self.children_start +| self.children_len);
        const start = @min(self.children_start, end);
        return child_indices[start..end];
    }
};

pub const Root = struct {
    element_index: usize,
    parent_id: u32 = 0,
    parent_node_index: ?usize = null,
    clip_element_id: u32 = 0,
    clip_node_index: ?usize = null,
    z_index: i16 = 0,
};

pub fn floatEqual(left: f32, right: f32) bool {
    const difference = left - right;
    return difference < epsilon and difference > -epsilon;
}

fn axisDimension(dimensions: *types.Dimensions, x_axis: bool) *f32 {
    return if (x_axis) &dimensions.width else &dimensions.height;
}

fn axisDimensionValue(dimensions: types.Dimensions, x_axis: bool) f32 {
    return if (x_axis) dimensions.width else dimensions.height;
}

fn axisSizing(node: *const Node, x_axis: bool) types.SizingAxis {
    // Clay__GetElementSizing deliberately ignores CLAY_LAYOUT_DEFAULT for
    // text elements and returns a zero/default FIT axis. The writable global
    // is consulted later by the final tree/render walk instead.
    if (node.is_text) return .{};
    return if (x_axis) node.config.layout.sizing.width else node.config.layout.sizing.height;
}

fn axisMinMax(axis: types.SizingAxis) types.SizingMinMax {
    return axis.size.min_max;
}

fn heightPropagationBounds(node: *const Node) types.SizingMinMax {
    const height = node.config.layout.sizing.height;
    if (height.type == .percent) {
        return .{
            .min = height.size.percent,
            .max = node.percent_height_max,
        };
    }
    return axisMinMax(height);
}

fn paddingAlongAxis(layout_config: *const types.LayoutConfig, x_axis: bool) f32 {
    return if (x_axis)
        @floatFromInt(@as(u32, layout_config.padding.left) + layout_config.padding.right)
    else
        @floatFromInt(@as(u32, layout_config.padding.top) + layout_config.padding.bottom);
}

fn childGapSize(child_count: usize, child_gap: u16) f32 {
    const gap_count = child_count -| 1;
    // A practical wasm32 tree can exceed the `usize` multiplication boundary
    // when the public u16 gap is large. The mathematical product always fits
    // u80 on supported targets; widen before multiplying, then round once to
    // f32 just like Clay's defined-range integer expression.
    const total: u128 = @as(u128, gap_count) * @as(u128, child_gap);
    return @floatFromInt(total);
}

fn sizingAlongAxis(layout_config: *const types.LayoutConfig, x_axis: bool) bool {
    return (x_axis and layout_config.layout_direction == .left_to_right) or
        (!x_axis and layout_config.layout_direction == .top_to_bottom);
}

fn normalizeAxis(axis: *types.SizingAxis) void {
    if (axis.type == .percent) return;
    if (axis.size.min_max.max <= 0) axis.size.min_max.max = std.math.floatMax(f32);
}

pub fn normalizeSizing(node: *Node) void {
    normalizeAxis(&node.config.layout.sizing.width);
    normalizeAxis(&node.config.layout.sizing.height);
}

pub fn updateAspectRatio(node: *Node) void {
    const ratio = node.config.aspect_ratio.aspect_ratio;
    if (ratio == 0) return;
    if (node.dimensions.width == 0 and node.dimensions.height != 0) {
        node.dimensions.width = node.dimensions.height * ratio;
    } else if (node.dimensions.width != 0 and node.dimensions.height == 0) {
        node.dimensions.height = node.dimensions.width * (1 / ratio);
    }
}

/// Calculate an element's intrinsic dimensions after all direct children have
/// already been finalized. Text nodes are measured before this function and do
/// not need intrinsic aggregation.
pub fn finalizeIntrinsic(nodes: []Node, child_indices: []const usize, node_index: usize) void {
    if (node_index >= nodes.len) return;
    if (nodes[node_index].children_start > child_indices.len or
        nodes[node_index].children_len > child_indices.len - nodes[node_index].children_start)
    {
        return;
    }
    for (nodes[node_index].children(child_indices)) |child_index| {
        if (child_index >= nodes.len) return;
    }
    var node = &nodes[node_index];
    if (node.is_text) return;

    const layout_config = &node.config.layout;
    const horizontal_clip = node.config.clip.horizontal;
    const vertical_clip = node.config.clip.vertical;
    const horizontal_padding: f32 = @floatFromInt(@as(u32, layout_config.padding.left) + layout_config.padding.right);
    const vertical_padding: f32 = @floatFromInt(@as(u32, layout_config.padding.top) + layout_config.padding.bottom);
    const children = node.children(child_indices);

    if (layout_config.layout_direction == .left_to_right) {
        node.dimensions.width = horizontal_padding;
        node.min_dimensions.width = horizontal_padding;
        for (children) |child_index| {
            const child = &nodes[child_index];
            node.dimensions.width += child.dimensions.width;
            node.dimensions.height = @max(node.dimensions.height, child.dimensions.height + vertical_padding);
            if (!horizontal_clip) node.min_dimensions.width += child.min_dimensions.width;
            if (!vertical_clip) node.min_dimensions.height = @max(node.min_dimensions.height, child.min_dimensions.height + vertical_padding);
        }
        const total_gap = childGapSize(children.len, layout_config.child_gap);
        node.dimensions.width += total_gap;
        if (!horizontal_clip) node.min_dimensions.width += total_gap;
    } else {
        node.dimensions.height = vertical_padding;
        node.min_dimensions.height = vertical_padding;
        for (children) |child_index| {
            const child = &nodes[child_index];
            node.dimensions.height += child.dimensions.height;
            node.dimensions.width = @max(node.dimensions.width, child.dimensions.width + horizontal_padding);
            if (!vertical_clip) node.min_dimensions.height += child.min_dimensions.height;
            if (!horizontal_clip) node.min_dimensions.width = @max(node.min_dimensions.width, child.min_dimensions.width + horizontal_padding);
        }
        const total_gap = childGapSize(children.len, layout_config.child_gap);
        node.dimensions.height += total_gap;
        if (!vertical_clip) node.min_dimensions.height += total_gap;
    }

    normalizeSizing(node);
    const width = node.config.layout.sizing.width;
    if (width.type == .percent) {
        node.dimensions.width = 0;
    } else {
        const bounds = axisMinMax(width);
        node.dimensions.width = @min(@max(node.dimensions.width, bounds.min), bounds.max);
        node.min_dimensions.width = @min(@max(node.min_dimensions.width, bounds.min), bounds.max);
    }

    const height = node.config.layout.sizing.height;
    if (height.type == .percent) {
        node.dimensions.height = 0;
    } else {
        const bounds = axisMinMax(height);
        node.dimensions.height = @min(@max(node.dimensions.height, bounds.min), bounds.max);
        node.min_dimensions.height = @min(@max(node.min_dimensions.height, bounds.min), bounds.max);
    }
    updateAspectRatio(node);
}

fn removeSwapBack(list: *std.ArrayList(usize), index: usize) void {
    _ = list.swapRemove(index);
}

fn scratchListsAlias(left: *const std.ArrayList(usize), right: *const std.ArrayList(usize)) bool {
    if (left == right) return true;
    if (left.capacity == 0 or right.capacity == 0) return false;
    const element_size = @sizeOf(usize);
    const left_bytes = std.math.mul(usize, left.capacity, element_size) catch return true;
    const right_bytes = std.math.mul(usize, right.capacity, element_size) catch return true;
    const left_start = @intFromPtr(left.items.ptr);
    const right_start = @intFromPtr(right.items.ptr);
    const left_end = std.math.add(usize, left_start, left_bytes) catch return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch return true;
    return left_start < right_end and right_start < left_end;
}

/// Mutation-oriented port of Clay's breadth-first container distribution pass.
/// The direct writes preserve the source implementation's `f32` operation
/// order.
pub fn sizeContainersAlongAxis(
    allocator: std.mem.Allocator,
    nodes: []Node,
    child_indices: []const usize,
    roots: []const Root,
    id_to_index: *const std.AutoHashMap(u32, usize),
    x_axis: bool,
) !void {
    var bfs: std.ArrayList(usize) = .empty;
    defer bfs.deinit(allocator);
    var resizable: std.ArrayList(usize) = .empty;
    defer resizable.deinit(allocator);
    try sizeContainersAlongAxisWithScratch(
        allocator,
        nodes,
        child_indices,
        roots,
        id_to_index,
        x_axis,
        &bfs,
        &resizable,
        null,
    );
}

/// Context-oriented sizing entry point. The caller owns the two scratch lists,
/// allowing warmed frames to reuse their capacity instead of allocating fresh
/// breadth-first buffers for every axis pass.
pub fn sizeContainersAlongAxisWithScratch(
    allocator: std.mem.Allocator,
    nodes: []Node,
    child_indices: []const usize,
    roots: []const Root,
    id_to_index: *const std.AutoHashMap(u32, usize),
    x_axis: bool,
    bfs: *std.ArrayList(usize),
    resizable: *std.ArrayList(usize),
    aspect_ratios: ?*std.ArrayList(usize),
) !void {
    if (scratchListsAlias(bfs, resizable)) return error.InvalidScratchAliasing;
    if (aspect_ratios) |indexes| {
        if (scratchListsAlias(indexes, bfs) or scratchListsAlias(indexes, resizable)) {
            return error.InvalidScratchAliasing;
        }
    }
    _ = try validateForest(nodes, child_indices, roots);
    for (roots) |root| {
        const root_node = &nodes[root.element_index];
        if (root_node.config.floating.attach_to == .none) continue;
        if (root.parent_node_index orelse id_to_index.get(root_node.config.floating.parent_id)) |parent_index| {
            if (parent_index >= nodes.len or
                nodes[parent_index].element_id.id != root_node.config.floating.parent_id)
            {
                return error.InvalidTreeParent;
            }
        }
    }

    // No allocator call may follow the first dimension mutation. A forest can
    // enqueue each node at most once and no resizable sibling set can exceed
    // the node count. Aspect-ratio results append to caller-retained output.
    try bfs.ensureTotalCapacity(allocator, nodes.len);
    try resizable.ensureTotalCapacity(allocator, nodes.len);
    if (aspect_ratios) |indexes| {
        const required_capacity = std.math.add(usize, indexes.items.len, nodes.len) catch
            return error.OutOfMemory;
        try indexes.ensureTotalCapacity(allocator, required_capacity);
    }

    for (roots) |root| {
        bfs.clearRetainingCapacity();
        const root_node = &nodes[root.element_index];
        try bfs.append(allocator, root.element_index);

        if (root_node.config.floating.attach_to != .none) {
            if (root.parent_node_index orelse id_to_index.get(root_node.config.floating.parent_id)) |parent_index| {
                const parent = &nodes[parent_index];
                const parent_size = axisDimensionValue(parent.dimensions, x_axis);
                const root_axis = axisSizing(root_node, x_axis);
                const root_size = axisDimension(&root_node.dimensions, x_axis);
                switch (root_axis.type) {
                    .grow => root_size.* = parent_size,
                    .percent => root_size.* = parent_size * root_axis.size.percent,
                    else => {},
                }
            }
        }

        const root_width = root_node.config.layout.sizing.width;
        if (root_width.type != .percent) {
            const bounds = axisMinMax(root_width);
            root_node.dimensions.width = @min(@max(root_node.dimensions.width, bounds.min), bounds.max);
        }
        const root_height = root_node.config.layout.sizing.height;
        if (root_height.type != .percent) {
            const bounds = axisMinMax(root_height);
            root_node.dimensions.height = @min(@max(root_node.dimensions.height, bounds.min), bounds.max);
        }

        var bfs_index: usize = 0;
        while (bfs_index < bfs.items.len) : (bfs_index += 1) {
            const parent = &nodes[bfs.items[bfs_index]];
            const parent_layout = &parent.config.layout;
            const parent_size = axisDimensionValue(parent.dimensions, x_axis);
            const parent_padding = paddingAlongAxis(parent_layout, x_axis);
            var inner_content_size: f32 = 0;
            var total_padding_and_gaps = parent_padding;
            const along_axis = sizingAlongAxis(parent_layout, x_axis);
            resizable.clearRetainingCapacity();
            var grow_count: usize = 0;
            var first_child = true;

            for (parent.children(child_indices)) |child_index| {
                const child = &nodes[child_index];
                const child_sizing = axisSizing(child, x_axis);
                const child_size = axisDimensionValue(child.dimensions, x_axis);

                if (!child.is_text and child.children_len > 0) try bfs.append(allocator, child_index);
                if (!child.is_text and child.config.aspect_ratio.aspect_ratio != 0) {
                    if (aspect_ratios) |indexes| try indexes.append(allocator, child_index);
                }
                if (child.exiting) continue;

                if (child_sizing.type != .percent and child_sizing.type != .fixed and
                    (!child.is_text or child.text_config.wrap_mode == .words))
                {
                    try resizable.append(allocator, child_index);
                }

                if (along_axis) {
                    if (child_sizing.type != .percent) inner_content_size += child_size;
                    if (child_sizing.type == .grow) grow_count += 1;
                    if (!first_child) {
                        const gap: f32 = @floatFromInt(parent_layout.child_gap);
                        inner_content_size += gap;
                        total_padding_and_gaps += gap;
                    }
                } else {
                    inner_content_size = @max(child_size, inner_content_size);
                }
                first_child = false;
            }

            for (parent.children(child_indices)) |child_index| {
                const child = &nodes[child_index];
                const child_sizing = axisSizing(child, x_axis);
                if (child_sizing.type != .percent) continue;
                const child_size = axisDimension(&child.dimensions, x_axis);
                child_size.* = (parent_size - total_padding_and_gaps) * child_sizing.size.percent;
                if (along_axis) inner_content_size += child_size.*;
                updateAspectRatio(child);
            }

            if (along_axis) {
                var size_to_distribute = parent_size - parent_padding - inner_content_size;
                // Invalid or overflowed public dimensions can make this value
                // infinite. The leveling loops require a finite amount that
                // can make progress; entering them with infinity can spin
                // forever when an infinite child is also the active extreme.
                if (!std.math.isFinite(size_to_distribute)) continue;
                if (size_to_distribute < 0) {
                    if ((x_axis and parent.config.clip.horizontal) or (!x_axis and parent.config.clip.vertical)) continue;
                    while (size_to_distribute < -epsilon and resizable.items.len > 0) {
                        const size_before = size_to_distribute;
                        const count_before = resizable.items.len;
                        var largest: f32 = 0;
                        var second_largest: f32 = 0;
                        var amount = size_to_distribute;
                        for (resizable.items) |child_index| {
                            const child_size = axisDimensionValue(nodes[child_index].dimensions, x_axis);
                            if (floatEqual(child_size, largest)) continue;
                            if (child_size > largest) {
                                second_largest = largest;
                                largest = child_size;
                            }
                            if (child_size < largest) {
                                second_largest = @max(second_largest, child_size);
                                amount = second_largest - largest;
                            }
                        }
                        amount = @max(amount, size_to_distribute / @as(f32, @floatFromInt(resizable.items.len)));

                        var index: usize = 0;
                        while (index < resizable.items.len) {
                            const child = &nodes[resizable.items[index]];
                            const child_size = axisDimension(&child.dimensions, x_axis);
                            const minimum = axisDimensionValue(child.min_dimensions, x_axis);
                            const previous = child_size.*;
                            if (floatEqual(child_size.*, largest)) {
                                child_size.* += amount;
                                var removed = false;
                                if (child_size.* <= minimum) {
                                    child_size.* = minimum;
                                    removeSwapBack(resizable, index);
                                    removed = true;
                                }
                                size_to_distribute -= child_size.* - previous;
                                if (removed) continue;
                            }
                            index += 1;
                        }
                        if (resizable.items.len == count_before and size_to_distribute == size_before) break;
                    }
                } else if (size_to_distribute > 0 and grow_count > 0) {
                    var index: usize = 0;
                    while (index < resizable.items.len) {
                        if (axisSizing(&nodes[resizable.items[index]], x_axis).type != .grow) {
                            removeSwapBack(resizable, index);
                        } else {
                            index += 1;
                        }
                    }

                    while (size_to_distribute > epsilon and resizable.items.len > 0) {
                        const size_before = size_to_distribute;
                        const count_before = resizable.items.len;
                        var smallest = std.math.floatMax(f32);
                        var second_smallest = std.math.floatMax(f32);
                        var amount = size_to_distribute;
                        for (resizable.items) |child_index| {
                            const child_size = axisDimensionValue(nodes[child_index].dimensions, x_axis);
                            if (floatEqual(child_size, smallest)) continue;
                            if (child_size < smallest) {
                                second_smallest = smallest;
                                smallest = child_size;
                            }
                            if (child_size > smallest) {
                                second_smallest = @min(second_smallest, child_size);
                                amount = second_smallest - smallest;
                            }
                        }
                        amount = @min(amount, size_to_distribute / @as(f32, @floatFromInt(resizable.items.len)));

                        index = 0;
                        while (index < resizable.items.len) {
                            const child = &nodes[resizable.items[index]];
                            const child_size = axisDimension(&child.dimensions, x_axis);
                            const bounds = axisMinMax(axisSizing(child, x_axis));
                            const previous = child_size.*;
                            if (floatEqual(child_size.*, smallest)) {
                                child_size.* += amount;
                                if (child_size.* >= bounds.max) {
                                    child_size.* = bounds.max;
                                    removeSwapBack(resizable, index);
                                } else {
                                    index += 1;
                                }
                                size_to_distribute -= child_size.* - previous;
                            } else {
                                index += 1;
                            }
                        }
                        if (resizable.items.len == count_before and size_to_distribute == size_before) break;
                    }
                }
            } else {
                for (resizable.items) |child_index| {
                    const child = &nodes[child_index];
                    const child_sizing = axisSizing(child, x_axis);
                    const minimum = axisDimensionValue(child.min_dimensions, x_axis);
                    const child_size = axisDimension(&child.dimensions, x_axis);
                    var maximum = parent_size - parent_padding;
                    if ((x_axis and parent.config.clip.horizontal) or (!x_axis and parent.config.clip.vertical)) {
                        maximum = @max(maximum, inner_content_size);
                    }
                    if (child_sizing.type == .grow) {
                        maximum = @min(maximum, axisMinMax(child_sizing).max);
                        child_size.* = maximum;
                    }
                    child_size.* = @max(minimum, @min(child_size.*, maximum));
                }
            }
        }
    }
}

/// Validate the complete public node graph before a sizing pass can mutate
/// dimensions. Declaration-ordered complete forests are acyclic by
/// construction; arbitrary-order or disconnected graphs receive the same
/// iterative cycle validation as height propagation.
fn validateForest(nodes: []Node, child_indices: []const usize, roots: []const Root) !void {
    for (nodes) |*node| {
        node.height_traversal_cursor = 0;
        node.height_traversal_state = .unseen;
        node.height_has_parent_edge = false;
        node.height_is_root = false;
    }

    var declaration_ordered = true;
    var edge_count: usize = 0;
    for (nodes, 0..) |node, parent_index| {
        if (node.children_start > child_indices.len or
            node.children_len > child_indices.len - node.children_start)
        {
            return error.InvalidTreeParent;
        }
        for (node.children(child_indices)) |child_index| {
            edge_count +|= 1;
            if (child_index >= nodes.len) return error.InvalidTreeParent;
            if (nodes[child_index].parent_index != parent_index) return error.InvalidTreeParent;
            if (child_index == parent_index or nodes[child_index].height_has_parent_edge) {
                return error.InvalidTreeParent;
            }
            nodes[child_index].height_has_parent_edge = true;
            if (child_index <= parent_index) declaration_ordered = false;
        }
    }

    for (roots) |root| {
        if (root.element_index >= nodes.len) return error.InvalidTreeParent;
        const root_node = &nodes[root.element_index];
        if (root_node.height_is_root or root_node.height_has_parent_edge) {
            return error.InvalidTreeParent;
        }
        root_node.height_is_root = true;
    }

    var complete_forest = edge_count == nodes.len -| roots.len;
    if (complete_forest) {
        for (nodes) |node| {
            if (!node.height_is_root and !node.height_has_parent_edge) {
                complete_forest = false;
                break;
            }
        }
    }
    if (declaration_ordered and complete_forest) return;

    for (roots) |root| {
        try traverseHeightComponent(nodes, child_indices, root.element_index, false);
    }
    for (nodes, 0..) |node, node_index| {
        if (node.height_traversal_state == .unseen and !node.height_has_parent_edge) {
            try traverseHeightComponent(nodes, child_indices, node_index, false);
        }
    }
    for (nodes) |node| {
        if (node.height_traversal_state == .unseen) return error.InvalidTreeParent;
    }
}

/// Recompute ancestor heights after wrapping text and scaling aspect-ratio
/// children, matching the post-order propagation between Clay's X and Y passes.
pub fn propagateHeights(nodes: []Node, child_indices: []const usize, roots: []const Root) !void {
    for (nodes) |*node| {
        node.height_traversal_cursor = 0;
        node.height_traversal_state = .unseen;
        node.height_has_parent_edge = false;
        node.height_is_root = false;
    }

    // Context declarations append every child after its parent and every node
    // belongs either to one explicit root or one parent child-list. Preserve the
    // linear reverse-order fast path for that complete forest, while retaining
    // this exported helper's root-driven behavior for arbitrary node ordering.
    var declaration_ordered = true;
    var edge_count: usize = 0;
    for (nodes, 0..) |node, parent_index| {
        if (node.children_start > child_indices.len or
            node.children_len > child_indices.len - node.children_start)
        {
            return error.InvalidTreeParent;
        }
        for (node.children(child_indices)) |child_index| {
            edge_count +|= 1;
            if (child_index >= nodes.len) return error.InvalidTreeParent;
            if (nodes[child_index].parent_index != parent_index) return error.InvalidTreeParent;
            if (child_index == parent_index or nodes[child_index].height_has_parent_edge) {
                return error.InvalidTreeParent;
            }
            nodes[child_index].height_has_parent_edge = true;
            if (child_index <= parent_index) declaration_ordered = false;
        }
    }

    for (roots) |root| {
        if (root.element_index >= nodes.len) return error.InvalidTreeParent;
        const root_node = &nodes[root.element_index];
        if (root_node.height_is_root or root_node.height_has_parent_edge) {
            return error.InvalidTreeParent;
        }
        root_node.height_is_root = true;
    }

    var complete_forest = edge_count == nodes.len -| roots.len;
    if (complete_forest) {
        for (nodes) |node| {
            if (!node.height_is_root and !node.height_has_parent_edge) {
                complete_forest = false;
                break;
            }
        }
    }

    if (declaration_ordered and complete_forest) {
        var node_index = nodes.len;
        while (node_index > 0) {
            node_index -= 1;
            propagateHeightNode(nodes, child_indices, node_index);
        }
        return;
    }

    // Validate the entire arbitrary-order graph before changing dimensions.
    // Supplied roots are walked first, then disconnected zero-incoming
    // components. Anything still unseen is part of a cycle.
    for (roots) |root| {
        try traverseHeightComponent(nodes, child_indices, root.element_index, false);
    }
    for (nodes, 0..) |node, node_index| {
        if (node.height_traversal_state == .unseen and !node.height_has_parent_edge) {
            try traverseHeightComponent(nodes, child_indices, node_index, false);
        }
    }
    for (nodes) |node| {
        if (node.height_traversal_state == .unseen) return error.InvalidTreeParent;
    }

    // Compatibility path for exported/advanced use: apply heights only to the
    // supplied roots after validation succeeds. A cursor stored on each node
    // makes returning from a child O(1), avoiding quadratic sibling searches.
    for (nodes) |*node| {
        node.height_traversal_cursor = 0;
        node.height_traversal_state = .unseen;
    }
    for (roots) |root| {
        try traverseHeightComponent(nodes, child_indices, root.element_index, true);
    }
}

fn traverseHeightComponent(
    nodes: []Node,
    child_indices: []const usize,
    root_index: usize,
    apply_heights: bool,
) !void {
    if (nodes[root_index].height_traversal_state != .unseen) return error.InvalidTreeParent;
    nodes[root_index].height_traversal_state = .active;
    nodes[root_index].height_traversal_cursor = 0;
    var current = root_index;
    var step_count: usize = 0;
    const step_count_max = std.math.mul(usize, nodes.len, 2) catch
        return error.InvalidTreeParent;

    while (step_count < step_count_max) : (step_count += 1) {
        const node = &nodes[current];
        const children = node.children(child_indices);
        if (node.height_traversal_cursor < children.len) {
            const child_index = children[node.height_traversal_cursor];
            node.height_traversal_cursor += 1;
            if (nodes[child_index].height_traversal_state != .unseen) {
                return error.InvalidTreeParent;
            }
            nodes[child_index].height_traversal_state = .active;
            nodes[child_index].height_traversal_cursor = 0;
            current = child_index;
            continue;
        }

        if (apply_heights) propagateHeightNode(nodes, child_indices, current);
        node.height_traversal_state = .complete;
        if (current == root_index) return;
        const parent_index = node.parent_index orelse return error.InvalidTreeParent;
        if (parent_index >= nodes.len or nodes[parent_index].height_traversal_state != .active) {
            return error.InvalidTreeParent;
        }
        current = parent_index;
    }
    return error.InvalidTreeParent;
}

fn propagateHeightNode(nodes: []Node, child_indices: []const usize, node_index: usize) void {
    const node = &nodes[node_index];
    if (node.is_text or node.children_len == 0) return;

    const layout_config = &node.config.layout;
    if (layout_config.layout_direction == .left_to_right) {
        for (node.children(child_indices)) |child_index| {
            const child = &nodes[child_index];
            const padded = @max(
                child.dimensions.height + @as(f32, @floatFromInt(@as(u32, layout_config.padding.top) + layout_config.padding.bottom)),
                node.dimensions.height,
            );
            const bounds = heightPropagationBounds(node);
            node.dimensions.height = @min(@max(padded, bounds.min), bounds.max);
        }
    } else {
        var content_height: f32 = @floatFromInt(@as(u32, layout_config.padding.top) + layout_config.padding.bottom);
        for (node.children(child_indices)) |child_index| content_height += nodes[child_index].dimensions.height;
        content_height += childGapSize(node.children_len, layout_config.child_gap);
        const bounds = heightPropagationBounds(node);
        node.dimensions.height = @min(@max(content_height, bounds.min), bounds.max);
    }
}

pub fn sortRootsByZ(roots: []Root) void {
    std.mem.sort(Root, roots, {}, struct {
        fn lessThan(_: void, left: Root, right: Root) bool {
            return left.z_index < right.z_index;
        }
    }.lessThan);
}

test "root z sort is ordered and stable" {
    var roots = [_]Root{
        .{ .element_index = 1, .z_index = 4 },
        .{ .element_index = 2, .z_index = -1 },
        .{ .element_index = 3, .z_index = 4 },
        .{ .element_index = 4, .z_index = 2 },
    };

    sortRootsByZ(&roots);

    try std.testing.expectEqualSlices(usize, &.{ 2, 4, 1, 3 }, &.{
        roots[0].element_index,
        roots[1].element_index,
        roots[2].element_index,
        roots[3].element_index,
    });
}

test "grow children divide remaining width" {
    const allocator = std.testing.allocator;
    var nodes = [_]Node{
        .{
            .element_id = .{ .id = 1 },
            .config = .{ .layout = .{ .sizing = .{ .width = types.fixed(300), .height = types.fixed(100) } } },
            .dimensions = .{ .width = 300, .height = 100 },
            .min_dimensions = .{ .width = 300, .height = 100 },
            .children_len = 2,
        },
        .{ .element_id = .{ .id = 2 }, .config = .{ .layout = .{ .sizing = .{ .width = types.grow(), .height = types.fixed(20) } } }, .parent_index = 0 },
        .{ .element_id = .{ .id = 3 }, .config = .{ .layout = .{ .sizing = .{ .width = types.grow(), .height = types.fixed(20) } } }, .parent_index = 0 },
    };
    const children = [_]usize{ 1, 2 };
    normalizeSizing(&nodes[1]);
    normalizeSizing(&nodes[2]);
    const roots = [_]Root{.{ .element_index = 0 }};
    var ids = std.AutoHashMap(u32, usize).init(allocator);
    defer ids.deinit();
    try ids.put(1, 0);
    try sizeContainersAlongAxis(allocator, &nodes, &children, &roots, &ids, true);
    try std.testing.expectEqual(@as(f32, 150), nodes[1].dimensions.width);
    try std.testing.expectEqual(@as(f32, 150), nodes[2].dimensions.width);
}

test "child gap totals cannot overflow native word size" {
    const total = childGapSize(std.math.maxInt(usize), std.math.maxInt(u16));
    try std.testing.expect(std.math.isFinite(total));
    try std.testing.expect(total > 0);
}

test "percentage sizing excludes padding and gaps" {
    const allocator = std.testing.allocator;
    var nodes = [_]Node{
        .{
            .element_id = .{ .id = 1 },
            .config = .{ .layout = .{
                .sizing = .{ .width = types.fixed(220), .height = types.fixed(100) },
                .padding = types.padding(10),
                .child_gap = 10,
            } },
            .dimensions = .{ .width = 220, .height = 100 },
            .children_len = 2,
        },
        .{ .element_id = .{ .id = 2 }, .config = .{ .layout = .{ .sizing = .{ .width = types.percent(0.5), .height = types.fixed(20) } } }, .parent_index = 0 },
        .{ .element_id = .{ .id = 3 }, .config = .{ .layout = .{ .sizing = .{ .width = types.percent(0.5), .height = types.fixed(20) } } }, .parent_index = 0 },
    };
    const children = [_]usize{ 1, 2 };
    const roots = [_]Root{.{ .element_index = 0 }};
    var ids = std.AutoHashMap(u32, usize).init(allocator);
    defer ids.deinit();
    try ids.put(1, 0);
    try sizeContainersAlongAxis(allocator, &nodes, &children, &roots, &ids, true);
    try std.testing.expectEqual(@as(f32, 95), nodes[1].dimensions.width);
    try std.testing.expectEqual(@as(f32, 95), nodes[2].dimensions.width);
}

test "public sizing helpers reject malformed graphs before dimensions change" {
    const allocator = std.testing.allocator;
    var ids = std.AutoHashMap(u32, usize).init(allocator);
    defer ids.deinit();

    var invalid_root_nodes = [_]Node{.{ .dimensions = .{ .width = 41 } }};
    const invalid_roots = [_]Root{.{ .element_index = 1 }};
    try std.testing.expectError(
        error.InvalidTreeParent,
        sizeContainersAlongAxis(allocator, &invalid_root_nodes, &.{}, &invalid_roots, &ids, true),
    );
    try std.testing.expectEqual(@as(f32, 41), invalid_root_nodes[0].dimensions.width);

    var invalid_child_nodes = [_]Node{.{
        .dimensions = .{ .width = 42 },
        .children_len = 1,
    }};
    const invalid_child_indices = [_]usize{1};
    const valid_root = [_]Root{.{ .element_index = 0 }};
    try std.testing.expectError(
        error.InvalidTreeParent,
        sizeContainersAlongAxis(allocator, &invalid_child_nodes, &invalid_child_indices, &valid_root, &ids, true),
    );
    try std.testing.expectEqual(@as(f32, 42), invalid_child_nodes[0].dimensions.width);

    var cyclic_nodes = [_]Node{.{
        .dimensions = .{ .width = 43 },
        .children_len = 1,
        .parent_index = 0,
    }};
    const cyclic_children = [_]usize{0};
    const no_roots = [_]Root{};
    try std.testing.expectError(
        error.InvalidTreeParent,
        sizeContainersAlongAxis(allocator, &cyclic_nodes, &cyclic_children, &no_roots, &ids, true),
    );
    try std.testing.expectEqual(@as(f32, 43), cyclic_nodes[0].dimensions.width);

    var floating_nodes = [_]Node{.{
        .element_id = .{ .id = 7 },
        .dimensions = .{ .width = 44 },
        .config = .{ .floating = .{
            .parent_id = 9,
            .attach_to = .element_with_id,
        } },
    }};
    try ids.put(9, 1);
    try std.testing.expectError(
        error.InvalidTreeParent,
        sizeContainersAlongAxis(allocator, &floating_nodes, &.{}, &valid_root, &ids, true),
    );
    try std.testing.expectEqual(@as(f32, 44), floating_nodes[0].dimensions.width);
}

test "sizing scratch buffers must be distinct" {
    const allocator = std.testing.allocator;
    var nodes = [_]Node{.{}};
    const roots = [_]Root{.{ .element_index = 0 }};
    var ids = std.AutoHashMap(u32, usize).init(allocator);
    defer ids.deinit();
    var scratch: std.ArrayList(usize) = .empty;
    defer scratch.deinit(allocator);

    try std.testing.expectError(
        error.InvalidScratchAliasing,
        sizeContainersAlongAxisWithScratch(
            allocator,
            &nodes,
            &.{},
            &roots,
            &ids,
            true,
            &scratch,
            &scratch,
            null,
        ),
    );

    var owned: std.ArrayList(usize) = .empty;
    defer owned.deinit(allocator);
    try owned.ensureTotalCapacity(allocator, 4);
    var copied_alias = owned;
    try std.testing.expectError(
        error.InvalidScratchAliasing,
        sizeContainersAlongAxisWithScratch(
            allocator,
            &nodes,
            &.{},
            &roots,
            &ids,
            true,
            &owned,
            &copied_alias,
            null,
        ),
    );
}

test "sizing scratch allocation failure precedes dimension mutation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    const allocator = failing.allocator();
    var nodes = [_]Node{.{
        .config = .{ .layout = .{ .sizing = .{
            .width = types.fixed(10),
            .height = types.fixed(20),
        } } },
        .dimensions = .{ .width = 77, .height = 88 },
    }};
    const roots = [_]Root{.{ .element_index = 0 }};
    var ids = std.AutoHashMap(u32, usize).init(std.testing.allocator);
    defer ids.deinit();
    var bfs: std.ArrayList(usize) = .empty;
    defer bfs.deinit(allocator);
    var resizable: std.ArrayList(usize) = .empty;
    defer resizable.deinit(allocator);

    try std.testing.expectError(
        error.OutOfMemory,
        sizeContainersAlongAxisWithScratch(
            allocator,
            &nodes,
            &.{},
            &roots,
            &ids,
            true,
            &bfs,
            &resizable,
            null,
        ),
    );
    try std.testing.expectEqual(types.Dimensions{ .width = 77, .height = 88 }, nodes[0].dimensions);
}

test "intrinsic finalization ignores invalid node and child ranges" {
    var nodes = [_]Node{.{
        .dimensions = .{ .width = 45, .height = 46 },
        .children_start = 1,
        .children_len = 1,
    }};

    finalizeIntrinsic(&nodes, &.{}, 0);
    finalizeIntrinsic(&nodes, &.{}, 1);
    try std.testing.expectEqual(types.Dimensions{ .width = 45, .height = 46 }, nodes[0].dimensions);

    nodes[0].children_start = 0;
    const invalid_child = [_]usize{1};
    finalizeIntrinsic(&nodes, &invalid_child, 0);
    try std.testing.expectEqual(types.Dimensions{ .width = 45, .height = 46 }, nodes[0].dimensions);
}

test "height propagation handles a deep chain iteratively" {
    const allocator = std.testing.allocator;
    const depth = 50_000;
    const nodes = try allocator.alloc(Node, depth);
    defer allocator.free(nodes);
    const child_indices = try allocator.alloc(usize, depth - 1);
    defer allocator.free(child_indices);

    for (nodes, 0..) |*node, index| {
        node.* = .{
            .config = .{ .layout = .{
                .sizing = .{ .height = types.grow() },
                .padding = .{ .top = 1, .bottom = 1 },
                .layout_direction = .top_to_bottom,
            } },
            .dimensions = .{ .height = if (index + 1 == depth) 1 else 0 },
            .children_start = index,
            .children_len = if (index + 1 < depth) 1 else 0,
            .parent_index = if (index == 0) null else index - 1,
        };
        normalizeSizing(node);
        if (index + 1 < depth) child_indices[index] = index + 1;
    }

    const roots = [_]Root{.{ .element_index = 0 }};
    try propagateHeights(nodes, child_indices, &roots);

    try std.testing.expectEqual(@as(f32, @floatFromInt(depth * 2 - 1)), nodes[0].dimensions.height);
    try std.testing.expectEqual(@as(f32, 1), nodes[depth - 1].dimensions.height);
}

test "height propagation handles a wide tree in linear declaration order" {
    const allocator = std.testing.allocator;
    const child_count = 50_000;
    const nodes = try allocator.alloc(Node, child_count + 1);
    defer allocator.free(nodes);
    const child_indices = try allocator.alloc(usize, child_count);
    defer allocator.free(child_indices);

    nodes[0] = .{
        .config = .{ .layout = .{
            .sizing = .{ .height = types.grow() },
            .layout_direction = .top_to_bottom,
        } },
        .children_len = child_count,
    };
    normalizeSizing(&nodes[0]);
    for (child_indices, 0..) |*child_index, index| {
        child_index.* = index + 1;
        nodes[index + 1] = .{
            .dimensions = .{ .height = 1 },
            .parent_index = 0,
        };
    }

    const roots = [_]Root{.{ .element_index = 0 }};
    try propagateHeights(nodes, child_indices, &roots);

    try std.testing.expectEqual(@as(f32, @floatFromInt(child_count)), nodes[0].dimensions.height);
}

test "height propagation mutates only subtrees reachable from supplied roots" {
    var nodes = [_]Node{
        .{},
        .{
            .config = .{ .layout = .{
                .sizing = .{ .height = types.fitMinMax(0, std.math.floatMax(f32)) },
                .layout_direction = .top_to_bottom,
            } },
            .children_start = 0,
            .children_len = 1,
        },
        .{ .dimensions = .{ .height = 10 }, .parent_index = 1 },
    };
    const child_indices = [_]usize{2};
    const roots = [_]Root{.{ .element_index = 0 }};

    try propagateHeights(&nodes, &child_indices, &roots);

    try std.testing.expectEqual(@as(f32, 0), nodes[1].dimensions.height);
}

test "height propagation accepts children stored before their parents" {
    var nodes = [_]Node{
        .{ .dimensions = .{ .height = 10 }, .parent_index = 1 },
        .{
            .config = .{ .layout = .{
                .sizing = .{ .height = types.fitMinMax(0, std.math.floatMax(f32)) },
                .layout_direction = .top_to_bottom,
            } },
            .children_start = 0,
            .children_len = 1,
        },
    };
    const child_indices = [_]usize{0};
    const roots = [_]Root{.{ .element_index = 1 }};

    try propagateHeights(&nodes, &child_indices, &roots);

    try std.testing.expectEqual(@as(f32, 10), nodes[1].dimensions.height);
}

test "height propagation handles a wide reverse-index tree in linear time" {
    const allocator = std.testing.allocator;
    const child_count = 20_000;
    const nodes = try allocator.alloc(Node, child_count + 1);
    defer allocator.free(nodes);
    const child_indices = try allocator.alloc(usize, child_count);
    defer allocator.free(child_indices);

    const root_index = child_count;
    for (child_indices, 0..) |*child_index, index| {
        child_index.* = index;
        nodes[index] = .{
            .dimensions = .{ .height = 1 },
            .parent_index = root_index,
        };
    }
    nodes[root_index] = .{
        .config = .{ .layout = .{
            .sizing = .{ .height = types.grow() },
            .layout_direction = .top_to_bottom,
        } },
        .children_len = child_count,
    };
    normalizeSizing(&nodes[root_index]);

    const roots = [_]Root{.{ .element_index = root_index }};
    try propagateHeights(nodes, child_indices, &roots);
    try std.testing.expectEqual(@as(f32, @floatFromInt(child_count)), nodes[root_index].dimensions.height);
}

test "height propagation rejects duplicate ranges and disconnected cycles" {
    var duplicate_nodes = [_]Node{
        .{ .parent_index = 1 },
        .{ .children_len = 2 },
    };
    const duplicate_children = [_]usize{ 0, 0 };
    const duplicate_roots = [_]Root{.{ .element_index = 1 }};
    try std.testing.expectError(
        error.InvalidTreeParent,
        propagateHeights(&duplicate_nodes, &duplicate_children, &duplicate_roots),
    );

    var invalid_range_nodes = [_]Node{.{
        .children_start = 1,
        .children_len = 1,
    }};
    const no_children = [_]usize{};
    const range_roots = [_]Root{.{ .element_index = 0 }};
    try std.testing.expectError(
        error.InvalidTreeParent,
        propagateHeights(&invalid_range_nodes, &no_children, &range_roots),
    );

    var cyclic_nodes = [_]Node{
        .{ .children_start = 0, .children_len = 1, .parent_index = 1 },
        .{ .children_start = 1, .children_len = 1, .parent_index = 0 },
        .{},
    };
    const cyclic_children = [_]usize{ 1, 0 };
    const cycle_roots = [_]Root{.{ .element_index = 2 }};
    try std.testing.expectError(
        error.InvalidTreeParent,
        propagateHeights(&cyclic_nodes, &cyclic_children, &cycle_roots),
    );

    var atomic_nodes = [_]Node{
        .{ .dimensions = .{ .height = 4 }, .parent_index = 1 },
        .{
            .config = .{ .layout = .{
                .sizing = .{ .height = types.grow() },
                .layout_direction = .top_to_bottom,
            } },
            .children_len = 1,
        },
        .{ .children_start = 1, .children_len = 1, .parent_index = 3 },
        .{ .children_start = 2, .children_len = 1, .parent_index = 2 },
    };
    normalizeSizing(&atomic_nodes[1]);
    atomic_nodes[1].dimensions.height = 99;
    const atomic_children = [_]usize{ 0, 3, 2 };
    const atomic_roots = [_]Root{.{ .element_index = 1 }};
    try std.testing.expectError(
        error.InvalidTreeParent,
        propagateHeights(&atomic_nodes, &atomic_children, &atomic_roots),
    );
    try std.testing.expectEqual(@as(f32, 99), atomic_nodes[1].dimensions.height);
}
