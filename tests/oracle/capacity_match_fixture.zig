const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [8]zlay.ErrorType = undefined,
    length: usize = 0,
};

var image_payload: u8 = 0;
var custom_payload: u8 = 0;

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("capacity-match diagnostics");
    log.types[log.length] = error_data.error_type;
    log.length += 1;
}

fn measureText(text: zlay.StringSlice, config: *zlay.TextElementConfig, _: ?*anyopaque) zlay.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * @as(f32, @floatFromInt(config.font_size)),
        .height = @floatFromInt(config.font_size),
    };
}

fn printErrors(out: *std.Io.Writer, log: *const ErrorLog) !void {
    try out.print("errors {d}", .{log.length});
    for (log.types[0..log.length]) |error_type| try out.print(" {d}", .{@backingInt(error_type)});
    try out.writeByte('\n');
}

fn opaquePointer(pointer: *u8) *anyopaque {
    return @ptrCast(pointer);
}

pub fn main(init: std.process.Init) !void {
    var error_log = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 200, .height = 100 }, .{
        .max_element_count = 8,
        .max_render_command_count = 8,
        .max_text_cache_word_count = 32,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &error_log,
        },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);

    try context.beginLayout();
    try context.textSlice(
        "a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a",
        .{ .font_size = 1, .text_color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    );
    try context.openElementWithId(context.staticId("rich"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(20), .height = zlay.fixed(20) } },
        .background_color = .{ .r = 10, .g = 20, .b = 30, .a = 255 },
        .overlay_color = .{ .r = 40, .g = 50, .b = 60, .a = 128 },
        .image = .{ .image_data = opaquePointer(&image_payload) },
        .custom = .{ .custom_data = opaquePointer(&custom_payload) },
        .border = .{
            .color = .{ .r = 70, .g = 80, .b = 90, .a = 255 },
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
        },
    });
    try context.closeElement();
    try context.openElementWithId(context.staticId("dropped"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(20), .height = zlay.fixed(20) } },
        .background_color = .{ .r = 100, .g = 110, .b = 120, .a = 255 },
    });
    try context.closeElement();
    const commands = try context.endLayout(0);

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.writeAll("limits element 8 text 32 render-effective 7\n");
    try printErrors(out, &error_log);
    try out.print("commands {d}\n", .{commands.length});
    for (commands.items(), 0..) |command, index| {
        const text_length: i32 = if (command.command_type == .text)
            command.render_data.text.string_contents.length
        else
            0;
        try out.print("command {d} type {d} id {d} text {d}\n", .{
            index,
            @backingInt(command.command_type),
            command.id,
            text_length,
        });
    }
    try out.flush();
}
