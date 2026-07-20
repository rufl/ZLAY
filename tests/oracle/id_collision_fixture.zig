const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [8]zlay.ErrorType = undefined,
    length: usize = 0,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("id-collision diagnostics");
    log.types[log.length] = error_data.error_type;
    log.length += 1;
}

fn printElement(out: *std.Io.Writer, context: *const zlay.Context, label: []const u8, id: zlay.ElementId) !void {
    const data = context.getElementData(id);
    try out.print("element {s} found {d} box {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
        label,
        @intFromBool(data.found),
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
    });
}

pub fn main(init: std.process.Init) !void {
    var error_log = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 100, .height = 40 }, .{
        .max_element_count = 8,
        .max_text_cache_word_count = 32,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &error_log,
        },
    });
    defer context.deinit();

    const alpha = context.staticId("alpha");
    const delta = context.staticId("delta");
    const alpha_bucket = alpha.id % 8;
    const delta_bucket = delta.id % 8;

    try context.beginLayout();
    try context.openElementWithId(alpha, .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(10), .height = zlay.fixed(20) } },
    });
    try context.closeElement();
    try context.openElementWithId(delta, .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(30), .height = zlay.fixed(20) } },
    });
    try context.closeElement();
    _ = try context.endLayout(0);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("id alpha {d} bucket {d}\n", .{ alpha.id, alpha_bucket });
    try out.print("id delta {d} bucket {d}\n", .{ delta.id, delta_bucket });
    try out.print("distinct {d} same-bucket {d}\n", .{
        @intFromBool(alpha.id != delta.id),
        @intFromBool(alpha_bucket == delta_bucket),
    });
    try printElement(out, &context, "alpha", alpha);
    try printElement(out, &context, "delta", delta);
    try out.print("errors {d}", .{error_log.length});
    for (error_log.types[0..error_log.length]) |error_type| try out.print(" {d}", .{@intFromEnum(error_type)});
    try out.writeByte('\n');
    try out.flush();
}
