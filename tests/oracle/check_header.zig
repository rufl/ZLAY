const std = @import("std");

const expected_hex = "54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;

    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    const contents = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));

    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &actual, .{});
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    if (!std.mem.eql(u8, &expected, &actual)) {
        std.debug.print("pinned clay.h SHA-256 mismatch\nexpected: {s}\nactual:   {x}\n", .{ expected_hex, actual });
        return error.UpstreamHeaderDigestMismatch;
    }
}
