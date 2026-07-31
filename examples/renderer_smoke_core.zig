//! Shared native/WebAssembly renderer smoke implementation.

const zlay = @import("zlay");

pub const expected_result: u32 = 0x5a1a_110e;

fn measureMonospace(
    text: zlay.StringSlice,
    config: *zlay.TextElementConfig,
    _: ?*anyopaque,
) zlay.Dimensions {
    return .{
        .width = @floatFromInt(text.asSlice().len * @as(usize, config.font_size)),
        .height = @floatFromInt(config.font_size),
    };
}

const SmokeBackend = struct {
    image_token: *u8,
    custom_token: *u8,
    seen_types: u16 = 0,
    command_count: usize = 0,

    fn note(self: *SmokeBackend, command: zlay.RenderCommand, expected: zlay.RenderCommandType) !void {
        if (command.command_type != expected or command.id == 0) return error.InvalidFrame;
        self.seen_types |= @as(u16, 1) << @intCast(@intFromEnum(expected));
        self.command_count += 1;
    }

    pub fn none(self: *SmokeBackend, command: zlay.RenderCommand) !void {
        try self.note(command, .none);
    }

    pub fn rectangle(self: *SmokeBackend, command: zlay.RenderCommand, data: zlay.RectangleRenderData) !void {
        if (data.background_color.r != 12 and data.background_color.r != 44) return error.InvalidFrame;
        try self.note(command, .rectangle);
    }

    pub fn border(self: *SmokeBackend, command: zlay.RenderCommand, data: zlay.BorderRenderData) !void {
        if (data.color.b != 90 or data.width.left != 2 or data.width.bottom != 5) return error.InvalidFrame;
        try self.note(command, .border);
    }

    pub fn text(self: *SmokeBackend, command: zlay.RenderCommand, data: zlay.TextRenderData) !void {
        if (!equal(data.string_contents.asSlice(), "native-wasm")) return error.InvalidFrame;
        if (data.font_size != 10 or data.text_color.g != 222) return error.InvalidFrame;
        try self.note(command, .text);
    }

    pub fn image(self: *SmokeBackend, command: zlay.RenderCommand, data: zlay.ImageRenderData) !void {
        if (data.image_data == null or @intFromPtr(data.image_data.?) != @intFromPtr(self.image_token)) {
            return error.InvalidFrame;
        }
        try self.note(command, .image);
    }

    pub fn custom(
        self: *SmokeBackend,
        command: *const zlay.RenderCommand,
        data: zlay.CustomRenderData,
    ) !void {
        if (data.custom_data == null or @intFromPtr(data.custom_data.?) != @intFromPtr(self.custom_token)) {
            return error.InvalidFrame;
        }
        try self.note(command.*, .custom);
    }

    pub fn scissorStart(self: *SmokeBackend, command: zlay.RenderCommand, data: zlay.ClipRenderData) !void {
        if (!data.horizontal) return error.InvalidFrame;
        try self.note(command, .scissor_start);
    }

    pub fn scissorEnd(self: *SmokeBackend, command: zlay.RenderCommand) !void {
        try self.note(command, .scissor_end);
    }

    pub fn overlayColorStart(self: *SmokeBackend, command: zlay.RenderCommand, data: zlay.OverlayColorRenderData) !void {
        if (data.color.r != 77 and data.color.r != 88) return error.InvalidFrame;
        try self.note(command, .overlay_color_start);
    }

    pub fn overlayColorEnd(self: *SmokeBackend, command: zlay.RenderCommand) !void {
        try self.note(command, .overlay_color_end);
    }
};

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (left_byte != right_byte) return false;
    }
    return true;
}

/// Generate a nested, renderer-neutral frame and dispatch every payload-bearing
/// command kind through the dependency-free adapter. The returned magic value
/// is stable across the native and freestanding WebAssembly builds.
pub fn run(storage: []u8) !u32 {
    var profiler = zlay.profile.FixedBufferProfiler.init(storage);
    var context = zlay.Context.init(profiler.allocator(), .{ .width = 256, .height = 192 }, .{
        .max_element_count = 32,
        .max_render_command_count = 32,
        .max_text_cache_word_count = 16,
    });
    defer context.deinit();
    context.setMeasureTextFunction(measureMonospace, null);

    var image_token: u8 = 17;
    var custom_token: u8 = 29;

    try context.beginLayout();
    try context.openElementWithId(context.staticId("renderer-smoke-root"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(180), .height = zlay.fixed(120) },
            .padding = zlay.padding(4),
        },
        .background_color = .{ .r = 12, .g = 20, .b = 30, .a = 255 },
        .overlay_color = .{ .r = 77, .g = 2, .b = 3, .a = 96 },
        .corner_radius = zlay.cornerRadius(6),
        .image = .{ .image_data = &image_token },
        .custom = .{ .custom_data = &custom_token },
        .clip = .{ .horizontal = true, .vertical = true },
        .border = .{
            .color = .{ .r = 10, .g = 20, .b = 90, .a = 255 },
            .width = .{ .left = 2, .right = 3, .top = 4, .bottom = 5 },
        },
    });
    try context.openElementWithId(context.staticId("renderer-smoke-child"), .{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(120), .height = zlay.fixed(40) },
            .padding = zlay.padding(2),
        },
        .background_color = .{ .r = 44, .g = 50, .b = 60, .a = 255 },
        .overlay_color = .{ .r = 88, .g = 6, .b = 7, .a = 64 },
        .clip = .{ .horizontal = true },
    });
    try context.textSlice("native-wasm", .{
        .font_size = 10,
        .text_color = .{ .r = 111, .g = 222, .b = 33, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();

    const commands = try context.endLayout(0);
    var backend = SmokeBackend{ .image_token = &image_token, .custom_token = &custom_token };
    const stats = try zlay.renderer.consumeArray(SmokeBackend, &backend, commands);

    if (stats.commandCount() != 14 or backend.command_count != 14) return error.InvalidFrame;
    if (stats.none != 0 or stats.rectangles != 2 or stats.borders != 1 or stats.text != 1 or
        stats.images != 1 or stats.custom != 1 or stats.scissor_starts != 2 or stats.scissor_ends != 2 or
        stats.overlay_starts != 2 or stats.overlay_ends != 2)
    {
        return error.InvalidFrame;
    }
    if (stats.max_scissor_depth != 2 or stats.max_overlay_depth != 2) return error.InvalidFrame;
    if (backend.seen_types != 0x03fe) return error.InvalidFrame;

    const allocation = profiler.snapshot();
    if (allocation.peak_bytes == 0 or allocation.failed_allocations != 0) return error.InvalidFrame;
    return expected_result;
}
