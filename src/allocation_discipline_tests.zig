//! Allocation and fixed-capacity regressions for the native Context.

const std = @import("std");
const zlay = @import("root.zig");
const types = zlay.types;

const red = types.Color{ .r = 255, .a = 255 };
const green = types.Color{ .g = 255, .a = 255 };
const blue = types.Color{ .b = 255, .a = 255 };

fn keepStableTransitionActive(_: types.TransitionCallbackArguments) bool {
    return false;
}

fn stableFrame(context: *zlay.Context) !void {
    const clip_id = context.staticId("allocation-clip");
    const row_id = context.staticId("allocation-row");
    const grow_id = context.staticId("allocation-grow");
    const nested_id = context.staticId("allocation-nested");

    try context.beginLayout();
    try context.openElementWithId(clip_id, .{
        .layout = .{
            .sizing = .{
                .width = zlay.fixed(240),
                .height = zlay.fixed(120),
            },
            .padding = zlay.padding(4),
            .layout_direction = .top_to_bottom,
        },
        .background_color = red,
        .clip = .{ .horizontal = true, .vertical = true },
    });
    try context.openElementWithId(row_id, .{
        .layout = .{
            .sizing = .{
                .width = zlay.grow(),
                .height = zlay.fixed(48),
            },
            .padding = zlay.padding(2),
            .child_gap = 3,
        },
        .background_color = green,
    });
    try context.openElementWithId(grow_id, .{
        .layout = .{ .sizing = .{
            .width = zlay.grow(),
            .height = zlay.fixed(24),
        } },
        .background_color = blue,
    });
    try context.openElementWithId(nested_id, .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(16),
            .height = zlay.fixed(12),
        } },
        .background_color = red,
        .transition = .{
            .handler = keepStableTransitionActive,
            .properties = .background_color,
        },
    });
    try context.closeElement();
    try context.closeElement();
    try context.closeElement();
    try context.closeElement();

    const commands = try context.endLayout(0);
    var rectangle_count: usize = 0;
    var scissor_start_count: usize = 0;
    var scissor_end_count: usize = 0;
    for (commands.items()) |command| switch (command.command_type) {
        .rectangle => rectangle_count += 1,
        .scissor_start => scissor_start_count += 1,
        .scissor_end => scissor_end_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), rectangle_count);
    try std.testing.expectEqual(@as(usize, 1), scissor_start_count);
    try std.testing.expectEqual(scissor_start_count, scissor_end_count);
}

test "warmed stable frames do not consume more fixed-buffer storage" {
    var memory: [512 * 1024]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&memory);
    var context = zlay.Context.init(fixed_buffer.allocator(), .{
        .width = 320,
        .height = 180,
    }, .{
        .max_element_count = 32,
        .max_render_command_count = 32,
    });
    defer context.deinit();

    // More than one frame is intentional: persistent maps and the iterative
    // layout/render scratch lists have different first-use points.
    for (0..8) |_| try stableFrame(&context);
    try context.transition_order.shrinkAndFreePrecise(context.allocator, context.transition_order.items.len);
    const warmed_end_index = fixed_buffer.end_index;
    try std.testing.expect(warmed_end_index > 0);

    for (0..64) |_| try stableFrame(&context);
    try std.testing.expectEqual(warmed_end_index, fixed_buffer.end_index);
}

const CapacityErrorLog = struct {
    capacity_errors: usize = 0,
    other_errors: usize = 0,
};

fn recordCapacityError(error_data: types.ErrorData) void {
    const log: *CapacityErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (error_data.error_type == .text_measurement_capacity_exceeded) {
        log.capacity_errors += 1;
    } else {
        log.other_errors += 1;
    }
}

fn measureText(
    text: types.StringSlice,
    config: *types.TextElementConfig,
    user_data: ?*anyopaque,
) types.Dimensions {
    _ = config;
    _ = user_data;
    return .{
        .width = @floatFromInt(text.asSlice().len * 8),
        .height = 12,
    };
}

test "Context enforces exact text word capacity and resets its frame warning" {
    var error_log = CapacityErrorLog{};
    var context = zlay.Context.init(std.testing.allocator, .{
        .width = 200,
        .height = 100,
    }, .{
        .max_element_count = 16,
        .max_text_cache_word_count = 1,
        .error_handler = .{
            .error_handler_function = recordCapacityError,
            .user_data = &error_log,
        },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);
    try std.testing.expectEqual(@as(usize, 1), context.getMaxMeasureTextCacheWordCount());

    const parent_id = context.staticId("capacity-parent");
    const text_config = types.TextElementConfig{
        .text_color = red,
        .font_size = 12,
    };

    try context.beginLayout();
    try context.openElementWithId(parent_id, .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(160),
            .height = zlay.fixed(60),
        } },
    });

    // One one-word entry exactly fills the configured cache. A new word then
    // fails before mutating the element tree. Retrying the cached word proves
    // the still-open parent and its automatic child IDs remain usable.
    try context.text(types.String.literal("one"), text_config);
    try std.testing.expectError(
        error.TextMeasurementCapacityExceeded,
        context.text(types.String.literal("two"), text_config),
    );
    try context.text(types.String.literal("one"), text_config);
    try std.testing.expectError(
        error.TextMeasurementCapacityExceeded,
        context.text(types.String.literal("three"), text_config),
    );
    try std.testing.expectEqual(@as(usize, 1), error_log.capacity_errors);
    try std.testing.expectEqual(@as(usize, 0), error_log.other_errors);

    try context.closeElement();
    const first_commands = try context.endLayout(0);
    var text_commands: usize = 0;
    for (first_commands.items()) |command| {
        if (command.command_type == .text) text_commands += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), text_commands);

    // `beginLayout` resets the once-per-frame warning latch. The cache itself
    // remains exactly full, so another new word fails and reports once again.
    try context.beginLayout();
    try context.openElementWithId(parent_id, .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(160),
            .height = zlay.fixed(60),
        } },
    });
    try std.testing.expectError(
        error.TextMeasurementCapacityExceeded,
        context.text(types.String.literal("four"), text_config),
    );
    try std.testing.expectError(
        error.TextMeasurementCapacityExceeded,
        context.text(types.String.literal("five"), text_config),
    );
    try std.testing.expectEqual(@as(usize, 2), error_log.capacity_errors);
    try std.testing.expectEqual(@as(usize, 0), error_log.other_errors);
    try context.closeElement();
    _ = try context.endLayout(0);
}
