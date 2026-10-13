const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [8]zlay.ErrorType = undefined,
    length: usize = 0,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("element-capacity diagnostics");
    log.types[log.length] = error_data.error_type;
    log.length += 1;
}

fn measureText(text: zlay.StringSlice, config: *zlay.TextElementConfig, _: ?*anyopaque) zlay.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * @as(f32, @floatFromInt(config.font_size)),
        .height = @floatFromInt(config.font_size),
    };
}

pub fn main(init: std.process.Init) !void {
    var error_log = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 100, .height = 40 }, .{
        .max_element_count = 4,
        .max_text_cache_word_count = 32,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &error_log,
        },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);

    try context.beginLayout();
    const labels = [_][]const u8{ "a", "b", "c", "d" };
    for (labels) |label| {
        context.textSlice(label, .{ .font_size = 1 }) catch |text_error| switch (text_error) {
            error.ElementCapacityExceeded => {},
            else => return text_error,
        };
    }
    const commands = try context.endLayout(0);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.writeAll("limits element 4 text 32\ntext-attempts 4\n");
    try out.print("errors {d}", .{error_log.length});
    for (error_log.types[0..error_log.length]) |error_type| try out.print(" {d}", .{@backingInt(error_type)});
    try out.writeByte('\n');
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
