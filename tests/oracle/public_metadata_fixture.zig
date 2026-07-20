const std = @import("std");
const zlay = @import("zlay");

const ErrorLog = struct {
    count: usize = 0,
    last_type: zlay.ErrorType = .internal_error,
    last_text_static: bool = false,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    log.count += 1;
    log.last_type = error_data.error_type;
    log.last_text_static = error_data.error_text.is_statically_allocated;
}

pub fn main(init: std.process.Init) !void {
    var errors = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = 8,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &errors,
        },
    });
    defer context.deinit();

    try context.beginLayout();
    try context.openElementWithId(context.staticId("metadata-box"), .{
        .layout = .{ .sizing = .{
            .width = zlay.percent(2),
            .height = zlay.fixed(20),
        } },
        .background_color = .{ .r = 10, .g = 20, .b = 30, .a = 255 },
    });
    try context.closeElement();
    const commands = try context.endLayout(0);

    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    const pointer_over = context.getPointerOverIds();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("render capacity {d} length {d}\n", .{ commands.capacity, commands.length });
    try out.print("pointer capacity {d} length {d}\n", .{ pointer_over.capacity, pointer_over.length });
    try out.print("error count {d} type {d} static {d}\n", .{
        errors.count,
        @intFromEnum(errors.last_type),
        @intFromBool(errors.last_text_static),
    });
    try out.flush();
}
