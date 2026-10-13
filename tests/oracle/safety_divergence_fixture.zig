const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const ErrorLog = struct {
    types: [32]zlay.ErrorType = undefined,
    length: usize = 0,
};

fn recordError(error_data: zlay.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    if (log.length >= log.types.len) contract.failLogOverflow("safety-divergence diagnostics");
    log.types[log.length] = error_data.error_type;
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

fn fixedBox(width: f32, height: f32, color: zlay.Color) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(width), .height = zlay.fixed(height) } },
        .background_color = color,
    };
}

fn floatingBox(x: f32, y: f32, color: zlay.Color) zlay.ElementDeclaration {
    var declaration = fixedBox(10, 10, color);
    declaration.floating = .{
        .offset = .{ .x = x, .y = y },
        .attach_to = .root,
    };
    return declaration;
}

fn printErrorDelta(out: *std.Io.Writer, errors: *const ErrorLog, start: usize) !void {
    try out.print(" errors {d}", .{errors.length - start});
    for (errors.types[start..errors.length]) |error_type| {
        try out.print(" {d}", .{@backingInt(error_type)});
    }
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

fn printElement(
    out: *std.Io.Writer,
    context: *const zlay.Context,
    label: []const u8,
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

fn runMalformedDepth(
    out: *std.Io.Writer,
    context: *zlay.Context,
    errors: *ErrorLog,
    depth: usize,
) !void {
    const error_start = errors.length;
    try context.beginLayout();
    for (0..depth) |index| {
        const id = context.staticIndexedId("safety-malformed", @intCast(depth * 10 + index));
        try context.openElementWithId(id, floatingBox(
            @floatFromInt(index * 15),
            @floatFromInt(depth * 20),
            .{
                .r = @floatFromInt(20 + depth * 20),
                .g = @floatFromInt(40 + index * 20),
                .b = 90,
                .a = 255,
            },
        ));
    }
    const commands = try context.endLayout(0);
    const residual_user_depth: usize = if (context.getOpenElementId()) |_| 1 else |_| 0;
    try out.print("malformed depth {d}", .{depth});
    try printErrorDelta(out, errors, error_start);
    try out.print(" residual {d}\n", .{residual_user_depth});
    var label_buffer: [32]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buffer, "malformed-{d}", .{depth});
    try printCommands(out, label, commands);

    const recovery_error_start = errors.length;
    const recovery_id = context.staticIndexedId("safety-recovery", @intCast(depth));
    try context.beginLayout();
    try context.openElementWithId(recovery_id, fixedBox(12, 7, .{ .r = 10, .g = 200, .b = 30, .a = 255 }));
    try context.closeElement();
    const recovery_commands = try context.endLayout(0);
    const recovery_residual: usize = if (context.getOpenElementId()) |_| 1 else |_| 0;
    try out.print("recovery depth {d}", .{depth});
    try printErrorDelta(out, errors, recovery_error_start);
    try out.print(" residual {d}\n", .{recovery_residual});
    const recovery_label = try std.fmt.bufPrint(&label_buffer, "recovery-{d}", .{depth});
    try printCommands(out, recovery_label, recovery_commands);
    try printElement(out, context, recovery_label, recovery_id);
}

fn runFloatingClipLeak(out: *std.Io.Writer, context: *zlay.Context, errors: *ErrorLog) !void {
    const error_start = errors.length;
    try context.beginLayout();
    try context.openElementWithId(context.staticId("safety-outer-clip"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(20), .height = zlay.fixed(20) } },
        .clip = .{ .horizontal = true, .vertical = true },
    });
    try context.openElementWithId(context.staticId("safety-floating-and-clip"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(10), .height = zlay.fixed(10) } },
        .floating = .{ .attach_to = .parent, .clip_to = .attached_parent },
        .clip = .{ .horizontal = true, .vertical = true },
    });
    try context.closeElement();
    try context.closeElement();
    try context.openElementWithId(context.staticId("safety-after-double-clip"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(10), .height = zlay.fixed(10) } },
        .floating = .{
            .offset = .{ .x = 50 },
            .attach_to = .parent,
            .clip_to = .attached_parent,
        },
        .background_color = .{ .r = 255, .b = 255, .a = 255 },
    });
    try context.closeElement();
    var commands = try context.endLayout(0);
    try out.writeAll("floating-clip");
    try printErrorDelta(out, errors, error_start);
    try out.writeAll(" leaked-clips 0\n");
    try printCommands(out, "floating-clip", commands);

    const recovery_error_start = errors.length;
    try context.beginLayout();
    try context.openElementWithId(context.staticId("safety-floating-clip-recovery"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(10), .height = zlay.fixed(10) } },
        .floating = .{
            .offset = .{ .x = 50 },
            .attach_to = .parent,
            .clip_to = .attached_parent,
        },
        .background_color = .{ .r = 30, .g = 180, .b = 220, .a = 255 },
    });
    try context.closeElement();
    commands = try context.endLayout(0);
    try out.writeAll("floating-clip-recovery");
    try printErrorDelta(out, errors, recovery_error_start);
    try out.writeAll(" leaked-clips 0\n");
    try printCommands(out, "floating-clip-recovery", commands);
    try printElement(out, context, "floating-clip-recovery", context.staticId("safety-floating-clip-recovery"));
}

fn runNegativeSliceEdge(out: *std.Io.Writer, context: *zlay.Context, errors: *ErrorLog) !void {
    const error_start = errors.length;
    try context.beginLayout();
    try context.openElementWithId(context.staticId("safety-negative-container"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(1), .height = zlay.fixed(30) } },
    });
    try context.text(zlay.String.literal(" \n"), .{ .font_size = 10, .line_height = 10 });
    try context.closeElement();
    var commands = try context.endLayout(0);
    try out.writeAll("negative-slice");
    try printErrorDelta(out, errors, error_start);
    try out.writeByte('\n');
    try printCommands(out, "negative-slice", commands);
    try printElement(
        out,
        context,
        "negative-slice",
        zlay.hash.number(0, context.staticId("safety-negative-container").id),
    );

    const recovery_error_start = errors.length;
    try context.beginLayout();
    try context.openElementWithId(context.staticId("safety-text-recovery-container"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(30), .height = zlay.fixed(20) } },
    });
    try context.text(zlay.String.literal("ok"), .{ .font_size = 10, .line_height = 10 });
    try context.closeElement();
    commands = try context.endLayout(0);
    try out.writeAll("negative-slice-recovery");
    try printErrorDelta(out, errors, recovery_error_start);
    try out.writeByte('\n');
    try printCommands(out, "negative-slice-recovery", commands);
    try printElement(
        out,
        context,
        "negative-slice-recovery",
        zlay.hash.number(0, context.staticId("safety-text-recovery-container").id),
    );
}

pub fn main(init: std.process.Init) !void {
    var errors = ErrorLog{};
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 200, .height = 200 }, .{
        .max_element_count = 256,
        .max_text_cache_word_count = 512,
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &errors,
        },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);
    context.setCullingEnabled(false);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    for (0..4) |depth| try runMalformedDepth(out, &context, &errors, depth);
    try runFloatingClipLeak(out, &context, &errors);
    try runNegativeSliceEdge(out, &context, &errors);

    try out.print("total-errors {d}", .{errors.length});
    for (errors.types[0..errors.length]) |error_type| {
        try out.print(" {d}", .{@backingInt(error_type)});
    }
    try out.writeByte('\n');
    try out.flush();
}
