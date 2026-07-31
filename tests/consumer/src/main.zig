const std = @import("std");
const zlay = @import("zlay");

const Backend = struct {
    calls: usize = 0,

    fn record(self: *Backend) !void {
        self.calls += 1;
    }

    pub fn none(self: *Backend, _: zlay.RenderCommand) !void {
        try self.record();
    }

    pub fn rectangle(self: *Backend, _: zlay.RenderCommand, data: zlay.RectangleRenderData) !void {
        if (data.background_color.r != 20) return error.UnexpectedRectangle;
        try self.record();
    }

    pub fn border(self: *Backend, _: zlay.RenderCommand, _: zlay.BorderRenderData) !void {
        try self.record();
    }

    pub fn text(self: *Backend, _: zlay.RenderCommand, _: zlay.TextRenderData) !void {
        try self.record();
    }

    pub fn image(self: *Backend, _: zlay.RenderCommand, _: zlay.ImageRenderData) !void {
        try self.record();
    }

    pub fn custom(
        self: *Backend,
        _: *const zlay.RenderCommand,
        _: zlay.CustomRenderData,
    ) !void {
        try self.record();
    }

    pub fn scissorStart(self: *Backend, _: zlay.RenderCommand, _: zlay.ClipRenderData) !void {
        try self.record();
    }

    pub fn scissorEnd(self: *Backend, _: zlay.RenderCommand) !void {
        try self.record();
    }

    pub fn overlayColorStart(self: *Backend, _: zlay.RenderCommand, _: zlay.OverlayColorRenderData) !void {
        try self.record();
    }

    pub fn overlayColorEnd(self: *Backend, _: zlay.RenderCommand) !void {
        try self.record();
    }
};

pub fn main() !void {
    var context = zlay.Context.init(
        std.heap.page_allocator,
        .{ .width = 320, .height = 200 },
        .{},
    );
    defer context.deinit();

    try context.beginLayout();
    try context.openElementWithId(context.id("consumer-smoke"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
        },
        .background_color = .{ .r = 20, .g = 40, .b = 60, .a = 255 },
    });
    try context.closeElement();

    const commands = try context.endLayout(1.0 / 60.0);
    var backend = Backend{};
    const stats = try zlay.renderer.consumeArray(Backend, &backend, commands);
    if (stats.rectangles != 1 or stats.commandCount() != 1 or backend.calls != 1) {
        return error.UnexpectedRenderCommandCount;
    }
}
