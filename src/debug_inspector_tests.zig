const std = @import("std");
const zlay = @import("root.zig");

fn measureText(
    text: zlay.StringSlice,
    config: *zlay.TextElementConfig,
    _: ?*anyopaque,
) zlay.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * 8,
        .height = if (config.font_size == 0) 16 else @floatFromInt(config.font_size),
    };
}

fn fixedBox(width: f32, height: f32, color: zlay.Color) zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(width), .height = zlay.fixed(height) } },
        .background_color = color,
    };
}

fn renderUserTree(context: *zlay.Context, parent_id: zlay.ElementId, child_id: zlay.ElementId) !void {
    try context.beginLayout();
    try context.openElementWithId(parent_id, fixedBox(200, 100, .{ .r = 30, .g = 60, .b = 90, .a = 255 }));
    try context.openElementWithId(child_id, fixedBox(50, 30, .{ .r = 90, .g = 60, .b = 30, .a = 255 }));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
}

fn renderClippedUserTree(context: *zlay.Context, parent_id: zlay.ElementId, child_id: zlay.ElementId) !void {
    try context.beginLayout();
    var parent = fixedBox(200, 100, .{ .r = 30, .g = 60, .b = 90, .a = 255 });
    parent.clip.vertical = true;
    try context.openElementWithId(parent_id, parent);
    try context.openElementWithId(child_id, fixedBox(50, 30, .{ .r = 90, .g = 60, .b = 30, .a = 255 }));
    try context.closeElement();
    try context.closeElement();
    _ = try context.endLayout(0);
}

fn expectBoxEqual(expected: zlay.BoundingBox, actual: zlay.BoundingBox) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.01);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.01);
    try std.testing.expectApproxEqAbs(expected.width, actual.width, 0.01);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, 0.01);
}

fn containsElementRow(context: *const zlay.Context, element_id: u32) bool {
    for (context.debug_rows.items) |row| {
        if (row.kind == .element and row.element_id == element_id) return true;
    }
    return false;
}

test "live inspector selects highlights collapses and closes across frames" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 1000, .height = 600 }, .{});
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);
    context.setDebugModeEnabled(true);

    const parent_id = context.id("inspected-parent");
    const child_id = context.id("inspected-child");
    const panel_id = context.id("Clay__DebugView");

    // Establish the released baseline expected by Clay's state machine before
    // the first press sample.
    try context.setPointerState(.{}, false);
    try context.setPointerState(.{}, false);
    try renderUserTree(&context, parent_id, child_id);

    const panel = context.getElementData(panel_id);
    try std.testing.expect(panel.found);
    try expectBoxEqual(.{ .x = 600, .y = 0, .width = 400, .height = 600 }, panel.bounding_box);
    try std.testing.expectEqual(@as(f32, 600), context.getElementData(context.id("Clay__RootContainer")).bounding_box.width);

    // The pinned coordinate formula maps y=65 to logical row one: the first
    // user element below the root row.
    try context.setPointerState(.{ .x = 650, .y = 65 }, true);
    try renderUserTree(&context, parent_id, child_id);
    try std.testing.expectEqual(parent_id.id, context.debug_selected_element_id);

    const parent = context.getElementData(parent_id);
    const highlight = context.getElementData(context.id("Clay__DebugView_ElementHighlight"));
    try std.testing.expect(parent.found);
    try std.testing.expect(highlight.found);
    try expectBoxEqual(parent.bounding_box, highlight.bounding_box);
    const highlight_rectangle_id = context.id("Clay__DebugView_ElementHighlightRectangle").id;
    var found_highlight_command = false;
    var command_index: i32 = 0;
    while (context.renderCommand(command_index)) |command| : (command_index += 1) {
        if (command.id != highlight_rectangle_id or command.command_type != .rectangle) continue;
        found_highlight_command = true;
        try std.testing.expectEqual(@as(i16, 32767), command.z_index);
        break;
    }
    try std.testing.expect(found_highlight_command);

    const collapse_id = zlay.hash.stringWithOffset(
        zlay.String.literal("Clay__DebugView_CollapseElement"),
        parent_id.id,
        0,
    );
    const collapse = context.getElementData(collapse_id);
    try std.testing.expect(collapse.found);
    const collapse_point = zlay.Vector2{
        .x = collapse.bounding_box.x + collapse.bounding_box.width / 2,
        .y = collapse.bounding_box.y + collapse.bounding_box.height / 2,
    };
    try context.setPointerState(collapse_point, false);
    try context.setPointerState(collapse_point, false);
    try context.setPointerState(collapse_point, true);
    try std.testing.expect(context.pointerOver(collapse_id));

    // Collapse is toggled after list declaration, so this interaction frame
    // still contains the child and the following frame suppresses it.
    try renderUserTree(&context, parent_id, child_id);
    try std.testing.expect(containsElementRow(&context, child_id.id));
    try context.setPointerState(collapse_point, false);
    try renderUserTree(&context, parent_id, child_id);
    try std.testing.expect(!containsElementRow(&context, child_id.id));

    // The close control is an automatic-ID child: title text, spacer, close.
    const header_id = zlay.hash.number(0, panel_id.id);
    const close_id = zlay.hash.number(2, header_id.id);
    const close = context.getElementData(close_id);
    try std.testing.expect(close.found);
    const close_point = zlay.Vector2{
        .x = close.bounding_box.x + close.bounding_box.width / 2,
        .y = close.bounding_box.y + close.bounding_box.height / 2,
    };
    try context.setPointerState(close_point, false);
    try context.setPointerState(close_point, true);
    try renderUserTree(&context, parent_id, child_id);
    try context.setPointerState(close_point, true);
    try std.testing.expect(!context.isDebugModeEnabled());

    try renderUserTree(&context, parent_id, child_id);
    try std.testing.expectEqual(@as(f32, 1000), context.getElementData(context.id("Clay__RootContainer")).bounding_box.width);
    try std.testing.expect(!context.getElementData(panel_id).found);
}

test "live inspector clamps its panes to a narrow viewport" {
    var context = zlay.Context.init(
        std.testing.allocator,
        .{ .width = 240, .height = 180 },
        .{},
    );
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);
    context.setDebugModeEnabled(true);

    try renderUserTree(
        &context,
        context.id("narrow-parent"),
        context.id("narrow-child"),
    );

    try expectBoxEqual(
        .{ .x = 0, .y = 0, .width = 240, .height = 180 },
        context.getElementData(context.id("Clay__DebugView")).bounding_box,
    );
    try std.testing.expectEqual(
        @as(f32, 118),
        context.getElementData(context.id("Clay__DebugViewWarningsScrollPane")).bounding_box.height,
    );

    var command_index: i32 = 0;
    while (context.renderCommand(command_index)) |command| : (command_index += 1) {
        try std.testing.expect(command.bounding_box.width >= 0);
        try std.testing.expect(command.bounding_box.height >= 0);
    }
}

test "rejected inspector frames commit no selection collapse or close interaction" {
    const render_capacity: usize = 512;
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 1000, .height = 600 }, .{
        .max_render_command_count = render_capacity,
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);
    context.setDebugModeEnabled(true);

    const parent_id = context.id("rejected-inspector-parent");
    const child_id = context.id("rejected-inspector-child");
    const panel_id = context.id("Clay__DebugView");

    try context.setPointerState(.{ .x = -1, .y = -1 }, false);
    try context.setPointerState(.{ .x = -1, .y = -1 }, false);
    try renderClippedUserTree(&context, parent_id, child_id);
    const committed_selection = context.debug_selected_element_id;

    // Row selection is staged while the inspector is declared. A later
    // command-capacity failure must not publish it.
    try context.setPointerState(.{ .x = 650, .y = 65 }, true);
    context.options.max_render_command_count = 2;
    try std.testing.expectError(
        error.RenderCommandCapacityExceeded,
        renderClippedUserTree(&context, parent_id, child_id),
    );
    try std.testing.expect(context.isDebugModeEnabled());
    try std.testing.expectEqual(committed_selection, context.debug_selected_element_id);

    context.options.max_render_command_count = render_capacity;
    try context.setPointerState(.{ .x = -1, .y = -1 }, false);
    try context.setPointerState(.{ .x = -1, .y = -1 }, false);
    try renderClippedUserTree(&context, parent_id, child_id);
    try std.testing.expectEqual(committed_selection, context.debug_selected_element_id);

    // Collapse is discovered near the end of inspector declaration. Reject
    // the frame after that point, recover, and prove the child is still shown.
    const collapse_id = zlay.hash.stringWithOffset(
        zlay.String.literal("Clay__DebugView_CollapseElement"),
        parent_id.id,
        0,
    );
    const collapse = context.getElementData(collapse_id);
    try std.testing.expect(collapse.found);
    const collapse_point = zlay.Vector2{
        .x = collapse.bounding_box.x + collapse.bounding_box.width / 2,
        .y = collapse.bounding_box.y + collapse.bounding_box.height / 2,
    };
    try context.setPointerState(collapse_point, false);
    try context.setPointerState(collapse_point, false);
    try context.setPointerState(collapse_point, true);
    context.options.max_render_command_count = 2;
    try std.testing.expectError(
        error.RenderCommandCapacityExceeded,
        renderClippedUserTree(&context, parent_id, child_id),
    );
    try std.testing.expectEqual(committed_selection, context.debug_selected_element_id);

    context.options.max_render_command_count = render_capacity;
    try context.setPointerState(.{ .x = -1, .y = -1 }, false);
    try context.setPointerState(.{ .x = -1, .y = -1 }, false);
    try renderClippedUserTree(&context, parent_id, child_id);
    try std.testing.expect(containsElementRow(&context, child_id.id));

    // Inject the already-committed close hit directly to isolate the
    // frame-local closeRequested path from its between-frame hover callback.
    const header_id = zlay.hash.number(0, panel_id.id);
    const close_id = zlay.hash.number(2, header_id.id);
    try std.testing.expect(context.getElementData(close_id).found);
    context.pointer_over_ids.clearRetainingCapacity();
    try context.pointer_over_ids.append(context.allocator, close_id);
    context.pointer_info.state = .pressed_this_frame;

    context.options.max_render_command_count = 2;
    try std.testing.expectError(
        error.RenderCommandCapacityExceeded,
        renderClippedUserTree(&context, parent_id, child_id),
    );
    try std.testing.expect(context.isDebugModeEnabled());
    try std.testing.expectEqual(committed_selection, context.debug_selected_element_id);

    context.options.max_render_command_count = render_capacity;
    try context.setPointerState(.{ .x = -1, .y = -1 }, false);
    try context.setPointerState(.{ .x = -1, .y = -1 }, false);
    try renderClippedUserTree(&context, parent_id, child_id);
    try std.testing.expect(context.getElementData(panel_id).found);
    try std.testing.expect(containsElementRow(&context, child_id.id));
}
