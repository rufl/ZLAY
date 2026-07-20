const smoke = @import("renderer_smoke_core.zig");

var storage: [1024 * 1024]u8 align(@alignOf(usize)) = undefined;

export fn zlay_renderer_smoke() u32 {
    return smoke.run(&storage) catch 0;
}
