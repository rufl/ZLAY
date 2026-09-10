const std = @import("std");
const retained = @import("retained_layout.zig");

const LayoutTree = retained.LayoutTree;
const Layout = retained.Layout;
const GridTrack = retained.GridTrack;

// Normalized from DioxusLabs/taffy@fc379ead7741188b45996b3acf84a3864c42ab8c
// README.md and test_fixtures/grid/grid_basic_implicit_tracks.html. The exact
// reference output was generated with that revision's TaffyTree implementation.
test "Taffy reference flex column distributes remaining height" {
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 3 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 800 },
        .height = .{ .length = 600 },
        .flex_direction = .column,
    });
    const header = try tree.create(.{
        .width = .{ .length = 800 },
        .height = .{ .length = 100 },
    });
    const body = try tree.create(.{
        .width = .{ .length = 800 },
        .flex_grow = 1,
    });
    try tree.appendChild(root, header);
    try tree.appendChild(root, body);

    try tree.compute(root, .{ .width = 800, .height = 600 });

    try std.testing.expectEqual(Layout{ .width = 800, .height = 600 }, try tree.readLayout(root));
    try std.testing.expectEqual(Layout{ .width = 800, .height = 100 }, try tree.readLayout(header));
    try std.testing.expectEqual(Layout{ .y = 100, .width = 800, .height = 500 }, try tree.readLayout(body));
}

test "Taffy reference auto grid grows an implicit row" {
    const columns = [_]GridTrack{GridTrack.fixedPx(40)};
    const rows = [_]GridTrack{GridTrack.fixedPx(40)};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4, .max_grid_tracks = 4 });
    defer tree.deinit();
    const root = try tree.create(.{
        .width = .{ .length = 100 },
        .height = .{ .length = 100 },
    });
    const grid = try tree.create(.{
        .display = .grid,
        .grid_columns = &columns,
        .grid_rows = &rows,
        .grid_auto_rows = .auto,
    });
    const first = try tree.create(.{
        .width = .{ .stretch = 1 },
        .height = .{ .stretch = 1 },
    });
    const second = try tree.create(.{
        .width = .{ .length = 35 },
        .height = .{ .length = 35 },
    });
    try tree.appendChild(root, grid);
    try tree.appendChild(grid, first);
    try tree.appendChild(grid, second);

    try tree.compute(root, .{ .width = 100, .height = 100 });

    try std.testing.expectEqual(Layout{ .width = 40, .height = 75 }, try tree.readLayout(grid));
    try std.testing.expectEqual(Layout{ .width = 40, .height = 40 }, try tree.readLayout(first));
    const second_layout = try tree.readLayout(second);
    try std.testing.expectEqual(@as(f32, 0), second_layout.x);
    try std.testing.expectEqual(@as(f32, 40), second_layout.y);
    try std.testing.expectEqual(@as(f32, 35), second_layout.width);
    try std.testing.expectEqual(@as(f32, 35), second_layout.height);
}

// Normalized from vizia/morphorm@2c09be204f25221b38fed4d9d37f3c8da5e33b4d
// tests/grid.rs::auto_columns_two_columns_different_widths.
test "Morphorm reference auto grid tracks use fixed child contributions" {
    const columns = [_]GridTrack{ GridTrack.auto, GridTrack.auto };
    const rows = [_]GridTrack{GridTrack.fixedPx(200)};
    var tree = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 3 });
    defer tree.deinit();
    const root = try tree.create(.{
        .display = .grid,
        .width = .{ .length = 600 },
        .height = .{ .length = 200 },
        .grid_columns = &columns,
        .grid_rows = &rows,
    });
    const first = try tree.create(.{
        .width = .{ .length = 80 },
        .height = .{ .stretch = 1 },
        .grid_column = 1,
        .grid_row = 1,
    });
    const second = try tree.create(.{
        .width = .{ .length = 150 },
        .height = .{ .stretch = 1 },
        .grid_column = 2,
        .grid_row = 1,
    });
    try tree.appendChild(root, first);
    try tree.appendChild(root, second);

    try tree.compute(root, .{ .width = 600, .height = 200 });

    try std.testing.expectEqual(Layout{ .width = 600, .height = 200 }, try tree.readLayout(root));
    try std.testing.expectEqual(Layout{ .width = 80, .height = 200 }, try tree.readLayout(first));
    try std.testing.expectEqual(Layout{ .x = 80, .width = 150, .height = 200 }, try tree.readLayout(second));
}

// Normalized from vizia/morphorm@2c09be204f25221b38fed4d9d37f3c8da5e33b4d
// tests/incremental.rs::incremental_matches_full_under_fixed_parent.
test "Morphorm reference dirty descendant matches full layout" {
    var full = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer full.deinit();
    var dirty = LayoutTree.init(std.testing.allocator, .{ .max_nodes = 4 });
    defer dirty.deinit();

    const full_root = try full.create(.{ .width = .{ .length = 600 }, .height = .{ .length = 600 }, .flex_direction = .column });
    const full_parent = try full.create(.{ .width = .{ .length = 400 }, .height = .{ .length = 400 }, .flex_direction = .column });
    const full_a = try full.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 100 } });
    const full_b = try full.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 100 } });
    try full.appendChild(full_root, full_parent);
    try full.appendChild(full_parent, full_a);
    try full.appendChild(full_parent, full_b);

    const dirty_root = try dirty.create(.{ .width = .{ .length = 600 }, .height = .{ .length = 600 }, .flex_direction = .column });
    const dirty_parent = try dirty.create(.{ .width = .{ .length = 400 }, .height = .{ .length = 400 }, .flex_direction = .column });
    const dirty_a = try dirty.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 100 } });
    const dirty_b = try dirty.create(.{ .width = .{ .length = 100 }, .height = .{ .length = 100 } });
    try dirty.appendChild(dirty_root, dirty_parent);
    try dirty.appendChild(dirty_parent, dirty_a);
    try dirty.appendChild(dirty_parent, dirty_b);

    const available = retained.Dimensions{ .width = 600, .height = 600 };
    try full.compute(full_root, available);
    try dirty.compute(dirty_root, available);
    try full.setStyle(full_a, .{ .width = .{ .length = 100 }, .height = .{ .length = 250 } });
    try dirty.setStyle(dirty_a, .{ .width = .{ .length = 100 }, .height = .{ .length = 250 } });
    try full.compute(full_root, available);
    try dirty.computeDirty(dirty_a, available);

    try std.testing.expectEqual(try full.readLayout(full_root), try dirty.readLayout(dirty_root));
    try std.testing.expectEqual(try full.readLayout(full_parent), try dirty.readLayout(dirty_parent));
    try std.testing.expectEqual(try full.readLayout(full_a), try dirty.readLayout(dirty_a));
    try std.testing.expectEqual(try full.readLayout(full_b), try dirty.readLayout(dirty_b));
    try std.testing.expectEqual(@as(f32, 250), (try dirty.readLayout(dirty_b)).y);
}
