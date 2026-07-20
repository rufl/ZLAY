const std = @import("std");
const zlay = @import("zlay");

fn printText(out: *std.Io.Writer, name: []const u8, bytes: []const u8, config: zlay.TextElementConfig) !void {
    try out.print("text {s} {d}\n", .{ name, zlay.hash.textWithConfig(zlay.String.fromSlice(bytes), config) });
}

pub fn main(init: std.process.Init) !void {
    var sequence: [64]u8 = undefined;
    for (&sequence, 0..) |*byte, index| byte.* = @intCast(index);
    const lengths = [_]usize{ 0, 1, 4, 7, 8, 9, 15, 16, 17, 24, 31, 32, 64 };
    const binary = [_]u8{ 0, 1, 2, 3, 127, 128, 255 };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    for (lengths) |length| {
        try out.print("data {d} {d}\n", .{ length, zlay.hash.data(sequence[0..length]) });
    }
    try out.print("binary {d}\n", .{zlay.hash.data(&binary)});
    try printText(out, "empty", "", .{});
    try printText(out, "clay", "Clay", .{});
    try printText(out, "styled", "Clay", .{
        .font_id = 7,
        .font_size = 24,
        .letter_spacing = 3,
        .line_height = 40,
        .wrap_mode = .none,
        .text_alignment = .right,
    });
    try printText(out, "binary", &binary, .{
        .font_id = 7,
        .font_size = 24,
        .letter_spacing = 3,
    });
    try out.flush();
}
