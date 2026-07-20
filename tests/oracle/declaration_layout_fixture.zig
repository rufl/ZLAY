const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

const FixtureIds = struct {
    query_auto: u32 = 0,
    row_auto: u32 = 0,
    local_content_auto: u32 = 0,
    local_fit: zlay.ElementId = .{},
    indexed_global: zlay.ElementId = .{},
    indexed_local: zlay.ElementId = .{},
    align_content: zlay.ElementId = .{},
};

const DeclarationResult = struct {
    ids: FixtureIds,
    query_hovered: bool,
};

fn printId(out: *std.Io.Writer, frame: usize, name: []const u8, id: zlay.ElementId) !void {
    try out.print("frame {d} id {s} {d} {d} {d} {d}\n", .{
        frame,
        name,
        id.id,
        id.offset,
        id.base_id,
        id.string_id.asSlice().len,
    });
}

fn printBox(out: *std.Io.Writer, context: *const zlay.Context, frame: usize, name: []const u8, id: u32) !void {
    const data = context.getElementData(.{ .id = id });
    try out.print("frame {d} box {s} found {d} {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{
        frame,
        name,
        @intFromBool(data.found),
        contract.f32Bits(data.bounding_box.x),
        contract.f32Bits(data.bounding_box.y),
        contract.f32Bits(data.bounding_box.width),
        contract.f32Bits(data.bounding_box.height),
    });
}

fn printCommand(out: *std.Io.Writer, frame: usize, index: usize, command: zlay.RenderCommand) !void {
    try out.print("frame {d} command {d} type {d} id {d} z {d} box {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
        frame,
        index,
        @intFromEnum(command.command_type),
        command.id,
        command.z_index,
        contract.f32Bits(command.bounding_box.x),
        contract.f32Bits(command.bounding_box.y),
        contract.f32Bits(command.bounding_box.width),
        contract.f32Bits(command.bounding_box.height),
    });
    if (command.command_type == .rectangle) {
        const color = command.render_data.rectangle.background_color;
        try out.print(" rgba {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
            contract.f32Bits(color.r),
            contract.f32Bits(color.g),
            contract.f32Bits(color.b),
            contract.f32Bits(color.a),
        });
    }
    try out.writeByte('\n');
}

fn declareLayout(context: *zlay.Context) !DeclarationResult {
    var ids = FixtureIds{};

    try context.openElementWithId(context.staticId("declaration-layout-root"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
            .padding = .{ .left = 7, .right = 11, .top = 5, .bottom = 9 },
            .child_gap = 6,
            .child_alignment = .{ .x = .center },
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 18, .g = 24, .b = 34, .a = 255 },
    });

    try context.openElementUnconfigured();
    ids.query_auto = try context.getOpenElementId();
    const query_hovered = context.hovered();
    try context.configureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(120), .height = zlay.fixed(28) },
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = if (query_hovered)
            .{ .r = 45, .g = 180, .b = 95, .a = 255 }
        else
            .{ .r = 180, .g = 65, .b = 55, .a = 255 },
    });
    try context.closeElement();

    try context.openElementWithId(context.staticId("compression-row"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.fixed(62) },
            .padding = .{ .left = 8, .right = 6, .top = 7, .bottom = 5 },
            .child_gap = 5,
            .child_alignment = .{ .y = .center },
        },
        .background_color = .{ .r = 35, .g = 48, .b = 66, .a = 255 },
    });

    try context.openElementUnconfigured();
    ids.row_auto = try context.getOpenElementId();
    try context.configureOpenElement(.{
        .layout = .{ .sizing = .{ .width = zlay.fixed(82), .height = zlay.fixed(24) } },
        .background_color = .{ .r = 185, .g = 75, .b = 85, .a = 255 },
    });
    try context.closeElement();

    ids.local_fit = try context.staticLocalId("local-fit");
    try context.openElementWithId(ids.local_fit, .{
        .layout = .{ .sizing = .{ .width = zlay.fitMinMax(18, 62), .height = zlay.fixed(36) } },
        .background_color = .{ .r = 195, .g = 125, .b = 55, .a = 255 },
    });
    try context.openElementUnconfigured();
    ids.local_content_auto = try context.getOpenElementId();
    try context.configureOpenElement(.{
        .layout = .{ .sizing = .{ .width = zlay.fixed(88), .height = zlay.fixed(14) } },
        .background_color = .{ .r = 240, .g = 190, .b = 80, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();

    ids.indexed_global = context.staticIndexedId("indexed-global", 7);
    try context.openElementWithId(ids.indexed_global, .{
        .layout = .{ .sizing = .{ .width = zlay.growMinMax(20, 70), .height = zlay.fixed(34) } },
        .background_color = .{ .r = 55, .g = 145, .b = 95, .a = 255 },
    });
    try context.closeElement();

    ids.indexed_local = try context.staticIndexedLocalId("indexed-local", 3);
    try context.openElementWithId(ids.indexed_local, .{
        .layout = .{ .sizing = .{ .width = zlay.percent(0.22), .height = zlay.fixed(20) } },
        .background_color = .{ .r = 45, .g = 125, .b = 170, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.staticId("nested-column"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(190), .height = zlay.grow() },
            .padding = .{ .left = 9, .right = 5, .top = 4, .bottom = 8 },
            .child_gap = 4,
            .child_alignment = .{ .x = .right },
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 40, .g = 42, .b = 76, .a = 255 },
    });

    try context.openElementWithId(context.staticId("align-fit"), .{
        .layout = .{ .sizing = .{ .width = zlay.fitMinMax(30, 110), .height = zlay.fitMinMax(16, 40) } },
        .background_color = .{ .r = 115, .g = 75, .b = 165, .a = 255 },
    });
    ids.align_content = try context.staticLocalId("align-content");
    try context.openElementWithId(ids.align_content, .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(96), .height = zlay.fixed(52) } },
        .background_color = .{ .r = 165, .g = 105, .b = 205, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.staticId("align-percent"), .{
        .layout = .{ .sizing = .{ .width = zlay.percent(0.55), .height = zlay.fixed(30) } },
        .background_color = .{ .r = 60, .g = 120, .b = 175, .a = 255 },
    });
    try context.closeElement();

    try context.openElementWithId(context.staticId("align-grow"), .{
        .layout = .{ .sizing = .{ .width = zlay.growMinMax(44, 120), .height = zlay.growMinMax(18, 70) } },
        .background_color = .{ .r = 55, .g = 155, .b = 130, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();
    try context.closeElement();

    return .{ .ids = ids, .query_hovered = query_hovered };
}

fn runFrame(
    context: *zlay.Context,
    out: *std.Io.Writer,
    frame: usize,
    dimensions: zlay.Dimensions,
) !FixtureIds {
    context.setLayoutDimensions(dimensions);
    try context.beginLayout();
    const declared = try declareLayout(context);
    const commands = try context.endLayout(0.016);
    const ids = declared.ids;

    try out.print("frame {d} summary viewport {x:0>8} {x:0>8} commands {d} hovered {d} query-auto {d} row-auto {d} local-content-auto {d}\n", .{
        frame,
        contract.f32Bits(dimensions.width),
        contract.f32Bits(dimensions.height),
        commands.items().len,
        @intFromBool(declared.query_hovered),
        ids.query_auto,
        ids.row_auto,
        ids.local_content_auto,
    });
    try printId(out, frame, "local-fit", ids.local_fit);
    try printId(out, frame, "indexed-global", ids.indexed_global);
    try printId(out, frame, "indexed-local", ids.indexed_local);
    try printId(out, frame, "align-content", ids.align_content);

    try printBox(out, context, frame, "root", context.staticId("declaration-layout-root").id);
    try printBox(out, context, frame, "query-auto", ids.query_auto);
    try printBox(out, context, frame, "compression-row", context.staticId("compression-row").id);
    try printBox(out, context, frame, "row-auto", ids.row_auto);
    try printBox(out, context, frame, "local-fit", ids.local_fit.id);
    try printBox(out, context, frame, "local-content-auto", ids.local_content_auto);
    try printBox(out, context, frame, "indexed-global", ids.indexed_global.id);
    try printBox(out, context, frame, "indexed-local", ids.indexed_local.id);
    try printBox(out, context, frame, "nested-column", context.staticId("nested-column").id);
    try printBox(out, context, frame, "align-fit", context.staticId("align-fit").id);
    try printBox(out, context, frame, "align-content", ids.align_content.id);
    try printBox(out, context, frame, "align-percent", context.staticId("align-percent").id);
    try printBox(out, context, frame, "align-grow", context.staticId("align-grow").id);

    for (commands.items(), 0..) |command, index| try printCommand(out, frame, index, command);
    return ids;
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 310, .height = 220 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const frame0 = try runFrame(&context, out, 0, .{ .width = 310, .height = 220 });
    const query = context.getElementData(.{ .id = frame0.query_auto });
    try context.setPointerState(.{
        .x = query.bounding_box.x + query.bounding_box.width * 0.5,
        .y = query.bounding_box.y + query.bounding_box.height * 0.5,
    }, false);
    _ = try runFrame(&context, out, 1, .{ .width = 310, .height = 220 });

    try context.setPointerState(.{ .x = -50, .y = -50 }, false);
    _ = try runFrame(&context, out, 2, .{ .width = 222, .height = 150 });
    _ = try runFrame(&context, out, 3, .{ .width = 420, .height = 260 });
    try out.flush();
}
