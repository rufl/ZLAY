const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

fn measureText(text: zlay.StringSlice, _: *zlay.TextElementConfig, _: ?*anyopaque) zlay.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * 6,
        .height = 10,
    };
}

fn printBox(stdout: *std.Io.Writer, context: *const zlay.Context, name: []const u8) !void {
    const element = context.getElementData(context.id(name));
    try stdout.print("box {s} {d} {d} {d} {d}\n", .{
        name,
        contract.f32Bits(element.bounding_box.x),
        contract.f32Bits(element.bounding_box.y),
        contract.f32Bits(element.bounding_box.width),
        contract.f32Bits(element.bounding_box.height),
    });
}

// Normalize pointer-bearing payloads by printing text contents, not addresses.
fn printCommand(stdout: *std.Io.Writer, index: usize, command: zlay.RenderCommand) !void {
    try stdout.print("command {d} {d} {d} {d} {d} {d} {d} {d}", .{
        index,
        @backingInt(command.command_type),
        command.id,
        command.z_index,
        contract.f32Bits(command.bounding_box.x),
        contract.f32Bits(command.bounding_box.y),
        contract.f32Bits(command.bounding_box.width),
        contract.f32Bits(command.bounding_box.height),
    });
    switch (command.command_type) {
        .rectangle => {
            const color = command.render_data.rectangle.background_color;
            try stdout.print(" rgba {d} {d} {d} {d}", .{ contract.f32Bits(color.r), contract.f32Bits(color.g), contract.f32Bits(color.b), contract.f32Bits(color.a) });
        },
        .border => {
            const border = command.render_data.border;
            try stdout.print(" border {d} {d} {d} {d} {d} {d} {d} {d} {d}", .{
                contract.f32Bits(border.color.r),
                contract.f32Bits(border.color.g),
                contract.f32Bits(border.color.b),
                contract.f32Bits(border.color.a),
                border.width.left,
                border.width.right,
                border.width.top,
                border.width.bottom,
                border.width.between_children,
            });
        },
        .text => {
            const text = command.render_data.text.string_contents.asSlice();
            try stdout.print(" text {d} \"{s}\"", .{ text.len, text });
        },
        .scissor_start => {
            const clip = command.render_data.clip;
            try stdout.print(" clip {d} {d}", .{ @intFromBool(clip.horizontal), @intFromBool(clip.vertical) });
        },
        else => {},
    }
    try stdout.writeByte('\n');
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 360, .height = 220 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);

    try context.beginLayout();
    try context.openElementWithId(context.id("panel"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
            .padding = zlay.padding(10),
            .child_gap = 8,
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 24, .g = 28, .b = 36, .a = 255 },
    });
    try context.openElementWithId(context.id("header"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.fixed(28) },
            .padding = zlay.padding(4),
        },
        .background_color = .{ .r = 48, .g = 56, .b = 72, .a = 255 },
    });
    try context.textSlice("complex oracle", .{
        .text_color = .{ .r = 240, .g = 240, .b = 240, .a = 255 },
        .font_size = 10,
        .wrap_mode = .none,
    });
    try context.closeElement();

    try context.openElementWithId(context.id("row"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
            .padding = zlay.padding(4),
            .child_gap = 10,
        },
        .border = .{
            .color = .{ .r = 220, .g = 180, .b = 40, .a = 255 },
            .width = zlay.borderAll(2),
        },
    });
    try context.openElementWithId(context.id("sidebar"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(80), .height = zlay.grow() },
            .padding = zlay.padding(3),
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 72, .g = 52, .b = 64, .a = 255 },
    });
    try context.textSlice("fixed", .{
        .text_color = .{ .r = 255, .g = 220, .b = 220, .a = 255 },
        .font_size = 10,
        .wrap_mode = .none,
    });
    try context.closeElement();

    try context.openElementWithId(context.id("clipper"), .{
        .layout = .{
            .sizing = .{ .width = zlay.percent(0.5), .height = zlay.fixed(72) },
            .padding = zlay.padding(5),
            .child_gap = 3,
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 34, .g = 72, .b = 82, .a = 255 },
        .clip = .{ .horizontal = true, .vertical = true },
    });
    try context.openElementWithId(context.id("text-column"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(100), .height = zlay.fit() },
            .layout_direction = .top_to_bottom,
        },
    });
    try context.textSlice("alpha beta gamma delta epsilon", .{
        .text_color = .{ .r = 210, .g = 245, .b = 250, .a = 255 },
        .font_size = 10,
        .line_height = 12,
        .wrap_mode = .words,
        .text_alignment = .center,
    });
    try context.closeElement();
    try context.openElementWithId(context.id("clip-item"), .{
        .layout = .{ .sizing = .{ .width = zlay.grow(), .height = zlay.fixed(14) } },
        .background_color = .{ .r = 20, .g = 110, .b = 120, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.id("tail"), .{
        .layout = .{ .sizing = .{ .width = zlay.grow(), .height = zlay.grow() } },
        .background_color = .{ .r = 58, .g = 70, .b = 50, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.id("badge"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(48), .height = zlay.fixed(18) },
            .padding = .{ .left = 4, .right = 4, .top = 2, .bottom = 2 },
        },
        .background_color = .{ .r = 180, .g = 64, .b = 72, .a = 255 },
        .floating = .{
            .offset = .{ .x = -4, .y = 4 },
            .z_index = 5,
            .parent_id = context.id("clipper").id,
            .attach_points = .{ .element = .right_top, .parent = .right_top },
            .attach_to = .element_with_id,
            .clip_to = .none,
        },
    });
    try context.textSlice("float", .{
        .text_color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .font_size = 10,
        .wrap_mode = .none,
    });
    try context.closeElement();
    try context.closeElement();

    const commands = try context.endLayout(0.016);
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    inline for (.{ "panel", "header", "row", "sidebar", "clipper", "text-column", "clip-item", "tail", "badge" }) |name| {
        try printBox(stdout, &context, name);
    }
    for (commands.items(), 0..) |command, index| try printCommand(stdout, index, command);
    try stdout.flush();
}
