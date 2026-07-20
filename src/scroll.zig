//! Persistent, engine-independent scroll-container state.
//!
//! The update order and constants follow `Clay_UpdateScrollContainers` from
//! Clay 0.14 at commit e6cc36941ab2af5d81107617039d6f527a1c660b. Layout
//! code owns the container storage and marks containers open each frame; this
//! module owns only the scrolling lifecycle and performs no allocation.

const std = @import("std");
const types = @import("types.zig");

pub const wheel_scale: f32 = 10.0;
pub const release_distance_threshold: f32 = 10.0;
pub const release_momentum_divisor: f32 = 25.0;
pub const momentum_decay: f32 = 0.95;
pub const momentum_stop_threshold: f32 = 0.1;
pub const stationary_time_threshold: f32 = 0.15;

/// Persistent state corresponding to `Clay__ScrollContainerDataInternal`,
/// with the layout-element pointer replaced by engine-owned value snapshots.
pub const Container = struct {
    id: u32,
    bounding_box: types.BoundingBox = .{},
    container_dimensions: types.Dimensions = .{},
    content_dimensions: types.Dimensions = .{},
    config: types.ClipElementConfig = .{},
    scroll_origin: types.Vector2 = .{ .x = -1, .y = -1 },
    pointer_origin: types.Vector2 = .{},
    scroll_momentum: types.Vector2 = .{},
    scroll_position: types.Vector2 = .{},
    previous_delta: types.Vector2 = .{},
    momentum_time: f32 = 0,
    open_this_frame: bool = true,
    pointer_scroll_active: bool = false,

    pub fn init(
        id: u32,
        bounding_box: types.BoundingBox,
        content_dimensions: types.Dimensions,
        config: types.ClipElementConfig,
    ) Container {
        return .{
            .id = id,
            .bounding_box = bounding_box,
            .container_dimensions = .{
                .width = bounding_box.width,
                .height = bounding_box.height,
            },
            .content_dimensions = content_dimensions,
            .config = config,
        };
    }

    /// Refresh the layout-owned fields and retain this container for the next
    /// update. Clay performs the equivalent work while configuring and then
    /// positioning a clip element.
    pub fn markOpen(
        self: *Container,
        bounding_box: types.BoundingBox,
        container_dimensions: types.Dimensions,
        content_dimensions: types.Dimensions,
        config: types.ClipElementConfig,
    ) void {
        self.bounding_box = bounding_box;
        self.container_dimensions = container_dimensions;
        self.content_dimensions = content_dimensions;
        self.config = config;
        self.open_this_frame = true;
    }

    pub fn reopen(self: *Container) void {
        self.open_this_frame = true;
    }

    /// Apply the result of an external scroll-offset query. This intentionally
    /// does not clamp: upstream stores the external provider's value verbatim.
    pub fn applyExternalOffset(self: *Container, offset: types.Vector2) void {
        self.scroll_position = offset;
    }

    pub fn publicData(self: *Container) types.ScrollContainerData {
        return .{
            .scroll_position = &self.scroll_position,
            .scroll_container_dimensions = self.container_dimensions,
            .content_dimensions = self.content_dimensions,
            .config = self.config,
            .found = true,
        };
    }
};

pub const UpdateInput = struct {
    enable_drag_scrolling: bool = false,
    scroll_delta: types.Vector2 = .{},
    delta_time: f32 = 0,
    pointer: types.PointerData = .{ .state = .released },
    pointer_over_ids: []const types.ElementId = &.{},
};

pub const UpdateResult = struct {
    /// Live prefix of the caller-provided storage after stale swap-removal.
    containers: []Container,
    selected_index: ?usize,

    pub fn selected(self: UpdateResult) ?*Container {
        const index = self.selected_index orelse return null;
        if (index >= self.containers.len) return null;
        return &self.containers[index];
    }
};

fn cMin(left: f32, right: f32) f32 {
    return if (left < right) left else right;
}

fn cMax(left: f32, right: f32) f32 {
    return if (left > right) left else right;
}

fn maxScrollExtent(content: f32, viewport: f32) f32 {
    return cMax(content - viewport, 0);
}

fn clampToExtent(position: f32, content: f32, viewport: f32) f32 {
    return cMin(cMax(position, -maxScrollExtent(content, viewport)), 0);
}

fn clampDragPosition(position: f32, content: f32, viewport: f32) f32 {
    return cMax(cMin(position, 0), -(content - viewport));
}

fn betweenExclusive(value: f32, magnitude: f32) bool {
    return value > -magnitude and value < magnitude;
}

fn pointerIsActive(input: UpdateInput) bool {
    return input.enable_drag_scrolling and
        (input.pointer.state == .pressed or input.pointer.state == .pressed_this_frame);
}

fn pointerOver(id: u32, pointer_over_ids: []const types.ElementId) bool {
    for (pointer_over_ids) |pointer_over_id| {
        if (pointer_over_id.id == id) return true;
    }
    return false;
}

/// Remove every container that layout did not mark open this frame. Storage is
/// compacted using swap-back removal, matching Clay's bounded-array behavior.
pub fn pruneStale(containers: []Container) []Container {
    var length = containers.len;
    var index: usize = 0;
    while (index < length) {
        if (containers[index].open_this_frame) {
            index += 1;
            continue;
        }

        length -= 1;
        if (index != length) containers[index] = containers[length];
    }
    return containers[0..length];
}

/// Select the last hovered container in persistent insertion order. Nested
/// containers are declared after their ancestors, which is the priority rule
/// used by upstream Clay's outer container scan.
pub fn highestPriorityHovered(
    containers: []const Container,
    pointer_over_ids: []const types.ElementId,
) ?usize {
    var selected_index: ?usize = null;
    for (containers, 0..) |container, index| {
        if (pointerOver(container.id, pointer_over_ids)) selected_index = index;
    }
    return selected_index;
}

fn releaseDrag(container: *Container) void {
    const x_difference = container.scroll_position.x - container.scroll_origin.x;
    if (x_difference < -release_distance_threshold or x_difference > release_distance_threshold) {
        container.scroll_momentum.x = releaseMomentum(x_difference, container.momentum_time);
    }

    const y_difference = container.scroll_position.y - container.scroll_origin.y;
    if (y_difference < -release_distance_threshold or y_difference > release_distance_threshold) {
        container.scroll_momentum.y = releaseMomentum(y_difference, container.momentum_time);
    }

    container.pointer_scroll_active = false;
    container.pointer_origin = .{};
    container.scroll_origin = .{};
    container.momentum_time = 0;
}

fn releaseMomentum(difference: f32, elapsed_time: f32) f32 {
    if (!std.math.isFinite(difference) or
        !std.math.isFinite(elapsed_time) or
        elapsed_time <= 0)
    {
        return 0;
    }
    const momentum = difference / (elapsed_time * release_momentum_divisor);
    return if (std.math.isFinite(momentum)) momentum else 0;
}

fn applyMomentumAndClamp(container: *Container, scroll_occurred: bool) void {
    if (!std.math.isFinite(container.scroll_position.x)) container.scroll_position.x = 0;
    if (!std.math.isFinite(container.scroll_position.y)) container.scroll_position.y = 0;
    if (!std.math.isFinite(container.scroll_momentum.x)) container.scroll_momentum.x = 0;
    if (!std.math.isFinite(container.scroll_momentum.y)) container.scroll_momentum.y = 0;

    container.scroll_position.x += container.scroll_momentum.x;
    container.scroll_momentum.x *= momentum_decay;
    if (betweenExclusive(container.scroll_momentum.x, momentum_stop_threshold) or scroll_occurred) {
        container.scroll_momentum.x = 0;
    }
    container.scroll_position.x = clampToExtent(
        container.scroll_position.x,
        container.content_dimensions.width,
        container.container_dimensions.width,
    );

    container.scroll_position.y += container.scroll_momentum.y;
    container.scroll_momentum.y *= momentum_decay;
    if (betweenExclusive(container.scroll_momentum.y, momentum_stop_threshold) or scroll_occurred) {
        container.scroll_momentum.y = 0;
    }
    container.scroll_position.y = clampToExtent(
        container.scroll_position.y,
        container.content_dimensions.height,
        container.container_dimensions.height,
    );
}

fn updateSelected(container: *Container, input: UpdateInput, is_pointer_active: bool) void {
    const can_scroll_vertically = container.config.vertical and
        container.content_dimensions.height > container.container_dimensions.height;
    const can_scroll_horizontally = container.config.horizontal and
        container.content_dimensions.width > container.container_dimensions.width;

    if (can_scroll_vertically) {
        container.scroll_position.y += input.scroll_delta.y * wheel_scale;
    }
    if (can_scroll_horizontally) {
        container.scroll_position.x += input.scroll_delta.x * wheel_scale;
    }

    if (is_pointer_active) {
        container.scroll_momentum = .{};
        if (!container.pointer_scroll_active) {
            container.pointer_origin = input.pointer.position;
            container.scroll_origin = container.scroll_position;
            container.pointer_scroll_active = true;
        } else {
            var scroll_delta_x: f32 = 0;
            var scroll_delta_y: f32 = 0;

            if (can_scroll_horizontally) {
                const old_position = container.scroll_position.x;
                container.scroll_position.x = container.scroll_origin.x +
                    (input.pointer.position.x - container.pointer_origin.x);
                container.scroll_position.x = clampDragPosition(
                    container.scroll_position.x,
                    container.content_dimensions.width,
                    container.bounding_box.width,
                );
                scroll_delta_x = container.scroll_position.x - old_position;
            }

            if (can_scroll_vertically) {
                const old_position = container.scroll_position.y;
                container.scroll_position.y = container.scroll_origin.y +
                    (input.pointer.position.y - container.pointer_origin.y);
                container.scroll_position.y = clampDragPosition(
                    container.scroll_position.y,
                    container.content_dimensions.height,
                    container.bounding_box.height,
                );
                scroll_delta_y = container.scroll_position.y - old_position;
            }

            if (betweenExclusive(scroll_delta_x, momentum_stop_threshold) and
                betweenExclusive(scroll_delta_y, momentum_stop_threshold) and
                container.momentum_time > stationary_time_threshold)
            {
                container.momentum_time = 0;
                container.pointer_origin = input.pointer.position;
                container.scroll_origin = container.scroll_position;
            } else {
                if (std.math.isFinite(input.delta_time) and input.delta_time > 0) {
                    container.momentum_time += input.delta_time;
                }
            }
        }
    }

    if (can_scroll_vertically) {
        container.scroll_position.y = clampDragPosition(
            container.scroll_position.y,
            container.content_dimensions.height,
            container.container_dimensions.height,
        );
    }
    if (can_scroll_horizontally) {
        container.scroll_position.x = clampDragPosition(
            container.scroll_position.x,
            container.content_dimensions.width,
            container.container_dimensions.width,
        );
    }
}

/// Advance all live scroll containers by one input frame.
///
/// As in Clay, any non-zero wheel delta cancels momentum on every container,
/// while the actual wheel/drag movement is applied only to the highest-priority
/// hovered container. Every processed container is marked closed so layout must
/// call `markOpen`/`reopen` before the following update.
pub fn update(storage: []Container, input: UpdateInput) UpdateResult {
    @setFloatMode(.strict);

    const containers = pruneStale(storage);
    const is_pointer_active = pointerIsActive(input);
    const scroll_occurred = input.scroll_delta.x != 0 or input.scroll_delta.y != 0;

    for (containers) |*container| {
        container.open_this_frame = false;

        if (!is_pointer_active and container.pointer_scroll_active) {
            releaseDrag(container);
        }
        applyMomentumAndClamp(container, scroll_occurred);
    }

    const selected_index = highestPriorityHovered(containers, input.pointer_over_ids);
    if (selected_index) |index| {
        updateSelected(&containers[index], input, is_pointer_active);
    }

    return .{
        .containers = containers,
        .selected_index = selected_index,
    };
}

fn testContainer(id: u32, width: f32, height: f32, horizontal: bool, vertical: bool) Container {
    return Container.init(
        id,
        .{ .width = 100, .height = 100 },
        .{ .width = width, .height = height },
        .{ .horizontal = horizontal, .vertical = vertical },
    );
}

test "stale containers are pruned with swap-back compaction" {
    var storage = [_]Container{
        testContainer(1, 200, 200, true, true),
        testContainer(2, 200, 200, true, true),
        testContainer(3, 200, 200, true, true),
    };
    storage[1].open_this_frame = false;

    const live = pruneStale(&storage);
    try std.testing.expectEqual(@as(usize, 2), live.len);
    try std.testing.expectEqual(@as(u32, 1), live[0].id);
    try std.testing.expectEqual(@as(u32, 3), live[1].id);
}

test "selected rejects a stale index instead of indexing outside the live prefix" {
    var storage = [_]Container{testContainer(1, 200, 200, true, true)};
    const result = UpdateResult{
        .containers = storage[0..0],
        .selected_index = 0,
    };

    try std.testing.expect(result.selected() == null);
}

test "innermost hovered container receives wheel input" {
    var storage = [_]Container{
        testContainer(10, 100, 500, false, true),
        testContainer(20, 100, 300, false, true),
    };
    const hovered = [_]types.ElementId{
        .{ .id = 10 },
        .{ .id = 20 },
    };

    const result = update(&storage, .{
        .scroll_delta = .{ .y = -1 },
        .pointer_over_ids = &hovered,
    });

    try std.testing.expectEqual(@as(?usize, 1), result.selected_index);
    try std.testing.expectEqual(@as(f32, 0), result.containers[0].scroll_position.y);
    try std.testing.expectEqual(@as(f32, -10), result.containers[1].scroll_position.y);
    try std.testing.expect(!result.containers[0].open_this_frame);
    try std.testing.expect(!result.containers[1].open_this_frame);
}

test "wheel axes and overscroll are clamped to content extents" {
    var storage = [_]Container{testContainer(7, 300, 50, true, false)};
    const hovered = [_]types.ElementId{.{ .id = 7 }};

    var result = update(&storage, .{
        .scroll_delta = .{ .x = -30, .y = -30 },
        .pointer_over_ids = &hovered,
    });
    try std.testing.expectEqual(@as(f32, -200), result.containers[0].scroll_position.x);
    try std.testing.expectEqual(@as(f32, 0), result.containers[0].scroll_position.y);

    result.containers[0].reopen();
    result = update(result.containers, .{
        .scroll_delta = .{ .x = 50 },
        .pointer_over_ids = &hovered,
    });
    try std.testing.expectEqual(@as(f32, 0), result.containers[0].scroll_position.x);
}

test "drag release creates and decays deterministic momentum" {
    var storage = [_]Container{testContainer(5, 100, 1_000, false, true)};
    const hovered = [_]types.ElementId{.{ .id = 5 }};

    var result = update(&storage, .{
        .enable_drag_scrolling = true,
        .pointer = .{ .position = .{ .y = 100 }, .state = .pressed_this_frame },
        .pointer_over_ids = &hovered,
        .delta_time = 0.1,
    });
    try std.testing.expect(result.containers[0].pointer_scroll_active);

    result.containers[0].reopen();
    result = update(result.containers, .{
        .enable_drag_scrolling = true,
        .pointer = .{ .position = .{ .y = 50 }, .state = .pressed },
        .pointer_over_ids = &hovered,
        .delta_time = 0.1,
    });
    try std.testing.expectEqual(@as(f32, -50), result.containers[0].scroll_position.y);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), result.containers[0].momentum_time, 0.0001);

    result.containers[0].reopen();
    result = update(result.containers, .{
        .enable_drag_scrolling = true,
        .pointer = .{ .position = .{}, .state = .pressed },
        .pointer_over_ids = &hovered,
        .delta_time = 0.1,
    });
    try std.testing.expectEqual(@as(f32, -100), result.containers[0].scroll_position.y);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), result.containers[0].momentum_time, 0.0001);

    result.containers[0].reopen();
    result = update(result.containers, .{
        .enable_drag_scrolling = true,
        .pointer = .{ .position = .{}, .state = .released_this_frame },
        .pointer_over_ids = &hovered,
        .delta_time = 0.016,
    });
    try std.testing.expect(!result.containers[0].pointer_scroll_active);
    try std.testing.expectEqual(@as(f32, -120), result.containers[0].scroll_position.y);
    try std.testing.expectEqual(@as(f32, -19), result.containers[0].scroll_momentum.y);

    result.containers[0].reopen();
    result = update(result.containers, .{
        .pointer = .{ .state = .released },
        .pointer_over_ids = &hovered,
        .delta_time = 0.016,
    });
    try std.testing.expectEqual(@as(f32, -139), result.containers[0].scroll_position.y);
    try std.testing.expectApproxEqAbs(@as(f32, -18.05), result.containers[0].scroll_momentum.y, 0.0001);
}

test "zero and invalid drag time cannot create non-finite momentum" {
    var storage = [_]Container{testContainer(6, 100, 1_000, false, true)};
    const hovered = [_]types.ElementId{.{ .id = 6 }};

    var result = update(&storage, .{
        .enable_drag_scrolling = true,
        .pointer = .{ .position = .{ .y = 100 }, .state = .pressed_this_frame },
        .pointer_over_ids = &hovered,
        .delta_time = 0,
    });
    result.containers[0].reopen();
    result = update(result.containers, .{
        .enable_drag_scrolling = true,
        .pointer = .{ .position = .{ .y = 50 }, .state = .pressed },
        .pointer_over_ids = &hovered,
        .delta_time = std.math.nan(f32),
    });
    result.containers[0].reopen();
    result = update(result.containers, .{
        .enable_drag_scrolling = true,
        .pointer = .{ .position = .{ .y = 50 }, .state = .released_this_frame },
        .pointer_over_ids = &hovered,
        .delta_time = -1,
    });

    try std.testing.expectEqual(@as(f32, 0), result.containers[0].scroll_momentum.y);
    try std.testing.expect(std.math.isFinite(result.containers[0].scroll_position.y));
}

test "non-finite stored scroll state is normalized before momentum advances" {
    var storage = [_]Container{testContainer(1, 300, 300, true, true)};
    storage[0].scroll_position = .{ .x = std.math.nan(f32), .y = std.math.inf(f32) };
    storage[0].scroll_momentum = .{ .x = std.math.inf(f32), .y = std.math.nan(f32) };

    const result = update(&storage, .{});

    try std.testing.expectEqual(@as(f32, 0), result.containers[0].scroll_position.x);
    try std.testing.expectEqual(@as(f32, 0), result.containers[0].scroll_position.y);
    try std.testing.expectEqual(@as(f32, 0), result.containers[0].scroll_momentum.x);
    try std.testing.expectEqual(@as(f32, 0), result.containers[0].scroll_momentum.y);
}

test "stationary drag resets its momentum sampling origin after threshold" {
    var storage = [_]Container{testContainer(8, 100, 500, false, true)};
    const hovered = [_]types.ElementId{.{ .id = 8 }};
    storage[0].pointer_scroll_active = true;
    storage[0].pointer_origin = .{ .y = 20 };
    storage[0].scroll_origin = .{ .y = -40 };
    storage[0].scroll_position = .{ .y = -40 };
    storage[0].momentum_time = 0.2;

    const result = update(&storage, .{
        .enable_drag_scrolling = true,
        .pointer = .{ .position = .{ .y = 20 }, .state = .pressed },
        .pointer_over_ids = &hovered,
        .delta_time = 0.1,
    });

    try std.testing.expectEqual(@as(f32, 0), result.containers[0].momentum_time);
    try std.testing.expectEqual(@as(f32, 20), result.containers[0].pointer_origin.y);
    try std.testing.expectEqual(@as(f32, -40), result.containers[0].scroll_origin.y);
}

test "wheel activity cancels momentum globally after applying one step" {
    var storage = [_]Container{
        testContainer(1, 500, 100, true, false),
        testContainer(2, 500, 100, true, false),
    };
    storage[0].scroll_position.x = -20;
    storage[0].scroll_momentum.x = -5;
    storage[1].scroll_position.x = -40;
    storage[1].scroll_momentum.x = -8;

    const result = update(&storage, .{ .scroll_delta = .{ .y = 1 } });
    try std.testing.expectEqual(@as(f32, -25), result.containers[0].scroll_position.x);
    try std.testing.expectEqual(@as(f32, -48), result.containers[1].scroll_position.x);
    try std.testing.expectEqual(@as(f32, 0), result.containers[0].scroll_momentum.x);
    try std.testing.expectEqual(@as(f32, 0), result.containers[1].scroll_momentum.x);
}

test "closed containers disappear on the following update" {
    var storage = [_]Container{testContainer(99, 200, 200, true, true)};
    var result = update(&storage, .{});
    try std.testing.expectEqual(@as(usize, 1), result.containers.len);

    result = update(result.containers, .{});
    try std.testing.expectEqual(@as(usize, 0), result.containers.len);
    try std.testing.expectEqual(@as(?usize, null), result.selected_index);
}

test "external offsets and public data expose persistent native state" {
    var container = testContainer(33, 400, 600, true, true);
    container.applyExternalOffset(.{ .x = -12, .y = -34 });
    var public_data = container.publicData();

    try std.testing.expect(public_data.found);
    try std.testing.expectEqual(@as(f32, -12), public_data.scroll_position.?.x);
    try std.testing.expectEqual(@as(f32, -34), public_data.scroll_position.?.y);
    try std.testing.expectEqual(container.content_dimensions, public_data.content_dimensions);
    try std.testing.expectEqual(container.config, public_data.config);

    public_data.scroll_position.?.y = -56;
    try std.testing.expectEqual(@as(f32, -56), container.scroll_position.y);
}
