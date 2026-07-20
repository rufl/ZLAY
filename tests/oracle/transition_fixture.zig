const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const animated_properties: zlay.TransitionProperty = @enumFromInt(
    @intFromEnum(zlay.TransitionProperty.x) | @intFromEnum(zlay.TransitionProperty.background_color),
);

const CallbackRecord = struct {
    state: zlay.TransitionState,
    properties: zlay.TransitionProperty,
    elapsed: f32,
    before: zlay.TransitionData,
    after: zlay.TransitionData,
    target: zlay.TransitionData,
    complete: bool,
};

const SetterKind = enum {
    enter,
    exit,
};

const SetterRecord = struct {
    kind: SetterKind,
    input: zlay.TransitionData,
    output: zlay.TransitionData,
};

var callback_records: [4]CallbackRecord = undefined;
var callback_count: usize = 0;
var setter_record: ?SetterRecord = null;

fn color(r: f32, g: f32, b: f32) zlay.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn enterInitial(target: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    var initial = target;
    initial.bounding_box.x -= 20;
    initial.background_color = color(0, 0, 0);
    if (setter_record != null) contract.failLogOverflow("transition setter");
    setter_record = .{ .kind = .enter, .input = target, .output = initial };
    return initial;
}

fn exitFinal(current: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    var final = current;
    final.bounding_box.x += 20;
    final.background_color = color(200, 0, 0);
    if (setter_record != null) contract.failLogOverflow("transition setter");
    setter_record = .{ .kind = .exit, .input = current, .output = final };
    return final;
}

fn linear(initial: f32, target: f32, ratio: f32) f32 {
    return initial + (target - initial) * ratio;
}

fn linearHandler(arguments: zlay.TransitionCallbackArguments) bool {
    var ratio: f32 = if (arguments.duration > 0) arguments.elapsed_time / arguments.duration else 1;
    if (ratio > 1) ratio = 1;

    if (callback_count >= callback_records.len) contract.failLogOverflow("transition callback");
    const record = &callback_records[callback_count];
    callback_count += 1;
    record.state = arguments.transition_state;
    record.properties = arguments.properties;
    record.elapsed = arguments.elapsed_time;
    record.before = arguments.current.*;
    record.target = arguments.target;

    arguments.current.bounding_box.x = linear(arguments.initial.bounding_box.x, arguments.target.bounding_box.x, ratio);
    arguments.current.background_color.r = linear(arguments.initial.background_color.r, arguments.target.background_color.r, ratio);
    arguments.current.background_color.g = linear(arguments.initial.background_color.g, arguments.target.background_color.g, ratio);
    arguments.current.background_color.b = linear(arguments.initial.background_color.b, arguments.target.background_color.b, ratio);
    arguments.current.background_color.a = linear(arguments.initial.background_color.a, arguments.target.background_color.a, ratio);

    record.after = arguments.current.*;
    record.complete = arguments.elapsed_time >= arguments.duration;
    return record.complete;
}

fn fixedBox(width: f32, height: f32, background: zlay.Color) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(width), .height = zlay.fixed(height) } },
        .background_color = background,
    };
}

fn animatedBox(background: zlay.Color) zlay.ElementDeclaration {
    var declaration = fixedBox(10, 10, background);
    declaration.transition = .{
        .handler = linearHandler,
        .duration = 0.5,
        .properties = animated_properties,
        .enter = .{
            .set_initial_state = enterInitial,
            .trigger = .trigger_on_first_parent_frame,
        },
        .exit = .{
            .set_final_state = exitFinal,
            .trigger = .skip_when_parent_exits,
            .sibling_ordering = .natural_order,
        },
    };
    return declaration;
}

fn printTransitionData(stdout: *std.Io.Writer, data: zlay.TransitionData) !void {
    try stdout.print("box {d} {d} {d} {d} bg {d} {d} {d} {d} ov {d} {d} {d} {d} border {d} {d} {d} {d} width {d} {d} {d} {d} {d}", .{
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
        contract.f32Bits(data.background_color.r),
        contract.f32Bits(data.background_color.g),
        contract.f32Bits(data.background_color.b),
        contract.f32Bits(data.background_color.a),
        contract.f32Bits(data.overlay_color.r),
        contract.f32Bits(data.overlay_color.g),
        contract.f32Bits(data.overlay_color.b),
        contract.f32Bits(data.overlay_color.a),
        contract.f32Bits(data.border_color.r),
        contract.f32Bits(data.border_color.g),
        contract.f32Bits(data.border_color.b),
        contract.f32Bits(data.border_color.a),
        data.border_width.left,
        data.border_width.right,
        data.border_width.top,
        data.border_width.bottom,
        data.border_width.between_children,
    });
}

fn nameForId(id: u32, first: zlay.ElementId, animated: zlay.ElementId, last: zlay.ElementId) ?[]const u8 {
    if (id == first.id) return "first";
    if (id == animated.id) return "animated";
    if (id == last.id) return "last";
    return null;
}

fn printFrame(stdout: *std.Io.Writer, context: *const zlay.Context, frame: usize, commands: zlay.RenderCommandArray) !void {
    const first = context.id("first");
    const animated = context.id("animated");
    const last = context.id("last");

    if (setter_record) |record| {
        try stdout.print("setter {d} {s} input ", .{ frame, @tagName(record.kind) });
        try printTransitionData(stdout, record.input);
        try stdout.writeAll(" output ");
        try printTransitionData(stdout, record.output);
        try stdout.writeByte('\n');
    }
    for (callback_records[0..callback_count]) |record| {
        try stdout.print("callback {d} {d} {d} {d} before ", .{
            frame,
            @intFromEnum(record.state),
            @intFromEnum(record.properties),
            contract.f32Bits(record.elapsed),
        });
        try printTransitionData(stdout, record.before);
        try stdout.writeAll(" after ");
        try printTransitionData(stdout, record.after);
        try stdout.writeAll(" target ");
        try printTransitionData(stdout, record.target);
        try stdout.print(" complete {d}\n", .{@intFromBool(record.complete)});
    }

    var animated_command: ?zlay.RenderCommand = null;
    var relevant_index: usize = 0;
    for (commands.items()) |command| {
        if (command.command_type != .rectangle) continue;
        const name = nameForId(command.id, first, animated, last) orelse continue;
        if (command.id == animated.id) animated_command = command;
        const command_color = command.render_data.rectangle.background_color;
        try stdout.print("rect {d} {d} {s} {d} {d} {d} {d} {d} rgba {d} {d} {d} {d}\n", .{
            frame,
            relevant_index,
            name,
            command.id,
            contract.f32Bits(command.bounding_box.x),
            contract.f32Bits(command.bounding_box.y),
            contract.f32Bits(command.bounding_box.width),
            contract.f32Bits(command.bounding_box.height),
            contract.f32Bits(command_color.r),
            contract.f32Bits(command_color.g),
            contract.f32Bits(command_color.b),
            contract.f32Bits(command_color.a),
        });
        relevant_index += 1;
    }

    if (animated_command) |command| {
        const command_color = command.render_data.rectangle.background_color;
        try stdout.print("frame {d} animated 1 box {d} {d} {d} {d} rgba {d} {d} {d} {d}\n", .{
            frame,
            contract.f32Bits(command.bounding_box.x),
            contract.f32Bits(command.bounding_box.y),
            contract.f32Bits(command.bounding_box.width),
            contract.f32Bits(command.bounding_box.height),
            contract.f32Bits(command_color.r),
            contract.f32Bits(command_color.g),
            contract.f32Bits(command_color.b),
            contract.f32Bits(command_color.a),
        });
    } else {
        try stdout.print("frame {d} animated 0 box 0 0 0 0 rgba 0 0 0 0\n", .{frame});
    }
}

fn runFrame(
    stdout: *std.Io.Writer,
    context: *zlay.Context,
    frame: usize,
    show_animated: bool,
    first_width: f32,
    target_color: zlay.Color,
    delta_time: f32,
) !void {
    callback_count = 0;
    setter_record = null;

    try context.beginLayout();
    try context.openElementWithId(context.id("parent"), fixedBox(100, 20, .{}));
    try context.openElementWithId(context.id("first"), fixedBox(first_width, 10, color(40, 40, 40)));
    try context.closeElement();
    if (show_animated) {
        try context.openElementWithId(context.id("animated"), animatedBox(target_color));
        try context.closeElement();
    }
    try context.openElementWithId(context.id("last"), fixedBox(10, 10, color(0, 0, 200)));
    try context.closeElement();
    try context.closeElement();
    const commands = try context.endLayout(delta_time);
    try printFrame(stdout, context, frame, commands);
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 120, .height = 40 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();

    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const entering_target = color(0, 200, 0);
    const changed_target = color(200, 100, 0);
    try runFrame(stdout, &context, 0, true, 10, entering_target, 0.25);
    try runFrame(stdout, &context, 1, true, 10, entering_target, 0.25);
    try runFrame(stdout, &context, 2, true, 10, entering_target, 0.25);
    try runFrame(stdout, &context, 3, true, 10, entering_target, 0.25);
    try runFrame(stdout, &context, 4, true, 30, changed_target, 0.25);
    try runFrame(stdout, &context, 5, true, 30, changed_target, 0.25);
    try runFrame(stdout, &context, 6, true, 30, changed_target, 0.25);
    try runFrame(stdout, &context, 7, false, 30, changed_target, 0.25);
    try runFrame(stdout, &context, 8, false, 30, changed_target, 0.25);
    try runFrame(stdout, &context, 9, false, 30, changed_target, 0.25);
    try runFrame(stdout, &context, 10, false, 30, changed_target, 0.25);
    try stdout.flush();
}
