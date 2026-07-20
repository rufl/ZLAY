const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

fn measureText(text: zlay.StringSlice, config: *zlay.TextElementConfig, _: ?*anyopaque) zlay.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * @as(f32, @floatFromInt(config.font_size)),
        .height = @floatFromInt(config.font_size),
    };
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 300, .height = 100 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);

    try context.beginLayout();
    try context.openElementWithId(context.id("row"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
            .child_gap = 10,
        },
    });
    try context.openElementWithId(context.id("left"), .{
        .layout = .{ .sizing = .{ .width = zlay.grow(), .height = zlay.grow() } },
        .background_color = .{ .r = 255, .a = 255 },
    });
    try context.closeElement();
    try context.openElementWithId(context.id("right"), .{
        .layout = .{ .sizing = .{ .width = zlay.grow(), .height = zlay.grow() } },
        .background_color = .{ .b = 255, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();
    const commands = try context.endLayout(0.016);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const left = context.getElementData(context.id("left"));
    const right = context.getElementData(context.id("right"));
    try stdout.print("left {d} {d} {d} {d}\n", .{ contract.f32Bits(left.bounding_box.x), contract.f32Bits(left.bounding_box.y), contract.f32Bits(left.bounding_box.width), contract.f32Bits(left.bounding_box.height) });
    try stdout.print("right {d} {d} {d} {d}\n", .{ contract.f32Bits(right.bounding_box.x), contract.f32Bits(right.bounding_box.y), contract.f32Bits(right.bounding_box.width), contract.f32Bits(right.bounding_box.height) });
    for (commands.items()) |command| {
        try stdout.print("command {d} {d} {d} {d} {d} {d}\n", .{
            @intFromEnum(command.command_type),
            command.id,
            contract.f32Bits(command.bounding_box.x),
            contract.f32Bits(command.bounding_box.y),
            contract.f32Bits(command.bounding_box.width),
            contract.f32Bits(command.bounding_box.height),
        });
    }
    try stdout.flush();
}
