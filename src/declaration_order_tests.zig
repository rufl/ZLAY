//! Regression coverage for Clay-style split element declaration ordering.

const std = @import("std");
const zlay = @import("root.zig");

const red = zlay.Color{ .r = 255, .a = 255 };
const green = zlay.Color{ .g = 255, .a = 255 };
const blue = zlay.Color{ .b = 255, .a = 255 };

fn fixedBox(width: f32, height: f32, color: zlay.Color) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(width),
            .height = zlay.fixed(height),
        } },
        .background_color = color,
    };
}

fn scrollContainer(offset: zlay.Vector2) zlay.ElementDeclaration {
    return .{
        .layout = .{
            .sizing = .{
                .width = zlay.fixed(100),
                .height = zlay.fixed(100),
            },
            .layout_direction = .top_to_bottom,
        },
        .clip = .{ .vertical = true, .child_offset = offset },
    };
}

fn expectCommandTypes(commands: zlay.RenderCommandArray, expected: []const zlay.RenderCommandType) !void {
    const items = commands.items();
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, items) |expected_type, command| {
        try std.testing.expectEqual(expected_type, command.command_type);
    }
}

fn hoveredBox(context: *zlay.Context) !zlay.ElementDeclaration {
    return fixedBox(40, 40, if (context.hovered()) green else red);
}

fn noChildren(_: *zlay.Context) !void {}

test "deferred scoped declaration evaluates its factory after opening" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const element_id = context.staticId("deferred-hover");

    try context.beginLayout();
    try context.elementWithIdDeferred(element_id, hoveredBox, noChildren);
    _ = try context.endLayout(0);
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);

    try context.beginLayout();
    try context.elementWithIdDeferred(element_id, hoveredBox, noChildren);
    const commands = try context.endLayout(0);
    try expectCommandTypes(commands, &.{.rectangle});
    try std.testing.expectEqual(green, commands.items()[0].render_data.rectangle.background_color);
}

test "automatic split declarations evaluate hovered for the newly opened element" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    try context.beginLayout();
    try context.openElementUnconfigured();
    const automatic_id = try context.getOpenElementId();
    try context.configureOpenElement(fixedBox(40, 40, red));
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.setPointerState(.{ .x = 10, .y = 10 }, false);

    try context.beginLayout();
    try context.openElementUnconfigured();
    try std.testing.expectEqual(automatic_id, try context.getOpenElementId());
    const declaration_hovered = context.hovered();
    try std.testing.expect(declaration_hovered);
    try context.configureOpenElement(fixedBox(40, 40, if (declaration_hovered) green else red));
    try context.closeElement();
    const commands = try context.endLayout(0);

    try expectCommandTypes(commands, &.{.rectangle});
    try std.testing.expectEqual(automatic_id, commands.items()[0].id);
    try std.testing.expectEqual(green, commands.items()[0].render_data.rectangle.background_color);
}

test "explicit split declarations evaluate scroll offset for the newly opened element" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 120, .height = 120 }, .{});
    defer context.deinit();
    const container_id = context.id("split-scroll-container");
    const child_id = context.id("split-scroll-child");

    try context.beginLayout();
    try context.openElementWithIdUnconfigured(container_id);
    try context.configureOpenElement(scrollContainer(.{}));
    try context.openElementWithIdUnconfigured(child_id);
    try context.configureOpenElement(fixedBox(100, 300, green));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    context.updateScrollContainers(false, .{ .y = -2 }, 0.016);
    const expected_offset = context.getScrollOffsetFor(container_id);
    try std.testing.expectEqual(@as(f32, -20), expected_offset.y);

    try context.beginLayout();
    try context.openElementWithIdUnconfigured(container_id);
    const declaration_offset = context.getScrollOffset();
    try std.testing.expectEqual(expected_offset, declaration_offset);
    try context.configureOpenElement(scrollContainer(declaration_offset));
    try context.openElementWithIdUnconfigured(child_id);
    try context.configureOpenElement(fixedBox(100, 300, green));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    const child = context.getElementData(child_id);
    try std.testing.expect(child.found);
    try std.testing.expectEqual(declaration_offset.y, child.bounding_box.y);
}

test "split configuration establishes nested active clips" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 200 }, .{});
    defer context.deinit();
    const outer_id = context.id("split-outer-clip");
    const inner_id = context.id("split-inner-clip");
    const child_id = context.id("split-nested-clipped-child");

    var outer = fixedBox(100, 100, .{});
    outer.clip = .{ .horizontal = true, .vertical = true };
    var inner = fixedBox(50, 50, .{});
    inner.clip = .{ .horizontal = true, .vertical = true };

    try context.beginLayout();
    try context.openElementWithIdUnconfigured(outer_id);
    try context.configureOpenElement(outer);
    try context.openElementWithIdUnconfigured(inner_id);
    try context.configureOpenElement(inner);
    try context.openElementWithIdUnconfigured(child_id);
    try context.configureOpenElement(fixedBox(100, 100, blue));
    try context.closeElement();
    try context.closeElement();
    try context.closeElement();
    const commands = try context.endLayout(0);

    try expectCommandTypes(commands, &.{
        .scissor_start,
        .scissor_start,
        .rectangle,
        .scissor_end,
        .scissor_end,
    });
    try std.testing.expectEqual(outer_id.id, commands.items()[0].id);
    try std.testing.expectEqual(inner_id.id, commands.items()[1].id);
    try std.testing.expectEqual(child_id.id, commands.items()[2].id);

    try context.setPointerState(.{ .x = 75, .y = 25 }, false);
    try std.testing.expect(!context.pointerOver(child_id));
    try context.setPointerState(.{ .x = 25, .y = 25 }, false);
    try std.testing.expect(context.pointerOver(child_id));
}

test "split configuration registers a floating render root" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 200 }, .{});
    defer context.deinit();
    const floating_id = context.id("split-floating-root");

    var floating = fixedBox(30, 20, blue);
    floating.floating = .{
        .offset = .{ .x = 12, .y = 8 },
        .z_index = 9,
        .attach_to = .root,
    };

    try context.beginLayout();
    try context.openElementWithIdUnconfigured(floating_id);
    try context.configureOpenElement(floating);
    try context.closeElement();
    const commands = try context.endLayout(0);

    try expectCommandTypes(commands, &.{.rectangle});
    const command = commands.items()[0];
    try std.testing.expectEqual(floating_id.id, command.id);
    try std.testing.expectEqual(@as(i16, 9), command.z_index);
    try std.testing.expectEqual(zlay.BoundingBox{
        .x = 12,
        .y = 8,
        .width = 30,
        .height = 20,
    }, command.bounding_box);
}

test "an open element cannot be configured twice" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const element_id = context.id("split-double-configure");

    try context.beginLayout();
    try context.openElementWithIdUnconfigured(element_id);
    try context.configureOpenElement(fixedBox(20, 20, red));
    try std.testing.expectError(
        zlay.ContextError.ElementAlreadyConfigured,
        context.configureOpenElement(fixedBox(30, 30, green)),
    );
    try context.closeElement();
    const commands = try context.endLayout(0);

    try expectCommandTypes(commands, &.{.rectangle});
    try std.testing.expectEqual(@as(f32, 20), commands.items()[0].bounding_box.width);
    try std.testing.expectEqual(red, commands.items()[0].render_data.rectangle.background_color);
}
