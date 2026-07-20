const std = @import("std");
const smoke = @import("renderer_smoke_core.zig");

// Keep the fixed-buffer arena out of the executable's platform-default stack.
var storage: [1024 * 1024]u8 align(@alignOf(usize)) = undefined;

pub fn main() !void {
    const first = try smoke.run(&storage);
    const second = try smoke.run(&storage);
    if (first != smoke.expected_result or second != smoke.expected_result) {
        return error.RendererSmokeMismatch;
    }
    std.debug.print("renderer-smoke 0x{x:0>8}\n", .{first});
}
