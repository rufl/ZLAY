//! Allocation-free dispatch and structural validation for renderer backends.
//!
//! `RenderData` is an untagged union. This adapter is the small, safe bridge
//! between ZLAY's externally tagged command stream and a concrete renderer:
//! it reads only the payload selected by `command_type`, validates clip and
//! overlay scope balance before invoking the backend, and preserves command
//! order exactly.

const std = @import("std");
const types = @import("types.zig");

pub const Error = error{
    InvalidCommandArray,
    ScissorScopeUnderflow,
    OverlayScopeUnderflow,
    UnclosedScissorScope,
    UnclosedOverlayScope,
};

pub const Stats = struct {
    none: usize = 0,
    rectangles: usize = 0,
    borders: usize = 0,
    text: usize = 0,
    images: usize = 0,
    scissor_starts: usize = 0,
    scissor_ends: usize = 0,
    overlay_starts: usize = 0,
    overlay_ends: usize = 0,
    custom: usize = 0,
    max_scissor_depth: usize = 0,
    max_overlay_depth: usize = 0,

    pub fn commandCount(self: Stats) usize {
        return self.none +
            self.rectangles +
            self.borders +
            self.text +
            self.images +
            self.scissor_starts +
            self.scissor_ends +
            self.overlay_starts +
            self.overlay_ends +
            self.custom;
    }
};

/// Validate the two independent renderer scope stacks and collect command
/// statistics. Overlay and scissor scopes may overlap, as they do in Clay's
/// own command order, while each scope kind must remain balanced.
pub fn validate(commands: []const types.RenderCommand) Error!Stats {
    var stats = Stats{};
    var scissor_depth: usize = 0;
    var overlay_depth: usize = 0;

    for (commands) |command| switch (command.command_type) {
        .none => stats.none += 1,
        .rectangle => stats.rectangles += 1,
        .border => stats.borders += 1,
        .text => stats.text += 1,
        .image => stats.images += 1,
        .custom => stats.custom += 1,
        .scissor_start => {
            stats.scissor_starts += 1;
            scissor_depth += 1;
            stats.max_scissor_depth = @max(stats.max_scissor_depth, scissor_depth);
        },
        .scissor_end => {
            if (scissor_depth == 0) return error.ScissorScopeUnderflow;
            stats.scissor_ends += 1;
            scissor_depth -= 1;
        },
        .overlay_color_start => {
            stats.overlay_starts += 1;
            overlay_depth += 1;
            stats.max_overlay_depth = @max(stats.max_overlay_depth, overlay_depth);
        },
        .overlay_color_end => {
            if (overlay_depth == 0) return error.OverlayScopeUnderflow;
            stats.overlay_ends += 1;
            overlay_depth -= 1;
        },
    };

    if (scissor_depth != 0) return error.UnclosedScissorScope;
    if (overlay_depth != 0) return error.UnclosedOverlayScope;
    return stats;
}

/// Validate a borrowed `RenderCommandArray` without silently accepting a
/// malformed length/capacity tuple.
pub fn validateArray(commands: types.RenderCommandArray) Error!Stats {
    return validate(try checkedItems(commands));
}

/// Dispatch a validated stream to a concrete backend. `Backend` must provide
/// the ten methods used below, each returning an error union with `void` as
/// its payload. Payload-bearing methods receive only the active union field.
/// Validation is a complete first pass, so malformed scope structure cannot
/// partially mutate the backend.
pub fn consume(
    comptime Backend: type,
    backend: *Backend,
    commands: []const types.RenderCommand,
) anyerror!Stats {
    const stats = try validate(commands);

    for (commands) |command| switch (command.command_type) {
        .none => try backend.none(command),
        .rectangle => try backend.rectangle(command, command.render_data.rectangle),
        .border => try backend.border(command, command.render_data.border),
        .text => try backend.text(command, command.render_data.text),
        .image => try backend.image(command, command.render_data.image),
        .custom => try backend.custom(command, command.render_data.custom),
        .scissor_start => try backend.scissorStart(command, command.render_data.clip),
        .scissor_end => try backend.scissorEnd(command),
        .overlay_color_start => try backend.overlayColorStart(command, command.render_data.overlay_color),
        .overlay_color_end => try backend.overlayColorEnd(command),
    };

    return stats;
}

pub fn consumeArray(
    comptime Backend: type,
    backend: *Backend,
    commands: types.RenderCommandArray,
) anyerror!Stats {
    return consume(Backend, backend, try checkedItems(commands));
}

fn checkedItems(commands: types.RenderCommandArray) Error![]const types.RenderCommand {
    if (commands.capacity < 0 or commands.length < 0 or commands.length > commands.capacity) {
        return error.InvalidCommandArray;
    }
    const length: usize = @intCast(commands.length);
    if (length > commands.internal_array.len) return error.InvalidCommandArray;
    return commands.internal_array[0..length];
}

const Probe = struct {
    order: [10]types.RenderCommandType = undefined,
    length: usize = 0,
    image_token: *u8,
    custom_token: *u8,

    fn record(self: *Probe, command_type: types.RenderCommandType) !void {
        if (self.length >= self.order.len) return error.TooManyCommands;
        self.order[self.length] = command_type;
        self.length += 1;
    }

    fn none(self: *Probe, command: types.RenderCommand) !void {
        try std.testing.expectEqual(types.RenderCommandType.none, command.command_type);
        try self.record(.none);
    }

    fn rectangle(self: *Probe, command: types.RenderCommand, data: types.RectangleRenderData) !void {
        try std.testing.expectEqual(types.RenderCommandType.rectangle, command.command_type);
        try std.testing.expectEqual(@as(f32, 11), data.background_color.r);
        try self.record(.rectangle);
    }

    fn border(self: *Probe, command: types.RenderCommand, data: types.BorderRenderData) !void {
        try std.testing.expectEqual(types.RenderCommandType.border, command.command_type);
        try std.testing.expectEqual(@as(u16, 7), data.width.left);
        try self.record(.border);
    }

    fn text(self: *Probe, command: types.RenderCommand, data: types.TextRenderData) !void {
        try std.testing.expectEqual(types.RenderCommandType.text, command.command_type);
        try std.testing.expectEqualStrings("payload", data.string_contents.asSlice());
        try self.record(.text);
    }

    fn image(self: *Probe, command: types.RenderCommand, data: types.ImageRenderData) !void {
        try std.testing.expectEqual(types.RenderCommandType.image, command.command_type);
        try std.testing.expectEqual(@intFromPtr(self.image_token), @intFromPtr(data.image_data.?));
        try self.record(.image);
    }

    fn custom(self: *Probe, command: types.RenderCommand, data: types.CustomRenderData) !void {
        try std.testing.expectEqual(types.RenderCommandType.custom, command.command_type);
        try std.testing.expectEqual(@intFromPtr(self.custom_token), @intFromPtr(data.custom_data.?));
        try self.record(.custom);
    }

    fn scissorStart(self: *Probe, command: types.RenderCommand, data: types.ClipRenderData) !void {
        try std.testing.expectEqual(types.RenderCommandType.scissor_start, command.command_type);
        try std.testing.expect(data.horizontal and data.vertical);
        try self.record(.scissor_start);
    }

    fn scissorEnd(self: *Probe, command: types.RenderCommand) !void {
        try std.testing.expectEqual(types.RenderCommandType.scissor_end, command.command_type);
        try self.record(.scissor_end);
    }

    fn overlayColorStart(self: *Probe, command: types.RenderCommand, data: types.OverlayColorRenderData) !void {
        try std.testing.expectEqual(types.RenderCommandType.overlay_color_start, command.command_type);
        try std.testing.expectEqual(@as(f32, 99), data.color.b);
        try self.record(.overlay_color_start);
    }

    fn overlayColorEnd(self: *Probe, command: types.RenderCommand) !void {
        try std.testing.expectEqual(types.RenderCommandType.overlay_color_end, command.command_type);
        try self.record(.overlay_color_end);
    }
};

test "adapter dispatches every command through only its active payload" {
    var image_token: u8 = 1;
    var custom_token: u8 = 2;
    const commands = [_]types.RenderCommand{
        .{ .command_type = .none },
        .{ .render_data = .{ .overlay_color = .{ .color = .{ .b = 99 } } }, .command_type = .overlay_color_start },
        .{ .render_data = .{ .image = .{ .image_data = &image_token } }, .command_type = .image },
        .{ .render_data = .{ .custom = .{ .custom_data = &custom_token } }, .command_type = .custom },
        .{ .render_data = .{ .clip = .{ .horizontal = true, .vertical = true } }, .command_type = .scissor_start },
        .{ .render_data = .{ .rectangle = .{ .background_color = .{ .r = 11 } } }, .command_type = .rectangle },
        .{ .render_data = .{ .text = .{ .string_contents = types.StringSlice.fromSlice("payload") } }, .command_type = .text },
        .{ .render_data = .{ .border = .{ .width = .{ .left = 7 } } }, .command_type = .border },
        // Clay scopes overlap independently: the overlay closes before the
        // scissor even though it opened first.
        .{ .command_type = .overlay_color_end },
        .{ .command_type = .scissor_end },
    };
    var probe = Probe{ .image_token = &image_token, .custom_token = &custom_token };

    const stats = try consume(Probe, &probe, &commands);

    try std.testing.expectEqual(commands.len, stats.commandCount());
    try std.testing.expectEqual(@as(usize, 1), stats.max_scissor_depth);
    try std.testing.expectEqual(@as(usize, 1), stats.max_overlay_depth);
    try std.testing.expectEqualSlices(types.RenderCommandType, &.{
        .none,
        .overlay_color_start,
        .image,
        .custom,
        .scissor_start,
        .rectangle,
        .text,
        .border,
        .overlay_color_end,
        .scissor_end,
    }, probe.order[0..probe.length]);
}

const CountingBackend = struct {
    calls: usize = 0,

    fn called(self: *CountingBackend) !void {
        self.calls += 1;
    }

    fn none(self: *CountingBackend, _: types.RenderCommand) !void {
        try self.called();
    }
    fn rectangle(self: *CountingBackend, _: types.RenderCommand, _: types.RectangleRenderData) !void {
        try self.called();
    }
    fn border(self: *CountingBackend, _: types.RenderCommand, _: types.BorderRenderData) !void {
        try self.called();
    }
    fn text(self: *CountingBackend, _: types.RenderCommand, _: types.TextRenderData) !void {
        try self.called();
    }
    fn image(self: *CountingBackend, _: types.RenderCommand, _: types.ImageRenderData) !void {
        try self.called();
    }
    fn custom(self: *CountingBackend, _: types.RenderCommand, _: types.CustomRenderData) !void {
        try self.called();
    }
    fn scissorStart(self: *CountingBackend, _: types.RenderCommand, _: types.ClipRenderData) !void {
        try self.called();
    }
    fn scissorEnd(self: *CountingBackend, _: types.RenderCommand) !void {
        try self.called();
    }
    fn overlayColorStart(self: *CountingBackend, _: types.RenderCommand, _: types.OverlayColorRenderData) !void {
        try self.called();
    }
    fn overlayColorEnd(self: *CountingBackend, _: types.RenderCommand) !void {
        try self.called();
    }
};

test "scope errors are rejected before backend mutation" {
    var backend = CountingBackend{};

    const scissor_underflow = [_]types.RenderCommand{.{ .command_type = .scissor_end }};
    try std.testing.expectError(error.ScissorScopeUnderflow, consume(CountingBackend, &backend, &scissor_underflow));
    try std.testing.expectEqual(@as(usize, 0), backend.calls);

    const overlay_underflow = [_]types.RenderCommand{.{ .command_type = .overlay_color_end }};
    try std.testing.expectError(error.OverlayScopeUnderflow, consume(CountingBackend, &backend, &overlay_underflow));
    try std.testing.expectEqual(@as(usize, 0), backend.calls);

    const unclosed_scissor = [_]types.RenderCommand{
        .{ .render_data = .{ .clip = .{} }, .command_type = .scissor_start },
        .{ .command_type = .rectangle },
    };
    try std.testing.expectError(error.UnclosedScissorScope, consume(CountingBackend, &backend, &unclosed_scissor));
    try std.testing.expectEqual(@as(usize, 0), backend.calls);

    const unclosed_overlay = [_]types.RenderCommand{
        .{ .render_data = .{ .overlay_color = .{} }, .command_type = .overlay_color_start },
        .{ .command_type = .rectangle },
    };
    try std.testing.expectError(error.UnclosedOverlayScope, consume(CountingBackend, &backend, &unclosed_overlay));
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
}

test "nested scopes report independent maximum depth" {
    const commands = [_]types.RenderCommand{
        .{ .render_data = .{ .clip = .{} }, .command_type = .scissor_start },
        .{ .render_data = .{ .clip = .{} }, .command_type = .scissor_start },
        .{ .render_data = .{ .overlay_color = .{} }, .command_type = .overlay_color_start },
        .{ .render_data = .{ .overlay_color = .{} }, .command_type = .overlay_color_start },
        .{ .command_type = .scissor_end },
        .{ .command_type = .overlay_color_end },
        .{ .command_type = .overlay_color_end },
        .{ .command_type = .scissor_end },
    };
    const stats = try validate(&commands);
    try std.testing.expectEqual(@as(usize, 2), stats.max_scissor_depth);
    try std.testing.expectEqual(@as(usize, 2), stats.max_overlay_depth);
}

test "command arrays reject every malformed metadata shape before dispatch" {
    var storage = [_]types.RenderCommand{.{}};

    try std.testing.expectError(error.InvalidCommandArray, validateArray(.{
        .capacity = -1,
        .length = 0,
        .internal_array = &storage,
    }));
    try std.testing.expectError(error.InvalidCommandArray, validateArray(.{
        .capacity = 0,
        .length = -1,
        .internal_array = &storage,
    }));
    try std.testing.expectError(error.InvalidCommandArray, validateArray(.{
        .capacity = 1,
        .length = 2,
        .internal_array = &storage,
    }));
    try std.testing.expectError(error.InvalidCommandArray, validateArray(.{
        .capacity = 2,
        .length = 2,
        .internal_array = &storage,
    }));

    var backend = CountingBackend{};
    try std.testing.expectError(error.InvalidCommandArray, consumeArray(CountingBackend, &backend, .{
        .capacity = 0,
        .length = 1,
        .internal_array = &storage,
    }));
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
}

test "logical command capacity may exceed the currently borrowed backing" {
    var storage = [_]types.RenderCommand{.{ .command_type = .none }};
    const stats = try validateArray(.{
        .capacity = 32,
        .length = 1,
        .internal_array = &storage,
    });

    try std.testing.expectEqual(@as(usize, 1), stats.none);
    try std.testing.expectEqual(@as(usize, 1), stats.commandCount());
}
