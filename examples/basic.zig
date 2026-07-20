const std = @import("std");
const zlay = @import("zlay");

fn measureMonospace(text: zlay.StringSlice, config: *zlay.TextElementConfig, _: ?*anyopaque) zlay.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * @as(f32, @floatFromInt(config.font_size)) * 0.6,
        .height = @floatFromInt(config.font_size),
    };
}

fn panelContents(context: *zlay.Context) !void {
    try context.textSlice("Native Zig layout", .{
        .font_size = 24,
        .text_color = .{ .r = 245, .g = 245, .b = 250, .a = 255 },
    });
}

pub fn main() !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 800, .height = 600 }, .{});
    defer context.deinit();
    context.setMeasureTextFunction(measureMonospace, null);

    try context.beginLayout();
    try context.elementWithId(context.staticId("panel"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
            .padding = zlay.padding(16),
            .child_gap = 12,
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 32, .g = 36, .b = 48, .a = 255 },
        .corner_radius = zlay.cornerRadius(8),
    }, panelContents);

    const commands = try context.endLayout(1.0 / 60.0);
    std.debug.print("ZLAY emitted {d} renderer-neutral commands\n", .{commands.length});
}
