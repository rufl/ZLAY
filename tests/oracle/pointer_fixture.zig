const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const HoverEvent = struct {
    id: u32,
    pointer: zlay.PointerData,
};

const HoverLog = struct {
    events: [16]HoverEvent = undefined,
    length: usize = 0,

    fn clear(self: *HoverLog) void {
        self.length = 0;
    }
};

fn recordHover(element_id: zlay.ElementId, pointer: zlay.PointerData, user_data: ?*anyopaque) void {
    const log: *HoverLog = @ptrCast(@alignCast(user_data.?));
    if (log.length >= log.events.len) contract.failLogOverflow("pointer hover");
    log.events[log.length] = .{
        .id = element_id.id,
        .pointer = pointer,
    };
    log.length += 1;
}

fn printHoverLog(out: *std.Io.Writer, label: []const u8, log: *const HoverLog) !void {
    try out.print("events {s} {d}", .{ label, log.length });
    for (log.events[0..log.length]) |event| {
        try out.print(" {d}:{d}:{d}:{d}", .{
            event.id,
            @intFromEnum(event.pointer.state),
            contract.f32Bits(event.pointer.position.x),
            contract.f32Bits(event.pointer.position.y),
        });
    }
    try out.writeByte('\n');
}

fn printPointer(out: *std.Io.Writer, context: *zlay.Context, label: []const u8) !void {
    const pointer = context.getPointerState();
    const over = context.getPointerOverIds().items();
    try out.print("pointer {s} pos {d} {d} state {d} over {d}", .{
        label,
        contract.f32Bits(pointer.position.x),
        contract.f32Bits(pointer.position.y),
        @intFromEnum(pointer.state),
        over.len,
    });
    for (over) |element_id| try out.print(" {d}", .{element_id.id});
    try out.writeByte('\n');
}

fn printFlags3(
    out: *std.Io.Writer,
    context: *const zlay.Context,
    label: []const u8,
    first_name: []const u8,
    first: zlay.ElementId,
    second_name: []const u8,
    second: zlay.ElementId,
    third_name: []const u8,
    third: zlay.ElementId,
) !void {
    try out.print("flags {s} {s} {d} {s} {d} {s} {d}\n", .{
        label,
        first_name,
        @intFromBool(context.pointerOver(first)),
        second_name,
        @intFromBool(context.pointerOver(second)),
        third_name,
        @intFromBool(context.pointerOver(third)),
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

fn drawNestedHover(context: *zlay.Context, log: *HoverLog) !void {
    try context.beginLayout();
    try context.openElementWithId(context.staticId("hover-parent"), fixedBox(100, 100));
    try context.onHover(recordHover, log);
    try context.openElementWithId(context.staticId("hover-child"), fixedBox(50, 50));
    try context.onHover(recordHover, log);
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
}

fn floatingBox(z_index: i16, capture_mode: zlay.PointerCaptureMode) zlay.ElementDeclaration {
    var declaration = fixedBox(100, 100);
    declaration.floating = .{
        .z_index = z_index,
        .pointer_capture_mode = capture_mode,
        .attach_to = .root,
    };
    return declaration;
}

fn drawFloatingStack(context: *zlay.Context, high_capture_mode: zlay.PointerCaptureMode) !void {
    try context.beginLayout();
    try context.openElementWithId(context.staticId("base"), fixedBox(100, 100));
    try context.closeElement();
    try context.openElementWithId(context.staticId("floating-low"), floatingBox(5, .passthrough));
    try context.closeElement();
    try context.openElementWithId(context.staticId("floating-high"), floatingBox(10, high_capture_mode));
    try context.closeElement();
    _ = try context.endLayout(0);
}

fn drawClippedChild(context: *zlay.Context) !void {
    try context.beginLayout();
    try context.openElementWithId(context.staticId("clip"), .{
        .layout = .{
            .sizing = .{
                .width = zlay.fixed(100),
                .height = zlay.fixed(40),
            },
            .layout_direction = .top_to_bottom,
        },
        .clip = .{ .vertical = true },
    });
    try context.openElementWithId(context.staticId("clipped-child"), fixedBox(100, 100));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 240, .height = 160 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var hover_log = HoverLog{};
    const root_id = context.staticId("Clay__RootContainer");
    const parent_id = context.staticId("hover-parent");
    const child_id = context.staticId("hover-child");
    const base_id = context.staticId("base");
    const low_id = context.staticId("floating-low");
    const high_id = context.staticId("floating-high");
    const clip_id = context.staticId("clip");
    const clipped_child_id = context.staticId("clipped-child");

    try printPointer(out, &context, "initial");

    // Two released samples normalize the state before a layout exists. This
    // also proves that hit testing consumes only a completed prior frame.
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try printPointer(out, &context, "prelayout");
    try printFlags3(out, &context, "prelayout", "root", root_id, "parent", parent_id, "child", child_id);

    try drawNestedHover(&context, &hover_log);
    try printPointer(out, &context, "nested-before-input");

    hover_log.clear();
    try context.setPointerState(.{ .x = 10, .y = 10 }, true);
    try printHoverLog(out, "press", &hover_log);
    try printPointer(out, &context, "press");
    try printFlags3(out, &context, "press", "root", root_id, "parent", parent_id, "child", child_id);

    hover_log.clear();
    try context.setPointerState(.{ .x = 10, .y = 10 }, true);
    try printHoverLog(out, "held", &hover_log);
    try printPointer(out, &context, "held");

    hover_log.clear();
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try printHoverLog(out, "release", &hover_log);
    try printPointer(out, &context, "release");

    hover_log.clear();
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try printHoverLog(out, "released", &hover_log);
    try printPointer(out, &context, "released");

    try drawFloatingStack(&context, .capture);
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try printPointer(out, &context, "floating-capture");
    try printFlags3(out, &context, "floating-capture", "base", base_id, "low", low_id, "high", high_id);

    try drawFloatingStack(&context, .passthrough);
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try printPointer(out, &context, "floating-passthrough");
    try printFlags3(out, &context, "floating-passthrough", "base", base_id, "low", low_id, "high", high_id);

    try drawClippedChild(&context);
    try context.setPointerState(.{ .x = 10, .y = 70 }, false);
    try printPointer(out, &context, "clip-outside");
    try printFlags3(out, &context, "clip-outside", "root", root_id, "clip", clip_id, "child", clipped_child_id);

    try context.setPointerState(.{ .x = 10, .y = 20 }, false);
    try printPointer(out, &context, "clip-inside");
    try printFlags3(out, &context, "clip-inside", "root", root_id, "clip", clip_id, "child", clipped_child_id);

    try out.flush();
}
