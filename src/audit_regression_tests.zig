//! Focused parity regressions derived from the pinned Clay `clay.h` audit.
//!
//! These tests intentionally exercise frame ordering and failure boundaries
//! that are easy to miss in broader end-to-end coverage.

const std = @import("std");
const zlay = @import("root.zig");
const types = zlay.types;

const red = types.Color{ .r = 255, .a = 255 };
const blue = types.Color{ .b = 255, .a = 255 };
const green = types.Color{ .g = 255, .a = 255 };

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

fn expectColor(expected: types.Color, actual: types.Color) !void {
    try std.testing.expectEqual(expected.r, actual.r);
    try std.testing.expectEqual(expected.g, actual.g);
    try std.testing.expectEqual(expected.b, actual.b);
    try std.testing.expectEqual(expected.a, actual.a);
}

fn rectangleColorForId(commands: types.RenderCommandArray, element_id: types.ElementId) !types.Color {
    for (commands.items()) |command| {
        if (command.command_type == .rectangle and command.id == element_id.id) {
            return command.render_data.rectangle.background_color;
        }
    }
    return error.ExpectedRectangleCommand;
}

test "floating roots inherit their attached parent's clip with balanced scissors" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 200 }, .{});
    defer context.deinit();

    const clip_id = context.id("audit-floating-clip");
    const floating_id = context.id("audit-floating-clipped-child");

    try context.beginLayout();
    try context.openElementWithId(clip_id, .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(100),
            .height = zlay.fixed(80),
        } },
        .clip = .{ .horizontal = true, .vertical = true },
    });
    var floating = fixedBox(20, 20, green);
    floating.floating = .{
        .z_index = 7,
        .attach_to = .parent,
        .clip_to = .attached_parent,
    };
    try context.openElementWithId(floating_id, floating);
    try context.closeElement();
    try context.closeElement();
    const commands = try context.endLayout(0);

    const expected_types = [_]types.RenderCommandType{
        .scissor_start,
        .scissor_end,
        .scissor_start,
        .rectangle,
        .scissor_end,
    };
    try std.testing.expectEqual(expected_types.len, commands.items().len);

    var depth: usize = 0;
    var starts: usize = 0;
    var ends: usize = 0;
    var floating_rendered_inside_clip = false;
    var first_clip_box: ?types.BoundingBox = null;
    for (commands.items(), expected_types) |command, expected_type| {
        try std.testing.expectEqual(expected_type, command.command_type);
        switch (command.command_type) {
            .scissor_start => {
                if (first_clip_box == null) {
                    first_clip_box = command.bounding_box;
                } else {
                    try expectBox(first_clip_box.?, command.bounding_box);
                }
                starts += 1;
                depth += 1;
            },
            .scissor_end => {
                try std.testing.expect(depth > 0);
                depth -= 1;
                ends += 1;
            },
            .rectangle => {
                if (command.id == floating_id.id) floating_rendered_inside_clip = depth > 0;
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 2), starts);
    try std.testing.expectEqual(starts, ends);
    try std.testing.expectEqual(@as(usize, 0), depth);
    try std.testing.expect(floating_rendered_inside_clip);
    try expectBox(.{ .width = 100, .height = 80 }, first_clip_box.?);
}

fn drawNegativeZAttachedClipFrame(
    context: *zlay.Context,
    parent_id: types.ElementId,
    child_id: types.ElementId,
) !types.RenderCommandArray {
    try context.beginLayout();
    var parent = clippedBox(40, 40, true, true);
    parent.background_color = red;
    parent.floating = .{
        .offset = .{ .x = 50 },
        .attach_to = .root,
    };
    try context.openElementWithId(parent_id, parent);

    var child = fixedBox(10, 10, green);
    child.floating = .{
        .offset = .{ .x = 5 },
        .z_index = -1,
        .attach_to = .parent,
        .clip_to = .attached_parent,
    };
    try context.openElementWithId(child_id, child);
    try context.closeElement();
    try context.closeElement();
    return context.endLayout(0);
}

test "negative-z attached roots retain exact prior parent and clip bounds" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 100 }, .{});
    defer context.deinit();
    const parent_id = context.staticId("audit-negative-z-parent");
    const child_id = context.staticId("audit-negative-z-child");

    _ = try drawNegativeZAttachedClipFrame(&context, parent_id, child_id);
    const commands = try drawNegativeZAttachedClipFrame(&context, parent_id, child_id);
    var child_box: ?types.BoundingBox = null;
    var inherited_clip_box: ?types.BoundingBox = null;
    for (commands.items()) |command| {
        if (command.command_type == .rectangle and command.id == child_id.id) {
            child_box = command.bounding_box;
        }
        if (command.command_type == .scissor_start and command.z_index == -1) {
            inherited_clip_box = command.bounding_box;
        }
    }

    try expectBox(
        .{ .x = 55, .width = 10, .height = 10 },
        child_box orelse return error.MissingChildCommand,
    );
    try expectBox(
        .{ .x = 50, .width = 40, .height = 40 },
        inherited_clip_box orelse return error.MissingClipCommand,
    );
}

test "a current-generation zero bounding box wins over persistent fallback data" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 100 }, .{});
    defer context.deinit();

    const spacer_id = context.id("audit-zero-box-spacer");
    const target_id = context.id("audit-zero-box-target");
    const floating_id = context.id("audit-zero-box-floating");

    try context.beginLayout();
    try context.openElementWithId(spacer_id, fixedBox(80, 20, .{}));
    try context.closeElement();
    try context.openElementWithId(target_id, fixedBox(20, 20, .{}));
    try context.closeElement();
    _ = try context.endLayout(0);
    try std.testing.expectEqual(@as(f32, 80), context.getElementData(target_id).bounding_box.x);

    try context.beginLayout();
    try context.openElementWithId(target_id, fixedBox(0, 0, .{}));
    try context.closeElement();
    var floating = fixedBox(10, 10, green);
    floating.floating = .{
        .parent_id = target_id.id,
        .z_index = 4,
        .attach_to = .element_with_id,
    };
    try context.openElementWithId(floating_id, floating);
    try context.closeElement();
    _ = try context.endLayout(0);

    const current_target = context.getElementData(target_id);
    try std.testing.expect(current_target.found);
    try expectBox(.{}, current_target.bounding_box);
    const attached = context.getElementData(floating_id);
    try std.testing.expect(attached.found);
    try expectBox(.{ .width = 10, .height = 10 }, attached.bounding_box);
}

const EnterProbe = struct {
    initial_calls: usize = 0,
    handler_calls: usize = 0,
    elapsed: [4]f32 = .{ 0, 0, 0, 0 },
};

var enter_probe = EnterProbe{};

fn setRedInitialState(target: types.TransitionData, _: types.TransitionProperty) types.TransitionData {
    enter_probe.initial_calls += 1;
    var initial = target;
    initial.background_color = red;
    return initial;
}

fn recordNonCompletingTransition(arguments: types.TransitionCallbackArguments) bool {
    if (enter_probe.handler_calls < enter_probe.elapsed.len) {
        enter_probe.elapsed[enter_probe.handler_calls] = arguments.elapsed_time;
    }
    enter_probe.handler_calls += 1;
    return false;
}

fn enteringDeclaration() types.ElementDeclaration {
    var declaration = fixedBox(20, 20, blue);
    declaration.transition = .{
        .handler = recordNonCompletingTransition,
        .duration = 1,
        .properties = .background_color,
        .enter = .{
            .set_initial_state = setRedInitialState,
            .trigger = .trigger_on_first_parent_frame,
        },
    };
    return declaration;
}

fn drawEnteringFrame(context: *zlay.Context, element_id: types.ElementId, delta_time: f32) !types.Color {
    try context.beginLayout();
    try context.openElementWithId(element_id, enteringDeclaration());
    try context.closeElement();
    const commands = try context.endLayout(delta_time);
    return rectangleColorForId(commands, element_id);
}

test "enter transition first frame applies initial state without callback or elapsed advancement" {
    enter_probe = .{};
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const element_id = context.id("audit-transition-enter");

    const first_color = try drawEnteringFrame(&context, element_id, 0.25);
    const calls_after_first_frame = enter_probe.handler_calls;
    const second_color = try drawEnteringFrame(&context, element_id, 0.25);

    try expectColor(red, first_color);
    try expectColor(red, second_color);
    try std.testing.expectEqual(@as(usize, 1), enter_probe.initial_calls);
    try std.testing.expectEqual(@as(usize, 0), calls_after_first_frame);
    try std.testing.expectEqual(@as(usize, 1), enter_probe.handler_calls);
    try std.testing.expectEqual(@as(f32, 0), enter_probe.elapsed[0]);
}

var completion_handler_calls: usize = 0;

fn completeWithGreen(arguments: types.TransitionCallbackArguments) bool {
    completion_handler_calls += 1;
    arguments.current.background_color = green;
    return true;
}

fn drawCompletingFrame(
    context: *zlay.Context,
    element_id: types.ElementId,
    color: types.Color,
) !types.Color {
    var declaration = fixedBox(20, 20, color);
    declaration.transition = .{
        .handler = completeWithGreen,
        .duration = 1,
        .properties = .background_color,
    };
    try context.beginLayout();
    try context.openElementWithId(element_id, declaration);
    try context.closeElement();
    const commands = try context.endLayout(0.25);
    return rectangleColorForId(commands, element_id);
}

test "completion renders handler-mutated current once before normalizing runtime state" {
    completion_handler_calls = 0;
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const element_id = context.id("audit-transition-completion");

    const initial_color = try drawCompletingFrame(&context, element_id, red);
    const completion_color = try drawCompletingFrame(&context, element_id, blue);
    const normalized_color = try drawCompletingFrame(&context, element_id, blue);

    try expectColor(red, initial_color);
    try expectColor(green, completion_color);
    try expectColor(blue, normalized_color);
    try std.testing.expectEqual(@as(usize, 1), completion_handler_calls);
}

fn offsetInitialPosition(target: types.TransitionData, _: types.TransitionProperty) types.TransitionData {
    var initial = target;
    initial.bounding_box.x += 10;
    return initial;
}

fn keepTransitionActive(_: types.TransitionCallbackArguments) bool {
    return false;
}

test "entering position transitions suppress interaction hit records" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const element_id = context.id("audit-transition-interactions");

    var declaration = fixedBox(40, 40, green);
    declaration.transition = .{
        .handler = keepTransitionActive,
        .duration = 1,
        .properties = .position,
        .interaction_handling = .disable_interactions_while_transitioning_position,
        .enter = .{
            .set_initial_state = offsetInitialPosition,
            .trigger = .trigger_on_first_parent_frame,
        },
    };
    try context.beginLayout();
    try context.openElementWithId(element_id, declaration);
    try context.closeElement();
    _ = try context.endLayout(0.1);

    try context.setPointerState(.{ .x = 15, .y = 10 }, false);
    try std.testing.expect(!context.pointerOver(element_id));
}

test "odd gaps and odd between-child widths truncate before coordinate arithmetic" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const row_id = context.id("audit-odd-between-border");
    const first_id = context.id("audit-odd-between-first");
    const second_id = context.id("audit-odd-between-second");
    const border_color = types.Color{ .r = 25, .g = 50, .b = 75, .a = 255 };

    try context.beginLayout();
    try context.openElementWithId(row_id, .{
        .layout = .{
            .sizing = .{
                .width = zlay.fixed(40),
                .height = zlay.fixed(20),
            },
            .padding = .{ .left = 3 },
            .child_gap = 5,
            .layout_direction = .left_to_right,
        },
        .border = .{
            .color = border_color,
            .width = .{ .between_children = 3 },
        },
    });
    try context.openElementWithId(first_id, fixedBox(10, 10, .{}));
    try context.closeElement();
    try context.openElementWithId(second_id, fixedBox(10, 10, .{}));
    try context.closeElement();
    try context.closeElement();
    const commands = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 2), commands.items().len);
    try std.testing.expectEqual(types.RenderCommandType.border, commands.items()[0].command_type);
    try std.testing.expectEqual(types.RenderCommandType.rectangle, commands.items()[1].command_type);
    // clay.h evaluates both integer `/ 2` expressions before assigning them
    // to floats: 5 / 2 == 2 and 3 / 2 == 1, yielding x = 15 here.
    try expectBox(.{ .x = 15, .width = 3, .height = 20 }, commands.items()[1].bounding_box);
    try expectColor(border_color, commands.items()[1].render_data.rectangle.background_color);
}

fn failNextAllocation(failing: *std.testing.FailingAllocator) void {
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
}

fn allowAllocations(failing: *std.testing.FailingAllocator) void {
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
}

const TextAllocationProbe = struct {
    calls: usize = 0,
};

const DeclarationDiagnosticProbe = struct {
    calls: usize = 0,
};

fn countDeclarationDiagnostic(error_data: types.ErrorData) void {
    const probe: *DeclarationDiagnosticProbe = @ptrCast(@alignCast(error_data.user_data.?));
    probe.calls += 1;
}

fn invalidDiagnosticDeclaration() types.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.percent(2),
            .height = zlay.fixed(10),
        } },
        .floating = .{
            .parent_id = 0xf00dbaad,
            .attach_to = .element_with_id,
        },
    };
}

fn countTextAllocationMeasurement(
    value: types.StringSlice,
    _: *types.TextElementConfig,
    user_data: ?*anyopaque,
) types.Dimensions {
    const probe: *TextAllocationProbe = @ptrCast(@alignCast(user_data.?));
    probe.calls += 1;
    return .{
        .width = @floatFromInt(value.asSlice().len),
        .height = 1,
    };
}

test "beginLayout OOM leaves the layout closed and permits retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    try std.testing.expectError(error.OutOfMemory, context.beginLayout());
    try std.testing.expect(!context.layout_open);
    try std.testing.expectEqual(@as(usize, 0), context.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), context.open_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), context.roots.items.len);

    allowAllocations(&failing);
    try context.beginLayout();
    _ = try context.endLayout(0);
    try std.testing.expect(!context.layout_open);
}

test "openElement OOM preserves hierarchy and permits the same declaration retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    try context.beginLayout();

    try context.open_stack.shrinkAndFreePrecise(context.allocator, context.open_stack.items.len);
    const element_id = context.id("audit-open-oom-retry");
    const nodes_before = context.nodes.items.len;
    const stack_before = context.open_stack.items.len;
    const roots_before = context.roots.items.len;
    const ids_before = context.id_to_index.count();
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.openElementWithId(element_id, fixedBox(10, 10, green)));
    try std.testing.expectEqual(nodes_before, context.nodes.items.len);
    try std.testing.expectEqual(stack_before, context.open_stack.items.len);
    try std.testing.expectEqual(roots_before, context.roots.items.len);
    try std.testing.expectEqual(ids_before, context.id_to_index.count());
    try std.testing.expect(!context.id_to_index.contains(element_id.id));

    allowAllocations(&failing);
    try context.openElementWithId(element_id, fixedBox(10, 10, green));
    try context.closeElement();
    _ = try context.endLayout(0);
    try std.testing.expect(context.getElementData(element_id).found);
}

test "new transition registration OOM precedes declaration mutation and permits retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    try context.beginLayout();

    try context.nodes.ensureTotalCapacity(context.allocator, context.nodes.items.len + 1);
    try context.id_to_index.ensureUnusedCapacity(1);
    try context.open_stack.ensureTotalCapacity(context.allocator, context.open_stack.items.len + 1);
    const element_id = context.id("audit-transition-register-oom-retry");
    var declaration = fixedBox(10, 10, green);
    declaration.transition = .{
        .handler = keepTransitionActive,
        .properties = .background_color,
    };
    const nodes_before = context.nodes.items.len;
    const stack_before = context.open_stack.items.len;
    const roots_before = context.roots.items.len;
    const ids_before = context.id_to_index.count();
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.openElementWithId(element_id, declaration));
    try std.testing.expectEqual(nodes_before, context.nodes.items.len);
    try std.testing.expectEqual(stack_before, context.open_stack.items.len);
    try std.testing.expectEqual(roots_before, context.roots.items.len);
    try std.testing.expectEqual(ids_before, context.id_to_index.count());
    try std.testing.expectEqual(@as(usize, 0), context.transition_order.items.len);
    try std.testing.expectEqual(@as(u32, 0), context.transition_states.count());

    allowAllocations(&failing);
    try context.openElementWithId(element_id, declaration);
    try context.closeElement();
    _ = try context.endLayout(0);
    try std.testing.expect(context.getElementData(element_id).found);
}

test "declaration OOM emits no percentage or missing-parent diagnostics" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var diagnostic_probe = DeclarationDiagnosticProbe{};
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{
        .error_handler = .{
            .error_handler_function = countDeclarationDiagnostic,
            .user_data = &diagnostic_probe,
        },
    });
    defer context.deinit();
    try context.beginLayout();

    try context.nodes.ensureTotalCapacity(context.allocator, context.nodes.items.len + 1);
    try context.id_to_index.ensureUnusedCapacity(1);
    try context.open_stack.ensureTotalCapacity(context.allocator, context.open_stack.items.len + 1);
    try context.roots.shrinkAndFreePrecise(context.allocator, context.roots.items.len);
    const combined_id = context.staticId("audit-diagnostic-combined-oom");
    failNextAllocation(&failing);

    try std.testing.expectError(
        error.OutOfMemory,
        context.openElementWithId(combined_id, invalidDiagnosticDeclaration()),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostic_probe.calls);
    try std.testing.expect(!context.id_to_index.contains(combined_id.id));

    allowAllocations(&failing);
    try context.openElementWithId(combined_id, invalidDiagnosticDeclaration());
    try std.testing.expectEqual(@as(usize, 2), diagnostic_probe.calls);
    try context.closeElement();

    const split_id = context.staticId("audit-diagnostic-split-oom");
    try context.openElementWithIdUnconfigured(split_id);
    const split_index = context.open_stack.items[context.open_stack.items.len - 1].node_index;
    try context.roots.shrinkAndFreePrecise(context.allocator, context.roots.items.len);
    failNextAllocation(&failing);

    try std.testing.expectError(
        error.OutOfMemory,
        context.configureOpenElement(invalidDiagnosticDeclaration()),
    );
    try std.testing.expectEqual(@as(usize, 2), diagnostic_probe.calls);
    try std.testing.expect(!context.nodes.items[split_index].configured);

    allowAllocations(&failing);
    try context.configureOpenElement(invalidDiagnosticDeclaration());
    try std.testing.expectEqual(@as(usize, 4), diagnostic_probe.calls);
    try context.closeElement();
    _ = try context.endLayout(0);
}

test "text OOM preserves parent counters and permits retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    try context.beginLayout();

    var measure_probe = TextAllocationProbe{};
    context.setMeasureTextFunction(countTextAllocationMeasurement, &measure_probe);
    try context.text_cache.ensureFreeCapacity(1, 1);

    try context.texts.ensureTotalCapacity(context.allocator, 1);
    const nodes_before = context.nodes.items.len;
    const texts_before = context.texts.items.len;
    const children_before = context.nodes.items[0].children_len;
    const child_buffer_before = context.child_buffer.items.len;
    const ids_before = context.id_to_index.count();
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.textSlice("x", .{}));
    try std.testing.expectEqual(nodes_before, context.nodes.items.len);
    try std.testing.expectEqual(texts_before, context.texts.items.len);
    try std.testing.expectEqual(children_before, context.nodes.items[0].children_len);
    try std.testing.expectEqual(child_buffer_before, context.child_buffer.items.len);
    try std.testing.expectEqual(ids_before, context.id_to_index.count());
    try std.testing.expectEqual(@as(usize, 0), measure_probe.calls);

    allowAllocations(&failing);
    try context.textSlice("x", .{});
    try std.testing.expect(measure_probe.calls > 0);
    _ = try context.endLayout(0);
    try std.testing.expect(!context.layout_open);
}

test "closeElement OOM leaves the element open and permits close retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    try context.beginLayout();

    try context.openElement(.{});
    try context.closeElement();
    while (context.child_buffer.items.len < context.child_buffer.capacity) {
        try context.openElement(.{});
        try context.closeElement();
    }

    const target_id = context.id("audit-close-oom-retry");
    try context.openElementWithId(target_id, fixedBox(10, 10, green));
    const stack_before = context.open_stack.items.len;
    const children_before = context.nodes.items[0].children_len;
    const child_buffer_before = context.child_buffer.items.len;
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.closeElement());
    try std.testing.expectEqual(stack_before, context.open_stack.items.len);
    try std.testing.expectEqual(children_before, context.nodes.items[0].children_len);
    try std.testing.expectEqual(child_buffer_before, context.child_buffer.items.len);
    try std.testing.expectEqual(target_id.id, try context.getOpenElementId());

    allowAllocations(&failing);
    try context.closeElement();
    _ = try context.endLayout(0);
    try std.testing.expect(context.getElementData(target_id).found);
}

test "render capacity exhaustion cannot return unbalanced scissor or overlay scopes" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = 8,
        .max_render_command_count = 2,
    });
    defer context.deinit();

    try context.beginLayout();
    try context.openElement(.{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(10),
            .height = zlay.fixed(10),
        } },
        .clip = .{ .horizontal = true, .vertical = true },
    });
    try context.closeElement();
    try std.testing.expectError(error.RenderCommandCapacityExceeded, context.endLayout(0));
    try std.testing.expect(!context.layout_open);

    // A capacity-invalid frame is closed and the same context remains usable.
    try context.beginLayout();
    const commands = try context.endLayout(0);
    try std.testing.expectEqual(@as(i32, 0), commands.length);

    try context.beginLayout();
    try context.openElement(.{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(10),
            .height = zlay.fixed(10),
        } },
        .overlay_color = red,
    });
    try context.closeElement();
    try std.testing.expectError(error.RenderCommandCapacityExceeded, context.endLayout(0));
    try std.testing.expect(!context.layout_open);

    try context.beginLayout();
    _ = try context.endLayout(0);
}

fn failScopedBody(_: *zlay.Context) error{BodyFailed}!void {
    return error.BodyFailed;
}

fn replaceScopedElement(context: *zlay.Context) !void {
    try context.closeElement();
    try context.openElement(.{});
}

fn replaceScopedElementFactory(context: *zlay.Context) !types.ElementDeclaration {
    try replaceScopedElement(context);
    return .{};
}

fn closeScopedElementAndAncestor(context: *zlay.Context) !void {
    try context.closeElement();
    try context.closeElement();
}

fn replaceScopedElementAndAncestorAtSameDepth(context: *zlay.Context) !void {
    try context.closeElement();
    try context.closeElement();
    try context.openElement(.{});
    try context.openElement(.{});
}

fn emptyScopedBody(_: *zlay.Context) !void {}

fn emptyScopedFactory(_: *zlay.Context) !types.ElementDeclaration {
    return .{};
}

test "scoped helpers reject a same-depth replacement instead of closing the wrong node" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    try context.beginLayout();

    try std.testing.expectError(
        error.ScopedElementUnbalanced,
        context.element(.{}, replaceScopedElement),
    );
    try std.testing.expectEqual(@as(usize, 1), context.open_stack.items.len);

    try std.testing.expectError(
        error.ScopedElementUnbalanced,
        context.elementWithId(context.staticId("audit-scoped-replaced-explicit"), .{}, replaceScopedElement),
    );
    try std.testing.expectEqual(@as(usize, 1), context.open_stack.items.len);

    try std.testing.expectError(
        error.ScopedElementUnbalanced,
        context.elementDeferred(replaceScopedElementFactory, emptyScopedBody),
    );
    try std.testing.expectEqual(@as(usize, 1), context.open_stack.items.len);

    try std.testing.expectError(
        error.ScopedElementUnbalanced,
        context.elementWithIdDeferred(
            context.staticId("audit-scoped-replaced-deferred-explicit"),
            replaceScopedElementFactory,
            emptyScopedBody,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), context.open_stack.items.len);

    // Deferred helpers also validate the identity after their body, not only
    // after the declaration factory.
    try std.testing.expectError(
        error.ScopedElementUnbalanced,
        context.elementDeferred(emptyScopedFactory, replaceScopedElement),
    );
    try std.testing.expectEqual(@as(usize, 1), context.open_stack.items.len);

    _ = try context.endLayout(0);
}

test "scoped ancestor underflow aborts the frame and permits a clean retry" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    try context.beginLayout();
    try context.openElementWithId(context.staticId("audit-scoped-underflow-parent"), .{});

    try std.testing.expectError(
        error.ScopedElementUnbalanced,
        context.element(.{}, closeScopedElementAndAncestor),
    );
    try std.testing.expect(!context.layout_open);
    try std.testing.expectEqual(@as(usize, 0), context.open_stack.items.len);

    try context.beginLayout();
    _ = try context.endLayout(0);
}

test "scoped ancestor replacement at the same depth aborts the frame" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    try context.beginLayout();
    try context.openElementWithId(context.staticId("audit-scoped-replaced-parent"), .{});

    try std.testing.expectError(
        error.ScopedElementUnbalanced,
        context.element(.{}, replaceScopedElementAndAncestorAtSameDepth),
    );
    try std.testing.expect(!context.layout_open);
    try std.testing.expectEqual(@as(usize, 0), context.open_stack.items.len);

    try context.beginLayout();
    _ = try context.endLayout(0);
}

test "scoped cleanup OOM aborts the frame instead of hiding a stale open element" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    try context.beginLayout();

    try context.nodes.ensureTotalCapacity(context.allocator, context.nodes.items.len + 1);
    try context.id_to_index.ensureUnusedCapacity(1);
    try context.open_stack.ensureTotalCapacity(context.allocator, context.open_stack.items.len + 1);
    try context.child_buffer.shrinkAndFreePrecise(context.allocator, 0);
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.element(.{}, failScopedBody));
    try std.testing.expect(!context.layout_open);
    try std.testing.expectEqual(@as(usize, 0), context.open_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), context.transition_order.items.len);
    try std.testing.expectEqual(@as(u32, 0), context.transition_states.count());
    try std.testing.expectEqual(@as(usize, 0), context.scroll_containers.items.len);

    allowAllocations(&failing);
    try context.beginLayout();
    _ = try context.endLayout(0);
}

test "duplicate debug bookkeeping OOM precedes combined declaration mutation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    context.setDebugModeEnabled(true);
    try context.beginLayout();

    const duplicate_id = context.staticId("audit-debug-duplicate-combined");
    try context.openElementWithId(duplicate_id, .{});
    try context.closeElement();
    try context.nodes.ensureTotalCapacity(context.allocator, context.nodes.items.len + 1);
    try context.id_to_index.ensureUnusedCapacity(1);
    try context.open_stack.ensureTotalCapacity(context.allocator, context.open_stack.items.len + 1);
    try context.debug_collision_ids.shrinkAndFreePrecise(context.allocator, 0);
    const nodes_before = context.nodes.items.len;
    const stack_before = context.open_stack.items.len;
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.openElementWithId(duplicate_id, .{}));
    try std.testing.expectEqual(nodes_before, context.nodes.items.len);
    try std.testing.expectEqual(stack_before, context.open_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), context.debug_collision_ids.items.len);

    allowAllocations(&failing);
    try context.openElementWithId(duplicate_id, .{});
    try context.closeElement();
    _ = try context.endLayout(0);
}

test "duplicate debug bookkeeping OOM precedes split and text declaration mutation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    context.setDebugModeEnabled(true);
    try context.beginLayout();

    const split_id = context.staticId("audit-debug-duplicate-split");
    try context.openElementWithId(split_id, .{});
    try context.closeElement();
    try context.nodes.ensureTotalCapacity(context.allocator, context.nodes.items.len + 2);
    try context.id_to_index.ensureUnusedCapacity(2);
    try context.open_stack.ensureTotalCapacity(context.allocator, context.open_stack.items.len + 1);
    try context.texts.ensureTotalCapacity(context.allocator, context.texts.items.len + 1);
    try context.child_buffer.ensureTotalCapacity(context.allocator, context.child_buffer.items.len + 1);
    try context.debug_collision_ids.shrinkAndFreePrecise(context.allocator, 0);
    const nodes_before_split = context.nodes.items.len;
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.openElementWithIdUnconfigured(split_id));
    try std.testing.expectEqual(nodes_before_split, context.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), context.open_stack.items.len);

    allowAllocations(&failing);
    const text_id = zlay.hash.number(2, context.nodes.items[0].element_id.id);
    try context.openElementWithId(text_id, .{});
    try context.closeElement();
    try context.debug_collision_ids.shrinkAndFreePrecise(context.allocator, 0);
    const nodes_before_text = context.nodes.items.len;
    const texts_before = context.texts.items.len;
    const children_before = context.nodes.items[0].children_len;
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.textSlice("duplicate", .{}));
    try std.testing.expectEqual(nodes_before_text, context.nodes.items.len);
    try std.testing.expectEqual(texts_before, context.texts.items.len);
    try std.testing.expectEqual(children_before, context.nodes.items[0].children_len);
    try std.testing.expectEqual(@as(usize, 0), context.debug_collision_ids.items.len);

    allowAllocations(&failing);
    _ = try context.endLayout(0);
}

test "public capacity options clamp to signed array metadata range" {
    const maximum: usize = @intCast(std.math.maxInt(i32));
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = std.math.maxInt(usize),
        .max_render_command_count = std.math.maxInt(usize),
    });
    defer context.deinit();

    try std.testing.expectEqual(maximum, context.getMaxElementCount());
    try std.testing.expectEqual(std.math.maxInt(i32), context.getPointerOverIds().capacity);
    context.setMaxElementCount(std.math.maxInt(usize));
    try std.testing.expectEqual(maximum, context.getMaxElementCount());

    try context.beginLayout();
    const commands = try context.endLayout(0);
    try std.testing.expectEqual(std.math.maxInt(i32), commands.capacity);
}

test "render-capacity rejection preserves committed hit testing and hides the partial command stream" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = 8,
        .max_render_command_count = 2,
    });
    defer context.deinit();

    const committed_id = context.staticId("audit-committed-hit-target");
    try context.beginLayout();
    try context.openElementWithId(committed_id, fixedBox(20, 20, green));
    try context.closeElement();
    _ = try context.endLayout(0);

    const rejected_id = context.staticId("audit-rejected-hit-target");
    try context.beginLayout();
    try context.openElementWithId(rejected_id, .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(20),
            .height = zlay.fixed(20),
        } },
        .clip = .{ .horizontal = true, .vertical = true },
    });
    try context.closeElement();
    try std.testing.expectError(error.RenderCommandCapacityExceeded, context.endLayout(0));

    try std.testing.expect(context.renderCommand(0) == null);
    try context.setPointerState(.{ .x = 5, .y = 5 }, false);
    try std.testing.expect(context.pointerOver(committed_id));
    try std.testing.expect(!context.pointerOver(rejected_id));
}

var pointer_oom_hover_calls: usize = 0;

fn recordPointerOomHover(_: types.ElementId, _: types.PointerData, _: ?*anyopaque) void {
    pointer_oom_hover_calls += 1;
}

test "setPointerState OOM leaves pointer state hit data and callbacks untouched" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    const child_id = context.staticId("audit-pointer-oom-child");
    try context.beginLayout();
    try context.openElementWithId(child_id, fixedBox(20, 20, green));
    try context.onHover(recordPointerOomHover, null);
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.setPointerState(.{ .x = -1, .y = -1 }, false);
    try context.setPointerState(.{ .x = -1, .y = -1 }, false);
    try context.pointer_over_ids.shrinkAndFreePrecise(context.allocator, 0);
    const pointer_before = context.getPointerState();
    pointer_oom_hover_calls = 0;
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.setPointerState(.{ .x = 5, .y = 5 }, true));
    try std.testing.expectEqual(pointer_before, context.getPointerState());
    try std.testing.expectEqual(@as(i32, 0), context.getPointerOverIds().length);
    try std.testing.expectEqual(@as(usize, 0), pointer_oom_hover_calls);

    allowAllocations(&failing);
    try context.setPointerState(.{ .x = 5, .y = 5 }, true);
    try std.testing.expect(context.pointerOver(child_id));
    try std.testing.expectEqual(@as(usize, 1), pointer_oom_hover_calls);
    try std.testing.expectEqual(types.PointerDataInteractionState.pressed_this_frame, context.getPointerState().state);
}

test "lowering the element ceiling preserves valid persistent pointer array metadata" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = 8,
    });
    defer context.deinit();

    try context.beginLayout();
    try context.openElementWithId(context.staticId("audit-pointer-capacity-child"), fixedBox(20, 20, green));
    try context.closeElement();
    _ = try context.endLayout(0);
    try context.setPointerState(.{ .x = 5, .y = 5 }, false);

    context.setMaxElementCount(1);
    const pointer_over = context.getPointerOverIds();
    try std.testing.expectEqual(@as(i32, 8), pointer_over.capacity);
    try std.testing.expectEqual(@as(i32, 2), pointer_over.length);
    try std.testing.expect(pointer_over.capacity >= pointer_over.length);
}

fn identityExitFinalState(current: types.TransitionData, _: types.TransitionProperty) types.TransitionData {
    return current;
}

var late_transition_handler_calls: usize = 0;

fn countLateTransition(_: types.TransitionCallbackArguments) bool {
    late_transition_handler_calls += 1;
    return false;
}

fn retainedExitBox(color: types.Color) types.ElementDeclaration {
    var declaration = fixedBox(20, 20, color);
    declaration.transition = .{
        .handler = countLateTransition,
        .duration = 1,
        .properties = .background_color,
        .exit = .{ .set_final_state = identityExitFinalState },
    };
    return declaration;
}

fn preflightEndLayoutScratch(context: *zlay.Context) !void {
    const count = context.nodes.items.len;
    try context.child_indices.ensureTotalCapacity(
        context.allocator,
        context.child_indices.items.len + context.child_buffer.items.len,
    );
    try context.layout_bfs.ensureTotalCapacity(context.allocator, count);
    try context.layout_resizable.ensureTotalCapacity(context.allocator, count);
    try context.layout_aspect_ratios.ensureTotalCapacity(context.allocator, count);
    try context.render_stack.ensureTotalCapacity(context.allocator, count);
    try context.pending_hit_records.ensureTotalCapacity(context.allocator, count * 2);
    try context.render_commands.ensureTotalCapacity(context.allocator, count * 2);
}

test "late endLayout OOM preserves the previous exit-transition snapshot" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    const retained_id = context.staticId("audit-retained-before-oom");
    try context.beginLayout();
    try context.openElementWithId(retained_id, retainedExitBox(red));
    try context.closeElement();
    _ = try context.endLayout(0);
    const retained_count = context.retained_nodes.items.len;
    try std.testing.expect(retained_count > 0);

    late_transition_handler_calls = 0;
    try context.beginLayout();
    try context.openElementWithId(retained_id, retainedExitBox(blue));
    try context.closeElement();
    for (0..32) |_| {
        try context.openElement(fixedBox(1, 1, .{}));
        try context.closeElement();
    }
    try preflightEndLayoutScratch(&context);
    try context.pending_retained_nodes.shrinkAndFreePrecise(context.allocator, 0);
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.endLayout(0));
    try std.testing.expectEqual(@as(usize, 0), late_transition_handler_calls);
    try std.testing.expectEqual(retained_count, context.retained_nodes.items.len);
    try std.testing.expect(context.retained_id_to_index.contains(retained_id.id));

    allowAllocations(&failing);
    try context.beginLayout();
    const commands = try context.endLayout(0);
    try expectColor(red, try rectangleColorForId(commands, retained_id));
}

test "persistent commit preflight OOM publishes neither frame state nor hit records" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    const committed_id = context.staticId("audit-persistent-before-oom");
    try context.beginLayout();
    try context.openElementWithId(committed_id, fixedBox(20, 20, green));
    try context.closeElement();
    _ = try context.endLayout(0);

    const rejected_id = context.staticId("audit-persistent-rejected-oom");
    try context.beginLayout();
    try context.openElementWithId(rejected_id, fixedBox(20, 20, blue));
    try context.closeElement();
    for (0..32) |_| {
        try context.openElement(fixedBox(1, 1, .{}));
        try context.closeElement();
    }
    try preflightEndLayoutScratch(&context);
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.endLayout(0));
    try std.testing.expect(context.getElementData(committed_id).found);
    try std.testing.expect(!context.getElementData(rejected_id).found);
    allowAllocations(&failing);
    try context.setPointerState(.{ .x = 5, .y = 5 }, false);
    try std.testing.expect(context.pointerOver(committed_id));
    try std.testing.expect(!context.pointerOver(rejected_id));
}

var rejected_scroll_query_count: usize = 0;

fn countRejectedScrollQuery(_: u32, _: ?*anyopaque) types.Vector2 {
    rejected_scroll_query_count += 1;
    return .{ .x = -10, .y = -20 };
}

test "render rejection publishes neither scroll state nor external queries" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = 8,
    });
    defer context.deinit();
    context.setExternalScrollHandlingEnabled(true);
    context.setQueryScrollOffsetFunction(countRejectedScrollQuery, null);

    const committed_id = context.staticId("audit-committed-scroll-container");
    rejected_scroll_query_count = 0;
    try context.beginLayout();
    var declaration = fixedBox(20, 20, .{});
    declaration.clip = .{ .horizontal = true, .vertical = true };
    try context.openElementWithId(committed_id, declaration);
    try context.closeElement();
    _ = try context.endLayout(0);
    try std.testing.expectEqual(@as(usize, 1), rejected_scroll_query_count);
    const committed_position = context.getScrollContainerData(committed_id).scroll_position.?.*;

    context.setMaxElementCount(2);
    const rejected_id = context.staticId("audit-rejected-scroll-container");
    rejected_scroll_query_count = 0;
    try context.beginLayout();
    try context.openElementWithId(rejected_id, declaration);
    try context.closeElement();
    try std.testing.expectError(error.RenderCommandCapacityExceeded, context.endLayout(0));

    const restored = context.getScrollContainerData(committed_id);
    try std.testing.expect(restored.found);
    try std.testing.expectEqual(committed_position.x, restored.scroll_position.?.x);
    try std.testing.expectEqual(committed_position.y, restored.scroll_position.?.y);
    try std.testing.expect(!context.getScrollContainerData(rejected_id).found);
    try std.testing.expectEqual(@as(usize, 0), rejected_scroll_query_count);
}

var reentrant_pointer_context: ?*zlay.Context = null;
var reentrant_pointer_error: ?anyerror = null;
var reentrant_layout_error: ?anyerror = null;

fn reenterPointerUpdate(_: types.ElementId, pointer: types.PointerData, _: ?*anyopaque) void {
    reentrant_pointer_context.?.setPointerState(pointer.position, false) catch |pointer_error| {
        reentrant_pointer_error = pointer_error;
    };
}

fn reenterLayoutFromHover(_: types.ElementId, _: types.PointerData, _: ?*anyopaque) void {
    reentrant_pointer_context.?.beginLayout() catch |layout_error| {
        reentrant_layout_error = layout_error;
    };
}

test "hover callback reentrancy is rejected without corrupting the outer pointer update" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    const child_id = context.staticId("audit-reentrant-pointer-child");
    try context.beginLayout();
    try context.openElementWithId(child_id, fixedBox(20, 20, green));
    try context.onHover(reenterPointerUpdate, null);
    try context.closeElement();
    _ = try context.endLayout(0);

    reentrant_pointer_context = &context;
    defer reentrant_pointer_context = null;
    reentrant_pointer_error = null;
    try context.setPointerState(.{ .x = 5, .y = 5 }, false);

    try std.testing.expectEqual(error.PointerUpdateAlreadyActive, reentrant_pointer_error.?);
    try std.testing.expectEqual(@as(i32, 2), context.getPointerOverIds().length);
    try std.testing.expectEqual(types.PointerDataInteractionState.released_this_frame, context.getPointerState().state);
}

test "hover callback cannot replace the committed layout during hit testing" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    const child_id = context.staticId("audit-reentrant-layout-child");
    try context.beginLayout();
    try context.openElementWithId(child_id, fixedBox(20, 20, green));
    try context.onHover(reenterLayoutFromHover, null);
    try context.closeElement();
    _ = try context.endLayout(0);

    reentrant_pointer_context = &context;
    defer reentrant_pointer_context = null;
    reentrant_layout_error = null;
    try context.setPointerState(.{ .x = 5, .y = 5 }, false);

    try std.testing.expectEqual(error.CallbackReentryNotAllowed, reentrant_layout_error.?);
    try std.testing.expect(context.getElementData(child_id).found);
    try std.testing.expect(context.pointerOver(child_id));
}

const CallbackScrollPointerProbe = struct {
    context: *zlay.Context,
    container_id: types.ElementId,
    borrowed_position: ?*types.Vector2 = null,
    calls: usize = 0,
};

fn mutateCallbackScrollPointer(
    _: types.ElementId,
    _: types.PointerData,
    user_data: ?*anyopaque,
) void {
    const probe: *CallbackScrollPointerProbe = @ptrCast(@alignCast(user_data.?));
    probe.calls += 1;
    if (probe.borrowed_position) |position| position.y = -777;
    const data = probe.context.getScrollContainerData(probe.container_id);
    if (data.scroll_position) |position| position.y = -999;
}

test "preborrowed and callback query pointers cannot mutate live scroll state" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const clip_id = context.staticId("audit-callback-query-clip");
    var probe = CallbackScrollPointerProbe{
        .context = &context,
        .container_id = clip_id,
    };

    try context.beginLayout();
    var clip = fixedBox(50, 50, .{});
    clip.clip = .{ .vertical = true };
    try context.openElementWithId(clip_id, clip);
    try context.onHover(mutateCallbackScrollPointer, &probe);
    try context.openElement(fixedBox(50, 100, .{}));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    const borrowed_position = context.getScrollContainerData(clip_id).scroll_position.?;
    borrowed_position.y = -20;
    probe.borrowed_position = borrowed_position;
    try context.setPointerState(.{ .x = 5, .y = 5 }, false);

    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(f32, -20), context.getScrollContainerData(clip_id).scroll_position.?.y);
    try std.testing.expectEqual(@as(i32, 3), context.getPointerOverIds().length);
}

const ReentrantScrollQueryProbe = struct {
    context: *zlay.Context,
    calls: usize = 0,
    layout_error: ?anyerror = null,
};

fn reenterDuringScrollQuery(_: u32, user_data: ?*anyopaque) types.Vector2 {
    const probe: *ReentrantScrollQueryProbe = @ptrCast(@alignCast(user_data.?));
    probe.calls += 1;
    probe.context.updateScrollContainers(false, .{}, 0);
    probe.context.beginLayout() catch |layout_error| {
        probe.layout_error = layout_error;
    };
    return .{ .y = -5 };
}

test "external scroll query cannot mutate scroll lifecycle or open a nested frame" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    var probe = ReentrantScrollQueryProbe{ .context = &context };
    context.setExternalScrollHandlingEnabled(true);
    context.setQueryScrollOffsetFunction(reenterDuringScrollQuery, &probe);

    const clip_id = context.staticId("audit-reentrant-scroll-query-clip");
    try context.beginLayout();
    var clip = fixedBox(50, 50, .{});
    clip.clip = .{ .vertical = true };
    try context.openElementWithId(clip_id, clip);
    try context.openElement(fixedBox(50, 100, .{}));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(error.CallbackReentryNotAllowed, probe.layout_error.?);
    try std.testing.expect(context.getScrollContainerData(clip_id).found);
    context.updateScrollContainers(false, .{}, 0);
    try std.testing.expect(context.getScrollContainerData(clip_id).found);
}

const MeasurementReentryProbe = struct {
    context: *zlay.Context,
    calls: usize = 0,
    begin_error: ?anyerror = null,
    end_error: ?anyerror = null,
};

fn reenterDuringMeasurement(
    value: types.StringSlice,
    _: *types.TextElementConfig,
    user_data: ?*anyopaque,
) types.Dimensions {
    const probe: *MeasurementReentryProbe = @ptrCast(@alignCast(user_data.?));
    probe.calls += 1;
    probe.context.beginLayout() catch |layout_error| {
        probe.begin_error = layout_error;
    };
    if (probe.context.endLayout(0)) |_| {} else |layout_error| {
        probe.end_error = layout_error;
    }
    probe.context.resetMeasureTextCache();
    probe.context.deinit();
    return .{
        .width = @floatFromInt(value.asSlice().len),
        .height = 1,
    };
}

test "measurement callbacks cannot mutate destroy or complete their Context" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    var probe = MeasurementReentryProbe{ .context = &context };
    context.setMeasureTextFunction(reenterDuringMeasurement, &probe);

    try context.beginLayout();
    try context.textSlice("guarded measurement", .{});
    _ = try context.endLayout(0);

    try std.testing.expect(probe.calls > 0);
    try std.testing.expectEqual(error.CallbackReentryNotAllowed, probe.begin_error.?);
    try std.testing.expectEqual(error.CallbackReentryNotAllowed, probe.end_error.?);
    try std.testing.expectEqual(@as(usize, 1), context.text_cache.entryCount());
    try context.beginLayout();
    _ = try context.endLayout(0);
}

const ErrorReentryProbe = struct {
    context: *zlay.Context,
    calls: usize = 0,
    begin_error: ?anyerror = null,
    end_error: ?anyerror = null,
};

fn reenterDuringDiagnostic(error_data: types.ErrorData) void {
    const probe: *ErrorReentryProbe = @ptrCast(@alignCast(error_data.user_data.?));
    probe.calls += 1;
    probe.context.beginLayout() catch |layout_error| {
        probe.begin_error = layout_error;
    };
    if (probe.context.endLayout(0)) |_| {} else |layout_error| {
        probe.end_error = layout_error;
    }
    probe.context.setLayoutDimensions(.{ .width = 1, .height = 1 });
    probe.context.deinit();
}

test "diagnostic callbacks cannot recursively complete or destroy their Context" {
    var probe: ErrorReentryProbe = undefined;
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .error_handler = .{
            .error_handler_function = reenterDuringDiagnostic,
            .user_data = &probe,
        },
    });
    defer context.deinit();
    probe = .{ .context = &context };

    try context.beginLayout();
    try context.openElement(.{});
    _ = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(error.CallbackReentryNotAllowed, probe.begin_error.?);
    try std.testing.expectEqual(error.CallbackReentryNotAllowed, probe.end_error.?);
    try std.testing.expectEqual(types.Dimensions{ .width = 100, .height = 100 }, context.getLayoutDimensions());
    try context.beginLayout();
    _ = try context.endLayout(0);
}

const MutatingMeasurementProbe = struct {
    space_calls: usize = 0,
};

fn mutateMeasurementKey(
    value: types.StringSlice,
    config: *types.TextElementConfig,
    user_data: ?*anyopaque,
) types.Dimensions {
    const probe: *MutatingMeasurementProbe = @ptrCast(@alignCast(user_data.?));
    if (std.mem.eql(u8, value.asSlice(), " ")) {
        probe.space_calls += 1;
        config.font_id = @intCast(100 + probe.space_calls);
    }
    return .{
        .width = @floatFromInt(value.asSlice().len),
        .height = 1,
    };
}

fn mutateMeasurementKeyFixed(
    value: types.StringSlice,
    config: *types.TextElementConfig,
    _: ?*anyopaque,
) types.Dimensions {
    if (std.mem.eql(u8, value.asSlice(), " ")) config.font_id = 9;
    return .{
        .width = @floatFromInt(value.asSlice().len),
        .height = 1,
    };
}

var text_preflight_transition_calls: usize = 0;

fn countTextPreflightTransition(_: types.TransitionCallbackArguments) bool {
    text_preflight_transition_calls += 1;
    return false;
}

fn textPreflightBox(color: types.Color) types.ElementDeclaration {
    var declaration = fixedBox(1, 10, color);
    declaration.transition = .{
        .handler = countTextPreflightTransition,
        .duration = 1,
        .properties = .background_color,
    };
    return declaration;
}

test "mutated text-cache keys reserve storage before transition callbacks" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    var measure_probe = MutatingMeasurementProbe{};
    context.setMeasureTextFunction(mutateMeasurementKey, &measure_probe);
    const id = context.staticId("audit-transition-text-preflight");

    try context.beginLayout();
    try context.openElementWithId(id, textPreflightBox(red));
    try context.textSlice("a a", .{ .font_id = 1, .font_size = 1 });
    try context.closeElement();
    _ = try context.endLayout(0);

    text_preflight_transition_calls = 0;
    try context.beginLayout();
    try context.openElementWithId(id, textPreflightBox(blue));
    try context.textSlice("a a", .{ .font_id = 1, .font_size = 1 });
    try context.closeElement();
    try preflightEndLayoutScratch(&context);
    failNextAllocation(&failing);

    try std.testing.expectError(error.OutOfMemory, context.endLayout(0.25));
    try std.testing.expectEqual(@as(usize, 0), text_preflight_transition_calls);

    allowAllocations(&failing);
    try context.beginLayout();
    try context.openElementWithId(id, textPreflightBox(blue));
    try context.textSlice("a a", .{ .font_id = 1, .font_size = 1 });
    try context.closeElement();
    _ = try context.endLayout(0.25);
    try std.testing.expectEqual(@as(usize, 1), text_preflight_transition_calls);
}

test "transition text preflight honors exact word limits and duplicate keys" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = 8,
        .max_text_cache_word_count = 2,
    });
    defer context.deinit();
    context.setMeasureTextFunction(mutateMeasurementKeyFixed, null);
    const id = context.staticId("audit-exact-transition-text-preflight");

    try context.beginLayout();
    try context.openElementWithId(id, textPreflightBox(red));
    try context.textSlice("\n", .{ .font_id = 1, .font_size = 1 });
    try context.textSlice("\n", .{ .font_id = 1, .font_size = 1 });
    try context.closeElement();
    _ = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 2), context.text_cache.owned_words.items.len);
}

var rejected_transition_handler_calls: usize = 0;

fn countRejectedTransition(_: types.TransitionCallbackArguments) bool {
    rejected_transition_handler_calls += 1;
    return false;
}

fn rejectedTransitionBox(color: types.Color, clipped: bool) types.ElementDeclaration {
    var declaration = fixedBox(20, 20, color);
    declaration.clip = .{ .horizontal = clipped, .vertical = clipped };
    declaration.transition = .{
        .handler = countRejectedTransition,
        .duration = 1,
        .properties = .background_color,
    };
    return declaration;
}

var late_render_transition_calls: usize = 0;

fn moveTransitionOnscreen(arguments: types.TransitionCallbackArguments) bool {
    late_render_transition_calls += 1;
    arguments.current.bounding_box.x = 0;
    return false;
}

fn offscreenClipTransition(offset_x: f32) types.ElementDeclaration {
    var declaration = fixedBox(20, 20, red);
    declaration.clip = .{ .horizontal = true, .vertical = true };
    declaration.floating = .{
        .attach_to = .root,
        .offset = .{ .x = offset_x },
    };
    declaration.transition = .{
        .handler = moveTransitionOnscreen,
        .duration = 1,
        .properties = .x,
    };
    return declaration;
}

test "worst-case transition render capacity is rejected before the handler" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .max_render_command_count = 16,
    });
    defer context.deinit();

    const id = context.staticId("audit-transition-late-render-capacity");
    try context.beginLayout();
    try context.openElementWithId(id, offscreenClipTransition(200));
    try context.closeElement();
    _ = try context.endLayout(0);

    context.options.max_render_command_count = 2;
    late_render_transition_calls = 0;
    try context.beginLayout();
    try context.openElementWithId(id, offscreenClipTransition(150));
    try context.closeElement();
    try std.testing.expectError(error.RenderCommandCapacityExceeded, context.endLayout(0.25));
    try std.testing.expectEqual(@as(usize, 0), late_render_transition_calls);
}

var exit_final_state_calls: usize = 0;

fn countExitFinalState(current: types.TransitionData, _: types.TransitionProperty) types.TransitionData {
    exit_final_state_calls += 1;
    return current;
}

fn countedExitTransitionBox() types.ElementDeclaration {
    var declaration = fixedBox(20, 20, red);
    declaration.transition = .{
        .handler = keepTransitionActive,
        .duration = 1,
        .properties = .background_color,
        .exit = .{ .set_final_state = countExitFinalState },
    };
    return declaration;
}

test "exit final-state callback is deferred past retained-clone allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = zlay.Context.init(failing.allocator(), .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    const id = context.staticId("audit-exit-final-before-clone-oom");
    try context.beginLayout();
    try context.openElementWithId(id, countedExitTransitionBox());
    try context.closeElement();
    _ = try context.endLayout(0);

    exit_final_state_calls = 0;
    try context.beginLayout();
    failNextAllocation(&failing);
    try std.testing.expectError(error.OutOfMemory, context.endLayout(0));
    try std.testing.expectEqual(@as(usize, 0), exit_final_state_calls);

    allowAllocations(&failing);
    try context.beginLayout();
    _ = try context.endLayout(0);
    try std.testing.expectEqual(@as(usize, 1), exit_final_state_calls);
}

test "render rejection invokes no transition callback and restores transition runtime" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = 8,
        .max_render_command_count = 2,
    });
    defer context.deinit();

    const id = context.staticId("audit-rejected-transition");
    rejected_transition_handler_calls = 0;
    try context.beginLayout();
    try context.openElementWithId(id, rejectedTransitionBox(red, false));
    try context.closeElement();
    _ = try context.endLayout(0);
    const runtime_before = context.transition_states.get(id.id).?;

    try context.beginLayout();
    try context.openElementWithId(id, rejectedTransitionBox(blue, true));
    try context.closeElement();
    try std.testing.expectError(error.RenderCommandCapacityExceeded, context.endLayout(0.25));

    const runtime_after = context.transition_states.get(id.id).?;
    try std.testing.expectEqual(@as(usize, 0), rejected_transition_handler_calls);
    try std.testing.expectEqual(runtime_before.state, runtime_after.state);
    try std.testing.expectEqual(runtime_before.elapsed_time, runtime_after.elapsed_time);
    try expectColor(runtime_before.current.background_color, runtime_after.current.background_color);
    try expectColor(runtime_before.target.background_color, runtime_after.target.background_color);
}

fn keepNegativeDeltaTransitionActive(_: types.TransitionCallbackArguments) bool {
    return false;
}

fn negativeDeltaTransitionBox(color: types.Color) types.ElementDeclaration {
    var declaration = fixedBox(20, 20, color);
    declaration.transition = .{
        .handler = keepNegativeDeltaTransitionActive,
        .duration = 1,
        .properties = .background_color,
    };
    return declaration;
}

test "Context normalizes negative and non-finite transition frame deltas" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    const id = context.staticId("audit-negative-transition-delta");
    try context.beginLayout();
    try context.openElementWithId(id, negativeDeltaTransitionBox(red));
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.beginLayout();
    try context.openElementWithId(id, negativeDeltaTransitionBox(blue));
    try context.closeElement();
    _ = try context.endLayout(-1);
    try std.testing.expectEqual(@as(f32, 0), context.transition_states.get(id.id).?.elapsed_time);

    try context.beginLayout();
    try context.openElementWithId(id, negativeDeltaTransitionBox(blue));
    try context.closeElement();
    _ = try context.endLayout(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 0), context.transition_states.get(id.id).?.elapsed_time);
}

fn duplicateExitBox(color: types.Color) types.ElementDeclaration {
    var declaration = fixedBox(20, 20, color);
    declaration.transition = .{
        .handler = keepTransitionActive,
        .duration = 1,
        .properties = .x,
        .exit = .{ .set_final_state = identityExitFinalState },
    };
    return declaration;
}

var duplicate_late_transition_calls: usize = 0;

fn countDuplicateLateTransition(_: types.TransitionCallbackArguments) bool {
    duplicate_late_transition_calls += 1;
    return false;
}

fn duplicateLateTransitionBox() types.ElementDeclaration {
    var declaration = fixedBox(20, 20, blue);
    declaration.transition = .{
        .handler = countDuplicateLateTransition,
        .duration = 1,
        .properties = .background_color,
        .exit = .{ .set_final_state = identityExitFinalState },
    };
    return declaration;
}

test "later duplicate IDs cannot register combined or split transition config" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const combined_id = context.staticId("audit-duplicate-late-transition-combined");
    const split_id = context.staticId("audit-duplicate-late-transition-split");
    duplicate_late_transition_calls = 0;

    try context.beginLayout();
    try context.openElementWithId(combined_id, fixedBox(20, 20, red));
    try context.closeElement();
    try context.openElementWithId(combined_id, duplicateLateTransitionBox());
    try context.closeElement();

    try context.openElementWithId(split_id, fixedBox(20, 20, red));
    try context.closeElement();
    try context.openElementWithIdUnconfigured(split_id);
    try context.configureOpenElement(duplicateLateTransitionBox());
    try context.closeElement();
    _ = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 0), duplicate_late_transition_calls);
    try std.testing.expectEqual(@as(usize, 0), context.transition_order.items.len);
    try std.testing.expectEqual(@as(u32, 0), context.transition_states.count());
    try std.testing.expectEqual(@as(usize, 0), context.retained_nodes.items.len);
    var duplicate_count: usize = 0;
    for (context.nodes.items, 0..) |node, node_index| {
        if (node.element_id.id != combined_id.id and node.element_id.id != split_id.id) continue;
        duplicate_count += 1;
        if (context.id_to_index.get(node.element_id.id) != node_index) {
            try std.testing.expect(node.config.transition.handler == null);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), duplicate_count);
}

var duplicate_scroll_query_calls: usize = 0;

fn countDuplicateScrollQuery(_: u32, _: ?*anyopaque) types.Vector2 {
    duplicate_scroll_query_calls += 1;
    return .{};
}

fn clippedBox(
    width: f32,
    height: f32,
    horizontal: bool,
    vertical: bool,
) types.ElementDeclaration {
    var declaration = fixedBox(width, height, .{});
    declaration.clip = .{ .horizontal = horizontal, .vertical = vertical };
    return declaration;
}

const DuplicateInteractionProbe = struct {
    calls: usize = 0,
};

fn countDuplicateInteraction(
    _: types.ElementId,
    _: types.PointerData,
    user_data: ?*anyopaque,
) void {
    const probe: *DuplicateInteractionProbe = @ptrCast(@alignCast(user_data.?));
    probe.calls += 1;
}

fn floatingClippedBox(offset_x: f32) types.ElementDeclaration {
    var declaration = clippedBox(30, 30, true, true);
    declaration.floating = .{
        .offset = .{ .x = offset_x },
        .attach_to = .root,
    };
    return declaration;
}

test "later duplicate IDs own no hits while their actual clip bounds guard descendants" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 100 }, .{});
    defer context.deinit();
    const combined_id = context.staticId("audit-duplicate-hit-combined");
    const combined_child_id = context.staticId("audit-duplicate-clip-child-combined");
    const split_id = context.staticId("audit-duplicate-hit-split");
    const split_child_id = context.staticId("audit-duplicate-clip-child-split");
    var combined_owner_probe = DuplicateInteractionProbe{};
    var combined_child_probe = DuplicateInteractionProbe{};
    var split_owner_probe = DuplicateInteractionProbe{};
    var split_child_probe = DuplicateInteractionProbe{};

    try context.beginLayout();
    try context.openElementWithId(combined_id, fixedBox(20, 20, red));
    try context.onHover(countDuplicateInteraction, &combined_owner_probe);
    try context.closeElement();
    try context.openElementWithId(combined_id, floatingClippedBox(60));
    try context.openElementWithId(combined_child_id, fixedBox(10, 10, green));
    try context.onHover(countDuplicateInteraction, &combined_child_probe);
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(split_id, fixedBox(20, 20, red));
    try context.onHover(countDuplicateInteraction, &split_owner_probe);
    try context.closeElement();
    try context.openElementWithIdUnconfigured(split_id);
    try context.configureOpenElement(floatingClippedBox(120));
    try context.openElementWithId(split_child_id, fixedBox(10, 10, green));
    try context.onHover(countDuplicateInteraction, &split_child_probe);
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.setPointerState(.{ .x = 65, .y = 5 }, false);
    try std.testing.expectEqual(@as(usize, 0), combined_owner_probe.calls);
    try std.testing.expectEqual(@as(usize, 1), combined_child_probe.calls);
    try std.testing.expect(!context.pointerOver(combined_id));
    try std.testing.expect(context.pointerOver(combined_child_id));

    try context.setPointerState(.{ .x = 125, .y = 5 }, false);
    try std.testing.expectEqual(@as(usize, 0), split_owner_probe.calls);
    try std.testing.expectEqual(@as(usize, 1), split_child_probe.calls);
    try std.testing.expect(!context.pointerOver(split_id));
    try std.testing.expect(context.pointerOver(split_child_id));
}

test "later duplicate IDs cannot create or overwrite combined or split scroll state" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 200 }, .{});
    defer context.deinit();
    context.setExternalScrollHandlingEnabled(true);
    context.setQueryScrollOffsetFunction(countDuplicateScrollQuery, null);
    const absent_id = context.staticId("audit-duplicate-scroll-absent");
    const combined_id = context.staticId("audit-duplicate-scroll-combined");
    const split_id = context.staticId("audit-duplicate-scroll-split");
    duplicate_scroll_query_calls = 0;

    try context.beginLayout();
    try context.openElementWithId(absent_id, fixedBox(10, 11, .{}));
    try context.closeElement();
    try context.openElementWithId(absent_id, clippedBox(70, 71, false, true));
    try context.closeElement();

    try context.openElementWithId(combined_id, clippedBox(30, 31, false, true));
    try context.closeElement();
    try context.openElementWithId(combined_id, clippedBox(80, 81, true, false));
    try context.closeElement();

    try context.openElementWithIdUnconfigured(split_id);
    try context.configureOpenElement(clippedBox(40, 41, false, true));
    try context.closeElement();
    try context.openElementWithIdUnconfigured(split_id);
    try context.configureOpenElement(clippedBox(90, 91, true, false));
    try context.closeElement();
    _ = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 2), duplicate_scroll_query_calls);
    try std.testing.expect(!context.getScrollContainerData(absent_id).found);

    const combined = context.getScrollContainerData(combined_id);
    try std.testing.expect(combined.found);
    try std.testing.expect(!combined.config.horizontal);
    try std.testing.expect(combined.config.vertical);
    try std.testing.expectEqual(types.Dimensions{ .width = 30, .height = 31 }, combined.scroll_container_dimensions);

    const split = context.getScrollContainerData(split_id);
    try std.testing.expect(split.found);
    try std.testing.expect(!split.config.horizontal);
    try std.testing.expect(split.config.vertical);
    try std.testing.expectEqual(types.Dimensions{ .width = 40, .height = 41 }, split.scroll_container_dimensions);
}

test "duplicate-ID retained exits preserve the first declaration" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const id = context.staticId("audit-duplicate-retained-exit");

    try context.beginLayout();
    try context.openElementWithId(id, duplicateExitBox(red));
    try context.closeElement();
    try context.openElementWithId(id, duplicateExitBox(blue));
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.beginLayout();
    const exiting = try context.endLayout(0);
    try expectColor(red, try rectangleColorForId(exiting, id));
}

test "retained subtree cloning preserves the first duplicate descendant owner" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const parent_id = context.staticId("audit-retained-duplicate-parent");
    const child_id = context.staticId("audit-retained-duplicate-child");

    try context.beginLayout();
    try context.openElementWithId(parent_id, duplicateExitBox(.{}));
    try context.openElementWithId(child_id, fixedBox(10, 10, red));
    try context.closeElement();
    try context.openElementWithId(child_id, fixedBox(10, 10, blue));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.beginLayout();
    _ = try context.endLayout(0);
    const owner_index = context.id_to_index.get(child_id.id) orelse
        return error.MissingRetainedDuplicateOwner;
    try expectColor(red, context.nodes.items[owner_index].config.background_color);
}

const CallbackCommandProbe = struct {
    context: *zlay.Context,
    calls: usize = 0,
    observed_type: ?types.RenderCommandType = null,
};

fn mutateCommandDuringExternalQuery(_: u32, user_data: ?*anyopaque) types.Vector2 {
    const probe: *CallbackCommandProbe = @ptrCast(@alignCast(user_data.?));
    probe.calls += 1;
    const command = probe.context.renderCommand(0) orelse return .{};
    probe.observed_type = command.command_type;
    command.command_type = .none;
    return .{};
}

test "callback command queries cannot mutate the validated live stream" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    var probe = CallbackCommandProbe{ .context = &context };
    context.setExternalScrollHandlingEnabled(true);
    context.setQueryScrollOffsetFunction(mutateCommandDuringExternalQuery, &probe);
    const id = context.staticId("audit-callback-command-alias");

    var declaration = fixedBox(50, 50, red);
    declaration.clip.vertical = true;
    try context.beginLayout();
    try context.openElementWithId(id, declaration);
    try context.closeElement();
    const commands = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(types.RenderCommandType.scissor_start, probe.observed_type.?);
    try std.testing.expectEqual(types.RenderCommandType.scissor_start, commands.items()[0].command_type);
    _ = try zlay.renderer.validate(commands.items());
}

test "non-finite grow bounds cannot stall layout distribution" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const id = context.staticId("audit-non-finite-grow-bound");

    try context.beginLayout();
    try context.openElementWithId(id, .{ .layout = .{ .sizing = .{
        .width = zlay.growMinMax(std.math.inf(f32), std.math.inf(f32)),
        .height = zlay.fixed(10),
    } } });
    try context.closeElement();
    _ = try context.endLayout(0);

    try std.testing.expect(context.getElementData(id).found);
}
