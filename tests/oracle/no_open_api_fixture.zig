const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [32]zlay.ErrorType = undefined,
    length: usize = 0,
};

var errors = ErrorLog{};

fn recordError(error_data: zlay.ErrorData) void {
    if (errors.length >= errors.types.len) contract.failLogOverflow("no-open API errors");
    errors.types[errors.length] = error_data.error_type;
    errors.length += 1;
}

fn probeNoOpen(out: *std.Io.Writer, context: *zlay.Context, label: []const u8) !void {
    const error_start = errors.length;
    var open_id: u32 = 0;
    var open_error = false;
    open_id = context.getOpenElementId() catch blk: {
        open_error = true;
        break :blk 0;
    };
    const hovered = context.hovered();
    const hover_error = false;
    var on_hover_error = false;
    context.onHover(null, null) catch {
        on_hover_error = true;
    };
    const offset = context.getScrollOffset();
    try out.print(
        "probe {s} open {d} open-error {d} hovered {d} hover-error {d} on-hover-error {d} offset {d} {d} errors {d}",
        .{
            label,
            open_id,
            @intFromBool(open_error),
            @intFromBool(hovered),
            @intFromBool(hover_error),
            @intFromBool(on_hover_error),
            contract.f32Bits(offset.x),
            contract.f32Bits(offset.y),
            errors.length - error_start,
        },
    );
    for (errors.types[error_start..errors.length]) |error_type| {
        try out.print(" {d}", .{@backingInt(error_type)});
    }
    try out.writeByte('\n');
}

fn recoveryBox() zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(23), .height = zlay.fixed(17) } },
        .background_color = .{ .r = 31, .g = 127, .b = 223, .a = 255 },
    };
}

fn printRecovery(
    out: *std.Io.Writer,
    context: *const zlay.Context,
    id: zlay.ElementId,
    commands: zlay.RenderCommandArray,
) !void {
    const data = context.getElementData(id);
    try out.print("recovery element found {d} box {d} {d} {d} {d} commands {d}\n", .{
        @intFromBool(data.found),
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
        commands.length,
    });
    for (commands.items(), 0..) |command, index| {
        try out.print("recovery command {d} type {d} id {d} box {d} {d} {d} {d}\n", .{
            index,
            @backingInt(command.command_type),
            command.id,
            contract.f32Bits(command.bounding_box.x),
            contract.f32Bits(command.bounding_box.y),
            contract.f32Bits(command.bounding_box.width),
            contract.f32Bits(command.bounding_box.height),
        });
    }
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 100, .height = 80 }, .{
        .max_element_count = 32,
        .max_text_cache_word_count = 64,
        .error_handler = .{ .error_handler_function = recordError },
    });
    defer context.deinit();
    context.setCullingEnabled(false);

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try probeNoOpen(out, &context, "before-first-begin");

    try context.beginLayout();
    try context.openElementWithId(context.staticId("no-open-seed"), recoveryBox());
    try context.closeElement();
    _ = try context.endLayout(0);
    try probeNoOpen(out, &context, "after-end");

    const recovery_error_start = errors.length;
    const recovery_id = context.staticId("no-open-recovery");
    try context.beginLayout();
    try context.openElementWithId(recovery_id, recoveryBox());
    try context.closeElement();
    const commands = try context.endLayout(0);
    try printRecovery(out, &context, recovery_id, commands);
    try out.print("recovery errors {d}\n", .{errors.length - recovery_error_start});
    try out.print("errors-total {d}\n", .{errors.length});
    try out.flush();
}
