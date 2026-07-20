const std = @import("std");
const zlay = @import("zlay");
const contract = @import("oracle_contract.zig");

fn measureText(text: zlay.StringSlice, config: *zlay.TextElementConfig, _: ?*anyopaque) zlay.Dimensions {
    const advance = 5.0 + @as(f32, @floatFromInt(config.letter_spacing));
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * advance,
        .height = @floatFromInt(config.font_size),
    };
}

fn printEscaped(out: *std.Io.Writer, text: zlay.StringSlice) !void {
    try out.writeByte('"');
    for (text.asSlice()) |byte| {
        switch (byte) {
            '\n' => try out.writeAll("\\n"),
            '\\' => try out.writeAll("\\\\"),
            '"' => try out.writeAll("\\\""),
            else => try out.writeByte(byte),
        }
    }
    try out.writeByte('"');
}

fn printBox(out: *std.Io.Writer, context: *const zlay.Context, frame: usize, name: []const u8) !void {
    const data = context.getElementData(context.id(name));
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

    switch (command.command_type) {
        .rectangle => {
            const rectangle = command.render_data.rectangle;
            try out.print(" rect {x:0>8} {x:0>8} {x:0>8} {x:0>8} radius {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
                contract.f32Bits(rectangle.background_color.r),
                contract.f32Bits(rectangle.background_color.g),
                contract.f32Bits(rectangle.background_color.b),
                contract.f32Bits(rectangle.background_color.a),
                contract.f32Bits(rectangle.corner_radius.top_left),
                contract.f32Bits(rectangle.corner_radius.top_right),
                contract.f32Bits(rectangle.corner_radius.bottom_left),
                contract.f32Bits(rectangle.corner_radius.bottom_right),
            });
        },
        .text => {
            const text = command.render_data.text;
            try out.print(" text {d} ", .{text.string_contents.asSlice().len});
            try printEscaped(out, text.string_contents);
            try out.print(" rgba {x:0>8} {x:0>8} {x:0>8} {x:0>8} font {d} {d} spacing {d} line {d}", .{
                contract.f32Bits(text.text_color.r),
                contract.f32Bits(text.text_color.g),
                contract.f32Bits(text.text_color.b),
                contract.f32Bits(text.text_color.a),
                text.font_id,
                text.font_size,
                text.letter_spacing,
                text.line_height,
            });
        },
        else => {},
    }
    try out.writeByte('\n');
}

fn declareLayout(context: *zlay.Context) !void {
    try context.openElementWithId(context.staticId("sizing-text-root"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
            .padding = zlay.padding(4),
            .child_gap = 4,
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 12, .g = 18, .b = 28, .a = 255 },
    });
    try context.openElementWithId(context.staticId("constraint-row"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.fixed(34) },
            .padding = zlay.padding(2),
            .child_gap = 4,
        },
        .background_color = .{ .r = 26, .g = 34, .b = 48, .a = 255 },
    });
    try context.openElementWithId(context.staticId("fit-min"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fitMin(26), .height = zlay.fixed(20) },
            .child_alignment = .{ .y = .center },
        },
        .background_color = .{ .r = 145, .g = 55, .b = 65, .a = 255 },
    });
    try context.textSlice("fit fit fit", .{
        .text_color = .{ .r = 255, .g = 235, .b = 235, .a = 255 },
        .font_id = 4,
        .font_size = 7,
        .wrap_mode = .words,
    });
    try context.closeElement();

    try context.openElementWithId(context.staticId("fit-range"), .{
        .layout = .{ .sizing = .{ .width = zlay.fitMinMax(12, 38), .height = zlay.fixed(18) } },
        .background_color = .{ .r = 155, .g = 105, .b = 35, .a = 255 },
    });
    try context.openElementWithId(context.staticId("fit-range-content"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(70), .height = zlay.fixed(8) } },
        .background_color = .{ .r = 235, .g = 185, .b = 55, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.staticId("grow-min"), .{
        .layout = .{ .sizing = .{ .width = zlay.growMin(24), .height = zlay.fixed(16) } },
        .background_color = .{ .r = 45, .g = 135, .b = 85, .a = 255 },
    });
    try context.closeElement();

    try context.openElementWithId(context.staticId("grow-range"), .{
        .layout = .{ .sizing = .{ .width = zlay.growMinMax(14, 48), .height = zlay.fixed(18) } },
        .background_color = .{ .r = 35, .g = 105, .b = 155, .a = 255 },
    });
    try context.closeElement();

    try context.openElementWithId(context.staticId("aspect"), .{
        .layout = .{ .sizing = .{ .width = zlay.growMinMax(16, 44), .height = zlay.fitMinMax(6, 30) } },
        .background_color = .{ .r = 105, .g = 65, .b = 165, .a = 255 },
        .aspect_ratio = .{ .aspect_ratio = 2 },
    });
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.staticId("text-row"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.growMinMax(58, 112) },
            .padding = zlay.padding(2),
            .child_gap = 4,
        },
        .background_color = .{ .r = 18, .g = 27, .b = 39, .a = 255 },
    });
    try context.openElementWithId(context.staticId("words-box"), .{
        .layout = .{
            .sizing = .{ .width = zlay.percent(0.33333334), .height = zlay.grow() },
            .padding = zlay.padding(3),
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 55, .g = 75, .b = 105, .a = 255 },
    });
    try context.textSlice("alpha beta gamma delta", .{
        .text_color = .{ .r = 205, .g = 225, .b = 250, .a = 255 },
        .font_id = 1,
        .font_size = 8,
        .letter_spacing = 1,
        .line_height = 11,
        .wrap_mode = .words,
        .text_alignment = .center,
    });
    try context.closeElement();

    try context.openElementWithId(context.staticId("newlines-box"), .{
        .layout = .{
            .sizing = .{ .width = zlay.percent(0.33333334), .height = zlay.grow() },
            .padding = zlay.padding(3),
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 65, .g = 95, .b = 75, .a = 255 },
    });
    try context.textSlice("wide line\nx\nmid", .{
        .text_color = .{ .r = 215, .g = 245, .b = 220, .a = 255 },
        .font_id = 2,
        .font_size = 9,
        .letter_spacing = 2,
        .line_height = 13,
        .wrap_mode = .newlines,
        .text_alignment = .right,
    });
    try context.closeElement();

    try context.openElementWithId(context.staticId("none-box"), .{
        .layout = .{
            .sizing = .{ .width = zlay.percent(0.33333334), .height = zlay.grow() },
            .padding = zlay.padding(3),
            .layout_direction = .top_to_bottom,
        },
        .background_color = .{ .r = 105, .g = 75, .b = 55, .a = 255 },
    });
    try context.textSlice("never wrap this", .{
        .text_color = .{ .r = 250, .g = 225, .b = 205, .a = 255 },
        .font_id = 3,
        .font_size = 10,
        .letter_spacing = 3,
        .line_height = 14,
        .wrap_mode = .none,
        .text_alignment = .left,
    });
    try context.closeElement();
    try context.closeElement();
    try context.closeElement();

    try context.openElementWithId(context.staticId("cull-probe"), .{
        .layout = .{ .sizing = .{ .width = zlay.fixed(30), .height = zlay.fixed(18) } },
        .background_color = .{ .r = 245, .g = 70, .b = 35, .a = 255 },
        .floating = .{
            .offset = .{ .x = 270, .y = 150 },
            .z_index = 6,
            .attach_to = .root,
        },
    });
    try context.closeElement();
}

fn runFrame(
    context: *zlay.Context,
    out: *std.Io.Writer,
    frame: usize,
    dimensions: zlay.Dimensions,
) !bool {
    context.setLayoutDimensions(dimensions);
    context.setCullingEnabled(true);
    try context.beginLayout();
    try declareLayout(context);
    const commands = try context.endLayout(0);

    const probe_id = context.staticId("cull-probe");
    var probe_commands: usize = 0;
    for (commands.items()) |command| {
        if (command.id == probe_id.id and command.command_type == .rectangle) probe_commands += 1;
    }

    try out.print("frame {d} summary viewport {x:0>8} {x:0>8} commands {d} probe-commands {d}\n", .{
        frame,
        contract.f32Bits(dimensions.width),
        contract.f32Bits(dimensions.height),
        commands.items().len,
        probe_commands,
    });

    inline for (.{
        "sizing-text-root",
        "constraint-row",
        "fit-min",
        "fit-range",
        "fit-range-content",
        "grow-min",
        "grow-range",
        "aspect",
        "text-row",
        "words-box",
        "newlines-box",
        "none-box",
        "cull-probe",
    }) |name| try printBox(out, context, frame, name);

    for (commands.items(), 0..) |command, index| try printCommand(out, frame, index, command);

    const probe = context.getElementData(probe_id);
    const expected_probe_commands: usize = if (frame == 0) 1 else 0;
    return probe.found and probe_commands == expected_probe_commands;
}

pub fn main(init: std.process.Init) !void {
    var context = zlay.Context.init(std.heap.page_allocator, .{ .width = 320, .height = 190 }, .{
        .error_handler = .{ .error_handler_function = contract.failOnError },
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureText, null);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const valid = try runFrame(&context, out, 0, .{ .width = 320, .height = 190 }) and
        try runFrame(&context, out, 1, .{ .width = 150, .height = 118 });
    try out.flush();
    if (!valid) return error.InvalidSizingTextFixture;
}
