const std = @import("std");

const expected_c_hex = "2c72689cb3f65e800e9da3a0b28dd250e88d3ca8649de562c94c41e523f9fc15";
const expected_zig_hex = "e9595acf986173933c453d32a64981d6cb5f59a74e33aab98cd2fa2bf2d49cb9";

fn readFile(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(64 * 1024));
}

fn expectDigest(contents: []const u8, expected_hex: []const u8, label: []const u8) !void {
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &actual, .{});
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    if (!std.mem.eql(u8, &expected, &actual)) {
        std.debug.print("{s} safety-divergence trace changed\nexpected: {s}\nactual:   {x}\n", .{
            label,
            expected_hex,
            actual,
        });
        return error.ReviewedDivergenceChanged;
    }
}

fn expectContains(contents: []const u8, needle: []const u8, label: []const u8) !void {
    if (std.mem.indexOf(u8, contents, needle) != null) return;
    std.debug.print("{s} safety-divergence trace is missing marker: {s}\n", .{ label, needle });
    return error.ReviewedDivergenceMarkerMissing;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;

    const c_output = try readFile(init, allocator, args[1]);
    const zig_output = try readFile(init, allocator, args[2]);
    try expectDigest(c_output, expected_c_hex, "pinned C");
    try expectDigest(zig_output, expected_zig_hex, "native Zig");
    if (std.mem.eql(u8, c_output, zig_output)) return error.ExpectedReviewedDivergence;

    try expectContains(c_output, "malformed depth 3 errors 1 8 residual 3", "pinned C");
    try expectContains(zig_output, "malformed depth 3 errors 1 8 residual 0", "native Zig");
    try expectContains(c_output, "recovery depth 3 errors 0 residual 0", "pinned C");
    try expectContains(zig_output, "recovery depth 3 errors 0 residual 0", "native Zig");
    try expectContains(c_output, "floating-clip errors 0 leaked-clips 1", "pinned C");
    try expectContains(zig_output, "floating-clip errors 0 leaked-clips 0", "native Zig");
    try expectContains(c_output, "command negative-slice 1 type 3", "pinned C");
    try expectContains(c_output, "text -1", "pinned C");
    if (std.mem.indexOf(u8, zig_output, "text -1") != null) {
        return error.NativeNegativeSliceRegression;
    }
    try expectContains(c_output, "negative-slice-recovery errors 0", "pinned C");
    try expectContains(zig_output, "negative-slice-recovery errors 0", "native Zig");
}
