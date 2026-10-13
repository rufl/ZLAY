const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorRecord = struct {
    phase: i32,
    error_type: zlay.ErrorType,
    text: zlay.String,
};

const ErrorLog = struct {
    phase: i32 = 0,
    length: usize = 0,
    records: [16]ErrorRecord = undefined,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.records.len) contract.failLogOverflow("parity-regression diagnostics");
    log.records[log.length] = .{
        .phase = log.phase,
        .error_type = error_data.error_type,
        .text = error_data.error_text,
    };
    log.length += 1;
}

fn measureText(
    text: zlay.StringSlice,
    config: *zlay.TextElementConfig,
    _: ?*anyopaque,
) zlay.Dimensions {
    const font_size: f32 = @floatFromInt(if (config.font_size == 0) 1 else config.font_size);
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * font_size,
        .height = font_size,
    };
}

fn f32Bits(value: f32) u32 {
    return @bitCast(value);
}

fn printElement(
    out: *std.Io.Writer,
    label: []const u8,
    context: *const zlay.Context,
    element_id: zlay.ElementId,
) !void {
    const data = context.getElementData(element_id);
    try out.print("element {s} found {d} box {d} {d} {d} {d}\n", .{
        label,
        @intFromBool(data.found),
        f32Bits(data.bounding_box.x),
        f32Bits(data.bounding_box.y),
        f32Bits(data.bounding_box.width),
        f32Bits(data.bounding_box.height),
    });
}

fn printCommands(out: *std.Io.Writer, label: []const u8, commands: zlay.RenderCommandArray) !void {
    try out.print("commands {s} {d}\n", .{ label, commands.length });
    for (commands.items(), 0..) |command, index| {
        const text_length: i32 = if (command.command_type == .text)
            command.render_data.text.string_contents.length
        else
            0;
        try out.print("command {s} {d} type {d} id {d} box {d} {d} {d} {d} text {d}\n", .{
            label,
            index,
            @backingInt(command.command_type),
            command.id,
            f32Bits(command.bounding_box.x),
            f32Bits(command.bounding_box.y),
            f32Bits(command.bounding_box.width),
            f32Bits(command.bounding_box.height),
            text_length,
        });
    }
}

fn printDiagnostics(out: *std.Io.Writer, log: *const ErrorLog) !void {
    try out.print("diagnostics {d}\n", .{log.length});
    for (log.records[0..log.length], 0..) |record, index| {
        try out.print("diagnostic {d} phase {d} type {d} static {d} len {d} text {s}\n", .{
            index,
            record.phase,
            @backingInt(record.error_type),
            @intFromBool(record.text.is_statically_allocated),
            record.text.length,
            record.text.asSlice(),
        });
    }
}

var hover_calls: usize = 0;
var mutation_space_calls: usize = 0;

fn countHover(_: zlay.ElementId, _: zlay.PointerData, _: ?*anyopaque) void {
    hover_calls += 1;
}

fn mutatingMeasureText(
    text: zlay.StringSlice,
    config: *zlay.TextElementConfig,
    _: ?*anyopaque,
) zlay.Dimensions {
    if (std.mem.eql(u8, text.asSlice(), " ")) {
        mutation_space_calls += 1;
        if (mutation_space_calls == 2) config.font_id = 77;
    }
    return .{ .width = @floatFromInt(text.asSlice().len), .height = 1 };
}

pub fn main(init: std.process.Init) !void {
    var errors = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 200, .height = 200 }, .{
        .max_element_count = 64,
        .max_text_cache_word_count = 128,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &errors,
        },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);
    context.setCullingEnabled(false);

    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const fresh_id = context.staticId("parity-fresh");
    try context.beginLayout();
    try context.openElementWithIdUnconfigured(fresh_id);
    try printElement(out, "fresh-open", &context, fresh_id);
    try context.configureOpenElement(.{
        .layout = .{ .sizing = .{ .width = zlay.fixed(10), .height = zlay.fixed(10) } },
    });
    try context.closeElement();
    try printElement(out, "fresh-closed", &context, fresh_id);
    var commands = try context.endLayout(0);
    try printElement(out, "fresh-ended", &context, fresh_id);
    try printCommands(out, "fresh", commands);

    try context.beginLayout();
    try context.openElementWithId(context.staticId("parity-floating-aspect"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(100), .height = zlay.fixed(20) } },
        .aspect_ratio = .{ .aspect_ratio = 2 },
        .floating = .{ .attach_to = .root },
        .background_color = .{ .r = 255, .a = 255 },
    });
    try context.closeElement();
    commands = try context.endLayout(0);
    try printElement(out, "floating-aspect", &context, context.staticId("parity-floating-aspect"));
    try printCommands(out, "floating-aspect", commands);

    try context.beginLayout();
    try context.openElementWithId(context.staticId("parity-clip-row"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(200), .height = zlay.fixed(40) },
            .layout_direction = .left_to_right,
        },
    });
    try context.openElementWithId(context.staticId("parity-spacer"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(50), .height = zlay.fixed(40) } },
    });
    try context.closeElement();
    try context.openElementWithId(context.staticId("parity-clipper"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(20), .height = zlay.fixed(20) } },
        .clip = .{ .horizontal = true, .vertical = true },
    });
    errors.phase = 30;
    try context.openElementWithId(context.staticId("parity-missing-clipped-float"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(10), .height = zlay.fixed(10) } },
        .floating = .{
            .parent_id = context.staticId("parity-not-there").id,
            .attach_to = .element_with_id,
            .clip_to = .attached_parent,
        },
        .background_color = .{ .b = 255, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();
    try context.closeElement();
    commands = try context.endLayout(0);
    try printElement(out, "missing-parent-clipper", &context, context.staticId("parity-clipper"));
    try printElement(out, "missing-parent-float", &context, context.staticId("parity-missing-clipped-float"));
    try printCommands(out, "missing-parent", commands);

    var capacity_context = zlay.Context.init(std.heap.page_allocator, .{ .width = 200, .height = 200 }, .{
        .max_element_count = 8,
        .max_text_cache_word_count = 128,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &errors,
        },
    });
    defer capacity_context.deinit();
    capacity_context.setMeasureTextFunction(measureText, null);
    capacity_context.setCullingEnabled(false);

    try capacity_context.beginLayout();
    try capacity_context.openElementWithId(capacity_context.staticId("parity-wrap-container"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(1), .height = zlay.grow() } },
    });
    try capacity_context.textSlice(
        "a a a a a a a a a a a a a a a a a a a a",
        .{ .font_size = 1 },
    );
    try capacity_context.closeElement();
    errors.phase = 40;
    commands = try capacity_context.endLayout(0);
    const wrapped_text_id = zlay.hash.number(0, capacity_context.staticId("parity-wrap-container").id);
    try printElement(out, "wrapped-text", &capacity_context, wrapped_text_id);
    try printCommands(out, "wrapped-text", commands);

    const missing_start = errors.length;
    context.setMeasureTextFunction(null, null);
    try context.beginLayout();
    errors.phase = 50;
    try context.text(zlay.String.literal("missing measure one"), .{
        .font_size = 1,
        .line_height = 3,
    });
    const missing_after_first = errors.length - missing_start;
    context.setMeasureTextFunction(measureText, null);
    context.setMeasureTextFunction(null, null);
    try context.text(zlay.String.literal("missing measure two"), .{
        .font_size = 1,
        .line_height = 3,
    });
    const missing_after_second = errors.length - missing_start;
    _ = try context.endLayout(0);
    const missing_after_end = errors.length - missing_start;
    try out.print("missing-measure diagnostics {d} {d} {d}\n", .{
        missing_after_first,
        missing_after_second,
        missing_after_end,
    });

    context.setMeasureTextFunction(measureText, null);
    const saved_layout_default = zlay.layout_default.*;
    zlay.layout_default.sizing.width = zlay.percent(0.5);
    zlay.layout_default.sizing.height = zlay.percent(0.5);
    zlay.layout_default.padding = .{ .left = 7, .right = 3, .top = 5, .bottom = 1 };
    try context.beginLayout();
    try context.openElementWithId(context.staticId("parity-layout-default-container"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(100), .height = zlay.fixed(20) } },
    });
    try context.text(zlay.String.literal("abc"), .{ .font_size = 1 });
    try context.closeElement();
    commands = try context.endLayout(0);
    const layout_default_text_id = zlay.hash.number(
        0,
        context.staticId("parity-layout-default-container").id,
    );
    try printElement(out, "layout-default-text", &context, layout_default_text_id);
    try printCommands(out, "layout-default", commands);
    zlay.layout_default.* = saved_layout_default;

    mutation_space_calls = 0;
    context.setMeasureTextFunction(mutatingMeasureText, null);
    try context.beginLayout();
    try context.openElementWithId(context.staticId("parity-measure-mutation-container"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(1), .height = zlay.fixed(10) } },
    });
    try context.text(zlay.String.literal("a a"), .{ .font_id = 1, .font_size = 1 });
    try context.closeElement();
    commands = try context.endLayout(0);
    try out.print("measure-mutation spaces {d} commands {d}\n", .{
        mutation_space_calls,
        commands.length,
    });
    for (commands.items(), 0..) |command, index| {
        if (command.command_type != .text) continue;
        try out.print("mutation-command {d} font {d} text {d} box {d} {d} {d} {d}\n", .{
            index,
            command.render_data.text.font_id,
            command.render_data.text.string_contents.length,
            f32Bits(command.bounding_box.x),
            f32Bits(command.bounding_box.y),
            f32Bits(command.bounding_box.width),
            f32Bits(command.bounding_box.height),
        });
    }
    context.setMeasureTextFunction(measureText, null);

    try context.beginLayout();
    try context.openElementWithId(context.staticId("parity-hover-retained"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(10), .height = zlay.fixed(10) } },
    });
    try context.onHover(countHover, null);
    try context.closeElement();
    try context.openElementWithId(context.staticId("parity-hover-cleared"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(10), .height = zlay.fixed(10) } },
    });
    try context.onHover(countHover, null);
    try context.onHover(null, null);
    try context.closeElement();
    _ = try context.endLayout(0);
    hover_calls = 0;
    try context.setPointerState(.{ .x = 5, .y = 5 }, false);
    const retained_calls = hover_calls;
    try context.setPointerState(.{ .x = 5, .y = 15 }, false);
    const cleared_calls = hover_calls - retained_calls;
    try out.print("hover retained {d} cleared {d}\n", .{ retained_calls, cleared_calls });

    try printDiagnostics(out, &errors);
    try out.flush();
}
