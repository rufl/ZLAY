const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [8]zlay.ErrorType = undefined,
    length: usize = 0,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("text-capacity diagnostics");
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
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 200, .height = 40 }, .{
        .max_element_count = 8,
        .max_text_cache_word_count = 32,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &error_log,
        },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);

    try context.beginLayout();
    var at_limit_returned_error = false;
    context.textSlice(
        "a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a",
        .{ .font_size = 1 },
    ) catch |text_error| switch (text_error) {
        error.TextMeasurementCapacityExceeded => at_limit_returned_error = true,
        else => return text_error,
    };
    const errors_after_limit = error_log.length;
    var over_limit_returned_error = false;
    context.textSlice(
        "b b b b b b b b b b b b b b b b b b b b b b b b b b b b b b b b b",
        .{ .font_size = 1 },
    ) catch |text_error| switch (text_error) {
        error.TextMeasurementCapacityExceeded => over_limit_returned_error = true,
        else => return text_error,
    };
    const errors_after_over_limit = error_log.length;
    const commands = try context.endLayout(0);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.writeAll("limits element 8 text 32\n");
    try out.print("text-api-returned-error {d} {d}\n", .{
        @intFromBool(at_limit_returned_error),
        @intFromBool(over_limit_returned_error),
    });
    try out.print("callback-errors-after-limit {d}\n", .{errors_after_limit});
    try out.print("callback-errors-after-over-limit {d}\n", .{errors_after_over_limit});
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
