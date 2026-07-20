const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

var image_payload: u8 = 0;
var custom_payload: u8 = 0;
var inject_warning = false;

const ErrorLog = struct {
    types: [32]zlay.ErrorType = undefined,
    length: usize = 0,
};

const FixtureIds = struct {
    root: zlay.ElementId,
    parent: zlay.ElementId,
    child: zlay.ElementId,
    floating: zlay.ElementId,
    text: zlay.ElementId,
    panel: zlay.ElementId,
    parent_row: zlay.ElementId,
    child_row: zlay.ElementId,
    collapse: zlay.ElementId,
    highlight: zlay.ElementId,
    highlight_rectangle: zlay.ElementId,
    scroll: zlay.ElementId,
    close: zlay.ElementId,
};

fn f32Bits(value: f32) u32 {
    return @bitCast(value);
}

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("debug diagnostics");
    log.types[log.length] = error_data.error_type;
    log.length += 1;
}

fn measureText(text: zlay.StringSlice, config: *zlay.TextElementConfig, _: ?*anyopaque) zlay.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * 8,
        .height = if (config.font_size == 0) 16 else @floatFromInt(config.font_size),
    };
}

fn drawFrame(context: *zlay.Context) !zlay.RenderCommandArray {
    try context.beginLayout();
    if (inject_warning) {
        try context.debug_warnings.append(context.allocator, .{
            .base_message = zlay.String.literal("Injected warning: "),
            .dynamic_message = zlay.String.literal("active payload"),
        });
    }
    try context.openElementWithId(context.staticId("inspected-parent"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(200), .height = zlay.fixed(100) },
            .padding = zlay.padding(4),
            .child_gap = 2,
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 30, .g = 60, .b = 90, .a = 255 },
    });
    try context.openElementWithId(context.staticId("inspected-child"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(50), .height = zlay.fixed(30) } },
        .background_color = .{ .r = 90, .g = 60, .b = 30, .a = 255 },
        .overlay_color = .{ .r = 14, .g = 28, .b = 42, .a = 96 },
        .corner_radius = .{ .top_left = 1, .top_right = 2, .bottom_left = 3, .bottom_right = 4 },
        .aspect_ratio = .{ .aspect_ratio = 1.25 },
        .image = .{ .image_data = @ptrCast(&image_payload) },
        .clip = .{ .horizontal = true, .vertical = true },
        .border = .{
            .color = .{ .r = 200, .g = 120, .b = 40, .a = 255 },
            .width = .{ .left = 1, .right = 2, .top = 3, .bottom = 4 },
        },
        .custom = .{ .custom_data = @ptrCast(&custom_payload) },
    });
    try context.closeElement();
    try context.textSlice("hello debug", .{
        .text_color = .{ .r = 230, .g = 220, .b = 210, .a = 255 },
        .font_id = 7,
        .font_size = 12,
        .letter_spacing = 3,
        .line_height = 19,
        .wrap_mode = .newlines,
        .text_alignment = .right,
    });
    try context.openElementWithId(context.staticId("inspected-floating"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(26), .height = zlay.fixed(18) } },
        .background_color = .{ .r = 70, .g = 80, .b = 90, .a = 255 },
        .floating = .{
            .offset = .{ .x = 11, .y = 13 },
            .expand = .{ .width = 3, .height = 5 },
            .parent_id = context.staticId("inspected-parent").id,
            .z_index = 9,
            .attach_points = .{ .element = .right_bottom, .parent = .left_top },
            .pointer_capture_mode = .passthrough,
            .attach_to = .element_with_id,
            .clip_to = .none,
        },
    });
    try context.closeElement();
    try context.closeElement();
    return context.endLayout(0);
}

fn countText(commands: zlay.RenderCommandArray, expected: []const u8) usize {
    var count: usize = 0;
    for (commands.items()) |command| {
        if (command.command_type == .text and std.mem.eql(u8, command.render_data.text.string_contents.asSlice(), expected)) {
            count += 1;
        }
    }
    return count;
}

fn printBox(out: *std.Io.Writer, context: *const zlay.Context, label: []const u8, id: zlay.ElementId) !void {
    const data = context.getElementData(id);
    try out.print("box {s} found {d} bits {d} {d} {d} {d}\n", .{
        label,
        @intFromBool(data.found),
        f32Bits(data.bounding_box.x),
        f32Bits(data.bounding_box.y),
        f32Bits(data.bounding_box.width),
        f32Bits(data.bounding_box.height),
    });
}

fn printScroll(out: *std.Io.Writer, context: *zlay.Context, label: []const u8, id: zlay.ElementId) !void {
    const data = context.getScrollContainerData(id);
    const position = if (data.scroll_position) |value| value.* else zlay.Vector2{};
    try out.print("scroll {s} found {d} pointer {d} pos {d} {d} viewport {d} {d} content {d} {d}\n", .{
        label,
        @intFromBool(data.found),
        @intFromBool(data.scroll_position != null),
        f32Bits(position.x),
        f32Bits(position.y),
        f32Bits(data.scroll_container_dimensions.width),
        f32Bits(data.scroll_container_dimensions.height),
        f32Bits(data.content_dimensions.width),
        f32Bits(data.content_dimensions.height),
    });
}

fn printErrors(out: *std.Io.Writer, log: *const ErrorLog) !void {
    try out.print("errors {d}", .{log.length});
    for (log.types[0..log.length]) |error_type| try out.print(" {d}", .{@intFromEnum(error_type)});
    try out.writeByte('\n');
}

fn printFullCommands(out: *std.Io.Writer, frame: usize, context: *const zlay.Context, commands: zlay.RenderCommandArray) !void {
    try out.print("full-frame {d} enabled {d} commands {d}\n", .{
        frame,
        @intFromBool(context.isDebugModeEnabled()),
        commands.length,
    });
    for (commands.items(), 0..) |command, index| {
        try out.print("command {d} {d} type {d} id {d} z {d} box {d} {d} {d} {d} user {d}", .{
            frame,
            index,
            @intFromEnum(command.command_type),
            command.id,
            command.z_index,
            f32Bits(command.bounding_box.x),
            f32Bits(command.bounding_box.y),
            f32Bits(command.bounding_box.width),
            f32Bits(command.bounding_box.height),
            @intFromBool(command.user_data != null),
        });
        if (command.command_type == .text) {
            const text = command.render_data.text.string_contents.asSlice();
            try out.print(" text {d} {s}\n", .{ text.len, text });
        } else {
            try out.writeAll(" text 0\n");
        }
    }
}

fn printMarkerCommand(
    out: *std.Io.Writer,
    label: []const u8,
    commands: zlay.RenderCommandArray,
    ids: FixtureIds,
    selected_row: bool,
) !void {
    var count: usize = 0;
    var first = zlay.RenderCommand{};
    for (commands.items()) |command| {
        if (command.command_type != .rectangle) continue;
        var matches = command.id == ids.highlight_rectangle.id;
        if (selected_row) {
            const color = command.render_data.rectangle.background_color;
            matches = color.r == 127.5 and color.g == 100 and color.b == 97.5 and color.a == 255;
        }
        if (!matches) continue;
        if (count == 0) first = command;
        count += 1;
    }
    try out.print("marker {s} count {d} id {d} z {d} box {d} {d} {d} {d}\n", .{
        label,
        count,
        if (count > 0) first.id else 0,
        if (count > 0) first.z_index else 0,
        if (count > 0) f32Bits(first.bounding_box.x) else 0,
        if (count > 0) f32Bits(first.bounding_box.y) else 0,
        if (count > 0) f32Bits(first.bounding_box.width) else 0,
        if (count > 0) f32Bits(first.bounding_box.height) else 0,
    });
}

fn printState(
    out: *std.Io.Writer,
    label: []const u8,
    context: *zlay.Context,
    commands: zlay.RenderCommandArray,
    ids: FixtureIds,
    errors: *const ErrorLog,
) !void {
    try out.print("state {s} enabled {d} commands {d}\n", .{
        label,
        @intFromBool(context.isDebugModeEnabled()),
        commands.length,
    });
    try printBox(out, context, "root", ids.root);
    try printBox(out, context, "panel", ids.panel);
    try printBox(out, context, "parent", ids.parent);
    try printBox(out, context, "child", ids.child);
    try printBox(out, context, "parent-row", ids.parent_row);
    try printBox(out, context, "child-row", ids.child_row);
    try printBox(out, context, "collapse", ids.collapse);
    try printBox(out, context, "highlight", ids.highlight);
    try printBox(out, context, "close", ids.close);
    try out.print("texts parent {d} child {d} plus {d} minus {d} details {d}\n", .{
        countText(commands, "inspected-parent"),
        countText(commands, "inspected-child"),
        countText(commands, "+"),
        countText(commands, "-"),
        countText(commands, "Element Configuration"),
    });
    try printMarkerCommand(out, "highlight", commands, ids, false);
    try printMarkerCommand(out, "selected-highlight-row", commands, ids, true);
    try printScroll(out, context, label, ids.scroll);
    try printErrors(out, errors);
}

fn centerOf(context: *const zlay.Context, id: zlay.ElementId) zlay.Vector2 {
    const data = context.getElementData(id);
    return .{
        .x = data.bounding_box.x + data.bounding_box.width / 2,
        .y = data.bounding_box.y + data.bounding_box.height / 2,
    };
}

pub fn main(init: std.process.Init) !void {
    var error_log = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 800, .height = 400 }, .{
        .max_element_count = 512,
        .max_render_command_count = 512,
        .max_text_cache_word_count = 2048,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &error_log,
        },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);
    context.setDebugModeEnabled(true);

    const panel = context.staticId("Clay__DebugView");
    const parent = context.staticId("inspected-parent");
    const child = context.staticId("inspected-child");
    const header = zlay.hash.number(0, panel.id);
    const ids = FixtureIds{
        .root = context.staticId("Clay__RootContainer"),
        .parent = parent,
        .child = child,
        .floating = context.staticId("inspected-floating"),
        .text = zlay.hash.number(1, parent.id),
        .panel = panel,
        .parent_row = context.staticIndexedId("Clay__DebugView_ElementOuter", parent.id),
        .child_row = context.staticIndexedId("Clay__DebugView_ElementOuter", child.id),
        .collapse = context.staticIndexedId("Clay__DebugView_CollapseElement", parent.id),
        .highlight = context.staticId("Clay__DebugView_ElementHighlight"),
        .highlight_rectangle = context.staticId("Clay__DebugView_ElementHighlightRectangle"),
        .scroll = context.staticId("Clay__DebugViewOuterScrollPane"),
        .close = zlay.hash.number(2, header.id),
    };

    var stdout_buffer: [256 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try context.setPointerState(.{}, false);
    try context.setPointerState(.{}, false);

    var commands = try drawFrame(&context);
    try printFullCommands(out, 0, &context, commands);
    try printState(out, "initial", &context, commands, ids, &error_log);

    try context.setPointerState(.{ .x = 650, .y = 65 }, false);
    context.updateScrollContainers(false, .{ .y = -2 }, 0.016);
    try printScroll(out, &context, "after-wheel", ids.scroll);
    commands = try drawFrame(&context);
    try printState(out, "scrolled-highlight", &context, commands, ids, &error_log);

    try context.setPointerState(.{ .x = 650, .y = 55 }, true);
    commands = try drawFrame(&context);
    try printState(out, "selected", &context, commands, ids, &error_log);
    try printFullCommands(out, 1, &context, commands);

    context.debug_selected_element_id = ids.child.id;
    try context.setPointerState(.{}, false);
    commands = try drawFrame(&context);
    try printFullCommands(out, 2, &context, commands);

    context.debug_selected_element_id = ids.text.id;
    commands = try drawFrame(&context);
    try printFullCommands(out, 3, &context, commands);

    context.debug_selected_element_id = ids.floating.id;
    commands = try drawFrame(&context);
    try printFullCommands(out, 4, &context, commands);

    context.debug_selected_element_id = 0;
    inject_warning = true;
    commands = try drawFrame(&context);
    try printFullCommands(out, 5, &context, commands);
    inject_warning = false;

    const collapse_point = centerOf(&context, ids.collapse);
    try context.setPointerState(collapse_point, false);
    try context.setPointerState(collapse_point, false);
    try context.setPointerState(collapse_point, true);
    commands = try drawFrame(&context);
    try printState(out, "collapse-click", &context, commands, ids, &error_log);

    try context.setPointerState(collapse_point, false);
    commands = try drawFrame(&context);
    try printState(out, "collapsed", &context, commands, ids, &error_log);

    const close_point = centerOf(&context, ids.close);
    try context.setPointerState(close_point, false);
    try context.setPointerState(close_point, true);
    commands = try drawFrame(&context);
    try printState(out, "close-press", &context, commands, ids, &error_log);

    try context.setPointerState(close_point, true);
    try out.print("close-callback enabled {d}\n", .{@intFromBool(context.isDebugModeEnabled())});
    commands = try drawFrame(&context);
    try printState(out, "closed", &context, commands, ids, &error_log);

    try out.flush();
}
