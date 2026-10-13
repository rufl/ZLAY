const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const all_transition_properties: zlay.TransitionProperty = @fromBackingInt(@intCast(
    @backingInt(zlay.TransitionProperty.bounding_box) |
        @backingInt(zlay.TransitionProperty.background_color) |
        @backingInt(zlay.TransitionProperty.overlay_color) |
        @backingInt(zlay.TransitionProperty.corner_radius) |
        @backingInt(zlay.TransitionProperty.border),
));

const EventRecord = struct {
    tag: i32,
    state: zlay.TransitionState,
    properties: zlay.TransitionProperty,
    elapsed: f32,
    duration: f32,
    current: zlay.TransitionData,
};

var events: [64]EventRecord = undefined;
var event_count: usize = 0;
var enter_skip_setters: usize = 0;
var enter_trigger_setters: usize = 0;
var parent_skip_finals: usize = 0;
var parent_trigger_finals: usize = 0;
var order_under_finals: usize = 0;
var order_natural_finals: usize = 0;
var order_above_finals: usize = 0;

fn color(r: f32, g: f32, b: f32, a: f32) zlay.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn lerp(initial: f32, target: f32, ratio: f32) f32 {
    return initial + (target - initial) * ratio;
}

fn lerpWidth(initial: u16, target: u16, ratio: f32) u16 {
    return @intFromFloat(lerp(@floatFromInt(initial), @floatFromInt(target), ratio));
}

fn lerpColor(initial: zlay.Color, target: zlay.Color, ratio: f32) zlay.Color {
    return .{
        .r = lerp(initial.r, target.r, ratio),
        .g = lerp(initial.g, target.g, ratio),
        .b = lerp(initial.b, target.b, ratio),
        .a = lerp(initial.a, target.a, ratio),
    };
}

fn matrixHandler(arguments: zlay.TransitionCallbackArguments, tag: i32) bool {
    var ratio: f32 = if (arguments.duration > 0) arguments.elapsed_time / arguments.duration else 1;
    if (ratio > 1) ratio = 1;

    arguments.current.bounding_box.x = lerp(arguments.initial.bounding_box.x, arguments.target.bounding_box.x, ratio);
    arguments.current.bounding_box.y = lerp(arguments.initial.bounding_box.y, arguments.target.bounding_box.y, ratio);
    arguments.current.bounding_box.width = lerp(arguments.initial.bounding_box.width, arguments.target.bounding_box.width, ratio);
    arguments.current.bounding_box.height = lerp(arguments.initial.bounding_box.height, arguments.target.bounding_box.height, ratio);
    arguments.current.background_color = lerpColor(arguments.initial.background_color, arguments.target.background_color, ratio);
    arguments.current.overlay_color = lerpColor(arguments.initial.overlay_color, arguments.target.overlay_color, ratio);
    arguments.current.border_color = lerpColor(arguments.initial.border_color, arguments.target.border_color, ratio);
    arguments.current.border_width.left = lerpWidth(arguments.initial.border_width.left, arguments.target.border_width.left, ratio);
    arguments.current.border_width.right = lerpWidth(arguments.initial.border_width.right, arguments.target.border_width.right, ratio);
    arguments.current.border_width.top = lerpWidth(arguments.initial.border_width.top, arguments.target.border_width.top, ratio);
    arguments.current.border_width.bottom = lerpWidth(arguments.initial.border_width.bottom, arguments.target.border_width.bottom, ratio);
    arguments.current.border_width.between_children = lerpWidth(arguments.initial.border_width.between_children, arguments.target.border_width.between_children, ratio);

    if (event_count >= events.len) contract.failLogOverflow("transition-matrix event");
    events[event_count] = .{
        .tag = tag,
        .state = arguments.transition_state,
        .properties = arguments.properties,
        .elapsed = arguments.elapsed_time,
        .duration = arguments.duration,
        .current = arguments.current.*,
    };
    event_count += 1;
    return arguments.elapsed_time >= arguments.duration;
}

fn allHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 1);
}
fn zeroHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 2);
}
fn cornerHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 3);
}
fn resizeHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 4);
}
fn enterSkipHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 5);
}
fn enterTriggerHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 6);
}
fn moveBlockHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 7);
}
fn moveAllowHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 8);
}
fn parentSkipHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 9);
}
fn parentTriggerHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 10);
}
fn orderUnderHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 11);
}
fn orderNaturalHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 12);
}
fn orderAboveHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 13);
}
fn interactionBlockHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 14);
}
fn interactionAllowHandler(arguments: zlay.TransitionCallbackArguments) bool {
    return matrixHandler(arguments, 15);
}

fn enterSkipInitial(target_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    enter_skip_setters += 1;
    var target = target_value;
    target.background_color = color(0, 0, 0, 255);
    return target;
}

fn enterTriggerInitial(target_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    enter_trigger_setters += 1;
    var target = target_value;
    target.background_color = color(0, 0, 0, 255);
    return target;
}

fn interactionInitial(target_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    var target = target_value;
    target.bounding_box.x -= 12;
    return target;
}

fn parentSkipFinal(current_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    parent_skip_finals += 1;
    var current = current_value;
    current.background_color = color(220, 30, 30, 255);
    return current;
}

fn parentTriggerFinal(current_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    parent_trigger_finals += 1;
    var current = current_value;
    current.background_color = color(220, 30, 30, 255);
    return current;
}

fn orderUnderFinal(current_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    order_under_finals += 1;
    var current = current_value;
    current.background_color = color(200, 20, 120, 255);
    return current;
}

fn orderNaturalFinal(current_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    order_natural_finals += 1;
    var current = current_value;
    current.background_color = color(200, 20, 120, 255);
    return current;
}

fn orderAboveFinal(current_value: zlay.TransitionData, _: zlay.TransitionProperty) zlay.TransitionData {
    order_above_finals += 1;
    var current = current_value;
    current.background_color = color(200, 20, 120, 255);
    return current;
}

fn measureText(text: zlay.StringSlice, config: *zlay.TextElementConfig, _: ?*anyopaque) zlay.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * 5,
        .height = @floatFromInt(config.font_size),
    };
}

fn fixedBox(width: f32, height: f32, background: zlay.Color) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(width), .height = zlay.fixed(height) } },
        .background_color = background,
    };
}

fn baseTransition(
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

fn floatingParent(x: f32, y: f32, width: f32, height: f32) zlay.ElementDeclaration {
    var declaration = fixedBox(width, height, .{});
    declaration.layout.padding = zlay.padding(2);
    declaration.layout.child_gap = 2;
    declaration.layout.layout_direction = .top_to_bottom;
    declaration.floating.offset = .{ .x = x, .y = y };
    declaration.floating.attach_to = .root;
    declaration.floating.pointer_capture_mode = .passthrough;
    return declaration;
}

fn allDeclaration(changed: bool) zlay.ElementDeclaration {
    var declaration = fixedBox(
        if (changed) 34 else 20,
        if (changed) 24 else 16,
        if (changed) color(180, 90, 30, 255) else color(20, 40, 60, 255),
    );
    declaration.overlay_color = if (changed) color(90, 20, 140, 128) else color(10, 30, 50, 64);
    declaration.corner_radius = zlay.cornerRadius(if (changed) 9 else 2);
    declaration.border.color = if (changed) color(230, 180, 40, 255) else color(80, 120, 160, 255);
    declaration.border.width = if (changed)
        .{ .left = 5, .right = 6, .top = 7, .bottom = 8, .between_children = 2 }
    else
        .{ .left = 1, .right = 2, .top = 3, .bottom = 4 };
    declaration.floating.offset = if (changed) .{ .x = 52, .y = 24 } else .{ .x = 8, .y = 8 };
    declaration.floating.z_index = 4;
    declaration.floating.attach_to = .root;
    declaration.transition = baseTransition(allHandler, 1, all_transition_properties);
    return declaration;
}

fn zeroDeclaration(changed: bool) zlay.ElementDeclaration {
    var declaration = fixedBox(
        20,
        14,
        if (changed) color(20, 210, 80, 255) else color(200, 40, 40, 255),
    );
    declaration.corner_radius = zlay.cornerRadius(3);
    declaration.floating.offset = .{ .x = 105, .y = 8 };
    declaration.floating.z_index = 3;
    declaration.floating.attach_to = .root;
    declaration.transition = baseTransition(zeroHandler, 0, .background_color);
    return declaration;
}

fn cornerDeclaration(changed: bool) zlay.ElementDeclaration {
    var declaration = fixedBox(20, 14, color(90, 80, 180, 255));
    declaration.corner_radius = zlay.cornerRadius(if (changed) 11 else 1);
    declaration.floating.offset = .{ .x = 135, .y = 8 };
    declaration.floating.z_index = 2;
    declaration.floating.attach_to = .root;
    declaration.transition = baseTransition(cornerHandler, 1, .corner_radius);
    return declaration;
}

fn resizeDeclaration() zlay.ElementDeclaration {
    var declaration = zlay.ElementDeclaration{
        .layout = .{ .sizing = .{ .width = zlay.percent(0.25), .height = zlay.fixed(10) } },
        .background_color = color(30, 150, 180, 255),
    };
    declaration.floating.offset = .{ .x = 0, .y = 238 };
    declaration.floating.z_index = 1;
    declaration.floating.attach_to = .root;
    declaration.transition = baseTransition(resizeHandler, 1, .width);
    return declaration;
}

fn interactionDeclaration(allow: bool) zlay.ElementDeclaration {
    var declaration = fixedBox(
        20,
        12,
        if (allow) color(30, 210, 170, 255) else color(220, 80, 150, 255),
    );
    declaration.floating.offset = if (allow) .{ .x = 230, .y = 90 } else .{ .x = 200, .y = 90 };
    declaration.floating.z_index = 5;
    declaration.floating.attach_to = .root;
    declaration.transition = baseTransition(
        if (allow) interactionAllowHandler else interactionBlockHandler,
        1,
        .x,
    );
    declaration.transition.interaction_handling = if (allow)
        .allow_interactions_while_transitioning_position
    else
        .disable_interactions_while_transitioning_position;
    declaration.transition.enter.set_initial_state = interactionInitial;
    declaration.transition.enter.trigger = .trigger_on_first_parent_frame;
    return declaration;
}

fn enterChild(trigger: bool, target: zlay.Color) zlay.ElementDeclaration {
    var declaration = fixedBox(44, 16, target);
    declaration.transition = baseTransition(
        if (trigger) enterTriggerHandler else enterSkipHandler,
        0.5,
        .background_color,
    );
    declaration.transition.enter.set_initial_state = if (trigger) enterTriggerInitial else enterSkipInitial;
    declaration.transition.enter.trigger = if (trigger) .trigger_on_first_parent_frame else .skip_on_first_parent_frame;
    return declaration;
}

fn moveChild(allow: bool) zlay.ElementDeclaration {
    var declaration = fixedBox(
        20,
        10,
        if (allow) color(40, 180, 90, 255) else color(190, 80, 40, 255),
    );
    declaration.transition = baseTransition(
        if (allow) moveAllowHandler else moveBlockHandler,
        0.75,
        .position,
    );
    declaration.transition.interaction_handling = if (allow)
        .allow_interactions_while_transitioning_position
    else
        .disable_interactions_while_transitioning_position;
    return declaration;
}

fn parentExitChild(trigger: bool) zlay.ElementDeclaration {
    var declaration = fixedBox(
        42,
        14,
        if (trigger) color(40, 130, 210, 255) else color(170, 120, 30, 255),
    );
    declaration.transition = baseTransition(
        if (trigger) parentTriggerHandler else parentSkipHandler,
        0.5,
        .background_color,
    );
    declaration.transition.exit.set_final_state = if (trigger) parentTriggerFinal else parentSkipFinal;
    declaration.transition.exit.trigger = if (trigger) .trigger_when_parent_exits else .skip_when_parent_exits;
    declaration.transition.exit.sibling_ordering = .natural_order;
    return declaration;
}

fn orderExitChild(ordering: usize) zlay.ElementDeclaration {
    var declaration = fixedBox(60, 14, color(40, 170, 70, 255));
    var handler: zlay.TransitionHandler = orderUnderHandler;
    var final_state: zlay.TransitionSetFinalStateFunction = orderUnderFinal;
    var sibling_ordering: zlay.ExitTransitionSiblingOrdering = .underneath_siblings;
    if (ordering == 1) {
        handler = orderNaturalHandler;
        final_state = orderNaturalFinal;
        sibling_ordering = .natural_order;
    } else if (ordering == 2) {
        handler = orderAboveHandler;
        final_state = orderAboveFinal;
        sibling_ordering = .above_siblings;
    }
    declaration.transition = baseTransition(handler, 0.5, .background_color);
    declaration.transition.exit.set_final_state = final_state;
    declaration.transition.exit.trigger = .skip_when_parent_exits;
    declaration.transition.exit.sibling_ordering = sibling_ordering;
    return declaration;
}

fn declareOrderRow(context: *zlay.Context, ordering: usize, show_removed: bool) !void {
    const y = 148.0 + @as(f32, @floatFromInt(ordering)) * 28.0;
    const row_name = if (ordering == 0) "order-under-row" else if (ordering == 1) "order-natural-row" else "order-above-row";
    const first_name = if (ordering == 0) "order-under-first" else if (ordering == 1) "order-natural-first" else "order-above-first";
    const removed_name = if (ordering == 0) "order-under-removed" else if (ordering == 1) "order-natural-removed" else "order-above-removed";
    const last_name = if (ordering == 0) "order-under-last" else if (ordering == 1) "order-natural-last" else "order-above-last";

    try context.openElementWithId(context.id(row_name), floatingParent(0, y, 140, 18));
    try context.openElementWithId(context.id(first_name), fixedBox(10, 14, color(190, 40, 40, 255)));
    try context.closeElement();
    if (show_removed) {
        try context.openElementWithId(context.id(removed_name), orderExitChild(ordering));
        if (ordering == 1) {
            try context.textSlice("retained text", .{
                .text_color = color(240, 240, 255, 255),
                .font_size = 7,
                .wrap_mode = .none,
            });
        }
        try context.closeElement();
    }
    try context.openElementWithId(context.id(last_name), fixedBox(10, 14, color(40, 70, 200, 255)));
    try context.closeElement();
    try context.closeElement();
}

fn declareLayout(context: *zlay.Context, frame: usize) !void {
    const changed = frame >= 1;
    const reparented = frame >= 1;
    const show_parent_exit = frame < 4;
    const show_order_removed = frame < 4;

    try context.openElementWithId(context.id("all-props"), allDeclaration(changed));
    try context.closeElement();
    try context.openElementWithId(context.id("zero-duration"), zeroDeclaration(changed));
    try context.closeElement();
    try context.openElementWithId(context.id("corner-noop"), cornerDeclaration(changed));
    try context.closeElement();
    if (frame >= 1) {
        try context.openElementWithId(context.id("interaction-block"), interactionDeclaration(false));
        try context.closeElement();
        try context.openElementWithId(context.id("interaction-allow"), interactionDeclaration(true));
        try context.closeElement();
    }

    try context.openElementWithId(context.id("enter-parent"), floatingParent(0, 48, 110, 24));
    try context.openElementWithId(context.id("enter-skip"), enterChild(false, color(40, 170, 80, 255)));
    try context.closeElement();
    try context.openElementWithId(context.id("enter-trigger"), enterChild(true, color(40, 90, 210, 255)));
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.id("move-source"), floatingParent(180, 48, 70, 30));
    if (!reparented) {
        try context.openElementWithId(context.id("move-block"), moveChild(false));
        try context.closeElement();
        try context.openElementWithId(context.id("move-allow"), moveChild(true));
        try context.closeElement();
    }
    try context.closeElement();
    try context.openElementWithId(context.id("move-destination"), floatingParent(270, 48, 70, 30));
    if (reparented) {
        try context.openElementWithId(context.id("move-block"), moveChild(false));
        try context.closeElement();
        try context.openElementWithId(context.id("move-allow"), moveChild(true));
        try context.closeElement();
    }
    try context.closeElement();

    if (show_parent_exit) {
        try context.openElementWithId(context.id("parent-skip"), floatingParent(0, 100, 80, 22));
        try context.openElementWithId(context.id("parent-skip-child"), parentExitChild(false));
        try context.closeElement();
        try context.closeElement();
        try context.openElementWithId(context.id("parent-trigger"), floatingParent(100, 100, 80, 22));
        try context.openElementWithId(context.id("parent-trigger-child"), parentExitChild(true));
        try context.closeElement();
        try context.closeElement();
    }

    try declareOrderRow(context, 0, show_order_removed);
    try declareOrderRow(context, 1, show_order_removed);
    try declareOrderRow(context, 2, show_order_removed);
    try context.openElementWithId(context.id("resize-suppressed"), resizeDeclaration());
    try context.closeElement();
}

fn printTransitionData(out: *std.Io.Writer, data: zlay.TransitionData) !void {
    try out.print("box {d} {d} {d} {d} bg {d} {d} {d} {d} ov {d} {d} {d} {d} border {d} {d} {d} {d} width {d} {d} {d} {d} {d}", .{
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

fn boxIsZero(box: zlay.BoundingBox) bool {
    return box.x == 0 and box.y == 0 and box.width == 0 and box.height == 0;
}

fn printCommand(out: *std.Io.Writer, frame: usize, index: usize, command: zlay.RenderCommand) !void {
    try out.print("frame {d} command {d} type {d} id {d} z {d} box {d} {d} {d} {d}", .{
        frame,
        index,
        @backingInt(command.command_type),
        command.id,
        command.z_index,
        contract.f32Bits(command.bounding_box.x),
        contract.f32Bits(command.bounding_box.y),
        contract.f32Bits(command.bounding_box.width),
        contract.f32Bits(command.bounding_box.height),
    });
    switch (command.command_type) {
        .rectangle => {
            const rectangle = command.render_data.rectangle;
            try out.print(" rect {d} {d} {d} {d} radius {d} {d} {d} {d}", .{
                contract.f32Bits(rectangle.background_color.r),
                contract.f32Bits(rectangle.background_color.g),
                contract.f32Bits(rectangle.background_color.b),
                contract.f32Bits(rectangle.background_color.a),
                contract.f32Bits(rectangle.corner_radius.top_left),
                contract.f32Bits(rectangle.corner_radius.top_right),
                contract.f32Bits(rectangle.corner_radius.bottom_left),
                contract.f32Bits(rectangle.corner_radius.bottom_right),
            });
        },
        .border => {
            const border = command.render_data.border;
            try out.print(" border {d} {d} {d} {d} radius {d} {d} {d} {d} width {d} {d} {d} {d} {d}", .{
                contract.f32Bits(border.color.r),
                contract.f32Bits(border.color.g),
                contract.f32Bits(border.color.b),
                contract.f32Bits(border.color.a),
                contract.f32Bits(border.corner_radius.top_left),
                contract.f32Bits(border.corner_radius.top_right),
                contract.f32Bits(border.corner_radius.bottom_left),
                contract.f32Bits(border.corner_radius.bottom_right),
                border.width.left,
                border.width.right,
                border.width.top,
                border.width.bottom,
                border.width.between_children,
            });
        },
        .text => {
            const text = command.render_data.text;
            const contents = text.string_contents.asSlice();
            try out.print(" text {d} \"{s}\" rgba {d} {d} {d} {d} font {d} {d} spacing {d} line {d}", .{
                contents.len,
                contents,
                contract.f32Bits(text.text_color.r),
                contract.f32Bits(text.text_color.g),
                contract.f32Bits(text.text_color.b),
                contract.f32Bits(text.text_color.a),
                text.font_id,
                text.font_size,
                text.letter_spacing,
                text.line_height,
            });
        },
        .overlay_color_start => {
            const overlay = command.render_data.overlay_color.color;
            try out.print(" overlay {d} {d} {d} {d} control-default {d}", .{
                contract.f32Bits(overlay.r),
                contract.f32Bits(overlay.g),
                contract.f32Bits(overlay.b),
                contract.f32Bits(overlay.a),
                @intFromBool(boxIsZero(command.bounding_box) and command.z_index == 0),
            });
        },
        .overlay_color_end => try out.print(" control-default {d}", .{@intFromBool(boxIsZero(command.bounding_box) and command.z_index == 0)}),
        else => {},
    }
    try out.writeByte('\n');
}

fn printStatus(out: *std.Io.Writer, context: *const zlay.Context, frame: usize, name: []const u8) !void {
    const data = context.getElementData(context.id(name));
    try out.print("frame {d} status {s} found {d} box {d} {d} {d} {d}\n", .{
        frame,
        name,
        @intFromBool(data.found),
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
    });
}

fn pointerOverCenter(context: *zlay.Context, id: zlay.ElementId) !bool {
    const data = context.getElementData(id);
    if (!data.found) return false;
    try context.setPointerState(.{
        .x = data.bounding_box.x + data.bounding_box.width / 2,
        .y = data.bounding_box.y + data.bounding_box.height / 2,
    }, false);
    return context.pointerOver(id);
}

fn pointerOverAt(context: *zlay.Context, id: zlay.ElementId, x: f32, y: f32) !bool {
    try context.setPointerState(.{ .x = x, .y = y }, false);
    return context.pointerOver(id);
}

fn runFrame(context: *zlay.Context, out: *std.Io.Writer, frame: usize, delta_time: f32) !void {
    event_count = 0;
    if (frame == 3) context.setLayoutDimensions(.{ .width = 360, .height = 260 });

    try context.beginLayout();
    try declareLayout(context, frame);
    const commands = try context.endLayout(delta_time);
    const dimensions = context.getLayoutDimensions();

    try out.print("frame {d} summary viewport {d} {d} commands {d} events {d} setters {d} {d} parent-finals {d} {d} order-finals {d} {d} {d}\n", .{
        frame,
        contract.f32Bits(dimensions.width),
        contract.f32Bits(dimensions.height),
        commands.items().len,
        event_count,
        enter_skip_setters,
        enter_trigger_setters,
        parent_skip_finals,
        parent_trigger_finals,
        order_under_finals,
        order_natural_finals,
        order_above_finals,
    });

    for (events[0..event_count], 0..) |event, index| {
        try out.print("frame {d} event {d} tag {d} state {d} properties {d} elapsed {d} duration {d} ", .{
            frame,
            index,
            event.tag,
            @backingInt(event.state),
            @backingInt(event.properties),
            contract.f32Bits(event.elapsed),
            contract.f32Bits(event.duration),
        });
        try printTransitionData(out, event.current);
        try out.writeByte('\n');
    }

    inline for (.{
        "all-props",
        "zero-duration",
        "corner-noop",
        "resize-suppressed",
        "enter-skip",
        "enter-trigger",
        "move-block",
        "move-allow",
        "interaction-block",
        "interaction-allow",
        "parent-skip-child",
        "parent-trigger-child",
        "order-under-removed",
        "order-natural-removed",
        "order-above-removed",
    }) |name| try printStatus(out, context, frame, name);

    try out.print("frame {d} hit move-block-current {d} move-allow-current {d} move-block-target {d} move-allow-target {d} interaction-block {d} interaction-allow {d} parent-trigger-exit {d} natural-exit {d}\n", .{
        frame,
        @intFromBool(try pointerOverCenter(context, context.id("move-block"))),
        @intFromBool(try pointerOverCenter(context, context.id("move-allow"))),
        @intFromBool(try pointerOverAt(context, context.id("move-block"), if (frame == 0) 192 else 282, 55)),
        @intFromBool(try pointerOverAt(context, context.id("move-allow"), if (frame == 0) 192 else 282, 67)),
        @intFromBool(try pointerOverCenter(context, context.id("interaction-block"))),
        @intFromBool(try pointerOverCenter(context, context.id("interaction-allow"))),
        @intFromBool(try pointerOverCenter(context, context.id("parent-trigger-child"))),
        @intFromBool(try pointerOverCenter(context, context.id("order-natural-removed"))),
    });

    for (commands.items(), 0..) |command, index| try printCommand(out, frame, index, command);
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 420, .height = 260 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);

    var stdout_buffer: [128 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    for (0..7) |frame| try runFrame(&context, out, frame, 0.25);
    try out.flush();
}
