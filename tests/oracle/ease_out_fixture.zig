const std = @import("std");
const zlay = @import("zlay");

fn bits(value: f32) u32 {
    return @bitCast(value);
}

fn printData(out: *std.Io.Writer, case_index: usize, time_index: usize, complete: bool, data: zlay.TransitionData) !void {
    try out.print(
        "ease {d} {d} {d} box {x:0>8} {x:0>8} {x:0>8} {x:0>8} bg {x:0>8} {x:0>8} {x:0>8} {x:0>8} overlay {x:0>8} {x:0>8} {x:0>8} {x:0>8} border {x:0>8} {x:0>8} {x:0>8} {x:0>8} width {d} {d} {d} {d} {d}\n",
        .{
            case_index,
            time_index,
            @intFromBool(complete),
            bits(data.bounding_box.x),
            bits(data.bounding_box.y),
            bits(data.bounding_box.width),
            bits(data.bounding_box.height),
            bits(data.background_color.r),
            bits(data.background_color.g),
            bits(data.background_color.b),
            bits(data.background_color.a),
            bits(data.overlay_color.r),
            bits(data.overlay_color.g),
            bits(data.overlay_color.b),
            bits(data.overlay_color.a),
            bits(data.border_color.r),
            bits(data.border_color.g),
            bits(data.border_color.b),
            bits(data.border_color.a),
            data.border_width.left,
            data.border_width.right,
            data.border_width.top,
            data.border_width.bottom,
            data.border_width.between_children,
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const initial = zlay.TransitionData{
        .bounding_box = .{ .x = -11.25, .y = 7.5, .width = 13, .height = 17.75 },
        .background_color = .{ .r = 1, .g = 17, .b = 63.5, .a = 127 },
        .overlay_color = .{ .r = 2, .g = 19, .b = 71.5, .a = 131 },
        .border_color = .{ .r = 3, .g = 23, .b = 79.5, .a = 137 },
        .border_width = .{ .left = 1001, .right = 1003, .top = 1005, .bottom = 1007, .between_children = 1009 },
    };
    const target = zlay.TransitionData{
        .bounding_box = .{ .x = 101.5, .y = -31.25, .width = 47, .height = 89.5 },
        .background_color = .{ .r = 201, .g = 217, .b = 231.5, .a = 251 },
        .overlay_color = .{ .r = 202, .g = 219, .b = 233.5, .a = 253 },
        .border_color = .{ .r = 203, .g = 223, .b = 239.5, .a = 255 },
        .border_width = .{ .left = 1020, .right = 1040, .top = 1060, .bottom = 1080, .between_children = 1100 },
    };
    const sentinel = zlay.TransitionData{
        .bounding_box = .{ .x = 301, .y = 302, .width = 303, .height = 304 },
        .background_color = .{ .r = 305, .g = 306, .b = 307, .a = 308 },
        .overlay_color = .{ .r = 309, .g = 310, .b = 311, .a = 312 },
        .border_color = .{ .r = 313, .g = 314, .b = 315, .a = 316 },
        .border_width = .{ .left = 317, .right = 318, .top = 319, .bottom = 320, .between_children = 321 },
    };
    const properties = [_]zlay.TransitionProperty{
        .none,
        .x,
        .y,
        .width,
        .height,
        .background_color,
        .overlay_color,
        .corner_radius,
        .border_color,
        .border_width,
        .bounding_box,
        .border,
        @fromBackingInt(@intCast(511)),
    };
    const elapsed = [_]f32{ 0, 0, 2, 4, 8, -1 };
    const duration = [_]f32{ 0, 4, 4, 4, 4, 4 };

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    for (properties, 0..) |property, case_index| {
        for (elapsed, duration, 0..) |elapsed_time, duration_time, time_index| {
            var current = sentinel;
            const complete = zlay.easeOut(.{
                .transition_state = .transitioning,
                .initial = initial,
                .current = &current,
                .target = target,
                .elapsed_time = elapsed_time,
                .duration = duration_time,
                .properties = property,
            });
            try printData(out, case_index, time_index, complete, current);
        }
    }
    try out.flush();
}
