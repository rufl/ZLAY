const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [8]zlay.ErrorType = undefined,
    length: usize = 0,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("id-error diagnostics");
    log.types[log.length] = error_data.error_type;
    log.length += 1;
}

fn printId(out: *std.Io.Writer, label: []const u8, id: zlay.ElementId) !void {
    // Slice identity and is_statically_allocated intentionally are normalized
    // away; only the counted contents and public hash fields are serialized.
    const contents = id.string_id.asSlice();
    try out.print("id {s} {d} {d} {d} text {d} {s}\n", .{
        label,
        id.id,
        id.offset,
        id.base_id,
        contents.len,
        contents,
    });
}

fn printErrors(out: *std.Io.Writer, log: *const ErrorLog) !void {
    try out.print("errors {d}", .{log.length});
    for (log.types[0..log.length]) |error_type| try out.print(" {d}", .{@backingInt(error_type)});
    try out.writeByte('\n');
}

fn printLookup(out: *std.Io.Writer, context: *const zlay.Context, label: []const u8, id: zlay.ElementId) !void {
    const data = context.getElementData(id);
    try out.print("lookup {s} found {d} {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
        label,
        @intFromBool(data.found),
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
    });
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
    var error_log = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 400, .height = 160 }, .{
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &error_log,
        },
    });
    defer context.deinit();

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const alpha_dynamic = [_]u8{ 'a', 'l', 'p', 'h', 'a' };
    const item_dynamic = [_]u8{ 'i', 't', 'e', 'm' };
    const child_dynamic = [_]u8{ 'c', 'h', 'i', 'l', 'd' };

    try printId(out, "global-literal", context.staticId("alpha"));
    try printId(out, "global-dynamic", context.id(&alpha_dynamic));
    try printId(out, "indexed-literal", context.staticIndexedId("item", 7));
    try printId(out, "indexed-dynamic", context.indexedId(&item_dynamic, 7));

    var automatic_first: u32 = 0;
    var automatic_nested: u32 = 0;
    var automatic_second: u32 = 0;
    try context.beginLayout();
    try context.openElementWithId(context.staticId("parent"), fixedBox(100, 40));
    try printId(out, "local-literal", try context.staticLocalId("child"));
    try printId(out, "local-dynamic", try context.localId(&child_dynamic));
    try printId(out, "indexed-local-literal", try context.staticIndexedLocalId("child", 3));
    try printId(out, "indexed-local-dynamic", try context.indexedLocalId(&child_dynamic, 3));

    try context.openElement(fixedBox(10, 10));
    automatic_first = try context.getOpenElementId();
    try context.openElement(fixedBox(5, 5));
    automatic_nested = try context.getOpenElementId();
    try context.closeElement();
    try context.closeElement();
    try context.openElement(fixedBox(10, 10));
    automatic_second = try context.getOpenElementId();
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
    try out.print("automatic first {d} nested {d} second {d}\n", .{
        automatic_first,
        automatic_nested,
        automatic_second,
    });

    error_log.length = 0;
    const duplicate_id = context.staticId("duplicate");
    try context.beginLayout();
    try context.openElementWithId(duplicate_id, fixedBox(10, 20));
    try context.closeElement();
    try context.openElementWithId(duplicate_id, fixedBox(30, 20));
    try context.closeElement();
    try context.openElementWithId(context.staticId("percent-over"), .{
        .layout = .{ .sizing = .{
            .width = zlay.percent(1.5),
            .height = zlay.fixed(10),
        } },
    });
    try context.closeElement();
    try context.openElementWithId(context.staticId("missing-floating-parent"), .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(5),
            .height = zlay.fixed(5),
        } },
        .floating = .{
            .parent_id = context.staticId("absent-parent").id,
            .attach_to = .element_with_id,
        },
    });
    try context.closeElement();
    _ = try context.endLayout(0);

    try printErrors(out, &error_log);
    try printLookup(out, &context, "missing", context.staticId("not-declared"));

    try out.flush();
}
