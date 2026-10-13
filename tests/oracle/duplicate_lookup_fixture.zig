const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [8]zlay.ErrorType = undefined,
    length: usize = 0,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("duplicate-lookup diagnostics");
    log.types[log.length] = error_data.error_type;
    log.length += 1;
}

fn fixedBox(width: f32, height: f32) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(width),
            .height = zlay.fixed(height),
        } },
    };
}

pub fn main(init: std.process.Init) !void {
    var errors = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 400, .height = 160 }, .{
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &errors,
        },
    });
    defer context.deinit();

    const duplicate_id = context.staticId("duplicate");
    try context.beginLayout();
    try context.openElementWithId(duplicate_id, fixedBox(10, 20));
    try context.closeElement();
    try context.openElementWithId(duplicate_id, fixedBox(30, 20));
    try context.closeElement();
    _ = try context.endLayout(0);

    const data = context.getElementData(duplicate_id);
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("lookup duplicate found {d} {d} {d} {d} {d}\n", .{
        @intFromBool(data.found),
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
    });
    try out.print("errors {d}", .{errors.length});
    for (errors.types[0..errors.length]) |error_type| {
        try out.print(" {d}", .{@backingInt(error_type)});
    }
    try out.writeByte('\n');
    try out.flush();
}
