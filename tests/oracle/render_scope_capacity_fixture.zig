const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [8]zlay.ErrorType = undefined,
    length: usize = 0,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("render-scope-capacity diagnostics");
    log.types[log.length] = error_data.error_type;
    log.length += 1;
}

pub fn main(init: std.process.Init) !void {
    var errors = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = 4,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &errors,
        },
    });
    defer context.deinit();

    try context.beginLayout();
    try context.openElementWithId(context.staticId("render-scope-capacity-a"), .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(10),
            .height = zlay.fixed(10),
        } },
        .clip = .{ .horizontal = true, .vertical = true },
    });
    try context.closeElement();
    try context.openElementWithId(context.staticId("render-scope-capacity-b"), .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(10),
            .height = zlay.fixed(10),
        } },
        .clip = .{ .horizontal = true, .vertical = true },
    });
    try context.closeElement();
    var end_error = false;
    _ = context.endLayout(0) catch |layout_error| switch (layout_error) {
        error.RenderCommandCapacityExceeded => {
            end_error = true;
        },
        else => return layout_error,
    };

    var length: i32 = 0;
    while (context.renderCommand(length) != null) : (length += 1) {}
    var scissor_depth: usize = 0;
    var balanced = true;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("end-error {d} layout-open {d}\n", .{
        @intFromBool(end_error),
        @intFromBool(context.layout_open),
    });
    try out.print("commands {d}\n", .{length});
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const command = context.renderCommand(index).?;
        try out.print("command {d} type {d}\n", .{ index, @backingInt(command.command_type) });
        switch (command.command_type) {
            .scissor_start => scissor_depth += 1,
            .scissor_end => {
                if (scissor_depth == 0) balanced = false else scissor_depth -= 1;
            },
            else => {},
        }
    }
    if (scissor_depth != 0) balanced = false;
    try out.print("balanced {d}\n", .{@intFromBool(balanced)});
    try out.print("errors {d}", .{errors.length});
    for (errors.types[0..errors.length]) |error_type| try out.print(" {d}", .{@backingInt(error_type)});
    try out.writeByte('\n');
    try out.flush();
}
