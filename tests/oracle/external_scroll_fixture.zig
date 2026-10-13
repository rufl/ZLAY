const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const QueryState = struct {
    outer_id: u32,
    inner_id: u32,
    round: i32 = 0,
    count: usize = 0,
    calls: [4]i32 = .{ 0, 0, 0, 0 },
};

fn queryScrollOffset(element_id: u32, user_data: ?*anyopaque) zlay.Vector2 {
    const state: *QueryState = @ptrCast(@alignCast(user_data.?));
    var token: i32 = 0;
    var result = zlay.Vector2{};
    if (element_id == state.outer_id) {
        token = 1;
        result = if (state.round == 1) .{ .x = -9, .y = -11 } else .{ .x = -7, .y = -8 };
    } else if (element_id == state.inner_id) {
        token = 2;
        result = if (state.round == 1) .{ .x = -21, .y = -23 } else .{ .x = -17, .y = -18 };
    }
    if (state.count >= state.calls.len) contract.failLogOverflow("external-scroll query");
    state.calls[state.count] = token;
    state.count += 1;
    return result;
}

fn resetQuery(state: *QueryState, round: i32) void {
    state.round = round;
    state.count = 0;
    state.calls = .{ 0, 0, 0, 0 };
}

fn printQuery(out: *std.Io.Writer, label: []const u8, state: *const QueryState) !void {
    try out.print("query {s} round {d} count {d}", .{ label, state.round, state.count });
    for (state.calls[0..state.count]) |token| try out.print(" {d}", .{token});
    try out.writeByte('\n');
}

fn printScrollData(
    out: *std.Io.Writer,
    context: *zlay.Context,
    label: []const u8,
    name: []const u8,
    id: zlay.ElementId,
) !void {
    const data = context.getScrollContainerData(id);
    const position = if (data.scroll_position) |value| value.* else zlay.Vector2{};
    try out.print("data {s} {s} found {d} pos {d} {d} viewport {d} {d} content {d} {d} config {d} {d} {d} {d}\n", .{
        label,
        name,
        @intFromBool(data.found),
        contract.f32Bits(position.x),
        contract.f32Bits(position.y),
        contract.f32Bits(data.scroll_container_dimensions.width),
        contract.f32Bits(data.scroll_container_dimensions.height),
        contract.f32Bits(data.content_dimensions.width),
        contract.f32Bits(data.content_dimensions.height),
        @intFromBool(data.config.horizontal),
        @intFromBool(data.config.vertical),
        contract.f32Bits(data.config.child_offset.x),
        contract.f32Bits(data.config.child_offset.y),
    });
}

fn printPointerOver(out: *std.Io.Writer, context: *zlay.Context, label: []const u8) !void {
    const over = context.getPointerOverIds().items();
    try out.print("over {s} {d}", .{ label, over.len });
    for (over) |element_id| try out.print(" {d}", .{element_id.id});
    try out.writeByte('\n');
}

fn boxIsZero(box: zlay.BoundingBox) bool {
    return box.x == 0 and box.y == 0 and box.width == 0 and box.height == 0;
}

fn printCommands(out: *std.Io.Writer, label: []const u8, commands: zlay.RenderCommandArray) !bool {
    try out.print("commands {s} {d}\n", .{ label, commands.items().len });
    var valid = true;
    for (commands.items(), 0..) |command, index| {
        try out.print("command {s} {d} type {d} id {d} z {d} box {d} {d} {d} {d}", .{
            label,
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
                const color = command.render_data.rectangle.background_color;
                try out.print(" rect {d} {d} {d} {d}", .{ contract.f32Bits(color.r), contract.f32Bits(color.g), contract.f32Bits(color.b), contract.f32Bits(color.a) });
            },
            .scissor_start => {
                const clip = command.render_data.clip;
                try out.print(" clip {d} {d}", .{ @intFromBool(clip.horizontal), @intFromBool(clip.vertical) });
            },
            .scissor_end => {
                const control_default = boxIsZero(command.bounding_box) and command.z_index == 0;
                try out.print(" control-default {d}", .{@intFromBool(control_default)});
                valid = valid and control_default;
            },
            else => {},
        }
        try out.writeByte('\n');
    }
    return valid;
}

fn drawLayout(context: *zlay.Context) !zlay.RenderCommandArray {
    try context.beginLayout();
    try context.openElementWithIdUnconfigured(context.staticId("external-outer"));
    const outer_offset = context.getScrollOffset();
    try context.configureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(120), .height = zlay.fixed(100) },
            .padding = zlay.padding(5),
            .child_gap = 4,
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 16, .g = 30, .b = 48, .a = 255 },
        .clip = .{
            .horizontal = true,
            .vertical = true,
            .child_offset = outer_offset,
        },
    });
    try context.openElementWithIdUnconfigured(context.staticId("external-inner"));
    const inner_offset = context.getScrollOffset();
    try context.configureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(80), .height = zlay.fixed(60) },
            .padding = zlay.padding(2),
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 30, .g = 70, .b = 90, .a = 255 },
        .clip = .{
            .horizontal = true,
            .vertical = true,
            .child_offset = inner_offset,
        },
    });
    try context.openElementWithId(context.staticId("external-inner-content"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(160), .height = zlay.fixed(180) } },
        .background_color = .{ .r = 80, .g = 130, .b = 170, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();
    try context.openElementWithId(context.staticId("external-outer-tail"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(160), .height = zlay.fixed(120) } },
        .background_color = .{ .r = 120, .g = 75, .b = 45, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();
    return context.endLayout(0);
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 180, .height = 140 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();

    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const outer_id = context.staticId("external-outer");
    const inner_id = context.staticId("external-inner");
    var query_state = QueryState{ .outer_id = outer_id.id, .inner_id = inner_id.id };
    context.setQueryScrollOffsetFunction(queryScrollOffset, &query_state);

    var valid = true;
    var commands = try drawLayout(&context);
    valid = try printCommands(out, "internal-initial", commands) and valid;
    try printScrollData(out, &context, "internal-initial", "outer", outer_id);
    try printScrollData(out, &context, "internal-initial", "inner", inner_id);

    try context.setPointerState(.{ .x = 20, .y = 20 }, false);
    try printPointerOver(out, &context, "internal-nested");
    context.updateScrollContainers(false, .{ .x = -1, .y = -2 }, 0.016);
    try printScrollData(out, &context, "internal-nested-wheel", "outer", outer_id);
    try printScrollData(out, &context, "internal-nested-wheel", "inner", inner_id);

    commands = try drawLayout(&context);
    valid = try printCommands(out, "internal-scrolled", commands) and valid;
    try printScrollData(out, &context, "internal-scrolled", "outer", outer_id);
    try printScrollData(out, &context, "internal-scrolled", "inner", inner_id);

    context.setExternalScrollHandlingEnabled(true);
    resetQuery(&query_state, 1);
    commands = try drawLayout(&context);
    try printQuery(out, "external-first", &query_state);
    valid = try printCommands(out, "external-first", commands) and valid;
    try printScrollData(out, &context, "external-first", "outer", outer_id);
    try printScrollData(out, &context, "external-first", "inner", inner_id);

    try context.setPointerState(.{ .x = 20, .y = 20 }, false);
    try printPointerOver(out, &context, "external-nested");
    context.updateScrollContainers(false, .{ .x = -1, .y = -1 }, 0.016);
    try printScrollData(out, &context, "external-nested-wheel", "outer", outer_id);
    try printScrollData(out, &context, "external-nested-wheel", "inner", inner_id);

    resetQuery(&query_state, 2);
    commands = try drawLayout(&context);
    try printQuery(out, "external-second", &query_state);
    valid = try printCommands(out, "external-second", commands) and valid;
    try printScrollData(out, &context, "external-second", "outer", outer_id);
    try printScrollData(out, &context, "external-second", "inner", inner_id);

    try out.flush();
    if (!valid) return error.InvalidExternalScrollFixture;
}
