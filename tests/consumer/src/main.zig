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
const ParagraphMock = struct {
    next_handle: u64 = 1,
    active_key: ?zlay.ParagraphLeaseKey = null,
    references: u32 = 0,

    fn provider(self: *ParagraphMock) zlay.ParagraphProvider {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(raw: *anyopaque) *ParagraphMock {
        return @ptrCast(@alignCast(raw));
    }

    fn measure(
        _: *anyopaque,
        _: std.mem.Allocator,
        request: zlay.ParagraphIntrinsicRequest,
    ) zlay.paragraph_provider.IntrinsicOutcome {
        const glyph_width = request.text_style.size_px * 0.55;
        const width = @as(f32, @floatFromInt(request.text.len)) * glyph_width;
        const height = request.text_style.size_px * 1.25;
        const baseline = request.text_style.size_px;
        return .{ .value = .{
            .min_content_width = @min(width, glyph_width * 8),
            .max_content_width = width,
            .height = height,
            .first_baseline = baseline,
            .last_baseline = baseline,
        } };
    }

    fn layout(
        raw: *anyopaque,
        _: std.mem.Allocator,
        request: zlay.ParagraphLayoutRequest,
    ) zlay.paragraph_provider.LayoutOutcome {
        const self = from(raw);
        if (self.active_key != null) {
            return .{ .failure = .{ .kind = .limit_exceeded, .provider_code = 1 } };
        }

        const natural_width = @as(f32, @floatFromInt(request.text.len)) *
            request.text_style.size_px * 0.55;
        const width = @min(natural_width, request.available_width_px);
        const line_count: u32 = if (natural_width > request.available_width_px) 2 else 1;
        const height = request.text_style.size_px * 1.25 *
            @as(f32, @floatFromInt(line_count));
        const key = zlay.ParagraphLeaseKey{
            .handle = @enumFromInt(self.next_handle),
            .generation = 1,
        };
        self.next_handle += 1;
        self.active_key = key;
        self.references = 1;
        return .{ .value = .{
            .handle = key.handle,
            .generation = key.generation,
            .paragraph_metrics = .{
                .logical = .{
                    .advance = .{ .x = width, .y = height },
                    .ascent = request.text_style.size_px,
                    .descent = request.text_style.size_px * 0.25,
                },
                .ink = .{ .min = .{}, .max = .{ .x = width, .y = height } },
                .line_count = line_count,
            },
        } };
    }

    fn retain(raw: *anyopaque, key: zlay.ParagraphLeaseKey) zlay.paragraph_provider.LeaseOutcome {
        const self = from(raw);
        if (!sameKey(self.active_key, key) or self.references == 0) {
            return .{ .failure = .{ .kind = .stale_handle } };
        }
        self.references += 1;
        return .{ .value = {} };
    }

    fn release(raw: *anyopaque, key: zlay.ParagraphLeaseKey) zlay.paragraph_provider.LeaseOutcome {
        const self = from(raw);
        if (!sameKey(self.active_key, key) or self.references == 0) {
            return .{ .failure = .{ .kind = .stale_handle } };
        }
        self.references -= 1;
        if (self.references == 0) self.active_key = null;
        return .{ .value = {} };
    }

    fn sameKey(active: ?zlay.ParagraphLeaseKey, key: zlay.ParagraphLeaseKey) bool {
        const value = active orelse return false;
        return value.handle == key.handle and value.generation == key.generation;
    }

    const vtable = zlay.ParagraphProviderVTable{
        .measure_intrinsic = measure,
        .layout_paragraph = layout,
        .retain_paragraph = retain,
        .release_paragraph = release,
    };
};

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

    const legacy_commands = try context.endLayout(1.0 / 60.0);
    var legacy_backend = Backend{};
    const legacy_stats = try zlay.renderer.consumeArray(Backend, &legacy_backend, legacy_commands);
    if (legacy_stats.rectangles != 1 or legacy_stats.text != 1 or
        legacy_stats.commandCount() != 2 or legacy_backend.calls != 2)
    {
        return error.UnexpectedRenderCommandCount;
    }

    var paragraph_mock = ParagraphMock{};
    const paragraph_provider = paragraph_mock.provider();
    context.setParagraphProvider(paragraph_provider);

    try context.beginLayout();
    try context.openElementWithId(context.id("paragraph-smoke"), .{
        .layout = .{
            .sizing = .{ .width = zlay.grow(), .height = zlay.grow() },
        },
        .background_color = .{ .r = 20, .g = 40, .b = 60, .a = 255 },
    });
    try context.textSliceWithParagraphStyle(
        "provider",
        .{},
        .{
            .font_stack_id = 7,
            .size_px = 12,
            .language = "en",
            .line_height = .{ .multiplier = 1.25 },
            .wrap = .word,
            .alignment = .start,
        },
    );
    try context.closeElement();

    const paragraph_commands_array = try context.endLayout(1.0 / 60.0);
    var paragraph_key: ?zlay.ParagraphLeaseKey = null;
    var paragraph_commands: usize = 0;
    for (paragraph_commands_array.items()) |*command| {
        const paragraph = context.paragraphRenderData(command) orelse continue;
        paragraph_commands += 1;
        if (paragraph.available_width_px <= 0 or paragraph.lease.paragraph_metrics.line_count == 0) {
            return error.UnexpectedParagraphMetrics;
        }
        const key = paragraph.lease.key();
        switch (try paragraph_provider.retainParagraph(key)) {
            .value => paragraph_key = key,
            .failure => return error.ParagraphRetainFailed,
        }
    }
    const retained_key = paragraph_key orelse return error.ParagraphCommandMissing;
    if (paragraph_commands != 1 or paragraph_mock.references != 2) {
        return error.UnexpectedParagraphLeaseState;
    }

    var paragraph_backend = Backend{};
    const paragraph_stats = try zlay.renderer.consumeArray(
        Backend,
        &paragraph_backend,
        paragraph_commands_array,
    );
    if (paragraph_stats.rectangles != 1 or paragraph_stats.custom != 1 or
        paragraph_stats.commandCount() != 2 or paragraph_backend.calls != 2)
    {
        return error.UnexpectedRenderCommandCount;
    }

    try context.beginLayout();
    if (paragraph_mock.references != 1) return error.UnexpectedParagraphRelease;
    _ = try context.endLayout(0);
    switch (try paragraph_provider.releaseParagraph(retained_key)) {
        .value => {},
        .failure => return error.ParagraphReleaseFailed,
    }
    if (paragraph_mock.references != 0 or paragraph_mock.active_key != null) {
        return error.UnexpectedParagraphLeaseState;
    }
}
