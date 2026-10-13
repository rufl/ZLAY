const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const MeasureState = struct {
    tag: u8,
    advance: f32,
    height_bias: f32,
};

const MeasureRecord = struct {
    tag: u8 = 0,
    length: i32 = 0,
    offset: usize = 0,
    same_base: bool = false,
    font_id: u16 = 0,
    font_size: u16 = 0,
    letter_spacing: u16 = 0,
    line_height: u16 = 0,
    bytes: [64]u8 = undefined,
    bytes_len: usize = 0,
};

const ExitRecord = struct {
    state: zlay.TransitionState,
    elapsed: f32,
    duration: f32,
};

var measure_records: [256]MeasureRecord = undefined;
var measure_record_count: usize = 0;
var exit_records: [16]ExitRecord = undefined;
var exit_record_count: usize = 0;
var error_records: [16]zlay.ErrorType = undefined;
var error_record_count: usize = 0;

var measure_a = MeasureState{ .tag = 1, .advance = 4, .height_bias = 0 };
var measure_b = MeasureState{ .tag = 2, .advance = 6, .height_bias = 1 };

const empty_static = zlay.String.literal("");
const static_text = zlay.String.literal("static-lit");
const cache_probe = zlay.String.literal("cache probe");
const clear_probe = zlay.String.literal("clear probe");
var dynamic_storage = [_]u8{ 'd', 'y', 'n', 'a', 'm', 'i', 'c', '-', 'd', 'a', 't', 'a' };
var derived_storage = [_]u8{ '_', '_', 'd', 'e', 'r', 'i', 'v', 'e', 'd', '-', 's', 'l', 'i', 'c', 'e', '_', '_' };
var retained_storage = [_]u8{ 'r', 'e', 't', 'a', 'i', 'n', 'e', 'd', '-', 'l', 'i', 'f', 'e' };

fn dynamicText() zlay.String {
    return zlay.String.fromSlice(dynamic_storage[0..]);
}

fn derivedText() zlay.String {
    return .{
        .length = 7,
        .chars = derived_storage[2..9],
    };
}

fn retainedText() zlay.String {
    return zlay.String.fromSlice(retained_storage[0..]);
}

fn pointerOffset(chars: []const u8, base_chars: []const u8) usize {
    if (chars.len == 0 and base_chars.len == 0 and chars.ptr == base_chars.ptr) return 0;
    return @intFromPtr(chars.ptr) - @intFromPtr(base_chars.ptr);
}

fn printEscaped(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeByte('"');
    for (bytes) |byte| {
        switch (byte) {
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            '\\' => try out.writeAll("\\\\"),
            '"' => try out.writeAll("\\\""),
            else => try out.writeByte(byte),
        }
    }
    try out.writeByte('"');
}

fn measureText(
    text: zlay.StringSlice,
    config: *zlay.TextElementConfig,
    user_data: ?*anyopaque,
) zlay.Dimensions {
    const state: *MeasureState = @ptrCast(@alignCast(user_data.?));
    if (measure_record_count >= measure_records.len) contract.failLogOverflow("string-text measure records");
    const record = &measure_records[measure_record_count];
    measure_record_count += 1;
    const bytes = text.asSlice();
    if (bytes.len > record.bytes.len) contract.failLogOverflow("string-text measure bytes");
    record.* = .{
        .tag = state.tag,
        .length = text.length,
        .offset = pointerOffset(text.chars, text.base_chars),
        .same_base = text.chars.ptr == text.base_chars.ptr,
        .font_id = config.font_id,
        .font_size = config.font_size,
        .letter_spacing = config.letter_spacing,
        .line_height = config.line_height,
        .bytes_len = bytes.len,
    };
    @memcpy(record.bytes[0..bytes.len], bytes);

    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) *
            (state.advance + @as(f32, @floatFromInt(config.letter_spacing))),
        .height = @as(f32, @floatFromInt(config.font_size)) + state.height_bias,
    };
}

fn recordError(error_data: zlay.ErrorData) void {
    if (error_record_count >= error_records.len) contract.failLogOverflow("string-text diagnostics");
    error_records[error_record_count] = error_data.error_type;
    error_record_count += 1;
}

fn printInput(
    out: *std.Io.Writer,
    name: []const u8,
    value: zlay.String,
    base_chars: []const u8,
) !void {
    try out.print("input {s} static {d} len {d} source-offset {d} bytes ", .{
        name,
        @intFromBool(value.is_statically_allocated),
        value.length,
        pointerOffset(value.chars, base_chars),
    });
    try printEscaped(out, value.asSlice());
    try out.writeByte('\n');
}

fn textRow() zlay.ElementDeclaration {
    return .{
        .layout = .{
            .sizing = .{
                .width = zlay.fixed(38),
                .height = zlay.fit(),
            },
        },
    };
}

fn declareTextCase(
    context: *zlay.Context,
    id_name: []const u8,
    text: zlay.String,
    font_id: u16,
    wrap_mode: zlay.TextElementConfigWrapMode,
) !void {
    try context.openElementWithId(context.id(id_name), textRow());
    try context.text(text, .{
        .text_color = .{ .r = 230, .g = 235, .b = 245, .a = 255 },
        .font_id = font_id,
        .font_size = 8,
        .letter_spacing = 1,
        .line_height = 10,
        .wrap_mode = wrap_mode,
    });
    try context.closeElement();
}

fn declareMetadataCorpus(context: *zlay.Context) !void {
    try context.openElementWithId(context.id("metadata-root"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
            .child_gap = 1,
            .layout_direction = .top_to_bottom,
        },
    });
    try declareTextCase(context, "empty-static", empty_static, 1, .words);
    try declareTextCase(context, "static-text", static_text, 2, .words);
    try declareTextCase(context, "dynamic-text", dynamicText(), 3, .words);
    try declareTextCase(context, "derived-text", derivedText(), 4, .words);
    try declareTextCase(context, "space-one", zlay.String.literal(" "), 10, .words);
    try declareTextCase(context, "space-two", zlay.String.literal("  "), 11, .words);
    try declareTextCase(context, "newline-one", zlay.String.literal("\n"), 12, .newlines);
    try declareTextCase(context, "newline-two", zlay.String.literal("\n\n"), 13, .newlines);
    try declareTextCase(context, "leading-space", zlay.String.literal(" lead"), 14, .words);
    try declareTextCase(context, "trailing-space", zlay.String.literal("trail "), 15, .words);
    try declareTextCase(context, "double-space", zlay.String.literal("a  b"), 16, .words);
    try declareTextCase(context, "double-newline", zlay.String.literal("a\n\nb"), 17, .newlines);
    try declareTextCase(context, "tab-edge", zlay.String.literal("tab\tedge"), 18, .words);
    try context.closeElement();
}

fn declareCacheCorpus(context: *zlay.Context, include_clear_probe: bool) !void {
    try context.openElementWithId(context.id("cache-root"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
            .child_gap = 2,
            .layout_direction = .top_to_bottom,
        },
    });
    try declareTextCase(context, "cache-probe-row", cache_probe, 30, .none);
    if (include_clear_probe) {
        try declareTextCase(context, "clear-probe-row", clear_probe, 31, .none);
    }
    try context.closeElement();
}

fn retainedExitFinal(current_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    var current = current_value;
    current.bounding_box.x += 12;
    return current;
}

fn retainedExitHandler(arguments: zlay.TransitionCallbackArguments) bool {
    if (exit_record_count >= exit_records.len) contract.failLogOverflow("string-text exit records");
    exit_records[exit_record_count] = .{
        .state = arguments.transition_state,
        .elapsed = arguments.elapsed_time,
        .duration = arguments.duration,
    };
    exit_record_count += 1;
    var ratio: f32 = if (arguments.duration > 0)
        arguments.elapsed_time / arguments.duration
    else
        1;
    if (ratio > 1) ratio = 1;
    arguments.current.bounding_box.x = arguments.initial.bounding_box.x +
        (arguments.target.bounding_box.x - arguments.initial.bounding_box.x) * ratio;
    return arguments.elapsed_time >= arguments.duration;
}

fn retainedDeclaration() zlay.ElementDeclaration {
    return .{
        .layout = .{
            .sizing = .{
                .width = zlay.fixed(90),
                .height = zlay.fixed(14),
            },
        },
        .transition = .{
            .handler = retainedExitHandler,
            .duration = 0.6,
            .properties = .x,
            .exit = .{
                .set_final_state = retainedExitFinal,
                .trigger = .skip_when_parent_exits,
                .sibling_ordering = .natural_order,
            },
        },
    };
}

fn declareRetainedCorpus(context: *zlay.Context, show_retained: bool) !void {
    try context.openElementWithId(context.id("retained-root"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
            .layout_direction = .top_to_bottom,
        },
    });
    if (show_retained) {
        try context.openElementWithId(context.id("retained-owner"), retainedDeclaration());
        try context.text(retainedText(), .{
            .text_color = .{ .r = 245, .g = 220, .b = 120, .a = 255 },
            .font_id = 40,
            .font_size = 8,
            .wrap_mode = .none,
        });
        try context.closeElement();
    }
    try context.closeElement();
}

fn printMeasureRecords(out: *std.Io.Writer, frame: usize) !void {
    try out.print("frame {d} measures {d}\n", .{ frame, measure_record_count });
    for (measure_records[0..measure_record_count], 0..) |record, index| {
        try out.print("frame {d} measure {d} tag {d} len {d} offset {d} same-base {d} font {d} {d} spacing {d} line {d} bytes ", .{
            frame,
            index,
            record.tag,
            record.length,
            record.offset,
            @intFromBool(record.same_base),
            record.font_id,
            record.font_size,
            record.letter_spacing,
            record.line_height,
        });
        try printEscaped(out, record.bytes[0..record.bytes_len]);
        try out.writeByte('\n');
    }
}

fn printExitRecords(out: *std.Io.Writer, frame: usize) !void {
    try out.print("frame {d} exits {d}\n", .{ frame, exit_record_count });
    for (exit_records[0..exit_record_count], 0..) |record, index| {
        try out.print("frame {d} exit {d} state {d} elapsed {x:0>8} duration {x:0>8}\n", .{
            frame,
            index,
            @backingInt(record.state),
            contract.f32Bits(record.elapsed),
            contract.f32Bits(record.duration),
        });
    }
}

fn printErrorRecords(out: *std.Io.Writer, frame: usize) !void {
    try out.print("frame {d} errors {d}", .{ frame, error_record_count });
    for (error_records[0..error_record_count]) |error_type| {
        try out.print(" {d}", .{@backingInt(error_type)});
    }
    try out.writeByte('\n');
}

fn printTextCommands(
    out: *std.Io.Writer,
    frame: usize,
    commands: zlay.RenderCommandArray,
) !void {
    var text_count: usize = 0;
    for (commands.items()) |command| {
        if (command.command_type == .text) text_count += 1;
    }
    try out.print("frame {d} texts {d}\n", .{ frame, text_count });

    var text_index: usize = 0;
    for (commands.items()) |command| {
        if (command.command_type != .text) continue;
        const text = command.render_data.text;
        try out.print("frame {d} text {d} len {d} offset {d} same-base {d} box {x:0>8} {x:0>8} {x:0>8} {x:0>8} font {d} {d} spacing {d} line {d} bytes ", .{
            frame,
            text_index,
            text.string_contents.length,
            pointerOffset(text.string_contents.chars, text.string_contents.base_chars),
            @intFromBool(text.string_contents.chars.ptr == text.string_contents.base_chars.ptr),
            contract.f32Bits(command.bounding_box.x),
            contract.f32Bits(command.bounding_box.y),
            contract.f32Bits(command.bounding_box.width),
            contract.f32Bits(command.bounding_box.height),
            text.font_id,
            text.font_size,
            text.letter_spacing,
            text.line_height,
        });
        try printEscaped(out, text.string_contents.asSlice());
        try out.writeByte('\n');
        text_index += 1;
    }
}

const FrameKind = enum {
    metadata,
    cache,
    retained,
};

fn runFrame(
    context: *zlay.Context,
    out: *std.Io.Writer,
    frame: usize,
    kind: FrameKind,
    option: bool,
    delta_time: f32,
) !void {
    measure_record_count = 0;
    exit_record_count = 0;
    error_record_count = 0;
    try context.beginLayout();
    switch (kind) {
        .metadata => try declareMetadataCorpus(context),
        .cache => try declareCacheCorpus(context, option),
        .retained => try declareRetainedCorpus(context, option),
    }
    const commands = try context.endLayout(delta_time);
    try printErrorRecords(out, frame);
    try printMeasureRecords(out, frame);
    try printExitRecords(out, frame);
    try printTextCommands(out, frame, commands);
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 180, .height = 260 }, .{
        .error_handler = .{ .error_handler_function = recordError },
    });
    defer context.deinit();
    context.setCullingEnabled(false);

    var stdout_buffer: [128 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try printInput(out, "empty", empty_static, empty_static.chars);
    try printInput(out, "static", static_text, static_text.chars);
    try printInput(out, "dynamic", dynamicText(), dynamic_storage[0..]);
    try printInput(out, "derived", derivedText(), derived_storage[0..]);

    context.setMeasureTextFunction(measureText, &measure_a);
    try runFrame(&context, out, 0, .metadata, false, 0);
    try runFrame(&context, out, 1, .cache, false, 0);

    context.setMeasureTextFunction(null, null);
    try runFrame(&context, out, 2, .cache, true, 0);

    context.setMeasureTextFunction(measureText, &measure_b);
    try runFrame(&context, out, 3, .cache, true, 0);

    context.resetMeasureTextCache();
    try runFrame(&context, out, 4, .cache, true, 0);

    try runFrame(&context, out, 5, .retained, true, 0);
    try runFrame(&context, out, 6, .retained, false, 0.2);
    try runFrame(&context, out, 7, .retained, false, 0.2);
    try runFrame(&context, out, 8, .retained, false, 0.2);
    try runFrame(&context, out, 9, .retained, false, 0.2);

    try out.flush();
}
