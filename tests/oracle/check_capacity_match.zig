const std = @import("std");
const manifest = @import("ordinary_manifest.zig");

fn readFile(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(64 * 1024));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;
    const entry = manifest.entryForPaths(args[1], args[2]) orelse return error.UnknownOracleFixture;

    const c_output = try readFile(init, allocator, args[1]);
    const zig_output = try readFile(init, allocator, args[2]);
    try manifest.verifyTrace(entry, c_output, "pinned C");
    try manifest.verifyTrace(entry, zig_output, "native Zig");
    if (!std.mem.eql(u8, c_output, zig_output)) return error.CapacityOracleMismatch;
}
