const std = @import("std");
const zlay = @import("zlay");

// Keep the profiled arena independent of the executable's default stack size.
var storage: [1024 * 1024]u8 align(@alignOf(usize)) = undefined;

fn drawRepresentativeFrame(context: *zlay.Context) !void {
    try context.beginLayout();
    try context.openElementWithId(context.staticId("profile-panel"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(320), .height = zlay.fixed(180) },
            .padding = zlay.padding(8),
            .child_gap = 4,
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 24, .g = 28, .b = 36, .a = 255 },
        .clip = .{ .horizontal = true, .vertical = true },
    });
    for (0..12) |index| {
        try context.openElementWithId(context.staticIndexedId("profile-row", @intCast(index)), .{
            .layout = .{ .sizing = .{ .width = zlay.grow(), .height = zlay.fixed(10) } },
            .background_color = .{ .r = @floatFromInt(20 + index), .g = 80, .b = 140, .a = 255 },
        });
        try context.closeElement();
    }
    try context.closeElement();
    _ = try context.endLayout(0);
}

pub fn main(_: std.process.Init) !void {
    var profiler = zlay.profile.FixedBufferProfiler.init(&storage);
    var context = zlay.Context.init(profiler.allocator(), .{ .width = 640, .height = 360 }, .{
        .max_element_count = 64,
        .max_render_command_count = 64,
    });
    defer context.deinit();

    for (0..8) |_| try drawRepresentativeFrame(&context);
    const warmed = profiler.snapshot();
    for (0..64) |_| try drawRepresentativeFrame(&context);
    const measured = profiler.snapshot();

    if (warmed.peak_bytes == 0 or measured.failed_allocations != 0) return error.InvalidProfile;
    if (measured.peak_bytes != warmed.peak_bytes) return error.ProfileDidNotStabilize;

    std.debug.print(
        "fixed-buffer-profile capacity={d} peak={d} current={d} headroom={d} allocations={d}\n",
        .{
            measured.capacity_bytes,
            measured.peak_bytes,
            measured.current_bytes,
            measured.headroomBytes(),
            measured.successful_allocations,
        },
    );
}
