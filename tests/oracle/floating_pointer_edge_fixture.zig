const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [64]zlay.ErrorType = undefined,
    length: usize = 0,
};

const QueryLog = struct {
    calls: [8]u32 = undefined,
    length: usize = 0,
};

const attach_points = [_]zlay.FloatingAttachPointType{
    .left_top,
    .left_center,
    .left_bottom,
    .center_top,
    .center_center,
    .center_bottom,
    .right_top,
    .right_center,
    .right_bottom,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("floating-pointer error");
    log.types[log.length] = error_data.error_type;
    log.length += 1;
    contract.failOnError(error_data);
}

fn queryScrollOffset(element_id: u32, user_data: ?*anyopaque) zlay.Vector2 {
    const log: *QueryLog = @ptrCast(@alignCast(user_data.?));
    if (log.length >= log.calls.len) contract.failLogOverflow("floating-pointer query");
    log.calls[log.length] = element_id;
    log.length += 1;
    return .{ .x = -11, .y = 17 };
}

fn color(r: f32, g: f32, b: f32) zlay.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn fixedBox(width: f32, height: f32, background: zlay.Color) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(width),
            .height = zlay.fixed(height),
        } },
        .background_color = background,
    };
}

fn floatingBox(
    width: f32,
    height: f32,
    offset: zlay.Vector2,
    parent_id: u32,
    z_index: i16,
    element_point: zlay.FloatingAttachPointType,
    parent_point: zlay.FloatingAttachPointType,
    capture_mode: zlay.PointerCaptureMode,
    attach_to: zlay.FloatingAttachToElement,
    clip_to: zlay.FloatingClipToElement,
    background: zlay.Color,
) zlay.ElementDeclaration {
    var declaration = fixedBox(width, height, background);
    declaration.floating = .{
        .offset = offset,
        .parent_id = parent_id,
        .z_index = z_index,
        .attach_points = .{ .element = element_point, .parent = parent_point },
        .pointer_capture_mode = capture_mode,
        .attach_to = attach_to,
        .clip_to = clip_to,
    };
    return declaration;
}

fn printCommand(out: *std.Io.Writer, label: []const u8, index: usize, command: zlay.RenderCommand) !void {
    try out.print("command {s} {d} type {d} id {d} z {d} box {d} {d} {d} {d}\n", .{
        label,
        index,
        @backingInt(command.command_type),
        command.id,
        command.z_index,
        contract.f32Bits(command.bounding_box.x),
        contract.f32Bits(command.bounding_box.y),
        contract.f32Bits(command.bounding_box.width),
        contract.f32Bits(command.bounding_box.height),
    });
}

fn printCommands(out: *std.Io.Writer, label: []const u8, commands: zlay.RenderCommandArray) !void {
    try out.print("commands {s} {d}\n", .{ label, commands.items().len });
    for (commands.items(), 0..) |command, index| try printCommand(out, label, index, command);
}

fn printElement(
    out: *std.Io.Writer,
    context: *const zlay.Context,
    label: []const u8,
    first: i32,
    second: i32,
    id: zlay.ElementId,
    commands: zlay.RenderCommandArray,
) !void {
    const data = context.getElementData(id);
    var rectangle_count: usize = 0;
    var rectangle_index: i32 = -1;
    var rectangle = zlay.RenderCommand{};
    for (commands.items(), 0..) |command, index| {
        if (command.command_type != .rectangle or command.id != id.id) continue;
        if (rectangle_count == 0) {
            rectangle = command;
            rectangle_index = @intCast(index);
        }
        rectangle_count += 1;
    }
    try out.print("element {s} {d} {d} id {d} found {d} box {d} {d} {d} {d} rect {d} index {d} z {d} box {d} {d} {d} {d}\n", .{
        label,
        first,
        second,
        id.id,
        @intFromBool(data.found),
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
        rectangle_count,
        rectangle_index,
        if (rectangle_count > 0) rectangle.z_index else 0,
        if (rectangle_count > 0) contract.f32Bits(rectangle.bounding_box.x) else 0,
        if (rectangle_count > 0) contract.f32Bits(rectangle.bounding_box.y) else 0,
        if (rectangle_count > 0) contract.f32Bits(rectangle.bounding_box.width) else 0,
        if (rectangle_count > 0) contract.f32Bits(rectangle.bounding_box.height) else 0,
    });
}

fn printPointer(out: *std.Io.Writer, context: *zlay.Context, label: []const u8) !void {
    const pointer = context.getPointerState();
    const over = context.getPointerOverIds().items();
    try out.print("pointer {s} pos {d} {d} state {d} over {d}", .{
        label,
        contract.f32Bits(pointer.position.x),
        contract.f32Bits(pointer.position.y),
        @backingInt(pointer.state),
        over.len,
    });
    for (over) |id| try out.print(" {d}", .{id.id});
    try out.writeByte('\n');
}

fn printQuery(out: *std.Io.Writer, label: []const u8, log: *const QueryLog) !void {
    try out.print("query {s} {d}", .{ label, log.length });
    for (log.calls[0..log.length]) |element_id| try out.print(" {d}", .{element_id});
    try out.writeByte('\n');
}

fn printErrors(out: *std.Io.Writer, log: *const ErrorLog) !void {
    try out.print("errors {d}", .{log.length});
    for (log.types[0..log.length]) |error_type| try out.print(" {d}", .{@backingInt(error_type)});
    try out.writeByte('\n');
}

fn drawAttachmentMatrix(context: *zlay.Context) !zlay.RenderCommandArray {
    const anchor_id = context.staticId("floating-anchor");
    try context.beginLayout();
    try context.openElementWithId(anchor_id, floatingBox(
        80,
        60,
        .{ .x = 100, .y = 200 },
        0,
        1,
        .left_top,
        .left_top,
        .passthrough,
        .root,
        .none,
        color(30, 50, 70),
    ));
    for (attach_points, 0..) |parent_point, parent_index| {
        for (attach_points, 0..) |element_point, element_index| {
            const index: u32 = @intCast(parent_index * 9 + element_index);
            try context.openElementWithId(context.staticIndexedId("floating-matrix", index), floatingBox(
                20,
                10,
                .{ .x = 3, .y = -4 },
                0,
                2,
                element_point,
                parent_point,
                .passthrough,
                .parent,
                .none,
                color(@floatFromInt(20 + parent_index), @floatFromInt(40 + element_index), 90),
            ));
            try context.closeElement();
        }
    }
    try context.closeElement();

    try context.openElementWithId(context.staticId("floating-root-probe"), floatingBox(
        24,
        12,
        .{ .x = -5, .y = 7 },
        0,
        3,
        .left_top,
        .center_center,
        .passthrough,
        .root,
        .attached_parent,
        color(100, 60, 30),
    ));
    try context.closeElement();

    try context.openElementWithId(context.staticId("floating-id-probe"), floatingBox(
        16,
        14,
        .{ .x = 2, .y = -3 },
        anchor_id.id,
        4,
        .center_center,
        .right_bottom,
        .passthrough,
        .element_with_id,
        .attached_parent,
        color(120, 80, 40),
    ));
    try context.closeElement();

    return context.endLayout(0);
}

fn drawClipFrame(context: *zlay.Context) !zlay.RenderCommandArray {
    const clip_id = context.staticId("floating-clip");
    const target_id = context.staticId("floating-clip-target");
    try context.beginLayout();
    try context.openElementWithId(clip_id, .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(80), .height = zlay.fixed(40) },
            .layout_direction = .top_to_bottom,
        },
        .background_color = color(15, 25, 35),
        .clip = .{
            .horizontal = true,
            .vertical = true,
            .child_offset = .{ .x = -7, .y = 13 },
        },
    });
    try context.openElementWithId(target_id, fixedBox(30, 20, color(45, 55, 65)));
    try context.closeElement();
    try context.openElementWithId(context.staticId("floating-clip-parent"), floatingBox(
        50,
        20,
        .{ .x = 10, .y = 50 },
        0,
        6,
        .left_top,
        .left_top,
        .passthrough,
        .parent,
        .attached_parent,
        color(70, 100, 130),
    ));
    try context.closeElement();
    try context.openElementWithId(context.staticId("floating-clip-none"), floatingBox(
        50,
        20,
        .{ .x = 10, .y = 50 },
        0,
        7,
        .left_top,
        .left_top,
        .passthrough,
        .parent,
        .none,
        color(90, 120, 150),
    ));
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.staticId("floating-clip-id"), floatingBox(
        45,
        18,
        .{ .x = 20, .y = 55 },
        target_id.id,
        8,
        .left_top,
        .left_top,
        .passthrough,
        .element_with_id,
        .attached_parent,
        color(110, 140, 170),
    ));
    try context.closeElement();

    return context.endLayout(0);
}

fn drawZStack(context: *zlay.Context, high_capture_mode: zlay.PointerCaptureMode) !zlay.RenderCommandArray {
    try context.beginLayout();
    try context.openElementWithId(context.staticId("pointer-base"), fixedBox(100, 100, color(20, 30, 40)));
    try context.closeElement();
    try context.openElementWithId(context.staticId("pointer-low"), floatingBox(
        100,
        100,
        .{},
        0,
        5,
        .left_top,
        .left_top,
        .passthrough,
        .root,
        .none,
        color(50, 60, 70),
    ));
    try context.closeElement();
    try context.openElementWithId(context.staticId("pointer-high"), floatingBox(
        100,
        100,
        .{},
        0,
        10,
        .left_top,
        .left_top,
        high_capture_mode,
        .root,
        .none,
        color(80, 90, 100),
    ));
    try context.openElementWithId(context.staticId("pointer-high-child"), fixedBox(40, 40, color(110, 120, 130)));
    try context.closeElement();
    try context.closeElement();
    return context.endLayout(0);
}

pub fn main(init: std.process.Init) !void {
    var errors = ErrorLog{};
    var query = QueryLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 640, .height = 480 }, .{
        .max_element_count = 256,
        .max_render_command_count = 256,
        .max_text_cache_word_count = 512,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &errors,
        },
    });
    defer context.deinit();
    context.setQueryScrollOffsetFunction(queryScrollOffset, &query);

    var stdout_buffer: [128 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try context.setPointerState(.{}, false);
    try context.setPointerState(.{}, false);
    try printPointer(out, &context, "normalized");

    var commands = try drawAttachmentMatrix(&context);
    try printCommands(out, "matrix", commands);
    for (0..9) |parent_index| {
        for (0..9) |element_index| {
            const index: u32 = @intCast(parent_index * 9 + element_index);
            try printElement(
                out,
                &context,
                "matrix",
                @intCast(parent_index),
                @intCast(element_index),
                context.staticIndexedId("floating-matrix", index),
                commands,
            );
        }
    }
    try printElement(out, &context, "anchor", -1, -1, context.staticId("floating-anchor"), commands);
    try printElement(out, &context, "root", -1, -1, context.staticId("floating-root-probe"), commands);
    try printElement(out, &context, "id", -1, -1, context.staticId("floating-id-probe"), commands);

    commands = try drawClipFrame(&context);
    try printCommands(out, "clip-internal", commands);
    try printElement(out, &context, "clip-target-internal", -1, -1, context.staticId("floating-clip-target"), commands);
    try printElement(out, &context, "clip-parent-internal", -1, -1, context.staticId("floating-clip-parent"), commands);
    try printElement(out, &context, "clip-none-internal", -1, -1, context.staticId("floating-clip-none"), commands);
    try printElement(out, &context, "clip-id-internal", -1, -1, context.staticId("floating-clip-id"), commands);
    try context.setPointerState(.{ .x = 25, .y = 69 }, false);
    try printPointer(out, &context, "clip-internal-overlap");

    context.setExternalScrollHandlingEnabled(true);
    query.length = 0;
    commands = try drawClipFrame(&context);
    try printQuery(out, "clip-external", &query);
    try printCommands(out, "clip-external", commands);
    try printElement(out, &context, "clip-target-external", -1, -1, context.staticId("floating-clip-target"), commands);
    try printElement(out, &context, "clip-parent-external", -1, -1, context.staticId("floating-clip-parent"), commands);
    try printElement(out, &context, "clip-none-external", -1, -1, context.staticId("floating-clip-none"), commands);
    try printElement(out, &context, "clip-id-external", -1, -1, context.staticId("floating-clip-id"), commands);
    try context.setPointerState(.{ .x = 15, .y = 68 }, false);
    try printPointer(out, &context, "clip-external-overlap");
    context.setExternalScrollHandlingEnabled(false);

    commands = try drawZStack(&context, .capture);
    try printCommands(out, "z-capture", commands);
    try context.setPointerState(.{ .x = 10, .y = 10 }, true);
    try printPointer(out, &context, "capture-press");
    try context.setPointerState(.{ .x = 10, .y = 10 }, true);
    try printPointer(out, &context, "capture-held");
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try printPointer(out, &context, "capture-release");
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try printPointer(out, &context, "capture-released");
    try context.setPointerState(.{ .x = 100, .y = 100 }, false);
    try printPointer(out, &context, "capture-inclusive-edge");
    try context.setPointerState(.{ .x = 100.25, .y = 100 }, false);
    try printPointer(out, &context, "capture-outside-edge");

    commands = try drawZStack(&context, .passthrough);
    try printCommands(out, "z-passthrough", commands);
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try printPointer(out, &context, "passthrough-overlap");
    try context.setPointerState(.{ .x = 40, .y = 40 }, false);
    try printPointer(out, &context, "passthrough-child-edge");
    try context.setPointerState(.{ .x = 40.25, .y = 40 }, false);
    try printPointer(out, &context, "passthrough-child-outside");

    try printErrors(out, &errors);
    try out.flush();
    if (errors.length != 0) return error.OracleErrors;
}
