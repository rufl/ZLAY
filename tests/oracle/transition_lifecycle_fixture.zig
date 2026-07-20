const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const EventRecord = struct {
    tag: i32,
    state: zlay.TransitionState,
    properties: zlay.TransitionProperty,
    elapsed: f32,
    duration: f32,
    initial: zlay.TransitionData,
    before: zlay.TransitionData,
    after: zlay.TransitionData,
    target: zlay.TransitionData,
    complete: bool,
};

var events: [128]EventRecord = undefined;
var event_count: usize = 0;
var reappear_finals: usize = 0;
var parent_finals: usize = 0;
var nested_initials: usize = 0;

fn color(r: f32, g: f32, b: f32, a: f32) zlay.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn lifecycleHandler(arguments: zlay.TransitionCallbackArguments, tag: i32) bool {
    if (event_count >= events.len) contract.failLogOverflow("transition lifecycle events");

    const event = &events[event_count];
    event_count += 1;
    event.tag = tag;
    event.state = arguments.transition_state;
    event.properties = arguments.properties;
    event.elapsed = arguments.elapsed_time;
    event.duration = arguments.duration;
    event.initial = arguments.initial;
    event.before = arguments.current.*;
    event.target = arguments.target;
    event.complete = arguments.elapsed_time >= arguments.duration;
    arguments.current.* = if (event.complete) arguments.target else arguments.initial;
    event.after = arguments.current.*;
    return event.complete;
}

fn pruneHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return lifecycleHandler(arguments, 11);
}

fn reappearHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return lifecycleHandler(arguments, 21);
}

fn moveHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return lifecycleHandler(arguments, 31);
}

fn parentHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return lifecycleHandler(arguments, 41);
}

fn nestedHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return lifecycleHandler(arguments, 42);
}

fn reappearFinal(current_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    reappear_finals += 1;
    var current = current_value;
    current.bounding_box.x += 13;
    current.background_color = color(230, 31, 47, 255);
    return current;
}

fn parentFinal(current_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    parent_finals += 1;
    var current = current_value;
    current.bounding_box.y += 17;
    current.background_color = color(19, 211, 73, 255);
    return current;
}

fn nestedInitial(target_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    nested_initials += 1;
    var target = target_value;
    target.background_color = color(3, 5, 7, 255);
    return target;
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

fn floatingBox(x: f32, y: f32, width: f32, height: f32, background: zlay.Color) zlay.ElementDeclaration {
    var declaration = fixedBox(width, height, background);
    declaration.floating.offset = .{ .x = x, .y = y };
    declaration.floating.attach_to = .root;
    declaration.floating.pointer_capture_mode = .passthrough;
    return declaration;
}

fn transitionConfig(
    handler: zlay.TransitionHandler,
    duration: f32,
    properties: zlay.TransitionProperty,
) zlay.TransitionElementConfig {
    return .{
        .handler = handler,
        .duration = duration,
        .properties = properties,
    };
}

fn pruneBox(background: zlay.Color) zlay.ElementDeclaration {
    var declaration = floatingBox(7, 9, 23, 13, background);
    declaration.transition = transitionConfig(pruneHandler, 1, .background_color);
    return declaration;
}

fn reappearBox(background: zlay.Color) zlay.ElementDeclaration {
    var declaration = floatingBox(43, 9, 25, 13, background);
    declaration.transition = transitionConfig(reappearHandler, 1, .background_color);
    declaration.transition.exit.set_final_state = reappearFinal;
    declaration.transition.exit.trigger = .skip_when_parent_exits;
    declaration.transition.exit.sibling_ordering = .natural_order;
    return declaration;
}

fn moveBox() zlay.ElementDeclaration {
    var declaration = fixedBox(17, 11, color(71, 83, 97, 255));
    declaration.transition = transitionConfig(moveHandler, 1, .position);
    return declaration;
}

fn parentExitBox() zlay.ElementDeclaration {
    var declaration = floatingBox(83, 91, 53, 31, color(101, 37, 149, 255));
    declaration.layout.padding = zlay.padding(3);
    declaration.transition = transitionConfig(parentHandler, 0.75, .background_color);
    declaration.transition.exit.set_final_state = parentFinal;
    declaration.transition.exit.trigger = .skip_when_parent_exits;
    declaration.transition.exit.sibling_ordering = .natural_order;
    return declaration;
}

fn nestedBox(background: zlay.Color) zlay.ElementDeclaration {
    var declaration = fixedBox(19, 9, background);
    declaration.transition = transitionConfig(nestedHandler, 0.5, .background_color);
    declaration.transition.enter.set_initial_state = nestedInitial;
    declaration.transition.enter.trigger = .skip_on_first_parent_frame;
    return declaration;
}

fn plainPruneBox() zlay.ElementDeclaration {
    return floatingBox(7, 9, 23, 13, color(59, 181, 43, 255));
}

fn declareLayout(context: *zlay.Context, frame: usize) !void {
    if (frame == 0) {
        try context.openElementWithId(context.id("prune"), pruneBox(color(193, 17, 29, 255)));
        try context.closeElement();
    } else if (frame == 1) {
        try context.openElementWithId(context.id("prune"), pruneBox(color(31, 47, 223, 255)));
        try context.closeElement();
    } else if (frame == 2) {
        try context.openElementWithId(context.id("prune"), plainPruneBox());
        try context.closeElement();
    } else if (frame == 3 or frame == 4) {
        try context.openElementWithId(context.id("prune"), pruneBox(color(241, 199, 11, 255)));
        try context.closeElement();
    } else if (frame >= 6) {
        try context.openElementWithId(context.id("prune"), pruneBox(color(241, 199, 11, 255)));
        try context.closeElement();
    }

    if (frame == 0) {
        try context.openElementWithId(context.id("reappear"), reappearBox(color(181, 23, 41, 255)));
        try context.closeElement();
    } else if (frame == 1) {
        try context.openElementWithId(context.id("reappear"), reappearBox(color(37, 61, 211, 255)));
        try context.closeElement();
    } else if (frame == 3 or frame >= 5) {
        try context.openElementWithId(context.id("reappear"), reappearBox(color(43, 197, 89, 255)));
        try context.closeElement();
    }

    try context.openElementWithId(context.id("move-a"), floatingBox(11, 43, 41, 25, .{}));
    if (frame == 0 or frame == 2 or frame >= 6) {
        try context.openElementWithId(context.id("move"), moveBox());
        try context.closeElement();
    }
    try context.closeElement();

    try context.openElementWithId(context.id("move-b"), floatingBox(151, 57, 41, 25, .{}));
    if (frame == 1 or frame == 3 or frame == 4) {
        try context.openElementWithId(context.id("move"), moveBox());
        try context.closeElement();
    }
    try context.closeElement();

    if (frame <= 1) {
        try context.openElementWithId(context.id("exit-parent"), parentExitBox());
        try context.openElementWithId(
            context.id("nested"),
            nestedBox(if (frame == 0) color(167, 53, 79, 255) else color(29, 173, 191, 255)),
        );
        try context.closeElement();
        try context.closeElement();
    }

    try context.openElementWithId(context.id("rescue-parent"), floatingBox(211, 91, 53, 31, .{}));
    if (frame >= 3) {
        try context.openElementWithId(
            context.id("nested"),
            nestedBox(if (frame < 5) color(47, 193, 107, 255) else color(229, 157, 13, 255)),
        );
        try context.closeElement();
    }
    try context.closeElement();
}

fn printData(out: *std.Io.Writer, data: zlay.TransitionData) !void {
    try out.print("{x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
        contract.f32Bits(data.background_color.r),
        contract.f32Bits(data.background_color.g),
        contract.f32Bits(data.background_color.b),
        contract.f32Bits(data.background_color.a),
    });
}

fn nameForId(context: *const zlay.Context, id: u32) ?[]const u8 {
    if (id == context.id("prune").id) return "prune";
    if (id == context.id("reappear").id) return "reappear";
    if (id == context.id("move").id) return "move";
    if (id == context.id("exit-parent").id) return "exit-parent";
    if (id == context.id("nested").id) return "nested";
    return null;
}

fn printStatus(
    out: *std.Io.Writer,
    context: *const zlay.Context,
    frame: usize,
    name: []const u8,
) !void {
    const data = context.getElementData(context.id(name));
    try out.print("status {d} {s} {d} {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
        frame,
        name,
        @intFromBool(data.found),
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
    });
}

fn runFrame(context: *zlay.Context, out: *std.Io.Writer, frame: usize) !void {
    event_count = 0;
    try context.beginLayout();
    try declareLayout(context, frame);
    const commands = try context.endLayout(0.25);

    try out.print("frame {d} commands {d} events {d} finals {d} {d} initials {d}\n", .{
        frame,
        commands.items().len,
        event_count,
        reappear_finals,
        parent_finals,
        nested_initials,
    });

    for (events[0..event_count], 0..) |event, index| {
        try out.print("event {d} {d} {d} {d} {x:0>8} {x:0>8} initial ", .{
            frame,
            index,
            event.tag,
            @intFromEnum(event.state),
            @intFromEnum(event.properties),
            contract.f32Bits(event.elapsed),
        });
        try printData(out, event.initial);
        try out.writeAll(" before ");
        try printData(out, event.before);
        try out.writeAll(" after ");
        try printData(out, event.after);
        try out.writeAll(" target ");
        try printData(out, event.target);
        try out.print(" duration {x:0>8} complete {d}\n", .{
            contract.f32Bits(event.duration),
            @intFromBool(event.complete),
        });
    }

    var relevant_index: usize = 0;
    for (commands.items()) |command| {
        if (command.command_type != .rectangle) continue;
        const name = nameForId(context, command.id) orelse continue;
        const command_color = command.render_data.rectangle.background_color;
        try out.print("rect {d} {d} {s} {d} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
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

    inline for (.{ "prune", "reappear", "move", "exit-parent", "nested" }) |name| {
        try printStatus(out, context, frame, name);
    }
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 300, .height = 180 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();

    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    for (0..8) |frame| try runFrame(&context, out, frame);
    try out.flush();
}
