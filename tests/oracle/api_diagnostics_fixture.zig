const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorRecord = struct {
    tag: i32,
    phase: i32,
    error_type: zlay.ErrorType,
    text: zlay.String,
};

const ErrorLog = struct {
    tag: i32 = 73,
    phase: i32 = 0,
    length: usize = 0,
    records: [8]ErrorRecord = undefined,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.records.len) contract.failLogOverflow("api diagnostics");
    log.records[log.length] = .{
        .tag = log.tag,
        .phase = log.phase,
        .error_type = error_data.error_type,
        .text = error_data.error_text,
    };
    log.length += 1;
}

fn printCheckpoint(out: *std.Io.Writer, label: []const u8, log: *const ErrorLog) !void {
    try out.print("checkpoint {s} errors {d}\n", .{ label, log.length });
}

fn printErrors(out: *std.Io.Writer, log: *const ErrorLog) !void {
    try out.print("errors {d}\n", .{log.length});
    for (log.records[0..log.length], 0..) |record, index| {
        try out.print("error {d} tag {d} phase {d} type {d} static {d} len {d} text {s}\n", .{
            index,
            record.tag,
            record.phase,
            @intFromEnum(record.error_type),
            @intFromBool(record.text.is_statically_allocated),
            record.text.length,
            record.text.asSlice(),
        });
    }
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
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 300, .height = 200 }, .{
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &errors,
        },
    });
    defer context.deinit();

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("limits initial element {d} text {d}\n", .{
        context.getMaxElementCount(),
        context.getMaxMeasureTextCacheWordCount(),
    });
    context.setMaxElementCount(64);
    context.setMaxMeasureTextCacheWordCount(128);
    try out.print("limits set element {d} text {d}\n", .{
        context.getMaxElementCount(),
        context.getMaxMeasureTextCacheWordCount(),
    });

    var dimensions = context.getLayoutDimensions();
    try out.print("dimensions initial {x:0>8} {x:0>8}\n", .{ contract.f32Bits(dimensions.width), contract.f32Bits(dimensions.height) });
    context.setLayoutDimensions(.{ .width = 320, .height = 180 });
    dimensions = context.getLayoutDimensions();
    try out.print("dimensions set {x:0>8} {x:0>8}\n", .{ contract.f32Bits(dimensions.width), contract.f32Bits(dimensions.height) });

    try out.print("debug initial {d}\n", .{@intFromBool(context.isDebugModeEnabled())});
    context.setDebugModeEnabled(true);
    try out.print("debug enabled {d}\n", .{@intFromBool(context.isDebugModeEnabled())});
    context.setDebugModeEnabled(false);
    try out.print("debug disabled {d}\n", .{@intFromBool(context.isDebugModeEnabled())});

    try context.beginLayout();
    errors.phase = 10;
    try context.text(zlay.String.literal("measure me"), .{ .font_size = 12 });
    try printCheckpoint(out, "measure-declaration", &errors);
    _ = try context.endLayout(0);

    const duplicate_id = context.staticId("diagnostic-duplicate");
    try context.beginLayout();
    try context.openElementWithId(duplicate_id, fixedBox(10, 10));
    try context.closeElement();
    errors.phase = 20;
    try context.openElementWithId(duplicate_id, fixedBox(20, 10));
    try context.closeElement();
    try printCheckpoint(out, "duplicate-declaration", &errors);
    _ = try context.endLayout(0);

    try context.beginLayout();
    errors.phase = 30;
    try context.openElementWithId(context.staticId("diagnostic-percent"), .{
        .layout = .{ .sizing = .{
            .width = zlay.percent(1.25),
            .height = zlay.fixed(10),
        } },
    });
    try context.closeElement();
    try printCheckpoint(out, "percent-declaration", &errors);

    errors.phase = 40;
    try context.openElementWithId(context.staticId("diagnostic-floating"), .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(10),
            .height = zlay.fixed(10),
        } },
        .floating = .{
            .parent_id = context.staticId("diagnostic-missing-parent").id,
            .attach_to = .element_with_id,
        },
    });
    try context.closeElement();
    try printCheckpoint(out, "floating-declaration", &errors);
    _ = try context.endLayout(0);

    try printErrors(out, &errors);
    try out.flush();
}
