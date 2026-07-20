const std = @import("std");

const expected_c_hex = "a0cfbe4de2c7c699ded2e398e37f74b4410f4426ab60cd10d0c8a57d495c1fce";
const expected_zig_hex = "c14cda9a8341c3ed8455376e77837715ce02b168f016609c495bb34def3e5988";

fn readFile(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(16 * 1024));
}

fn expectDigest(contents: []const u8, expected_hex: []const u8, label: []const u8) !void {
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &actual, .{});
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    if (std.mem.eql(u8, &expected, &actual)) return;
    std.debug.print("{s} no-open API trace changed\nexpected: {s}\nactual:   {x}\n", .{
        label,
        expected_hex,
        actual,
    });
    return error.ReviewedDivergenceChanged;
}

fn expectContains(contents: []const u8, needle: []const u8, label: []const u8) !void {
    if (std.mem.indexOf(u8, contents, needle) != null) return;
    std.debug.print("{s} no-open API trace is missing marker: {s}\n", .{ label, needle });
    return error.ReviewedDivergenceMarkerMissing;
}

fn recoverySuffix(contents: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, contents, "recovery element ") orelse
        return error.RecoveryTraceMissing;
    const end = std.mem.indexOfPos(u8, contents, start, "errors-total ") orelse
        return error.RecoveryTraceMissing;
    return contents[start..end];
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

    try expectContains(c_output, "probe before-first-begin open 0 open-error 0", "pinned C");
    try expectContains(c_output, "errors 8 7 7 7 7 7 7 7 7", "pinned C");
    try expectContains(c_output, "probe after-end open 2268583112 open-error 0", "pinned C");
    try expectContains(zig_output, "probe before-first-begin open 0 open-error 1", "native Zig");
    try expectContains(zig_output, "probe after-end open 0 open-error 1", "native Zig");
    try expectContains(zig_output, "on-hover-error 1", "native Zig");

    const c_recovery = try recoverySuffix(c_output);
    const zig_recovery = try recoverySuffix(zig_output);
    if (!std.mem.eql(u8, c_recovery, zig_recovery)) {
        std.debug.print("no-open recovery traces differ\nC:   {s}\nZig: {s}\n", .{
            c_recovery,
            zig_recovery,
        });
        return error.UnexpectedRecoveryDivergence;
    }
}
