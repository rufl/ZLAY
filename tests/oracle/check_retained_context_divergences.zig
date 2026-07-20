const std = @import("std");

const expected_c_hex = "dc7c359c9883c8fd748104d935554ec715dc6a4dddec85be8cb859e6fd047300";
const expected_zig_hex = "5e3e3214cece4e880b5d868624a326a7a675527844bc3e921211c4da028812b0";

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
        std.debug.print("{s} retained-context trace changed\nexpected: {s}\nactual:   {x}\n", .{
            label,
            expected_hex,
            actual,
        });
        return error.ReviewedDivergenceChanged;
    }
}

fn expectContains(contents: []const u8, needle: []const u8, label: []const u8) !void {
    if (std.mem.indexOf(u8, contents, needle) != null) return;
    std.debug.print("{s} retained-context trace is missing marker: {s}\n", .{ label, needle });
    return error.ReviewedDivergenceMarkerMissing;
}

fn callbackOwnerRecord(line: []const u8) bool {
    return std.mem.eql(u8, line, "callback-owner A install-order A-then-B function B data A calls 2") or
        std.mem.eql(u8, line, "callback-owner B install-order A-then-B function B data B calls 2") or
        std.mem.eql(u8, line, "callback-owner A install-order A-then-B function A data A calls 2") or
        std.mem.eql(u8, line, "query-callback-owner A install-order A-then-B function B data A calls 1") or
        std.mem.eql(u8, line, "query-callback-owner B install-order A-then-B function B data B calls 1") or
        std.mem.eql(u8, line, "query-callback-owner A install-order A-then-B function A data A calls 1");
}

fn debugGlobalOwnerRecord(line: []const u8) bool {
    return std.mem.eql(u8, line, "debug-global-owner B after-A-set width 321 color 1067450368 1075838976 1081081856 1082130432") or
        std.mem.eql(u8, line, "debug-global-owner B after-A-set width 400 color 1126694912 1115947008 1105199104 1120403456");
}

fn intentionallyDifferent(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "context-model ") or
        std.mem.startsWith(u8, line, "query A duplicate-ended ") or
        callbackOwnerRecord(line) or
        debugGlobalOwnerRecord(line);
}

fn nextComparable(iterator: anytype) ?[]const u8 {
    while (iterator.next()) |line| {
        if (!intentionallyDifferent(line)) return line;
    }
    return null;
}

fn expectNormalizedEquality(c_output: []const u8, zig_output: []const u8) !void {
    var c_lines = std.mem.splitScalar(u8, c_output, '\n');
    var zig_lines = std.mem.splitScalar(u8, zig_output, '\n');
    var comparable_index: usize = 0;
    while (true) : (comparable_index += 1) {
        const c_line = nextComparable(&c_lines);
        const zig_line = nextComparable(&zig_lines);
        if (c_line == null or zig_line == null) {
            if (c_line == null and zig_line == null) return;
            std.debug.print("normalized retained-context traces have different lengths at line {d}\n", .{comparable_index});
            return error.UnexpectedRetainedContextDivergence;
        }
        if (!std.mem.eql(u8, c_line.?, zig_line.?)) {
            std.debug.print(
                "unexpected retained-context divergence at normalized line {d}\nC:   {s}\nZig: {s}\n",
                .{ comparable_index, c_line.?, zig_line.? },
            );
            return error.UnexpectedRetainedContextDivergence;
        }
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

    try expectContains(c_output, "context-model global-current\n", "pinned C");
    try expectContains(zig_output, "context-model explicit-instances\n", "native Zig");
    try expectContains(c_output, "query A fresh-open id 831365708 found 1 box 0 0 0 0", "pinned C");
    try expectContains(zig_output, "query A fresh-open id 831365708 found 1 box 0 0 0 0", "native Zig");
    try expectContains(c_output, "query A prior-open-frame id 831365708 found 1", "pinned C");
    try expectContains(zig_output, "query A prior-open-frame id 831365708 found 1", "native Zig");
    try expectContains(c_output, "query A stale-ended id 831365708 found 0", "pinned C");
    try expectContains(zig_output, "query A stale-ended id 831365708 found 0", "native Zig");
    try expectContains(c_output, "collision ids 767087019 1117510171 buckets 3 3 distinct 1 same-bucket 1", "pinned C");
    try expectContains(zig_output, "collision ids 767087019 1117510171 buckets 3 3 distinct 1 same-bucket 1", "native Zig");
    try expectContains(c_output, "query A duplicate-ended id 278403903 found 1 box 1092616192 0 1106247680 1094713344", "pinned C");
    try expectContains(zig_output, "query A duplicate-ended id 278403903 found 1 box 0 0 1092616192 1094713344", "native Zig");
    try expectContains(c_output, "hovered A retained-declaration 1", "pinned C");
    try expectContains(zig_output, "hovered A retained-declaration 1", "native Zig");
    try expectContains(c_output, "scroll A stale-pruned id 2069084997 found 0", "pinned C");
    try expectContains(zig_output, "scroll A stale-pruned id 2069084997 found 0", "native Zig");
    try expectContains(c_output, "scroll B retained-after-A-prune id 2069084997 found 1", "pinned C");
    try expectContains(zig_output, "scroll B retained-after-A-prune id 2069084997 found 1", "native Zig");
    try expectContains(c_output, "callback-owner A install-order A-then-B function B data A calls 2\n", "pinned C");
    try expectContains(c_output, "callback-owner B install-order A-then-B function B data B calls 2\n", "pinned C");
    try expectContains(zig_output, "callback-owner A install-order A-then-B function A data A calls 2\n", "native Zig");
    try expectContains(zig_output, "callback-owner B install-order A-then-B function B data B calls 2\n", "native Zig");
    try expectContains(c_output, "query-callback-owner A install-order A-then-B function B data A calls 1\n", "pinned C");
    try expectContains(c_output, "query-callback-owner B install-order A-then-B function B data B calls 1\n", "pinned C");
    try expectContains(zig_output, "query-callback-owner A install-order A-then-B function A data A calls 1\n", "native Zig");
    try expectContains(zig_output, "query-callback-owner B install-order A-then-B function B data B calls 1\n", "native Zig");
    try expectContains(c_output, "debug-global-owner A after-A-set width 321 color 1067450368 1075838976 1081081856 1082130432\n", "pinned C");
    try expectContains(zig_output, "debug-global-owner A after-A-set width 321 color 1067450368 1075838976 1081081856 1082130432\n", "native Zig");
    try expectContains(c_output, "debug-global-owner B after-A-set width 321 color 1067450368 1075838976 1081081856 1082130432\n", "pinned C");
    try expectContains(zig_output, "debug-global-owner B after-A-set width 400 color 1126694912 1115947008 1105199104 1120403456\n", "native Zig");

    try expectNormalizedEquality(c_output, zig_output);
}
