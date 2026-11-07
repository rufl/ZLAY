//! Pinned `clay.h` regressions for synthetic exit-transition trees.
//!
//! Exit transitions are unusual because an element omitted by the caller is
//! cloned back into the frame's layout tree until its callback completes.
//! These tests keep that behavior observable through the public command and
//! pointer APIs.

const std = @import("std");
const zlay = @import("zlay");
const types = zlay.types;

const red = types.Color{ .r = 255, .a = 255 };
const green = types.Color{ .g = 255, .a = 255 };
const blue = types.Color{ .b = 255, .a = 255 };

fn fixedBox(width: f32, height: f32, color: types.Color) types.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(width),
            .height = zlay.fixed(height),
        } },
        .background_color = color,
    };
}

fn expectBox(expected: types.BoundingBox, actual: types.BoundingBox) !void {
    try std.testing.expectEqual(expected.x, actual.x);
    try std.testing.expectEqual(expected.y, actual.y);
    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
}

fn rectangleBoxForId(commands: types.RenderCommandArray, element_id: types.ElementId) ?types.BoundingBox {
    for (commands.items()) |command| {
        if (command.command_type == .rectangle and command.id == element_id.id) return command.bounding_box;
    }
    return null;
}

fn hasRectangle(commands: types.RenderCommandArray, element_id: types.ElementId) bool {
    return rectangleBoxForId(commands, element_id) != null;
}

fn idFor(label: []const u8) types.ElementId {
    return zlay.hash.string(types.String.fromSlice(label), 0);
}

fn identityFinalState(current: types.TransitionData, _: types.TransitionProperty) types.TransitionData {
    return current;
}

fn neverComplete(_: types.TransitionCallbackArguments) bool {
    return false;
}

fn exitBox(
    width: f32,
    height: f32,
    color: types.Color,
    handler: types.TransitionHandler,
    set_final_state: types.TransitionSetFinalStateFunction,
    trigger: types.TransitionExitTriggerType,
    sibling_ordering: types.ExitTransitionSiblingOrdering,
    interaction_handling: types.TransitionInteractionHandlingType,
) types.ElementDeclaration {
    var declaration = fixedBox(width, height, color);
    declaration.transition = .{
        .handler = handler,
        .duration = 1,
        .properties = .background_color,
        .interaction_handling = interaction_handling,
        .exit = .{
            .set_final_state = set_final_state,
            .trigger = trigger,
            .sibling_ordering = sibling_ordering,
        },
    };
    return declaration;
}

const ExitProbe = struct {
    final_calls: usize = 0,
    exit_calls: usize = 0,
    complete_on_exit_call: usize = std.math.maxInt(usize),
    states: [8]types.TransitionState = @splat(.idle),
    elapsed: [8]f32 = @splat(0),
};

var exit_probe = ExitProbe{};

fn probedFinalState(current: types.TransitionData, _: types.TransitionProperty) types.TransitionData {
    exit_probe.final_calls += 1;
    var target = current;
    target.background_color = blue;
    return target;
}

fn probedExitHandler(arguments: types.TransitionCallbackArguments) bool {
    if (arguments.transition_state != .exiting) return false;
    const index = exit_probe.exit_calls;
    if (index < exit_probe.states.len) {
        exit_probe.states[index] = arguments.transition_state;
        exit_probe.elapsed[index] = arguments.elapsed_time;
    }
    exit_probe.exit_calls += 1;
    return exit_probe.exit_calls >= exit_probe.complete_on_exit_call;
}

test "removed subtree is retained until the exit callback completes" {
    exit_probe = .{ .complete_on_exit_call = 3 };
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 120, .height = 80 }, .{});
    defer context.deinit();
    const parent_id = context.id("exit-retained-parent");
    const child_id = context.id("exit-retained-child");

    try context.beginLayout();
    try context.openElementWithId(parent_id, exitBox(
        50,
        30,
        red,
        probedExitHandler,
        probedFinalState,
        .skip_when_parent_exits,
        .underneath_siblings,
        .disable_interactions_while_transitioning_position,
    ));
    try context.openElementWithId(child_id, fixedBox(20, 10, green));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0.25);

    try context.beginLayout();
    var commands = try context.endLayout(0.25);
    const retained_first = hasRectangle(commands, parent_id) and hasRectangle(commands, child_id);

    try context.beginLayout();
    commands = try context.endLayout(0.25);
    const retained_second = hasRectangle(commands, parent_id) and hasRectangle(commands, child_id);

    // clay.h removes the transition data before final command generation when
    // the callback reports completion, so the completed subtree is absent on
    // that same frame rather than receiving one last render.
    try context.beginLayout();
    commands = try context.endLayout(0.25);
    const parent_absent_on_completion = !hasRectangle(commands, parent_id);
    const child_absent_on_completion = !hasRectangle(commands, child_id);

    try context.beginLayout();
    commands = try context.endLayout(0.25);
    const remains_absent = !hasRectangle(commands, parent_id) and !hasRectangle(commands, child_id);

    try std.testing.expectEqual(@as(usize, 1), exit_probe.final_calls);
    try std.testing.expectEqual(@as(usize, 3), exit_probe.exit_calls);
    try std.testing.expectEqual(types.TransitionState.exiting, exit_probe.states[0]);
    try std.testing.expectEqual(types.TransitionState.exiting, exit_probe.states[1]);
    try std.testing.expectEqual(types.TransitionState.exiting, exit_probe.states[2]);
    try std.testing.expectEqual(@as(f32, 0), exit_probe.elapsed[0]);
    try std.testing.expectEqual(@as(f32, 0.25), exit_probe.elapsed[1]);
    try std.testing.expectEqual(@as(f32, 0.5), exit_probe.elapsed[2]);
    try std.testing.expect(retained_first);
    try std.testing.expect(retained_second);
    try std.testing.expect(parent_absent_on_completion);
    try std.testing.expect(child_absent_on_completion);
    try std.testing.expect(remains_absent);
}

test "exit transitions suppress interaction even when moving interactions are allowed" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 60 }, .{});
    defer context.deinit();
    const parent_id = context.id("exit-interaction-parent");
    const child_id = context.id("exit-interaction-child");
    const descendant_id = context.id("exit-interaction-descendant");

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(80, 40, .{}));
    try context.openElementWithId(child_id, exitBox(
        30,
        20,
        green,
        neverComplete,
        identityFinalState,
        .skip_when_parent_exits,
        .underneath_siblings,
        .allow_interactions_while_transitioning_position,
    ));
    try context.openElementWithId(descendant_id, fixedBox(10, 10, blue));
    try context.closeElement();
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(80, 40, .{}));
    try context.closeElement();
    const commands = try context.endLayout(0.1);
    const retained = hasRectangle(commands, child_id) and hasRectangle(commands, descendant_id);
    try context.setPointerState(.{ .x = 5, .y = 5 }, false);
    const exiting_child_was_hit = context.pointerOver(child_id);
    const exiting_descendant_was_hit = context.pointerOver(descendant_id);

    try std.testing.expect(retained);
    try std.testing.expect(!exiting_child_was_hit);
    try std.testing.expect(!exiting_descendant_was_hit);
}

const OrderingObservation = struct {
    ids: [3]u32 = @splat(0),
    x: [3]f32 = @splat(0),
    len: usize = 0,
};

fn observeSiblingOrdering(ordering: types.ExitTransitionSiblingOrdering) !OrderingObservation {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 120, .height = 40 }, .{});
    defer context.deinit();
    const parent_id = context.id("exit-order-parent");
    const first_id = context.id("exit-order-first");
    const exiting_id = context.id("exit-order-removed");
    const last_id = context.id("exit-order-last");

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(100, 20, .{}));
    try context.openElementWithId(first_id, fixedBox(10, 10, red));
    try context.closeElement();
    try context.openElementWithId(exiting_id, exitBox(
        10,
        10,
        green,
        neverComplete,
        identityFinalState,
        .skip_when_parent_exits,
        ordering,
        .disable_interactions_while_transitioning_position,
    ));
    try context.closeElement();
    try context.openElementWithId(last_id, fixedBox(10, 10, blue));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(100, 20, .{}));
    try context.openElementWithId(first_id, fixedBox(10, 10, red));
    try context.closeElement();
    try context.openElementWithId(last_id, fixedBox(10, 10, blue));
    try context.closeElement();
    try context.closeElement();
    const commands = try context.endLayout(0.1);

    var observation = OrderingObservation{};
    for (commands.items()) |command| {
        if (command.command_type != .rectangle) continue;
        if (command.id != first_id.id and command.id != exiting_id.id and command.id != last_id.id) continue;
        if (observation.len < observation.ids.len) {
            observation.ids[observation.len] = command.id;
            observation.x[observation.len] = command.bounding_box.x;
        }
        observation.len += 1;
    }
    return observation;
}

fn expectOrdering(
    observation: OrderingObservation,
    expected_ids: [3]u32,
    expected_x: [3]f32,
) !void {
    try std.testing.expectEqual(@as(usize, 3), observation.len);
    try std.testing.expectEqual(expected_ids, observation.ids);
    try std.testing.expectEqual(expected_x, observation.x);
}

test "underneath exit ordering inserts the synthetic child before siblings" {
    const observation = try observeSiblingOrdering(.underneath_siblings);
    try expectOrdering(
        observation,
        .{
            idFor("exit-order-removed").id,
            idFor("exit-order-first").id,
            idFor("exit-order-last").id,
        },
        .{ 0, 0, 10 },
    );
}

test "natural exit ordering restores the synthetic child at its former index" {
    const observation = try observeSiblingOrdering(.natural_order);
    try expectOrdering(
        observation,
        .{
            idFor("exit-order-first").id,
            idFor("exit-order-removed").id,
            idFor("exit-order-last").id,
        },
        .{ 0, 10, 10 },
    );
}

test "above exit ordering appends the synthetic child after siblings" {
    const observation = try observeSiblingOrdering(.above_siblings);
    try expectOrdering(
        observation,
        .{
            idFor("exit-order-first").id,
            idFor("exit-order-last").id,
            idFor("exit-order-removed").id,
        },
        .{ 0, 10, 20 },
    );
}

const ParentExitProbe = struct {
    final_calls: usize = 0,
    handler_calls: usize = 0,
};

var parent_exit_probe = ParentExitProbe{};

fn parentExitFinal(current: types.TransitionData, _: types.TransitionProperty) types.TransitionData {
    parent_exit_probe.final_calls += 1;
    return current;
}

fn parentExitHandler(arguments: types.TransitionCallbackArguments) bool {
    if (arguments.transition_state == .exiting) parent_exit_probe.handler_calls += 1;
    return false;
}

fn removeParentWithTransitioningChild(trigger: types.TransitionExitTriggerType) !?types.BoundingBox {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 80 }, .{});
    defer context.deinit();
    const parent_id = context.id("exit-trigger-parent");
    const child_id = context.id("exit-trigger-child");

    try context.beginLayout();
    try context.openElementWithId(parent_id, .{
        .layout = .{
            .sizing = .{
                .width = zlay.fixed(50),
                .height = zlay.fixed(40),
            },
            .padding = .{ .left = 7, .top = 9 },
        },
    });
    try context.openElementWithId(child_id, exitBox(
        10,
        10,
        green,
        parentExitHandler,
        parentExitFinal,
        trigger,
        .underneath_siblings,
        .disable_interactions_while_transitioning_position,
    ));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.beginLayout();
    const commands = try context.endLayout(0.1);
    return rectangleBoxForId(commands, child_id);
}

test "child exit transition is skipped when its parent disappears by default" {
    parent_exit_probe = .{};
    const child_box = try removeParentWithTransitioningChild(.skip_when_parent_exits);

    try std.testing.expectEqual(@as(usize, 0), parent_exit_probe.final_calls);
    try std.testing.expectEqual(@as(usize, 0), parent_exit_probe.handler_calls);
    try std.testing.expectEqual(@as(?types.BoundingBox, null), child_box);
}

test "child exit transition becomes a root when configured to trigger with parent exit" {
    parent_exit_probe = .{};
    const child_box = try removeParentWithTransitioningChild(.trigger_when_parent_exits);

    try std.testing.expectEqual(@as(usize, 1), parent_exit_probe.final_calls);
    try std.testing.expectEqual(@as(usize, 1), parent_exit_probe.handler_calls);
    try std.testing.expect(child_box != null);
    try expectBox(.{ .x = 7, .y = 9, .width = 10, .height = 10 }, child_box.?);
}

fn measureMonospace(
    text: types.StringSlice,
    config: *types.TextElementConfig,
    _: ?*anyopaque,
) types.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * @as(f32, @floatFromInt(config.font_size)),
        .height = @floatFromInt(config.font_size),
    };
}

test "text descendants are rewrapped and rendered with a retained exit subtree" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 140, .height = 60 }, .{});
    defer context.deinit();
    context.setMeasureTextFunction(measureMonospace, null);
    const parent_id = context.id("exit-text-parent");

    try context.beginLayout();
    try context.openElementWithId(parent_id, exitBox(
        100,
        20,
        red,
        neverComplete,
        identityFinalState,
        .skip_when_parent_exits,
        .underneath_siblings,
        .disable_interactions_while_transitioning_position,
    ));
    try context.textSlice("retained", .{
        .text_color = blue,
        .font_size = 8,
        .wrap_mode = .none,
    });
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.beginLayout();
    const commands = try context.endLayout(0.1);
    var retained_text = false;
    for (commands.items()) |command| {
        if (command.command_type != .text) continue;
        if (std.mem.eql(u8, command.render_data.text.string_contents.asSlice(), "retained")) {
            retained_text = true;
            break;
        }
    }

    try std.testing.expect(hasRectangle(commands, parent_id));
    try std.testing.expect(retained_text);
}

const TransitionOrderProbe = struct {
    events: [16]u8 = @splat(0),
    len: usize = 0,

    fn record(self: *TransitionOrderProbe, event: u8) void {
        self.events[self.len] = event;
        self.len += 1;
    }
};

var transition_order_probe = TransitionOrderProbe{};

fn recordTransitionA(arguments: types.TransitionCallbackArguments) bool {
    if (arguments.transition_state != .idle) transition_order_probe.record('A');
    return false;
}

fn recordTransitionB(arguments: types.TransitionCallbackArguments) bool {
    if (arguments.transition_state != .idle) transition_order_probe.record('B');
    return false;
}

fn recordTransitionC(arguments: types.TransitionCallbackArguments) bool {
    if (arguments.transition_state != .idle) transition_order_probe.record('C');
    return false;
}

fn completeExitA(arguments: types.TransitionCallbackArguments) bool {
    if (arguments.transition_state != .idle) transition_order_probe.record('A');
    return arguments.transition_state == .exiting;
}

fn trackedBox(color: types.Color, handler: types.TransitionHandler) types.ElementDeclaration {
    var declaration = fixedBox(10, 10, color);
    declaration.transition = .{
        .handler = handler,
        .duration = 1,
        .properties = .background_color,
    };
    return declaration;
}

fn drawTrackedChild(
    context: *zlay.Context,
    element_id: types.ElementId,
    color: types.Color,
    handler: types.TransitionHandler,
) !void {
    try context.openElementWithId(element_id, trackedBox(color, handler));
    try context.closeElement();
}

test "transition callbacks retain first-declaration order when current node order changes" {
    transition_order_probe = .{};
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 40 }, .{});
    defer context.deinit();
    const parent_id = context.id("transition-order-parent");
    const a_id = context.id("transition-order-a");
    const b_id = context.id("transition-order-b");
    const c_id = context.id("transition-order-c");

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(80, 20, .{}));
    try drawTrackedChild(&context, a_id, red, recordTransitionA);
    try drawTrackedChild(&context, b_id, red, recordTransitionB);
    try drawTrackedChild(&context, c_id, red, recordTransitionC);
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(80, 20, .{}));
    try drawTrackedChild(&context, c_id, blue, recordTransitionC);
    try drawTrackedChild(&context, b_id, blue, recordTransitionB);
    try drawTrackedChild(&context, a_id, blue, recordTransitionA);
    try context.closeElement();
    _ = try context.endLayout(0.1);

    try std.testing.expectEqualStrings("ABC", transition_order_probe.events[0..transition_order_probe.len]);
}

fn drawExitOrderChild(
    context: *zlay.Context,
    element_id: types.ElementId,
    handler: types.TransitionHandler,
) !void {
    try context.openElementWithId(element_id, exitBox(
        10,
        10,
        green,
        handler,
        identityFinalState,
        .skip_when_parent_exits,
        .underneath_siblings,
        .disable_interactions_while_transitioning_position,
    ));
    try context.closeElement();
}

test "completed exit swapback skips the swapped tail until the next frame" {
    transition_order_probe = .{};
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 40 }, .{});
    defer context.deinit();
    const parent_id = context.id("transition-swap-parent");
    const a_id = context.id("transition-swap-a");
    const b_id = context.id("transition-swap-b");
    const c_id = context.id("transition-swap-c");

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(80, 20, .{}));
    try drawExitOrderChild(&context, a_id, completeExitA);
    try drawExitOrderChild(&context, b_id, recordTransitionB);
    try drawExitOrderChild(&context, c_id, recordTransitionC);
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(80, 20, .{}));
    try context.closeElement();
    var commands = try context.endLayout(0.1);
    try std.testing.expectEqualStrings("AB", transition_order_probe.events[0..transition_order_probe.len]);
    try std.testing.expect(!hasRectangle(commands, a_id));
    try std.testing.expect(hasRectangle(commands, b_id));
    try std.testing.expect(hasRectangle(commands, c_id));

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(80, 20, .{}));
    try context.closeElement();
    commands = try context.endLayout(0.1);
    try std.testing.expectEqualStrings("ABCB", transition_order_probe.events[0..transition_order_probe.len]);
    try std.testing.expect(hasRectangle(commands, b_id));
    try std.testing.expect(hasRectangle(commands, c_id));
}

fn offsetEnteringPosition(target: types.TransitionData, _: types.TransitionProperty) types.TransitionData {
    var initial = target;
    initial.bounding_box.y -= 100;
    return initial;
}

fn enteringInteractionBox(
    color: types.Color,
    interaction_handling: types.TransitionInteractionHandlingType,
) types.ElementDeclaration {
    var declaration = fixedBox(20, 10, color);
    declaration.transition = .{
        .handler = neverComplete,
        .duration = 1,
        .properties = .position,
        .interaction_handling = interaction_handling,
        .enter = .{
            .set_initial_state = offsetEnteringPosition,
            .trigger = .trigger_on_first_parent_frame,
        },
    };
    return declaration;
}

test "pinned root-sticky transition suppression reaches later allow-policy siblings" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 60 }, .{});
    defer context.deinit();
    const parent_id = context.id("root-sticky-parent");
    const blocker_id = context.id("root-sticky-blocker");
    const allow_id = context.id("root-sticky-allow");

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(80, 30, .{}));
    try context.openElementWithId(blocker_id, enteringInteractionBox(
        red,
        .disable_interactions_while_transitioning_position,
    ));
    try context.closeElement();
    try context.openElementWithId(allow_id, enteringInteractionBox(
        blue,
        .allow_interactions_while_transitioning_position,
    ));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0.1);

    const allow_data = context.getElementData(allow_id);
    try std.testing.expect(allow_data.found);
    try context.setPointerState(.{
        .x = allow_data.bounding_box.x + allow_data.bounding_box.width / 2,
        .y = allow_data.bounding_box.y + allow_data.bounding_box.height / 2,
    }, false);
    try std.testing.expect(!context.pointerOver(allow_id));
}
