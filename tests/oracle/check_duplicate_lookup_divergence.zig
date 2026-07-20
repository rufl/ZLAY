const std = @import("std");

const expected_c_hex = "43b6309b69a05eb1f7ef13a0c572fd0d1887090899841399251614eb406ae95b";
const expected_zig_hex = "8f0c6ea1d770eec89e9b106831b741990c0f84391d687777836bc4b7035a4436";

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
        std.debug.print("{s} reviewed-divergence trace changed\nexpected: {s}\nactual:   {x}\n", .{
            label,
            expected_hex,
            actual,
        });
        return error.ReviewedDivergenceChanged;
    }
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
    if (!std.mem.endsWith(u8, c_output, "errors 1 4\n") or
        !std.mem.endsWith(u8, zig_output, "errors 1 4\n"))
    {
        return error.DuplicateDiagnosticContractChanged;
    }
}
