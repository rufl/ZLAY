const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [8]zlay.ErrorType = undefined,
    length: usize = 0,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("invalid-render diagnostics");
    log.types[log.length] = error_data.error_type;
    log.length += 1;
}

fn printAccess(out: *std.Io.Writer, label: []const u8, command: ?*zlay.RenderCommand) !void {
    try out.print("access {s} present {d} type {d} id {d}\n", .{
        label,
        @intFromBool(command != null),
        if (command) |value| @backingInt(value.command_type) else 0,
        if (command) |value| value.id else 0,
    });
}

pub fn main(init: std.process.Init) !void {
    var error_log = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 100, .height = 40 }, .{
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &error_log,
        },
    });
    defer context.deinit();

    try context.beginLayout();
    try context.openElementWithId(context.staticId("box"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(10), .height = zlay.fixed(10) } },
        .background_color = .{ .r = 255, .a = 255 },
    });
    try context.closeElement();
    var commands = try context.endLayout(0);

    const negative = commands.get(-1);
    const past_end = commands.get(commands.length);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("commands {d}\n", .{commands.length});
    try printAccess(out, "valid", commands.get(0));
    try printAccess(out, "negative", negative);
    try printAccess(out, "past-end", past_end);
    try out.print("invalid-default-shared {d}\n", .{@intFromBool(negative == null and past_end == null)});
    try out.print("errors {d}", .{error_log.length});
    for (error_log.types[0..error_log.length]) |error_type| try out.print(" {d}", .{@backingInt(error_type)});
    try out.writeByte('\n');
    try out.flush();
}
