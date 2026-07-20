const std = @import("std");
const zlay = @import("zlay");

var error_count: usize = 0;
var measure_calls: usize = 0;

fn recordError(_: zlay.ErrorData) void {
    error_count += 1;
}

fn measureText(
    value: zlay.StringSlice,
    _: *zlay.TextElementConfig,
    _: ?*anyopaque,
) zlay.Dimensions {
    measure_calls += 1;
    return .{ .width = @floatFromInt(value.asSlice().len), .height = 1 };
}

fn runFrame(
    context: *zlay.Context,
    out: *std.Io.Writer,
    phase: []const u8,
) !void {
    try context.beginLayout();
    try context.text(zlay.String.fromSlice("Clay"), .{
        .font_id = 7,
        .font_size = 24,
        .letter_spacing = 3,
        .wrap_mode = .none,
    });
    const commands = try context.endLayout(0);
    try out.print("phase {s} limit {d} measures {d} commands {d} errors {d}\n", .{
        phase,
        context.getMaxMeasureTextCacheWordCount(),
        measure_calls,
        commands.length,
        error_count,
    });
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 240, .height = 80 }, .{
        .max_element_count = 64,
        .max_text_cache_word_count = 96,
        .error_handler = .{ .error_handler_function = recordError },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);
    context.setCullingEnabled(false);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try runFrame(&context, out, "initial");
    context.setMaxMeasureTextCacheWordCount(64);
    try runFrame(&context, out, "lowered");
    context.setMaxMeasureTextCacheWordCount(96);
    try runFrame(&context, out, "restored");
    try out.flush();

    if (error_count != 0 or measure_calls != 4) return error.UnexpectedRuntimeSetterTrace;
}
