const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

fn printScrollData(out: *std.Io.Writer, context: *zlay.Context, label: []const u8, id: zlay.ElementId) !void {
    const data = context.getScrollContainerData(id);
    const position = if (data.scroll_position) |value| value.* else zlay.Vector2{};
    try out.print(
        "data {s} found {d} pos {d} {d} viewport {d} {d} content {d} {d} config {d} {d}\n",
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

fn drawScroll(context: *zlay.Context) !void {
    try context.beginLayout();
    try context.openElementWithIdUnconfigured(context.staticId("scroll"));
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
    try context.openElementWithId(context.staticId("content"), fixedBox(100, 1000));
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
    const scroll_id = context.staticId("scroll");

    try context.setPointerState(.{ .x = 50, .y = 50 }, false);
    try context.setPointerState(.{ .x = 50, .y = 50 }, false);
    try printScrollData(out, &context, "before", scroll_id);

    try drawScroll(&context);
    try printScrollData(out, &context, "initial", scroll_id);
    try context.setPointerState(.{ .x = 50, .y = 90 }, true);
    try printPointerOver(out, &context, "press");
    context.updateScrollContainers(true, .{}, 0.100);
    try printScrollData(out, &context, "press", scroll_id);

    try drawScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 50 }, true);
    context.updateScrollContainers(true, .{}, 0.100);
    try printScrollData(out, &context, "move-1", scroll_id);

    try drawScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 10 }, true);
    context.updateScrollContainers(true, .{}, 0.100);
    try printScrollData(out, &context, "move-2", scroll_id);

    try drawScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 10 }, false);
    context.updateScrollContainers(true, .{}, 0.016);
    try printScrollData(out, &context, "release", scroll_id);

    try drawScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 10 }, false);
    context.updateScrollContainers(false, .{}, 0.016);
    try printScrollData(out, &context, "momentum", scroll_id);

    try drawEmpty(&context);
    context.updateScrollContainers(false, .{}, 0.016);
    try printScrollData(out, &context, "stale", scroll_id);

    try out.flush();
}
