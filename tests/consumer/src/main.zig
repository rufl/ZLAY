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

    pub fn text(self: *Backend, _: zlay.RenderCommand, data: zlay.TextRenderData) !void {
        if (!std.mem.eql(u8, data.string_contents.asSlice(), "go!")) {
            return error.UnexpectedTextPayload;
        }
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
fn measureText(value: zlay.StringSlice, _: *zlay.TextElementConfig, _: ?*anyopaque) zlay.Dimensions {
    return .{ .width = @floatFromInt(value.asSlice().len), .height = 1 };
}

fn exercisePublicApis(text_storage: []u8) !zlay.text_widgets.TextInput {
    var button = zlay.widgets.Button.init(.{ .id = 100 });
    if (!button.activate() or !button.consumeActivation()) return error.UnexpectedButtonState;

    var tab_storage: [2]zlay.ElementId = undefined;
    var tabs = zlay.widgets.Tabs.init(&tab_storage);
    try tabs.append(.{ .id = 101 });
    try tabs.append(.{ .id = 102 });
    if (try tabs.moveNext(.wrap) != 1 or tabs.selectedId().?.id != 102) {
        return error.UnexpectedTabsState;
    }

    var input = zlay.text_widgets.TextInput.init(text_storage);
    try input.setSlice("go");
    try input.insert("!");
    if (!std.mem.eql(u8, input.bytes(), "go!")) return error.UnexpectedTextInputState;

    var virtual = try zlay.text_widgets.VirtualListState.init(20, 10, 25, 10, 1);
    const visible = try virtual.visibleRange();
    if (visible.start != 0 or visible.end != 5) return error.UnexpectedVisibleRange;

    var metadata_storage: [1]zlay.accessibility.WidgetMetadata = undefined;
    var registry = zlay.accessibility.Registry.init(&metadata_storage);
    var metadata = zlay.accessibility.WidgetMetadata.init(button.id, .button);
    metadata.label = zlay.StringSlice.fromSlice("Submit");
    metadata.states = (zlay.accessibility.State{}).with(.focused);
    try registry.register(metadata);
    const queried = registry.query(button.id) orelse return error.MissingAccessibilityMetadata;
    if (queried.role != .button or !queried.hasState(.focused)) {
        return error.UnexpectedAccessibilityMetadata;
    }
    if (!std.mem.eql(u8, queried.label.?.asSlice(), "Submit")) {
        return error.UnexpectedAccessibilityLabel;
    }
    return input;
}

pub fn main(_: std.process.Init) !void {
    var context = zlay.Context.init(
        std.heap.page_allocator,
        .{ .width = 320, .height = 200 },
        .{},
    );
    defer context.deinit();
    var text_storage: [16]u8 = undefined;
    const input = try exercisePublicApis(&text_storage);
    context.setMeasureTextFunction(measureText, null);

    try context.beginLayout();
    try context.openElementWithId(context.id("consumer-smoke"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
        },
        .background_color = .{ .r = 20, .g = 40, .b = 60, .a = 255 },
    });
    try context.textSlice(input.bytes(), .{ .font_size = 12 });

    try context.closeElement();

    const commands = try context.endLayout(1.0 / 60.0);
    var backend = Backend{};
    const stats = try zlay.renderer.consumeArray(Backend, &backend, commands);
    if (stats.rectangles != 1 or stats.text != 1 or stats.commandCount() != 2 or backend.calls != 2) {
        return error.UnexpectedRenderCommandCount;
    }
}
