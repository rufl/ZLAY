//! Regression coverage for public array metadata and error-string lifetime.

const std = @import("std");
const zlay = @import("zlay");

const ErrorCapture = struct {
    count: usize = 0,
    error_type: zlay.ErrorType = .internal_error,
    is_statically_allocated: bool = false,
};

fn captureError(error_data: zlay.ErrorData) void {
    const capture: *ErrorCapture = @ptrCast(@alignCast(error_data.user_data.?));
    capture.count += 1;
    capture.error_type = error_data.error_type;
    capture.is_statically_allocated = error_data.error_text.is_statically_allocated;
}

fn metadataBox() zlay.ElementDeclaration {
    return .{
        .layout = .{ .sizing = .{
            .width = zlay.percent(2),
            .height = zlay.fixed(20),
        } },
        .background_color = .{ .r = 10, .g = 20, .b = 30, .a = 255 },
    };
}

test "public capacities are logical ceilings and error text is static" {
    var capture = ErrorCapture{};
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = 8,
        .max_render_command_count = 13,
        .error_handler = .{
            .error_handler_function = captureError,
            .user_data = &capture,
        },
    });
    defer context.deinit();

    try context.beginLayout();
    try context.openElementWithId(context.staticId("metadata-box"), metadataBox());
    try context.closeElement();
    const commands = try context.endLayout(0);

    try std.testing.expectEqual(@as(i32, 13), commands.capacity);
    try std.testing.expectEqual(@as(i32, 1), commands.length);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(zlay.ErrorType.percentage_over_1, capture.error_type);
    try std.testing.expect(capture.is_statically_allocated);

    try context.setPointerState(.{ .x = 10, .y = 10 }, false);
    const pointer_over = context.getPointerOverIds();
    try std.testing.expectEqual(@as(i32, 8), pointer_over.capacity);
    try std.testing.expectEqual(@as(i32, 2), pointer_over.length);
}

test "derived render capacity matches the element ceiling" {
    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{
        .max_element_count = 8,
    });
    defer context.deinit();

    try context.beginLayout();
    try context.openElementWithId(context.staticId("box"), .{
        .layout = .{ .sizing = .{
            .width = zlay.fixed(20),
            .height = zlay.fixed(20),
        } },
        .background_color = .{ .a = 255 },
    });
    try context.closeElement();
    const commands = try context.endLayout(0);

    try std.testing.expectEqual(@as(i32, 8), commands.capacity);
    try std.testing.expectEqual(@as(i32, 1), commands.length);
}

test "public global replacements are readable and mutable" {
    const saved_layout_default = zlay.layout_default.*;
    defer zlay.layout_default.* = saved_layout_default;

    zlay.layout_default.layout_direction = .top_to_bottom;
    zlay.layout_default.padding.left = 17;
    try std.testing.expectEqual(zlay.LayoutDirection.top_to_bottom, zlay.layout_default.layout_direction);
    try std.testing.expectEqual(@as(u16, 17), zlay.layout_default.padding.left);

    var context = zlay.Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    try std.testing.expectEqual(@as(u32, 400), context.getDebugViewWidth());
    context.setDebugViewWidth(512);
    try std.testing.expectEqual(@as(u32, 512), context.getDebugViewWidth());

    const highlight = zlay.Color{ .r = 1, .g = 2, .b = 3, .a = 4 };
    context.setDebugViewHighlightColor(highlight);
    try std.testing.expectEqual(highlight, context.getDebugViewHighlightColor());
}
