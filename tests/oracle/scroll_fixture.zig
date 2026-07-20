const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

fn printScrollData(out: *std.Io.Writer, context: *zlay.Context, label: []const u8, id: zlay.ElementId) !void {
    const data = context.getScrollContainerData(id);
    const position = if (data.scroll_position) |value| value.* else zlay.Vector2{};
    try out.print(
        "data {s} found {d} pos {d} {d} viewport {d} {d} content {d} {d} config {d} {d} {d} {d}\n",
        .{
            label,
            @intFromBool(data.found),
            contract.f32Bits(position.x),
            contract.f32Bits(position.y),
            contract.f32Bits(data.scroll_container_dimensions.width),
            contract.f32Bits(data.scroll_container_dimensions.height),
            contract.f32Bits(data.content_dimensions.width),
            contract.f32Bits(data.content_dimensions.height),
            @intFromBool(data.config.horizontal),
            @intFromBool(data.config.vertical),
            contract.f32Bits(data.config.child_offset.x),
            contract.f32Bits(data.config.child_offset.y),
        },
    );
}

fn printPointerOver(out: *std.Io.Writer, context: *zlay.Context, label: []const u8) !void {
    const over = context.getPointerOverIds().items();
    try out.print("over {s} {d}", .{ label, over.len });
    for (over) |element_id| try out.print(" {d}", .{element_id.id});
    try out.writeByte('\n');
}

fn fixedBox(width: f32, height: f32) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(width),
            .height = zlay.fixed(height),
        } },
    };
}

fn drawOldScroll(context: *zlay.Context) !void {
    try context.beginLayout();
    try context.openElementWithIdUnconfigured(context.staticId("old-scroll"));
    const offset = context.getScrollOffset();
    try context.configureOpenElement(.{
        .layout = .{
            .sizing = .{
                .width = zlay.fixed(100),
                .height = zlay.fixed(100),
            },
            .layout_direction = .top_to_bottom,
        },
        .clip = .{
            .horizontal = true,
            .vertical = true,
            .child_offset = offset,
        },
    });
    try context.openElementWithId(context.staticId("old-content"), fixedBox(300, 300));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
}

fn drawReplacementScroll(context: *zlay.Context) !void {
    try context.beginLayout();
    try context.openElementWithIdUnconfigured(context.staticId("replacement-scroll"));
    const offset = context.getScrollOffset();
    try context.configureOpenElement(.{
        .layout = .{
            .sizing = .{
                .width = zlay.fixed(100),
                .height = zlay.fixed(100),
            },
            .layout_direction = .top_to_bottom,
        },
        .clip = .{
            .vertical = true,
            .child_offset = offset,
        },
    });
    try context.openElementWithId(context.staticId("replacement-content"), fixedBox(100, 1000));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
}

fn drawEmpty(context: *zlay.Context) !void {
    try context.beginLayout();
    _ = try context.endLayout(0);
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 240, .height = 180 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const old_id = context.staticId("old-scroll");
    const replacement_id = context.staticId("replacement-scroll");

    try context.setPointerState(.{ .x = 50, .y = 50 }, false);
    try context.setPointerState(.{ .x = 50, .y = 50 }, false);
    try printScrollData(out, &context, "old-before", old_id);

    try drawOldScroll(&context);
    try printScrollData(out, &context, "old-initial", old_id);
    try context.setPointerState(.{ .x = 50, .y = 50 }, false);
    try printPointerOver(out, &context, "old");
    context.updateScrollContainers(false, .{ .x = -50, .y = -50 }, 0.016);
    try printScrollData(out, &context, "old-wheel-clamp", old_id);

    // The old container is now closed. Declaring a differently identified
    // container in the same layout-array slot before pruning exposes pinned
    // Clay's retained layoutElement-pointer and swap-remove behavior.
    try drawReplacementScroll(&context);
    try printScrollData(out, &context, "old-after-replacement", old_id);
    try printScrollData(out, &context, "replacement-initial", replacement_id);

    try context.setPointerState(.{ .x = 50, .y = 90 }, true);
    try printPointerOver(out, &context, "replacement-press");
    context.updateScrollContainers(true, .{}, 0.100);
    try printScrollData(out, &context, "replacement-press", replacement_id);
    try printScrollData(out, &context, "old-pruned", old_id);

    try drawReplacementScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 50 }, true);
    context.updateScrollContainers(true, .{}, 0.100);
    try printScrollData(out, &context, "replacement-move-1", replacement_id);

    try drawReplacementScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 10 }, true);
    context.updateScrollContainers(true, .{}, 0.100);
    try printScrollData(out, &context, "replacement-move-2", replacement_id);

    try drawReplacementScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 10 }, false);
    context.updateScrollContainers(true, .{}, 0.016);
    try printScrollData(out, &context, "replacement-release", replacement_id);

    try drawReplacementScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 10 }, false);
    context.updateScrollContainers(false, .{}, 0.016);
    try printScrollData(out, &context, "replacement-momentum", replacement_id);

    try drawEmpty(&context);
    context.updateScrollContainers(false, .{}, 0.016);
    try printScrollData(out, &context, "replacement-stale", replacement_id);

    try out.flush();
}
