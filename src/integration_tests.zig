//! End-to-end tests through ZLAY's public `Context` and data types.

const std = @import("std");
const zlay = @import("root.zig");
const types = zlay.types;

fn fixedBox(width: f32, height: f32, color: types.Color) types.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(width),
            .height = zlay.fixed(height),
        } },
        .background_color = color,
    };
}

fn expectCommandTypes(
    commands: types.RenderCommandArray,
    expected: []const types.RenderCommandType,
) !void {
    const items = commands.items();
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, items) |expected_type, command| {
        try std.testing.expectEqual(expected_type, command.command_type);
    }
}

fn drawSingleBox(
    context: *zlay.Context,
    element_id: types.ElementId,
    width: f32,
    height: f32,
) !void {
    try context.beginLayout();
    try context.openElementWithId(element_id, fixedBox(width, height, .{ .r = 255, .a = 255 }));
    try context.closeElement();
    _ = try context.endLayout(0);
}

test "multiple public contexts retain isolated layout pointer and persistent state" {
    var first = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer first.deinit();
    var second = zlay.Context.init(std.testing.allocator, .{ .width = 240, .height = 180 }, .{});
    defer second.deinit();

    const first_id = first.id("shared-name");
    const second_id = second.id("shared-name");
    try std.testing.expectEqual(first_id.id, second_id.id);

    try drawSingleBox(&first, first_id, 20, 30);
    try drawSingleBox(&second, second_id, 70, 80);

    const first_data = first.getElementData(first_id);
    const second_data = second.getElementData(second_id);
    try std.testing.expect(first_data.found);
    try std.testing.expect(second_data.found);
    try std.testing.expectEqual(@as(f32, 20), first_data.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 70), second_data.bounding_box.width);
    try std.testing.expectEqual(types.Dimensions{ .width = 100, .height = 100 }, first.getLayoutDimensions());
    try std.testing.expectEqual(types.Dimensions{ .width = 240, .height = 180 }, second.getLayoutDimensions());

    try first.setPointerState(.{ .x = 5, .y = 5 }, true);
    try std.testing.expectEqual(types.PointerDataInteractionState.pressed, first.getPointerState().state);
    try std.testing.expectEqual(types.PointerDataInteractionState.pressed_this_frame, second.getPointerState().state);

    // Advancing only the first context removes only its stale persistent item.
    try first.beginLayout();
    _ = try first.endLayout(0);
    try std.testing.expect(!first.getElementData(first_id).found);
    try std.testing.expect(second.getElementData(second_id).found);
}

const HoverLog = struct {
    ids: [16]u32 = undefined,
    states: [16]types.PointerDataInteractionState = undefined,
    length: usize = 0,

    fn clear(self: *HoverLog) void {
        self.length = 0;
    }
};

fn recordHover(
    element_id: types.ElementId,
    pointer_data: types.PointerData,
    user_data: ?*anyopaque,
) void {
    const log: *HoverLog = @ptrCast(@alignCast(user_data.?));
    log.ids[log.length] = element_id.id;
    log.states[log.length] = pointer_data.state;
    log.length += 1;
}

fn expectHoverFrame(
    log: *const HoverLog,
    parent_id: u32,
    child_id: u32,
    state_seen_by_callback: types.PointerDataInteractionState,
) !void {
    try std.testing.expectEqual(@as(usize, 2), log.length);
    try std.testing.expectEqual(parent_id, log.ids[0]);
    try std.testing.expectEqual(child_id, log.ids[1]);
    try std.testing.expectEqual(state_seen_by_callback, log.states[0]);
    try std.testing.expectEqual(state_seen_by_callback, log.states[1]);
}

test "pointer transitions and nested hover callbacks preserve frame ordering" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 200 }, .{});
    defer context.deinit();
    var log = HoverLog{};
    const parent_id = context.id("hover-parent");
    const child_id = context.id("hover-child");

    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(100, 100, .{}));
    try context.onHover(recordHover, &log);
    try context.openElementWithId(child_id, fixedBox(50, 50, .{}));
    try context.onHover(recordHover, &log);
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    // Clay invokes hover callbacks before advancing the stored interaction
    // state, so callbacks observe the previous state for each input sample.
    try context.setPointerState(.{ .x = 10, .y = 10 }, true);
    try expectHoverFrame(&log, parent_id.id, child_id.id, .pressed_this_frame);
    try std.testing.expectEqual(types.PointerDataInteractionState.pressed, context.getPointerState().state);

    const over = context.getPointerOverIds().items();
    try std.testing.expectEqual(@as(usize, 3), over.len);
    try std.testing.expectEqual(context.id("Clay__RootContainer").id, over[0].id);
    try std.testing.expectEqual(parent_id.id, over[1].id);
    try std.testing.expectEqual(child_id.id, over[2].id);

    log.clear();
    try context.setPointerState(.{ .x = 10, .y = 10 }, true);
    try expectHoverFrame(&log, parent_id.id, child_id.id, .pressed);
    try std.testing.expectEqual(types.PointerDataInteractionState.pressed, context.getPointerState().state);

    log.clear();
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try expectHoverFrame(&log, parent_id.id, child_id.id, .pressed);
    try std.testing.expectEqual(types.PointerDataInteractionState.released_this_frame, context.getPointerState().state);

    log.clear();
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try expectHoverFrame(&log, parent_id.id, child_id.id, .released_this_frame);
    try std.testing.expectEqual(types.PointerDataInteractionState.released, context.getPointerState().state);
}

fn floatingBox(
    z_index: i16,
    capture_mode: types.PointerCaptureMode,
    color: types.Color,
) types.ElementDeclaration {
    var declaration = fixedBox(100, 100, color);
    declaration.floating = .{
        .z_index = z_index,
        .pointer_capture_mode = capture_mode,
        .attach_to = .root,
    };
    return declaration;
}

fn drawFloatingStack(
    context: *zlay.Context,
    base_id: types.ElementId,
    low_id: types.ElementId,
    high_id: types.ElementId,
    high_capture_mode: types.PointerCaptureMode,
) !types.RenderCommandArray {
    try context.beginLayout();
    try context.openElementWithId(base_id, fixedBox(100, 100, .{ .r = 10, .a = 255 }));
    try context.closeElement();
    try context.openElementWithId(low_id, floatingBox(5, .passthrough, .{ .g = 20, .a = 255 }));
    try context.closeElement();
    try context.openElementWithId(high_id, floatingBox(10, high_capture_mode, .{ .b = 30, .a = 255 }));
    try context.closeElement();
    return context.endLayout(0);
}

test "floating roots sort by z and capture lower pointer roots" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 200 }, .{});
    defer context.deinit();
    const base_id = context.id("base");
    const low_id = context.id("floating-low");
    const high_id = context.id("floating-high");

    var commands = try drawFloatingStack(&context, base_id, low_id, high_id, .capture);
    try expectCommandTypes(commands, &.{ .rectangle, .rectangle, .rectangle });
    try std.testing.expectEqual(base_id.id, commands.items()[0].id);
    try std.testing.expectEqual(low_id.id, commands.items()[1].id);
    try std.testing.expectEqual(high_id.id, commands.items()[2].id);
    try std.testing.expectEqual(@as(i16, 0), commands.items()[0].z_index);
    try std.testing.expectEqual(@as(i16, 5), commands.items()[1].z_index);
    try std.testing.expectEqual(@as(i16, 10), commands.items()[2].z_index);

    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    try std.testing.expect(context.pointerOver(high_id));
    try std.testing.expect(!context.pointerOver(low_id));
    try std.testing.expect(!context.pointerOver(base_id));
    try std.testing.expectEqual(@as(i32, 1), context.getPointerOverIds().length);

    commands = try drawFloatingStack(&context, base_id, low_id, high_id, .passthrough);
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    const over = context.getPointerOverIds().items();
    try std.testing.expectEqual(@as(usize, 4), over.len);
    try std.testing.expectEqual(high_id.id, over[0].id);
    try std.testing.expectEqual(low_id.id, over[1].id);
    try std.testing.expectEqual(context.id("Clay__RootContainer").id, over[2].id);
    try std.testing.expectEqual(base_id.id, over[3].id);
    try expectCommandTypes(commands, &.{ .rectangle, .rectangle, .rectangle });
}

test "clip containers bracket descendants with ordered scissor commands" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 300 }, .{});
    defer context.deinit();
    const clip_id = context.id("clip");
    const child_id = context.id("clipped-child");

    try context.beginLayout();
    try context.openElementWithId(clip_id, .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(100), .height = zlay.fixed(100) },
            .layout_direction = .top_to_bottom,
        },
        .clip = .{ .vertical = true },
    });
    try context.openElementWithId(child_id, fixedBox(100, 200, .{ .r = 200, .a = 255 }));
    try context.closeElement();
    try context.closeElement();
    const commands = try context.endLayout(0);

    try expectCommandTypes(commands, &.{ .scissor_start, .rectangle, .scissor_end });
    try std.testing.expectEqual(clip_id.id, commands.items()[0].id);
    try std.testing.expectEqual(child_id.id, commands.items()[1].id);
    try std.testing.expect(commands.items()[0].render_data.clip.vertical);

    try context.setPointerState(.{ .x = 10, .y = 150 }, false);
    try std.testing.expect(!context.pointerOver(child_id));
    try context.setPointerState(.{ .x = 10, .y = 50 }, false);
    try std.testing.expect(context.pointerOver(child_id));
}

fn drawScrollFrame(
    context: *zlay.Context,
    container_id: types.ElementId,
    child_id: types.ElementId,
    child_offset: types.Vector2,
) !void {
    try context.beginLayout();
    try context.openElementWithId(container_id, .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(100), .height = zlay.fixed(100) },
            .layout_direction = .top_to_bottom,
        },
        .clip = .{ .vertical = true, .child_offset = child_offset },
    });
    try context.openElementWithId(child_id, fixedBox(100, 300, .{ .g = 255, .a = 255 }));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
}

test "context scroll state persists and is applied by the next layout frame" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 120, .height = 120 }, .{});
    defer context.deinit();
    const container_id = context.id("scroll-container");
    const child_id = context.id("scroll-content");

    try drawScrollFrame(&context, container_id, child_id, .{});
    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    context.updateScrollContainers(false, .{ .y = -2 }, 0.016);

    const offset = context.getScrollOffsetFor(container_id);
    try std.testing.expectEqual(@as(f32, -20), offset.y);
    const first_data = context.getScrollContainerData(container_id);
    try std.testing.expect(first_data.found);
    try std.testing.expectEqual(types.Dimensions{ .width = 100, .height = 100 }, first_data.scroll_container_dimensions);
    try std.testing.expectEqual(types.Dimensions{ .width = 100, .height = 300 }, first_data.content_dimensions);

    try drawScrollFrame(&context, container_id, child_id, offset);
    const child_data = context.getElementData(child_id);
    try std.testing.expect(child_data.found);
    try std.testing.expectEqual(@as(f32, -20), child_data.bounding_box.y);
    try std.testing.expectEqual(@as(f32, -20), context.getScrollOffsetFor(container_id).y);

    // Consume the open flag, omit the container for a frame, then verify the
    // persistent scroll entry is pruned on the next update.
    context.updateScrollContainers(false, .{}, 0.016);
    try context.beginLayout();
    _ = try context.endLayout(0);
    context.updateScrollContainers(false, .{}, 0.016);
    try std.testing.expect(!context.getScrollContainerData(container_id).found);
}

const ErrorLog = struct {
    types_seen: [8]types.ErrorType = undefined,
    messages: [8][]const u8 = undefined,
    length: usize = 0,
};

fn recordError(error_data: types.ErrorData) void {
    const log: *ErrorLog = @ptrCast(@alignCast(error_data.user_data.?));
    log.types_seen[log.length] = error_data.error_type;
    log.messages[log.length] = error_data.error_text.asSlice();
    log.length += 1;
}

test "duplicate IDs report through the configured public error callback" {
    var error_log = ErrorLog{};
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &error_log,
        },
    });
    defer context.deinit();
    const duplicate_id = context.id("duplicate");

    try context.beginLayout();
    try context.openElementWithId(duplicate_id, fixedBox(10, 10, .{}));
    try context.closeElement();
    try context.openElementWithId(duplicate_id, fixedBox(20, 20, .{}));
    try context.closeElement();
    _ = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 1), error_log.length);
    try std.testing.expectEqual(types.ErrorType.duplicate_id, error_log.types_seen[0]);
    try std.testing.expectEqualStrings(
        "An element with this ID was already previously declared during this layout.",
        error_log.messages[0],
    );
}

test "unbalanced end reports the pinned diagnostic while repairing native state" {
    var error_log = ErrorLog{};
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .error_handler = .{
            .error_handler_function = recordError,
            .user_data = &error_log,
        },
    });
    defer context.deinit();

    try context.beginLayout();
    try context.openElementWithId(context.id("unbalanced"), fixedBox(10, 10, .{}));
    _ = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 1), error_log.length);
    try std.testing.expectEqual(types.ErrorType.unbalanced_open_close, error_log.types_seen[0]);
    try std.testing.expectEqualStrings(
        "There were still open layout elements when EndLayout was called. This results from an unequal number of calls to Clay__OpenElement and Clay__CloseElement.",
        error_log.messages[0],
    );

    // Native Zig deliberately repairs every outstanding declaration, so the
    // same context remains usable after reporting the pinned diagnostic.
    try context.beginLayout();
    _ = try context.endLayout(0);
}

fn drawOffscreenFloating(
    context: *zlay.Context,
    element_id: types.ElementId,
) !types.RenderCommandArray {
    var declaration = floatingBox(1, .passthrough, .{ .r = 255, .a = 255 });
    declaration.layout.sizing.width = zlay.fixed(20);
    declaration.layout.sizing.height = zlay.fixed(20);
    declaration.floating.offset.x = 150;

    try context.beginLayout();
    try context.openElementWithId(element_id, declaration);
    try context.closeElement();
    return context.endLayout(0);
}

test "culling toggle controls offscreen commands without deleting element data" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const offscreen_id = context.id("offscreen");

    var commands = try drawOffscreenFloating(&context, offscreen_id);
    try std.testing.expectEqual(@as(i32, 0), commands.length);
    var data = context.getElementData(offscreen_id);
    try std.testing.expect(data.found);
    try std.testing.expectEqual(@as(f32, 150), data.bounding_box.x);

    context.setCullingEnabled(false);
    commands = try drawOffscreenFloating(&context, offscreen_id);
    try expectCommandTypes(commands, &.{.rectangle});
    try std.testing.expectEqual(offscreen_id.id, commands.items()[0].id);
    data = context.getElementData(offscreen_id);
    try std.testing.expect(data.found);
}

test "image custom rectangle border and overlay commands retain upstream order" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    var image_token: u8 = 1;
    var custom_token: u8 = 2;
    const element_id = context.id("rich-render-element");
    const background = types.Color{ .r = 20, .g = 30, .b = 40, .a = 255 };
    const overlay = types.Color{ .r = 200, .g = 100, .b = 50, .a = 128 };
    const border = types.Color{ .r = 1, .g = 2, .b = 3, .a = 255 };

    try context.beginLayout();
    try context.openElementWithId(element_id, .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(40),
            .height = zlay.fixed(40),
        } },
        .background_color = background,
        .overlay_color = overlay,
        .corner_radius = zlay.cornerRadius(4),
        .image = .{ .image_data = &image_token },
        .custom = .{ .custom_data = &custom_token },
        .border = .{
            .color = border,
            .width = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
        },
    });
    try context.closeElement();
    const commands = try context.endLayout(0);

    try expectCommandTypes(commands, &.{
        .overlay_color_start,
        .image,
        .custom,
        .rectangle,
        .border,
        .overlay_color_end,
    });
    try std.testing.expectEqual(overlay, commands.items()[0].render_data.overlay_color.color);
    try std.testing.expectEqual(@intFromPtr(&image_token), @intFromPtr(commands.items()[1].render_data.image.image_data.?));
    try std.testing.expectEqual(@intFromPtr(&custom_token), @intFromPtr(commands.items()[2].render_data.custom.custom_data.?));
    try std.testing.expectEqual(background, commands.items()[3].render_data.rectangle.background_color);
    try std.testing.expectEqual(border, commands.items()[4].render_data.border.color);
    try std.testing.expectEqual(element_id.id, commands.items()[0].id);
    try std.testing.expectEqual(element_id.id, commands.items()[5].id);
    try std.testing.expectEqual(types.BoundingBox{}, commands.items()[5].bounding_box);
    try std.testing.expectEqual(@as(i16, 0), commands.items()[5].z_index);
}

test "percent-height container with children reaches the vertical sizing pass" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 100 }, .{});
    defer context.deinit();
    const parent_id = context.id("percent-height-parent");
    const child_id = context.id("percent-height-child");

    try context.beginLayout();
    try context.openElementWithId(parent_id, .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(100),
            .height = zlay.percent(0.5),
        } },
    });
    try context.openElementWithId(child_id, fixedBox(10, 10, .{}));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    const parent = context.getElementData(parent_id);
    const child = context.getElementData(child_id);
    try std.testing.expect(parent.found);
    try std.testing.expect(child.found);
    try std.testing.expectEqual(@as(f32, 100), parent.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 50), parent.bounding_box.height);
    try std.testing.expectEqual(@as(f32, 10), child.bounding_box.height);
}

test "aspect-ratio percent height preserves Clay union propagation semantics" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 200, .height = 100 }, .{});
    defer context.deinit();
    const outer_id = context.id("aspect-percent-outer");
    const aspect_id = context.id("aspect-percent-child");
    const leaf_id = context.id("aspect-percent-leaf");

    try context.beginLayout();
    try context.openElementWithId(outer_id, .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(100), .height = zlay.fit() },
            .layout_direction = .top_to_bottom,
        },
    });
    try context.openElementWithId(aspect_id, .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(100), .height = zlay.percent(0.5) },
            .layout_direction = .top_to_bottom,
        },
        .aspect_ratio = .{ .aspect_ratio = 2 },
    });
    try context.openElementWithId(leaf_id, fixedBox(10, 10, .{}));
    try context.closeElement();
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);

    const outer = context.getElementData(outer_id);
    const aspect = context.getElementData(aspect_id);
    const leaf = context.getElementData(leaf_id);
    try std.testing.expect(outer.found);
    try std.testing.expect(aspect.found);
    try std.testing.expect(leaf.found);
    try std.testing.expectEqual(@as(f32, 100), outer.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 10), outer.bounding_box.height);
    try std.testing.expectEqual(@as(f32, 10), aspect.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 5), aspect.bounding_box.height);
    try std.testing.expectEqual(@as(f32, 10), leaf.bounding_box.height);
}
