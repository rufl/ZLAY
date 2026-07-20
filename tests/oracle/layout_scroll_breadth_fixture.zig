const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

fn fixedBox(width: f32, height: f32) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(width),
            .height = zlay.fixed(height),
        } },
    };
}

fn printElement(
    out: *std.Io.Writer,
    context: *const zlay.Context,
    label: []const u8,
    id: zlay.ElementId,
) !void {
    const data = context.getElementData(id);
    try out.print("element {s} found {d} box {d} {d} {d} {d}\n", .{
        label,
        @intFromBool(data.found),
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
    });
}

fn printScroll(
    out: *std.Io.Writer,
    context: *zlay.Context,
    label: []const u8,
    id: zlay.ElementId,
) !void {
    const data = context.getScrollContainerData(id);
    const position = if (data.scroll_position) |value| value.* else zlay.Vector2{};
    try out.print("scroll {s} found {d} pos {d} {d} viewport {d} {d} content {d} {d} config {d} {d}\n", .{
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
    });
}

fn drawAspects(context: *zlay.Context) !void {
    try context.beginLayout();
    try context.openElementWithId(context.staticId("aspect-row"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(200), .height = zlay.fixed(100) },
            .layout_direction = .left_to_right,
        },
    });
    try context.openElementWithId(context.staticId("aspect-width-from-height"), .{
        .layout = .{ .sizing = .{ .width = zlay.fit(), .height = zlay.fixed(30) } },
        .aspect_ratio = .{ .aspect_ratio = 2 },
        .background_color = .{ .r = 10, .g = 20, .b = 30, .a = 255 },
    });
    try context.closeElement();
    try context.openElementWithId(context.staticId("aspect-height-from-width"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(80), .height = zlay.fit() } },
        .aspect_ratio = .{ .aspect_ratio = 4 },
        .background_color = .{ .r = 40, .g = 50, .b = 60, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
}

fn drawHorizontalScroll(context: *zlay.Context) !void {
    try context.beginLayout();
    try context.openElementWithIdUnconfigured(context.staticId("horizontal-scroll"));
    const offset = context.getScrollOffset();
    try context.configureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(100), .height = zlay.fixed(40) },
            .layout_direction = .left_to_right,
        },
        .clip = .{ .horizontal = true, .child_offset = offset },
    });
    try context.openElementWithId(context.staticId("horizontal-content"), fixedBox(300, 40));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 320, .height = 200 }, .{
        .max_element_count = 32,
        .max_text_cache_word_count = 64,
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();
    context.setCullingEnabled(false);

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try drawAspects(&context);
    try printElement(out, &context, "width-from-height", context.staticId("aspect-width-from-height"));
    try printElement(out, &context, "height-from-width", context.staticId("aspect-height-from-width"));

    const scroll_id = context.staticId("horizontal-scroll");
    try context.setPointerState(.{ .x = 90, .y = 20 }, false);
    try context.setPointerState(.{ .x = 90, .y = 20 }, false);
    try printScroll(out, &context, "before", scroll_id);

    try drawHorizontalScroll(&context);
    try printScroll(out, &context, "initial", scroll_id);
    try context.setPointerState(.{ .x = 90, .y = 20 }, true);
    context.updateScrollContainers(true, .{}, 0.1);
    try printScroll(out, &context, "press", scroll_id);

    try drawHorizontalScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 20 }, true);
    context.updateScrollContainers(true, .{}, 0.1);
    try printScroll(out, &context, "move-one", scroll_id);

    try drawHorizontalScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 20 }, true);
    context.updateScrollContainers(true, .{}, 0.2);
    try printScroll(out, &context, "stationary-one", scroll_id);

    try drawHorizontalScroll(&context);
    try context.setPointerState(.{ .x = 50, .y = 20 }, true);
    context.updateScrollContainers(true, .{}, 0.1);
    try printScroll(out, &context, "stationary-reset", scroll_id);

    try drawHorizontalScroll(&context);
    try context.setPointerState(.{ .x = 10, .y = 20 }, true);
    context.updateScrollContainers(true, .{}, 0.1);
    try printScroll(out, &context, "move-two", scroll_id);

    try drawHorizontalScroll(&context);
    try context.setPointerState(.{ .x = 10, .y = 20 }, false);
    context.updateScrollContainers(true, .{}, 0.016);
    try printScroll(out, &context, "release", scroll_id);

    try drawHorizontalScroll(&context);
    try context.setPointerState(.{ .x = 10, .y = 20 }, false);
    context.updateScrollContainers(false, .{}, 0.016);
    try printScroll(out, &context, "momentum", scroll_id);

    try out.flush();
}
