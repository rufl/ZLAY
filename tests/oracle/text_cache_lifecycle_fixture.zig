const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [8]zlay.ErrorType = undefined,
    length: usize = 0,
};

var errors = ErrorLog{};
var measure_calls: usize = 0;
var measure_advance: f32 = 1;
var measure_height: f32 = 1;

const text_a = zlay.String.fromSlice(
    "a a a a a a a a a a a a a a a a a a a a a a a a a a a a a a",
);
const text_b = zlay.String.fromSlice(
    "b b b b b b b b b b b b b b b b b b b b b b b b b b b b b b",
);
const reset_text = zlay.String.literal("word");

fn recordError(error_data: zlay.ErrorData) void {
    if (errors.length >= errors.types.len) contract.failLogOverflow("text-cache errors");
    errors.types[errors.length] = error_data.error_type;
    errors.length += 1;
}

fn measureText(
    text: zlay.StringSlice,
    _: *zlay.TextElementConfig,
    _: ?*anyopaque,
) zlay.Dimensions {
    measure_calls += 1;
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * measure_advance,
        .height = measure_height,
    };
}

fn printFrame(
    out: *std.Io.Writer,
    frame: usize,
    error_start: usize,
    commands: zlay.RenderCommandArray,
) !void {
    try out.print("frame {d} measures {d} errors {d} commands {d}", .{
        frame,
        measure_calls,
        errors.length - error_start,
        commands.length,
    });
    for (errors.types[error_start..errors.length]) |error_type| {
        try out.print(" error-type {d}", .{@backingInt(error_type)});
    }
    try out.writeByte('\n');

    for (commands.items(), 0..) |command, index| {
        if (command.command_type != .text) continue;
        try out.print("text {d} index {d} id {d} len {d} box {d} {d} {d} {d}\n", .{
            frame,
            index,
            command.id,
            command.render_data.text.string_contents.length,
            contract.f32Bits(command.bounding_box.x),
            contract.f32Bits(command.bounding_box.y),
            contract.f32Bits(command.bounding_box.width),
            contract.f32Bits(command.bounding_box.height),
        });
    }
}

fn runFrame(
    context: *zlay.Context,
    out: *std.Io.Writer,
    frame: usize,
    text: ?zlay.String,
) !void {
    measure_calls = 0;
    const error_start = errors.length;
    try context.beginLayout();
    if (text) |value| {
        try context.openElementWithId(context.staticId("cache-lifecycle-row"), .{
            .layout = .{ .sizing = .{
                .width = zlay.fixed(200),
                .height = zlay.fixed(10),
            } },
        });
        try context.text(value, .{ .font_size = 1, .wrap_mode = .none });
        try context.closeElement();
    }
    const commands = try context.endLayout(0);
    try printFrame(out, frame, error_start, commands);
}

fn runResetBetweenDeclarationAndLayout(
    context: *zlay.Context,
    out: *std.Io.Writer,
    frame: usize,
) !void {
    measure_calls = 0;
    measure_advance = 5;
    measure_height = 10;
    const error_start = errors.length;
    try context.beginLayout();
    try context.openElementWithId(context.staticId("cache-lifecycle-reset-row"), .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(200),
            .height = zlay.fixed(10),
        } },
    });
    try context.text(reset_text, .{ .font_size = 1, .wrap_mode = .words });
    context.resetMeasureTextCache();
    measure_advance = 25;
    measure_height = 30;
    try context.closeElement();
    const commands = try context.endLayout(0);
    try printFrame(out, frame, error_start, commands);
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 240, .height = 80 }, .{
        .max_element_count = 64,
        .max_text_cache_word_count = 32,
        .error_handler = .{ .error_handler_function = recordError },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);
    context.setCullingEnabled(false);

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.writeAll("cache buckets 1 words 32 text-words 30\n");
    try runFrame(&context, out, 1, text_a);
    try runFrame(&context, out, 2, null);
    try runFrame(&context, out, 3, null);
    try runFrame(&context, out, 4, text_a);
    try runFrame(&context, out, 5, null);
    try runFrame(&context, out, 6, null);
    try runFrame(&context, out, 7, text_b);
    try runFrame(&context, out, 8, text_b);
    try runFrame(&context, out, 9, null);
    try runFrame(&context, out, 10, null);
    try runFrame(&context, out, 11, text_a);
    try runResetBetweenDeclarationAndLayout(&context, out, 12);

    try out.print("errors-total {d}\n", .{errors.length});
    try out.flush();
    if (errors.length != 0) return error.UnexpectedDiagnostics;
}
