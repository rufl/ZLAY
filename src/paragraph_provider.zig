//! Generic optional paragraph-provider declarations for ZLAY.
//!
//! Registration is context-local. The legacy Clay-compatible text path remains
//! authoritative while no provider is installed. Width-time provider layout
//! and paragraph-handle render transport are separate integration stages.

const std = @import("std");
const types = @import("types.zig");

pub const FailureKind = enum(u8) {
    invalid_style,
    limit_exceeded,
    out_of_memory,
    unavailable,
    stale_handle,
    internal,
};

pub const Failure = struct {
    kind: FailureKind,
    provider_code: u32 = 0,
};

pub const ContractError = error{
    InvalidUtf8,
    InvalidAvailableWidth,
    InvalidIntrinsicMetrics,
    InvalidParagraphMetrics,
    InvalidParagraphHandle,
    InvalidParagraphGeneration,
};

pub fn Outcome(comptime T: type) type {
    return union(enum) {
        value: T,
        failure: Failure,
    };
}

/// Four-byte OpenType tag stored in display order.
pub const Tag = enum(u32) {
    _,

    pub fn fromBytes(bytes: [4]u8) Tag {
        return @enumFromInt(
            (@as(u32, bytes[0]) << 24) |
                (@as(u32, bytes[1]) << 16) |
                (@as(u32, bytes[2]) << 8) |
                @as(u32, bytes[3]),
        );
    }
};

pub const Direction = enum(u8) {
    auto,
    left_to_right,
    right_to_left,
    top_to_bottom,
    bottom_to_top,
};

pub const OpenTypeFeature = struct {
    tag: Tag,
    value: u32 = 1,
    byte_start: u32 = 0,
    byte_end: u32 = std.math.maxInt(u32),
};

pub const VariationAxis = struct {
    tag: Tag,
    value: f32,
};

pub const WrapMode = enum(u8) {
    none,
    word,
    grapheme,
};

/// Physical alignment values preserve legacy Clay behavior; logical start/end
/// values are available to direction-aware providers without coercion.
pub const Alignment = enum(u8) {
    left,
    center,
    right,
    start,
    end,
    justified,
};

pub const Overflow = enum(u8) {
    visible,
    clip,
    ellipsis,
};

pub const LineHeight = union(enum) {
    font_default,
    multiplier: f32,
    absolute_px: f32,
};

/// Lossless provider-facing typography and paragraph state. All slices are
/// borrowed for one provider callback; providers copy anything they retain.
pub const TextStyle = struct {
    font_stack_id: u32 = 0,
    size_px: f32 = 16,
    direction: Direction = .auto,
    script: ?Tag = null,
    language: []const u8 = "",
    features: []const OpenTypeFeature = &.{},
    variations: []const VariationAxis = &.{},
    letter_spacing_px: f32 = 0,
    word_spacing_px: f32 = 0,
    line_height: LineHeight = .font_default,
    wrap: WrapMode = .word,
    alignment: Alignment = .start,
    overflow: Overflow = .visible,
    max_lines: ?u32 = null,

    /// Preserve the complete representable legacy values when adapting an
    /// existing Clay-compatible text declaration. `.newlines` and `.none`
    /// both mean hard-break-only layout in the pinned ZLAY implementation.
    pub fn fromLegacy(config: types.TextElementConfig) TextStyle {
        return .{
            .font_stack_id = config.font_id,
            .size_px = @floatFromInt(config.font_size),
            .letter_spacing_px = @floatFromInt(config.letter_spacing),
            .line_height = if (config.line_height == 0)
                .font_default
            else
                .{ .absolute_px = @floatFromInt(config.line_height) },
            .wrap = if (config.wrap_mode == .words) .word else .none,
            .alignment = switch (config.text_alignment) {
                .left => .left,
                .center => .center,
                .right => .right,
            },
        };
    }
};

pub const IntrinsicMetrics = struct {
    min_content_width: f32 = 0,
    max_content_width: f32 = 0,
    height: f32 = 0,
    first_baseline: f32 = 0,
    last_baseline: f32 = 0,
};

pub const LogicalMetrics = struct {
    advance: types.Vector2 = .{},
    ascent: f32 = 0,
    descent: f32 = 0,
    line_gap: f32 = 0,
};

pub const InkBounds = struct {
    min: types.Vector2 = .{},
    max: types.Vector2 = .{},
};

pub const ParagraphMetrics = struct {
    logical: LogicalMetrics = .{},
    ink: InkBounds = .{},
    line_count: u32 = 0,
};

pub const ParagraphHandle = enum(u64) {
    invalid = 0,
    _,
};

pub const LeaseKey = struct {
    handle: ParagraphHandle,
    generation: u64,
};

pub const ParagraphLease = struct {
    handle: ParagraphHandle,
    generation: u64,
    paragraph_metrics: ParagraphMetrics,

    pub fn key(self: ParagraphLease) LeaseKey {
        return .{ .handle = self.handle, .generation = self.generation };
    }
};

/// Typed payload carried by ZLAY's existing custom render-command channel.
/// `Context.paragraphRenderData` validates the opaque command pointer before
/// exposing this value to an adapter.
pub const RenderData = struct {
    lease: ParagraphLease,
    available_width_px: f32,
};

pub const IntrinsicRequest = struct {
    text: []const u8,
    text_style: TextStyle,
};

pub const LayoutRequest = struct {
    text: []const u8,
    text_style: TextStyle,
    available_width_px: f32,
};

pub const IntrinsicOutcome = Outcome(IntrinsicMetrics);
pub const LayoutOutcome = Outcome(ParagraphLease);
pub const LeaseOutcome = Outcome(void);

pub const VTable = struct {
    measure_intrinsic: *const fn (
        context: *anyopaque,
        scratch_allocator: std.mem.Allocator,
        request: IntrinsicRequest,
    ) IntrinsicOutcome,
    layout_paragraph: *const fn (
        context: *anyopaque,
        scratch_allocator: std.mem.Allocator,
        request: LayoutRequest,
    ) LayoutOutcome,
    retain_paragraph: *const fn (context: *anyopaque, key: LeaseKey) LeaseOutcome,
    release_paragraph: *const fn (context: *anyopaque, key: LeaseKey) LeaseOutcome,
};

pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub fn measureIntrinsic(
        self: Provider,
        scratch_allocator: std.mem.Allocator,
        request: IntrinsicRequest,
    ) ContractError!IntrinsicOutcome {
        try validateText(request.text);
        const outcome = self.vtable.measure_intrinsic(
            self.context,
            scratch_allocator,
            request,
        );
        switch (outcome) {
            .value => |value| try validateIntrinsicMetrics(value),
            .failure => {},
        }
        return outcome;
    }

    /// A successful call returns one provider-owned reference. ZLAY releases
    /// it exactly once when the command/frame/cache lifetime ends.
    pub fn layoutParagraph(
        self: Provider,
        scratch_allocator: std.mem.Allocator,
        request: LayoutRequest,
    ) ContractError!LayoutOutcome {
        try validateText(request.text);
        if (!finiteNonNegative(request.available_width_px)) {
            return error.InvalidAvailableWidth;
        }
        const outcome = self.vtable.layout_paragraph(
            self.context,
            scratch_allocator,
            request,
        );
        switch (outcome) {
            .value => |value| try validateLease(value),
            .failure => {},
        }
        return outcome;
    }

    pub fn retainParagraph(self: Provider, key: LeaseKey) ContractError!LeaseOutcome {
        try validateLeaseKey(key);
        return self.vtable.retain_paragraph(self.context, key);
    }

    pub fn releaseParagraph(self: Provider, key: LeaseKey) ContractError!LeaseOutcome {
        try validateLeaseKey(key);
        return self.vtable.release_paragraph(self.context, key);
    }
};

fn validateText(text: []const u8) ContractError!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
}

fn validateIntrinsicMetrics(value: IntrinsicMetrics) ContractError!void {
    if (!finiteNonNegative(value.min_content_width) or
        !finiteNonNegative(value.max_content_width) or
        !finiteNonNegative(value.height) or
        !finiteNonNegative(value.first_baseline) or
        !finiteNonNegative(value.last_baseline) or
        value.min_content_width > value.max_content_width or
        value.first_baseline > value.height or
        value.last_baseline > value.height)
    {
        return error.InvalidIntrinsicMetrics;
    }
}

fn validateParagraphMetrics(value: ParagraphMetrics) ContractError!void {
    if (!finite(value.logical.advance.x) or
        !finite(value.logical.advance.y) or
        !finiteNonNegative(value.logical.ascent) or
        !finiteNonNegative(value.logical.descent) or
        !finiteNonNegative(value.logical.line_gap) or
        !finite(value.ink.min.x) or
        !finite(value.ink.min.y) or
        !finite(value.ink.max.x) or
        !finite(value.ink.max.y) or
        value.ink.min.x > value.ink.max.x or
        value.ink.min.y > value.ink.max.y or
        value.line_count == 0)
    {
        return error.InvalidParagraphMetrics;
    }
}

fn validateLease(value: ParagraphLease) ContractError!void {
    try validateLeaseKey(value.key());
    try validateParagraphMetrics(value.paragraph_metrics);
}

fn validateLeaseKey(key: LeaseKey) ContractError!void {
    if (key.handle == .invalid) return error.InvalidParagraphHandle;
    if (key.generation == 0) return error.InvalidParagraphGeneration;
}

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

fn finiteNonNegative(value: f32) bool {
    return finite(value) and value >= 0;
}

const ValidationProvider = struct {
    calls: usize = 0,
    invalid_intrinsic: bool = false,
    invalid_layout: bool = false,

    fn from(context: *anyopaque) *ValidationProvider {
        return @ptrCast(@alignCast(context));
    }

    fn measure(
        context: *anyopaque,
        _: std.mem.Allocator,
        _: IntrinsicRequest,
    ) IntrinsicOutcome {
        const self = from(context);
        self.calls += 1;
        return .{ .value = .{
            .min_content_width = if (self.invalid_intrinsic) 20 else 10,
            .max_content_width = 15,
            .height = 12,
            .first_baseline = 9,
            .last_baseline = 9,
        } };
    }

    fn layout(
        context: *anyopaque,
        _: std.mem.Allocator,
        _: LayoutRequest,
    ) LayoutOutcome {
        const self = from(context);
        self.calls += 1;
        return .{ .value = .{
            .handle = if (self.invalid_layout) .invalid else @enumFromInt(4),
            .generation = 2,
            .paragraph_metrics = .{
                .logical = .{ .advance = .{ .x = 15, .y = 12 }, .ascent = 9, .descent = 3 },
                .ink = .{ .min = .{}, .max = .{ .x = 15, .y = 12 } },
                .line_count = 1,
            },
        } };
    }

    fn lease(_: *anyopaque, _: LeaseKey) LeaseOutcome {
        return .{ .value = {} };
    }
};

const validation_vtable = VTable{
    .measure_intrinsic = ValidationProvider.measure,
    .layout_paragraph = ValidationProvider.layout,
    .retain_paragraph = ValidationProvider.lease,
    .release_paragraph = ValidationProvider.lease,
};

test "provider wrapper rejects invalid requests and results before host adoption" {
    var state = ValidationProvider{};
    const provider = Provider{ .context = &state, .vtable = &validation_vtable };
    try std.testing.expectError(error.InvalidUtf8, provider.measureIntrinsic(std.testing.allocator, .{
        .text = &.{0xff},
        .text_style = .{},
    }));
    try std.testing.expectEqual(@as(usize, 0), state.calls);
    try std.testing.expectError(error.InvalidAvailableWidth, provider.layoutParagraph(std.testing.allocator, .{
        .text = "valid",
        .text_style = .{},
        .available_width_px = std.math.nan(f32),
    }));
    try std.testing.expectEqual(@as(usize, 0), state.calls);

    state.invalid_intrinsic = true;
    try std.testing.expectError(error.InvalidIntrinsicMetrics, provider.measureIntrinsic(std.testing.allocator, .{
        .text = "valid",
        .text_style = .{},
    }));
    state.invalid_intrinsic = false;
    state.invalid_layout = true;
    try std.testing.expectError(error.InvalidParagraphHandle, provider.layoutParagraph(std.testing.allocator, .{
        .text = "valid",
        .text_style = .{},
        .available_width_px = 20,
    }));
    try std.testing.expectError(error.InvalidParagraphHandle, provider.releaseParagraph(.{
        .handle = .invalid,
        .generation = 2,
    }));
}

test "legacy bridge preserves full unsigned values without changing semantics" {
    const style = TextStyle.fromLegacy(.{
        .font_id = std.math.maxInt(u16),
        .font_size = 513,
        .letter_spacing = std.math.maxInt(u16),
        .line_height = 777,
        .wrap_mode = .newlines,
        .text_alignment = .right,
    });

    try std.testing.expectEqual(@as(u32, std.math.maxInt(u16)), style.font_stack_id);
    try std.testing.expectEqual(@as(f32, 513), style.size_px);
    try std.testing.expectEqual(@as(f32, std.math.maxInt(u16)), style.letter_spacing_px);
    try std.testing.expectEqual(WrapMode.none, style.wrap);
    try std.testing.expectEqual(Alignment.right, style.alignment);
    switch (style.line_height) {
        .absolute_px => |value| try std.testing.expectEqual(@as(f32, 777), value),
        else => return error.TestUnexpectedResult,
    }
}

test "advanced style retains signed tracking and direction-aware fields exactly" {
    const features = [_]OpenTypeFeature{.{
        .tag = Tag.fromBytes("kern".*),
        .value = 0,
        .byte_start = 2,
        .byte_end = 9,
    }};
    const variations = [_]VariationAxis{.{
        .tag = Tag.fromBytes("wght".*),
        .value = 612.5,
    }};
    const style = TextStyle{
        .font_stack_id = 0xfedc_ba98,
        .size_px = 17.25,
        .direction = .right_to_left,
        .script = Tag.fromBytes("Arab".*),
        .language = "ar-EG",
        .features = &features,
        .variations = &variations,
        .letter_spacing_px = -1.375,
        .word_spacing_px = 0.625,
        .line_height = .{ .multiplier = 1.35 },
        .wrap = .grapheme,
        .alignment = .end,
        .overflow = .ellipsis,
        .max_lines = 3,
    };

    try std.testing.expectEqual(@as(u32, 0xfedc_ba98), style.font_stack_id);
    try std.testing.expectEqual(@as(f32, -1.375), style.letter_spacing_px);
    try std.testing.expectEqual(@as(f32, 0.625), style.word_spacing_px);
    try std.testing.expectEqualStrings("ar-EG", style.language);
    try std.testing.expectEqual(Direction.right_to_left, style.direction);
    try std.testing.expectEqual(WrapMode.grapheme, style.wrap);
    try std.testing.expectEqual(Alignment.end, style.alignment);
    try std.testing.expectEqual(Overflow.ellipsis, style.overflow);
    try std.testing.expectEqual(@as(?u32, 3), style.max_lines);
    try std.testing.expectEqual(Tag.fromBytes("kern".*), style.features[0].tag);
    try std.testing.expectEqual(@as(f32, 612.5), style.variations[0].value);
    switch (style.line_height) {
        .multiplier => |value| try std.testing.expectEqual(@as(f32, 1.35), value),
        else => return error.TestUnexpectedResult,
    }
}
