const std = @import("std");
const zlay = @import("zlay");

pub fn f32Bits(value: f32) u32 {
    return @bitCast(value);
}

pub fn failOnError(error_data: zlay.ErrorData) void {
    std.debug.print("unexpected oracle diagnostic {d}: {s}\n", .{
        @backingInt(error_data.error_type),
        error_data.error_text.asSlice(),
    });
    @panic("unexpected oracle diagnostic");
}

pub fn failLogOverflow(name: []const u8) noreturn {
    std.debug.panic("oracle log overflow: {s}", .{name});
}
