const std = @import("std");
const zlay = @import("zlay");

const MockProvider = struct {
    next_handle: u64 = 1,
    active_key: ?zlay.ParagraphLeaseKey = null,
    references: u32 = 0,

    fn provider(self: *MockProvider) zlay.ParagraphProvider {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(raw: *anyopaque) *MockProvider {
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

pub fn main() !void {
    var mock = MockProvider{};
    const provider = mock.provider();
    var context = zlay.Context.init(
        std.heap.page_allocator,
        .{ .width = 420, .height = 180 },
        .{},
    );
    defer context.deinit();
    context.setParagraphProvider(provider);

    const features = [_]zlay.ParagraphTextFeature{.{
        .tag = zlay.paragraph_provider.Tag.fromBytes("kern".*),
    }};
    const variations = [_]zlay.ParagraphTextVariation{.{
        .tag = zlay.paragraph_provider.Tag.fromBytes("wght".*),
        .value = 575,
    }};

    try context.beginLayout();
    try context.openElement(.{
        .layout = .{
            .sizing = .{ .width = zlay.fixed(360), .height = zlay.fit() },
            .padding = zlay.padding(16),
        },
    });
    try context.textSliceWithParagraphStyle(
        "Provider-owned shaping with an asynchronous render lease.",
        .{ .text_color = .{ .r = 235, .g = 238, .b = 245, .a = 255 } },
        .{
            .font_stack_id = 7,
            .size_px = 20,
            .language = "en",
            .features = &features,
            .variations = &variations,
            .line_height = .{ .multiplier = 1.25 },
            .wrap = .word,
            .alignment = .start,
        },
    );
    try context.closeElement();
    const commands = try context.endLayout(1.0 / 60.0);

    var retained_key: ?zlay.ParagraphLeaseKey = null;
    for (commands.items()) |*command| {
        const paragraph = context.paragraphRenderData(command) orelse continue;
        switch (try provider.retainParagraph(paragraph.lease.key())) {
            .value => retained_key = paragraph.lease.key(),
            .failure => return error.MockRetainFailed,
        }
        std.debug.print(
            "draw paragraph handle={d} width={d:.1} lines={d}\n",
            .{
                @intFromEnum(paragraph.lease.handle),
                paragraph.available_width_px,
                paragraph.lease.paragraph_metrics.line_count,
            },
        );
    }
    const key = retained_key orelse return error.ParagraphCommandMissing;

    // Starting the next frame releases ZLAY's reference. The mock renderer's
    // retained reference remains live until its queued work completes.
    try context.beginLayout();
    _ = try context.endLayout(0);
    std.debug.assert(mock.references == 1);
    switch (try provider.releaseParagraph(key)) {
        .value => {},
        .failure => return error.MockReleaseFailed,
    }
    std.debug.assert(mock.references == 0);
}
