//! Public regression coverage for stack-safe render traversal.

const std = @import("std");
const zlay = @import("root.zig");

test "a fifty-thousand-element public layout renders without native stack recursion" {
    const depth: usize = 50_000;
    const leaf_color = zlay.Color{ .r = 17, .g = 34, .b = 51, .a = 255 };
    var context = zlay.Context.init(
        std.testing.allocator,
        .{ .width = 64, .height = 64 },
        .{ .max_element_count = depth + 1 },
    );
    defer context.deinit();

    try context.beginLayout();
    var leaf_id = zlay.ElementId{};
    for (0..depth) |index| {
        const element_id = context.indexedId("deep-render-node", @intCast(index));
        var declaration = zlay.ElementDeclaration{
            .layout = .{ .sizing = .{
                .width = zlay.fixed(1),
                .height = zlay.fixed(1),
            } },
        };
        if (index + 1 == depth) {
            leaf_id = element_id;
            declaration.background_color = leaf_color;
        }
        try context.openElementWithId(element_id, declaration);
    }
    for (0..depth) |_| try context.closeElement();

    const commands = try context.endLayout(0);
    try std.testing.expectEqual(@as(usize, 1), commands.items().len);
    const leaf_command = commands.items()[0];
    try std.testing.expectEqual(zlay.RenderCommandType.rectangle, leaf_command.command_type);
    try std.testing.expectEqual(leaf_id.id, leaf_command.id);
    try std.testing.expectEqual(leaf_color, leaf_command.render_data.rectangle.background_color);
    try std.testing.expectEqual(zlay.BoundingBox{
        .width = 1,
        .height = 1,
    }, leaf_command.bounding_box);

    const leaf_data = context.getElementData(leaf_id);
    try std.testing.expect(leaf_data.found);
    try std.testing.expectEqual(leaf_command.bounding_box, leaf_data.bounding_box);
}
