const std = @import("std");

const ReviewedCase = struct {
    label: []const u8,
    c_hex: []const u8,
    zig_hex: []const u8,
};

const reviewed_cases = [_]ReviewedCase{
    .{
        .label = "invalid render-command access",
        .c_hex = "82c645c516430159c884bd70f030512c1f1ece0403295e05e1ad79e6a651b7d3",
        .zig_hex = "2f05c3fd8c2e6d8317c9b5c0afc4d19df88abbd49241a02ccad55be30da66e9a",
    },
    .{
        .label = "element capacity",
        .c_hex = "4db44bb96d6a07c7488ec0ac2e36f794f6d7870e952bee7e7116f17cb34bd7bb",
        .zig_hex = "5bef0ddca404fc2368fdaade89d75e2b4eaac48c09840c8c0e01f8d85dae738c",
    },
    .{
        .label = "text capacity",
        .c_hex = "07928a1158e9be60d8584089cf9e091bbbb6f98e8bd1242b32d179d046d7016d",
        .zig_hex = "6f15a9fb805f77a83d1e7f3f6b819803523ad6db76ed13696f70920a78a5256f",
    },
    .{
        .label = "render scope capacity",
        .c_hex = "7bce37f8c37b5dc0b1c5f6c6a8890ead8cb5ad209f09d8175ed8753bd0fa5380",
        .zig_hex = "870aa5b633584102529b0959c59041bd05276dc23180337a03c6ca1462d0a395",
    },
};

fn readFile(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(64 * 1024));
}

fn expectDigest(contents: []const u8, expected_hex: []const u8, label: []const u8, side: []const u8) !void {
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &actual, .{});
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    if (!std.mem.eql(u8, &expected, &actual)) {
        std.debug.print("{s} {s} reviewed-divergence trace changed\nexpected: {s}\nactual:   {x}\n", .{
            label,
            side,
            expected_hex,
            actual,
        });
        return error.ReviewedDivergenceChanged;
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 1 + reviewed_cases.len * 2) return error.InvalidArguments;

    for (reviewed_cases, 0..) |reviewed, index| {
        const c_output = try readFile(init, allocator, args[1 + index * 2]);
        const zig_output = try readFile(init, allocator, args[2 + index * 2]);
        try expectDigest(c_output, reviewed.c_hex, reviewed.label, "pinned C");
        try expectDigest(zig_output, reviewed.zig_hex, reviewed.label, "native Zig");
        if (std.mem.eql(u8, c_output, zig_output)) return error.ExpectedReviewedDivergence;
    }
}
