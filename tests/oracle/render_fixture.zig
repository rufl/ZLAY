const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

var image_payload: u8 = 0;
var custom_payload: u8 = 0;
var outer_user: u8 = 0;
var inner_user: u8 = 0;
var image_user: u8 = 0;
var custom_user: u8 = 0;
var row_user: u8 = 0;
var child_a_user: u8 = 0;
var child_b_user: u8 = 0;
var offscreen_user: u8 = 0;

fn opaquePointer(pointer: *u8) *anyopaque {
    return @ptrCast(pointer);
}

fn pointerToken(pointer_optional: ?*anyopaque) i32 {
    const pointer = pointer_optional orelse return 0;
    if (pointer == opaquePointer(&image_payload)) return 101;
    if (pointer == opaquePointer(&custom_payload)) return 102;
    if (pointer == opaquePointer(&outer_user)) return 201;
    if (pointer == opaquePointer(&inner_user)) return 202;
    if (pointer == opaquePointer(&image_user)) return 203;
    if (pointer == opaquePointer(&custom_user)) return 204;
    if (pointer == opaquePointer(&row_user)) return 205;
    if (pointer == opaquePointer(&child_a_user)) return 206;
    if (pointer == opaquePointer(&child_b_user)) return 207;
    if (pointer == opaquePointer(&offscreen_user)) return 208;
    return -1;
}

fn boxIsZero(box: zlay.BoundingBox) bool {
    return box.x == 0 and box.y == 0 and box.width == 0 and box.height == 0;
}

// Pointer payloads are normalized to stable integer tokens. Closing controls
// inspect only fields outside RenderData, mirroring the untagged C union rule.
fn printCommand(
    stdout: *std.Io.Writer,
    frame: usize,
    index: usize,
    command: zlay.RenderCommand,
) !bool {
    try stdout.print("frame {d} command {d} type {d} id {d} z {d} box {x:0>8} {x:0>8} {x:0>8} {x:0>8} user {d}", .{
        frame,
        index,
        @backingInt(command.command_type),
        command.id,
        command.z_index,
        contract.f32Bits(command.bounding_box.x),
        contract.f32Bits(command.bounding_box.y),
        contract.f32Bits(command.bounding_box.width),
        contract.f32Bits(command.bounding_box.height),
        pointerToken(command.user_data),
    });

    var valid = true;
    switch (command.command_type) {
        .rectangle => {
            const rectangle = command.render_data.rectangle;
            try stdout.print(" rect {x:0>8} {x:0>8} {x:0>8} {x:0>8} radius {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
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
            try stdout.print(" border {x:0>8} {x:0>8} {x:0>8} {x:0>8} radius {x:0>8} {x:0>8} {x:0>8} {x:0>8} width {d} {d} {d} {d} {d}", .{
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
        .image => {
            const image = command.render_data.image;
            try stdout.print(" image {x:0>8} {x:0>8} {x:0>8} {x:0>8} radius {x:0>8} {x:0>8} {x:0>8} {x:0>8} data {d}", .{
                contract.f32Bits(image.background_color.r),
                contract.f32Bits(image.background_color.g),
                contract.f32Bits(image.background_color.b),
                contract.f32Bits(image.background_color.a),
                contract.f32Bits(image.corner_radius.top_left),
                contract.f32Bits(image.corner_radius.top_right),
                contract.f32Bits(image.corner_radius.bottom_left),
                contract.f32Bits(image.corner_radius.bottom_right),
                pointerToken(image.image_data),
            });
        },
        .custom => {
            const custom = command.render_data.custom;
            try stdout.print(" custom {x:0>8} {x:0>8} {x:0>8} {x:0>8} radius {x:0>8} {x:0>8} {x:0>8} {x:0>8} data {d}", .{
                contract.f32Bits(custom.background_color.r),
                contract.f32Bits(custom.background_color.g),
                contract.f32Bits(custom.background_color.b),
                contract.f32Bits(custom.background_color.a),
                contract.f32Bits(custom.corner_radius.top_left),
                contract.f32Bits(custom.corner_radius.top_right),
                contract.f32Bits(custom.corner_radius.bottom_left),
                contract.f32Bits(custom.corner_radius.bottom_right),
                pointerToken(custom.custom_data),
            });
        },
        .scissor_start => {
            const clip = command.render_data.clip;
            try stdout.print(" clip {d} {d}", .{ @intFromBool(clip.horizontal), @intFromBool(clip.vertical) });
        },
        .overlay_color_start => {
            const color = command.render_data.overlay_color.color;
            const control_default = boxIsZero(command.bounding_box) and command.z_index == 0;
            try stdout.print(" overlay {x:0>8} {x:0>8} {x:0>8} {x:0>8} control-default {d}", .{
                contract.f32Bits(color.r),
                contract.f32Bits(color.g),
                contract.f32Bits(color.b),
                contract.f32Bits(color.a),
                @intFromBool(control_default),
            });
            valid = control_default;
        },
        .scissor_end, .overlay_color_end => {
            const control_default = boxIsZero(command.bounding_box) and command.z_index == 0;
            try stdout.print(" control-default {d}", .{@intFromBool(control_default)});
            valid = control_default;
        },
        else => {},
    }
    try stdout.writeByte('\n');
    return valid;
}

fn declareLayout(context: *zlay.Context) !void {
    try context.openElementWithId(context.staticId("render-outer"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(120), .height = zlay.fixed(90) },
            .padding = zlay.padding(2),
            .child_gap = 3,
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 12, .g = 24, .b = 36, .a = 255 },
        .overlay_color = .{ .r = 80, .g = 40, .b = 120, .a = 96 },
        .clip = .{ .horizontal = true, .vertical = true },
        .user_data = opaquePointer(&outer_user),
    });
    try context.openElementWithId(context.staticId("render-inner"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(80), .height = zlay.fixed(32) },
            .padding = zlay.padding(1),
            .child_gap = 4,
        },
        .background_color = .{ .r = 20, .g = 50, .b = 70, .a = 255 },
        .clip = .{ .horizontal = true },
        .user_data = opaquePointer(&inner_user),
    });
    try context.openElementWithId(context.staticId("render-image"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(20), .height = zlay.fixed(16) } },
        .background_color = .{ .r = 200, .g = 180, .b = 30, .a = 128 },
        .corner_radius = zlay.cornerRadius(2),
        .image = .{ .image_data = opaquePointer(&image_payload) },
        .user_data = opaquePointer(&image_user),
    });
    try context.closeElement();
    try context.openElementWithId(context.staticId("render-custom"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(22), .height = zlay.fixed(16) } },
        .background_color = .{ .r = 40, .g = 160, .b = 100, .a = 192 },
        .corner_radius = .{ .top_left = 1, .top_right = 2, .bottom_left = 3, .bottom_right = 4 },
        .custom = .{ .custom_data = opaquePointer(&custom_payload) },
        .user_data = opaquePointer(&custom_user),
    });
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.staticId("render-row"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(80), .height = zlay.fixed(28) },
            .padding = zlay.padding(1),
            .child_gap = 7,
        },
        .corner_radius = zlay.cornerRadius(5),
        .border = .{
            .color = .{ .r = 220, .g = 70, .b = 40, .a = 255 },
            .width = .{ .left = 1, .right = 2, .top = 3, .bottom = 4, .between_children = 3 },
        },
        .user_data = opaquePointer(&row_user),
    });
    try context.openElementWithId(context.staticId("render-child-a"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(12), .height = zlay.fixed(10) } },
        .background_color = .{ .r = 180, .g = 20, .b = 30, .a = 255 },
        .corner_radius = zlay.cornerRadius(1),
        .user_data = opaquePointer(&child_a_user),
    });
    try context.closeElement();
    try context.openElementWithId(context.staticId("render-child-b"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(14), .height = zlay.fixed(10) } },
        .background_color = .{ .r = 30, .g = 60, .b = 190, .a = 255 },
        .user_data = opaquePointer(&child_b_user),
    });
    try context.closeElement();
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.staticId("render-offscreen"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(20), .height = zlay.fixed(12) } },
        .background_color = .{ .r = 250, .g = 90, .b = 20, .a = 255 },
        .floating = .{
            .offset = .{ .x = 220, .y = 8 },
            .z_index = 7,
            .attach_to = .root,
        },
        .user_data = opaquePointer(&offscreen_user),
    });
    try context.closeElement();
}

fn runFrame(context: *zlay.Context, stdout: *std.Io.Writer, frame: usize, culling_enabled: bool) !bool {
    context.setCullingEnabled(culling_enabled);
    try context.beginLayout();
    try declareLayout(context);
    const commands = try context.endLayout(0);
    const offscreen_id = context.staticId("render-offscreen");
    const offscreen = context.getElementData(offscreen_id);
    var offscreen_commands: usize = 0;
    for (commands.items()) |command| {
        if (command.id == offscreen_id.id and command.command_type == .rectangle) offscreen_commands += 1;
    }

    try stdout.print("frame {d} summary commands {d} offscreen-found {d} box {x:0>8} {x:0>8} {x:0>8} {x:0>8} offscreen-commands {d}\n", .{
        frame,
        commands.items().len,
        @intFromBool(offscreen.found),
        contract.f32Bits(offscreen.bounding_box.x),
        contract.f32Bits(offscreen.bounding_box.y),
        contract.f32Bits(offscreen.bounding_box.width),
        contract.f32Bits(offscreen.bounding_box.height),
        offscreen_commands,
    });

    var valid = offscreen.found and offscreen_commands == @as(usize, if (culling_enabled) 0 else 1);
    for (commands.items(), 0..) |command, index| {
        if (!try printCommand(stdout, frame, index, command)) valid = false;
    }
    return valid;
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 180, .height = 110 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();

    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const valid = try runFrame(&context, stdout, 0, true) and try runFrame(&context, stdout, 1, false);
    try stdout.flush();
    if (!valid) return error.InvalidRenderFixture;
}
