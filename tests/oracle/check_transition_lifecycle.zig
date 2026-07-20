const std = @import("std");

const expected_sha256 = "3b17ee216c890e5c60889a598a031f98264ec791da9418fe3acb66e7e6d31067";
const expected_lines = 100;
const expected_bytes = 14_171;

const expected_event_tags = [_][]const i32{
    &.{},
    &.{ 11, 21, 31, 42 },
    &.{ 41, 21, 31 },
    &.{ 41, 21, 31, 11, 42 },
    &.{ 41, 21, 31, 11, 42 },
    &.{ 41, 21 },
    &.{ 42, 21 },
    &.{ 42, 21 },
};

fn readFile(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(64 * 1024));
}

fn expectDigest(contents: []const u8, label: []const u8) !void {
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &actual, .{});
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_sha256);
    if (!std.mem.eql(u8, &expected, &actual)) {
        std.debug.print("{s} transition-lifecycle trace changed\nexpected: {s}\nactual:   {x}\n", .{
            label,
            expected_sha256,
            actual,
        });
        return error.TransitionLifecycleTraceChanged;
    }
}

fn expectContains(contents: []const u8, needle: []const u8, label: []const u8) !void {
    if (std.mem.indexOf(u8, contents, needle) != null) return;
    std.debug.print("{s} transition-lifecycle trace is missing marker: {s}\n", .{ label, needle });
    return error.TransitionLifecycleMarkerMissing;
}

fn verifyEventSequence(contents: []const u8, label: []const u8) !void {
    var counts: [expected_event_tags.len]usize = @splat(0);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "event ")) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse return error.MalformedEventRecord;
        const frame = try std.fmt.parseInt(usize, fields.next() orelse return error.MalformedEventRecord, 10);
        const index = try std.fmt.parseInt(usize, fields.next() orelse return error.MalformedEventRecord, 10);
        const tag = try std.fmt.parseInt(i32, fields.next() orelse return error.MalformedEventRecord, 10);
        if (frame >= counts.len or index != counts[frame]) {
            std.debug.print("{s} malformed transition event routing at frame {d}, index {d}\n", .{ label, frame, index });
            return error.MalformedEventRecord;
        }
        const expected = expected_event_tags[frame];
        if (index >= expected.len or tag != expected[index]) {
            std.debug.print("{s} unexpected transition event at frame {d}, index {d}: tag {d}\n", .{ label, frame, index, tag });
            return error.TransitionLifecycleEventMismatch;
        }
        counts[frame] += 1;
    }

    for (counts, expected_event_tags, 0..) |actual_count, expected, frame| {
        if (actual_count == expected.len) continue;
        std.debug.print("{s} transition event count changed at frame {d}: expected {d}, got {d}\n", .{
            label,
            frame,
            expected.len,
            actual_count,
        });
        return error.TransitionLifecycleEventMismatch;
    }
}

fn verifyTrace(contents: []const u8, label: []const u8) !void {
    if (contents.len != expected_bytes) {
        std.debug.print("{s} transition-lifecycle byte count changed: expected {d}, got {d}\n", .{
            label,
            expected_bytes,
            contents.len,
        });
        return error.TransitionLifecycleTraceChanged;
    }
    if (contents.len == 0 or contents[contents.len - 1] != '\n') {
        return error.IncompleteTransitionLifecycleTrace;
    }
    const line_count = std.mem.count(u8, contents, "\n");
    if (line_count != expected_lines) {
        std.debug.print("{s} transition-lifecycle line count changed: expected {d}, got {d}\n", .{
            label,
            expected_lines,
            line_count,
        });
        return error.TransitionLifecycleTraceChanged;
    }

    try expectDigest(contents, label);
    try verifyEventSequence(contents, label);

    // Handler deletion must prune the active tag-11 record, and restoring the
    // handler must register a fresh zero-valued transition record.
    try expectContains(contents, "frame 2 commands 5 events 3 finals 1 1 initials 0\n", label);
    try expectContains(
        contents,
        "event 3 3 11 2 00000010 00000000 initial 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000",
        label,
    );

    // A declaration that returns while its exit is active cancels EXITING and
    // resumes through an ordinary target transition, not a second exit/enter.
    try expectContains(contents, "event 2 1 21 3 00000010 00000000", label);
    try expectContains(contents, "event 3 1 21 2 00000010 00000000", label);

    // The child tag is absent on the parent-removal frame. Its later tag-42
    // record starts from zero because the exiting-tree clone pruned the nested
    // transition state before the child was moved under the rescue parent.
    try expectContains(contents, "event 2 0 41 3 00000010 00000000", label);
    try expectContains(
        contents,
        "event 3 4 42 2 00000010 00000000 initial 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000",
        label,
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;

    const c_output = try readFile(init, allocator, args[1]);
    const zig_output = try readFile(init, allocator, args[2]);
    try verifyTrace(c_output, "pinned C");
    try verifyTrace(zig_output, "native Zig");
    if (!std.mem.eql(u8, c_output, zig_output)) return error.TransitionLifecycleOracleMismatch;
}
