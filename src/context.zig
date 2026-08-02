//! Stateful native Zig layout engine.
//!
//! `Context` replaces Clay's process-global current-context pointer with an
//! explicit allocator-owned value. The low-level open/configure/close lifecycle
//! remains available so upstream behavior can be compared operation-for-
//! operation, while every context is naturally independent.

const std = @import("std");
const types = @import("types.zig");
const hashes = @import("hash.zig");
const globals = @import("globals.zig");
const layout = @import("layout.zig");
const text_engine = @import("text.zig");
const scroll_engine = @import("scroll.zig");
const transitions = @import("transition.zig");
const debug_inspector = @import("debug.zig");
const renderer = @import("renderer.zig");
const paragraph_provider = @import("paragraph_provider.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{
    LayoutAlreadyOpen,
    LayoutNotOpen,
    NoOpenElement,
    CannotCloseRoot,
    CannotConfigureRoot,
    ElementAlreadyConfigured,
    ScopedElementUnbalanced,
    PointerUpdateAlreadyActive,
    CallbackReentryNotAllowed,
    ElementCapacityExceeded,
    TextMeasurementCapacityExceeded,
    DebugStringCapacityExceeded,
    RenderCommandCapacityExceeded,
    ParagraphProviderFailed,
    ParagraphProviderContractViolation,
    ParagraphProviderStaleHandle,
    ParagraphProviderNotInstalled,
};

const ParagraphProviderError = error{
    ParagraphProviderFailed,
    ParagraphProviderContractViolation,
    ParagraphProviderStaleHandle,
    TextMeasurementCapacityExceeded,
    OutOfMemory,
};

pub const Options = struct {
    max_element_count: usize = 8192,
    max_render_command_count: usize = 0,
    max_text_cache_word_count: usize = 16_384,
    error_handler: types.ErrorHandler = .{},
};

const max_public_array_capacity: usize = @intCast(std.math.maxInt(i32));

fn normalizeOptions(options: Options) Options {
    var normalized = options;
    normalized.max_element_count = @min(normalized.max_element_count, max_public_array_capacity);
    if (normalized.max_render_command_count > 0) {
        normalized.max_render_command_count = @min(
            normalized.max_render_command_count,
            max_public_array_capacity,
        );
    }
    return normalized;
}

const OpenEntry = struct {
    node_index: usize,
    active_clip_id: u32 = 0,
    active_clip_node_index: ?usize = null,
};

const TextRecord = struct {
    text: types.String,
    config: types.TextElementConfig,
    paragraph_style: paragraph_provider.TextStyle,
    preferred_dimensions: types.Dimensions,
    min_width: f32,
    wrapped_start: usize = 0,
    wrapped_len: usize = 0,
    paragraph_layout_index: ?usize = null,
};

const ParagraphCacheKey = struct {
    provider_context: usize,
    provider_vtable: usize,
    text_digest: [Sha256.digest_length]u8,
    style_digest: [Sha256.digest_length]u8,

    fn init(
        provider: paragraph_provider.Provider,
        text: types.String,
        style: paragraph_provider.TextStyle,
    ) ParagraphCacheKey {
        return .{
            .provider_context = @intFromPtr(provider.context),
            .provider_vtable = @intFromPtr(provider.vtable),
            .text_digest = hashParagraphText(text.asSlice()),
            .style_digest = hashParagraphStyle(style),
        };
    }
};

const ParagraphLayoutKey = struct {
    paragraph: ParagraphCacheKey,
    available_width_bits: u32,

    fn init(
        provider: paragraph_provider.Provider,
        text: types.String,
        style: paragraph_provider.TextStyle,
        available_width_px: f32,
    ) ParagraphLayoutKey {
        return .{
            .paragraph = ParagraphCacheKey.init(provider, text, style),
            .available_width_bits = @bitCast(available_width_px),
        };
    }
};

const ParagraphIntrinsicCacheEntry = struct {
    metrics: paragraph_provider.IntrinsicMetrics,
};

const ParagraphLayoutCacheEntry = struct {
    provider: paragraph_provider.Provider,
    render_data: paragraph_provider.RenderData,
};

fn hashParagraphText(text: []const u8) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &digest, .{});
    return digest;
}

fn hashParagraphScalar(
    comptime T: type,
    hasher: *Sha256,
    value: T,
) void {
    var copy = value;
    hasher.update(std.mem.asBytes(&copy));
}

fn hashParagraphStyle(
    style: paragraph_provider.TextStyle,
) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hashParagraphScalar(u32, &hasher, style.font_stack_id);
    hashParagraphScalar(u32, &hasher, @bitCast(style.size_px));
    hashParagraphScalar(u8, &hasher, @intFromEnum(style.direction));
    hashParagraphScalar(u8, &hasher, @intFromBool(style.script != null));
    if (style.script) |script| {
        hashParagraphScalar(u32, &hasher, @intFromEnum(script));
    }
    hashParagraphScalar(u64, &hasher, @intCast(style.language.len));
    hasher.update(style.language);
    hashParagraphScalar(u64, &hasher, @intCast(style.features.len));
    for (style.features) |feature| {
        hashParagraphScalar(u32, &hasher, @intFromEnum(feature.tag));
        hashParagraphScalar(u32, &hasher, feature.value);
        hashParagraphScalar(u32, &hasher, feature.byte_start);
        hashParagraphScalar(u32, &hasher, feature.byte_end);
    }
    hashParagraphScalar(u64, &hasher, @intCast(style.variations.len));
    for (style.variations) |variation| {
        hashParagraphScalar(u32, &hasher, @intFromEnum(variation.tag));
        hashParagraphScalar(u32, &hasher, @bitCast(variation.value));
    }
    hashParagraphScalar(u32, &hasher, @bitCast(style.letter_spacing_px));
    hashParagraphScalar(u32, &hasher, @bitCast(style.word_spacing_px));
    switch (style.line_height) {
        .font_default => hashParagraphScalar(u8, &hasher, 0),
        .multiplier => |value| {
            hashParagraphScalar(u8, &hasher, 1);
            hashParagraphScalar(u32, &hasher, @bitCast(value));
        },
        .absolute_px => |value| {
            hashParagraphScalar(u8, &hasher, 2);
            hashParagraphScalar(u32, &hasher, @bitCast(value));
        },
    }
    hashParagraphScalar(u8, &hasher, @intFromEnum(style.wrap));
    hashParagraphScalar(u8, &hasher, @intFromEnum(style.alignment));
    hashParagraphScalar(u8, &hasher, @intFromEnum(style.overflow));
    hashParagraphScalar(u8, &hasher, @intFromBool(style.max_lines != null));
    if (style.max_lines) |max_lines| {
        hashParagraphScalar(u32, &hasher, max_lines);
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

const PersistentElement = struct {
    element_id: types.ElementId,
    bounding_box: types.BoundingBox = .{},
    clip_element_id: u32 = 0,
    parent_id: u32 = 0,
    on_hover: ?types.HoverFunction = null,
    hover_user_data: ?*anyopaque = null,
    debug_data: debug_inspector.ElementDebugData = .{},
    generation: u32 = 0,
};

const HitRecord = struct {
    element_id: types.ElementId,
    bounding_box: types.BoundingBox,
    clip_box: ?types.BoundingBox = null,
    root_sequence: usize,
    capture_root: bool,
};

const RenderPhase = enum {
    pre,
    children,
    post,
};

const ApplicationCallbackPhase = enum {
    none,
    hover,
    transition,
    external_scroll,
    measure_text,
    paragraph_provider,
    error_handler,
};

const RenderFrame = struct {
    node_index: usize,
    position: types.Vector2,
    z_index: i16,
    root_sequence: usize,
    capture_root: bool,
    root_child_count: usize,
    ancestor_blocks_interactions: bool,
    phase: RenderPhase = .pre,
    next_child: usize = 0,
    bounding_box: types.BoundingBox = .{},
    offscreen: bool = false,
    skip_render: bool = false,
    blocks_interactions: bool = false,
    next_offset: types.Vector2 = .{},
    scroll_offset: types.Vector2 = .{},
};

const TransitionRuntime = struct {
    element_id: u32,
    parent_id: u32 = 0,
    state: types.TransitionState = .idle,
    initial: types.TransitionData = .{},
    current: types.TransitionData = .{},
    target: types.TransitionData = .{},
    elapsed_time: f32 = 0,
    active_properties: types.TransitionProperty = .none,
    old_parent_relative_position: types.Vector2 = .{},
    sibling_index: usize = 0,
    reparented: bool = false,
    appeared_this_frame: bool = false,
    exit_final_state_pending: bool = false,
    config: types.TransitionElementConfig = .{},
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    options: Options,
    layout_dimensions: types.Dimensions,
    root_resized_last_frame: bool = false,
    generation: u32 = 0,
    layout_open: bool = false,

    measure_text_function: ?types.MeasureTextFunction = null,
    measure_text_user_data: ?*anyopaque = null,
    paragraph_provider: ?paragraph_provider.Provider = null,
    query_scroll_offset_function: ?types.QueryScrollOffsetFunction = null,
    query_scroll_offset_user_data: ?*anyopaque = null,

    nodes: std.ArrayList(layout.Node) = .empty,
    child_indices: std.ArrayList(usize) = .empty,
    child_buffer: std.ArrayList(usize) = .empty,
    open_stack: std.ArrayList(OpenEntry) = .empty,
    roots: std.ArrayList(layout.Root) = .empty,
    texts: std.ArrayList(TextRecord) = .empty,
    paragraph_intrinsic_cache: std.ArrayList(ParagraphIntrinsicCacheEntry) = .empty,
    paragraph_layout_cache: std.ArrayList(ParagraphLayoutCacheEntry) = .empty,
    wrapped_lines: std.ArrayList(text_engine.WrappedLine) = .empty,
    render_commands: std.ArrayList(types.RenderCommand) = .empty,
    pointer_over_ids: std.ArrayList(types.ElementId) = .empty,
    hit_records: std.ArrayList(HitRecord) = .empty,
    pending_hit_records: std.ArrayList(HitRecord) = .empty,
    render_stack: std.ArrayList(RenderFrame) = .empty,
    layout_bfs: std.ArrayList(usize) = .empty,
    layout_resizable: std.ArrayList(usize) = .empty,
    layout_aspect_ratios: std.ArrayList(usize) = .empty,
    exit_removal_ids: std.ArrayList(u32) = .empty,
    clone_old_indices: std.ArrayList(usize) = .empty,
    stale_ids: std.ArrayList(u32) = .empty,
    transition_order: std.ArrayList(u32) = .empty,
    rollback_transition_order: std.ArrayList(u32) = .empty,
    scroll_containers: std.ArrayList(scroll_engine.Container) = .empty,
    rollback_scroll_containers: std.ArrayList(scroll_engine.Container) = .empty,
    callback_scroll_containers: std.ArrayList(scroll_engine.Container) = .empty,
    pending_scroll_query_ids: std.ArrayList(u32) = .empty,
    retained_nodes: std.ArrayList(layout.Node) = .empty,
    retained_child_indices: std.ArrayList(usize) = .empty,
    retained_texts: std.ArrayList(TextRecord) = .empty,
    pending_retained_nodes: std.ArrayList(layout.Node) = .empty,
    pending_retained_child_indices: std.ArrayList(usize) = .empty,
    pending_retained_texts: std.ArrayList(TextRecord) = .empty,
    debug_rows: std.ArrayList(debug_inspector.Row) = .empty,
    debug_traversal: std.ArrayList(debug_inspector.TraversalEntry) = .empty,
    debug_dynamic_strings: std.ArrayList(u8) = .empty,
    debug_collision_ids: std.ArrayList(u32) = .empty,
    debug_warnings: std.ArrayList(debug_inspector.Warning) = .empty,

    id_to_index: std.AutoHashMap(u32, usize),
    retained_id_to_index: std.AutoHashMap(u32, usize),
    pending_retained_id_to_index: std.AutoHashMap(u32, usize),
    clone_old_to_new: std.AutoHashMap(usize, usize),
    persistent_elements: std.AutoHashMap(u32, PersistentElement),
    transition_states: std.AutoHashMap(u32, TransitionRuntime),
    rollback_transition_states: std.AutoHashMap(u32, TransitionRuntime),
    text_cache_preflight_keys: std.AutoHashMap(text_engine.MeasurementKey, void),
    paragraph_intrinsic_cache_map: std.AutoHashMap(ParagraphCacheKey, usize),
    paragraph_layout_cache_map: std.AutoHashMap(ParagraphLayoutKey, usize),
    text_cache: text_engine.Cache,

    pointer_info: types.PointerData = .{},
    callback_scroll_position: types.Vector2 = .{},
    callback_render_command: types.RenderCommand = .{},
    pointer_over_capacity: usize = 0,
    pointer_update_active: bool = false,
    application_callback_phase: ApplicationCallbackPhase = .none,
    frame_rollback_snapshot_active: bool = false,
    culling_enabled: bool = true,
    debug_mode_enabled: bool = false,
    debug_selected_element_id: u32 = 0,
    pending_debug_mode_enabled: bool = false,
    pending_debug_selected_element_id: u32 = 0,
    pending_debug_collapse_id: ?u32 = null,
    debug_view_width: u32 = debug_inspector.default_view_width,
    debug_highlight_color: types.Color = debug_inspector.default_highlight_color,
    debug_theme: debug_inspector.Theme = debug_inspector.default_theme,
    debug_view_action: ?debug_inspector.Action = null,
    debug_warnings_enabled: bool = false,
    external_scroll_handling_enabled: bool = false,
    apply_transition_overrides: bool = false,
    warned_missing_measure: bool = false,
    warned_text_capacity: bool = false,
    warned_element_capacity: bool = false,
    warned_render_capacity: bool = false,
    last_paragraph_provider_failure: ?paragraph_provider.Failure = null,

    pub fn init(allocator: std.mem.Allocator, dimensions: types.Dimensions, options: Options) Context {
        const normalized_options = normalizeOptions(options);
        return .{
            .allocator = allocator,
            .options = normalized_options,
            .layout_dimensions = dimensions,
            .pointer_over_capacity = normalized_options.max_element_count,
            .id_to_index = std.AutoHashMap(u32, usize).init(allocator),
            .retained_id_to_index = std.AutoHashMap(u32, usize).init(allocator),
            .pending_retained_id_to_index = std.AutoHashMap(u32, usize).init(allocator),
            .clone_old_to_new = std.AutoHashMap(usize, usize).init(allocator),
            .persistent_elements = std.AutoHashMap(u32, PersistentElement).init(allocator),
            .transition_states = std.AutoHashMap(u32, TransitionRuntime).init(allocator),
            .rollback_transition_states = std.AutoHashMap(u32, TransitionRuntime).init(allocator),
            .text_cache_preflight_keys = std.AutoHashMap(text_engine.MeasurementKey, void).init(allocator),
            .paragraph_intrinsic_cache_map = std.AutoHashMap(
                ParagraphCacheKey,
                usize,
            ).init(allocator),
            .paragraph_layout_cache_map = std.AutoHashMap(
                ParagraphLayoutKey,
                usize,
            ).init(allocator),
            .text_cache = text_engine.Cache.initWithLimits(
                allocator,
                @max(normalized_options.max_text_cache_word_count / 32, 1),
                normalized_options.max_text_cache_word_count,
            ),
        };
    }

    pub fn deinit(self: *Context) void {
        // Application callbacks may retain the context through their opaque
        // user-data pointer. Destroying it while an engine operation is still
        // using its storage would turn ordinary callback reentry into a
        // use-after-free, so the Clay-compatible void API follows the same
        // callback-time no-op rule as the other configuration mutators.
        if (self.application_callback_phase != .none) return;
        self.releaseParagraphLayoutsBestEffort();
        self.nodes.deinit(self.allocator);
        self.child_indices.deinit(self.allocator);
        self.child_buffer.deinit(self.allocator);
        self.open_stack.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.texts.deinit(self.allocator);
        self.paragraph_intrinsic_cache.deinit(self.allocator);
        self.paragraph_layout_cache.deinit(self.allocator);
        self.wrapped_lines.deinit(self.allocator);
        self.render_commands.deinit(self.allocator);
        self.pointer_over_ids.deinit(self.allocator);
        self.hit_records.deinit(self.allocator);
        self.pending_hit_records.deinit(self.allocator);
        self.render_stack.deinit(self.allocator);
        self.layout_bfs.deinit(self.allocator);
        self.layout_resizable.deinit(self.allocator);
        self.layout_aspect_ratios.deinit(self.allocator);
        self.exit_removal_ids.deinit(self.allocator);
        self.clone_old_indices.deinit(self.allocator);
        self.stale_ids.deinit(self.allocator);
        self.transition_order.deinit(self.allocator);
        self.rollback_transition_order.deinit(self.allocator);
        self.scroll_containers.deinit(self.allocator);
        self.rollback_scroll_containers.deinit(self.allocator);
        self.callback_scroll_containers.deinit(self.allocator);
        self.pending_scroll_query_ids.deinit(self.allocator);
        self.retained_nodes.deinit(self.allocator);
        self.retained_child_indices.deinit(self.allocator);
        self.retained_texts.deinit(self.allocator);
        self.pending_retained_nodes.deinit(self.allocator);
        self.pending_retained_child_indices.deinit(self.allocator);
        self.pending_retained_texts.deinit(self.allocator);
        self.debug_rows.deinit(self.allocator);
        self.debug_traversal.deinit(self.allocator);
        self.debug_dynamic_strings.deinit(self.allocator);
        self.debug_collision_ids.deinit(self.allocator);
        self.debug_warnings.deinit(self.allocator);
        self.id_to_index.deinit();
        self.retained_id_to_index.deinit();
        self.pending_retained_id_to_index.deinit();
        self.clone_old_to_new.deinit();
        self.persistent_elements.deinit();
        self.transition_states.deinit();
        self.rollback_transition_states.deinit();
        self.text_cache_preflight_keys.deinit();
        self.paragraph_intrinsic_cache_map.deinit();
        self.paragraph_layout_cache_map.deinit();
        self.text_cache.deinit();
        self.* = undefined;
    }

    pub fn setMeasureTextFunction(self: *Context, function: ?types.MeasureTextFunction, user_data: ?*anyopaque) void {
        if (self.application_callback_phase != .none) return;
        self.measure_text_function = function;
        self.measure_text_user_data = user_data;
    }

    /// Install or clear a context-local optional paragraph provider. A provider
    /// cannot change inside an open layout. Replacing it invalidates returned
    /// commands and releases every outstanding frame lease first.
    pub fn setParagraphProvider(self: *Context, provider: ?paragraph_provider.Provider) void {
        if (self.application_callback_phase != .none or self.layout_open) return;
        self.last_paragraph_provider_failure = null;
        self.releaseParagraphLayoutsBestEffort();
        self.clearParagraphIntrinsicCache();
        self.render_commands.clearRetainingCapacity();
        self.paragraph_provider = provider;
    }

    pub fn getParagraphProvider(self: *const Context) ?paragraph_provider.Provider {
        return self.paragraph_provider;
    }

    pub fn getLastParagraphProviderFailure(self: *const Context) ?paragraph_provider.Failure {
        return self.last_paragraph_provider_failure;
    }

    /// Safely resolve a provider paragraph carried through the existing custom
    /// render-command channel. The command must be borrowed from the current
    /// Context command array; copied and unrelated application pointers are
    /// never dereferenced or reinterpreted. The pointer is invalid after the
    /// next Context mutation and may then alias newly reused command storage.
    pub fn paragraphRenderData(
        self: *const Context,
        command: *const types.RenderCommand,
    ) ?*const paragraph_provider.RenderData {
        const commands = self.render_commands.items;
        if (commands.len == 0) return null;
        const command_address = @intFromPtr(command);
        const first_command_address = @intFromPtr(&commands[0]);
        if (command_address < first_command_address) return null;
        const command_offset = command_address - first_command_address;
        if (command_offset % @sizeOf(types.RenderCommand) != 0) return null;
        const command_index = command_offset / @sizeOf(types.RenderCommand);
        if (command_index >= commands.len) return null;
        const current_command = &commands[command_index];
        if (current_command.command_type != .custom) return null;

        const custom_pointer = current_command.render_data.custom.custom_data orelse return null;
        const layouts = self.paragraph_layout_cache.items;
        if (layouts.len == 0) return null;
        const custom_address = @intFromPtr(custom_pointer);
        const first_render_data_address = @intFromPtr(&layouts[0].render_data);
        if (custom_address < first_render_data_address) return null;
        const layout_offset = custom_address - first_render_data_address;
        if (layout_offset % @sizeOf(ParagraphLayoutCacheEntry) != 0) return null;
        const layout_index = layout_offset / @sizeOf(ParagraphLayoutCacheEntry);
        if (layout_index >= layouts.len) return null;
        const render_data = &layouts[layout_index].render_data;
        if (@intFromPtr(render_data) != custom_address) return null;
        return render_data;
    }

    pub fn resetMeasureTextCache(self: *Context) void {
        if (self.application_callback_phase != .none) return;
        self.releaseParagraphLayoutsBestEffort();
        self.clearParagraphIntrinsicCache();
        self.render_commands.clearRetainingCapacity();
        self.text_cache.reset();
    }

    pub fn setQueryScrollOffsetFunction(self: *Context, function: ?types.QueryScrollOffsetFunction, user_data: ?*anyopaque) void {
        if (self.application_callback_phase != .none) return;
        self.query_scroll_offset_function = function;
        self.query_scroll_offset_user_data = user_data;
    }

    pub fn setLayoutDimensions(self: *Context, dimensions: types.Dimensions) void {
        if (self.application_callback_phase != .none) return;
        self.root_resized_last_frame = !layout.floatEqual(self.layout_dimensions.width, dimensions.width) or
            !layout.floatEqual(self.layout_dimensions.height, dimensions.height);
        self.layout_dimensions = dimensions;
    }

    pub fn getLayoutDimensions(self: *const Context) types.Dimensions {
        return self.layout_dimensions;
    }

    pub fn setDebugModeEnabled(self: *Context, enabled: bool) void {
        if (self.application_callback_phase != .none) return;
        self.debug_mode_enabled = enabled;
        if (self.layout_open) self.pending_debug_mode_enabled = enabled;
    }

    pub fn isDebugModeEnabled(self: *const Context) bool {
        return self.debug_mode_enabled;
    }

    /// Override the width reserved for Clay's built-in inspector. Like the
    /// upstream global, this value is consumed by the next `beginLayout`.
    pub fn setDebugViewWidth(self: *Context, width: u32) void {
        if (self.application_callback_phase != .none) return;
        self.debug_view_width = width;
    }

    /// Override the translucent overlay used to identify the hovered layout
    /// element while the inspector is visible.
    pub fn setDebugViewHighlightColor(self: *Context, color: types.Color) void {
        if (self.application_callback_phase != .none) return;
        self.debug_highlight_color = color;
    }

    pub fn getDebugViewWidth(self: *const Context) u32 {
        return self.debug_view_width;
    }

    pub fn getDebugViewHighlightColor(self: *const Context) types.Color {
        return self.debug_highlight_color;
    }

    pub fn setDebugViewTheme(self: *Context, theme: debug_inspector.Theme) void {
        if (self.application_callback_phase != .none) return;
        self.debug_theme = theme;
        self.debug_theme.font_size = std.math.clamp(self.debug_theme.font_size, 8, 48);
        self.debug_theme.tree_control_size = std.math.clamp(
            self.debug_theme.tree_control_size,
            1,
            30,
        );
        self.debug_theme.close_control_size = std.math.clamp(
            self.debug_theme.close_control_size,
            1,
            30,
        );
        const content_height = @max(
            @as(u8, @intCast(self.debug_theme.font_size)),
            @max(self.debug_theme.tree_control_size, self.debug_theme.close_control_size),
        );
        self.debug_theme.row_height = std.math.clamp(
            self.debug_theme.row_height,
            content_height,
            64,
        );
    }

    pub fn getDebugViewTheme(self: *const Context) debug_inspector.Theme {
        return self.debug_theme;
    }

    /// Queue one renderer-neutral inspector action for the next successful
    /// frame. A later call replaces the queued action; rejected frames retain
    /// it so input is not lost.
    pub fn setDebugViewAction(self: *Context, action: debug_inspector.Action) void {
        if (self.application_callback_phase != .none or self.layout_open) return;
        if (!self.debug_mode_enabled) return;
        self.debug_view_action = action;
    }

    pub fn getDebugViewState(self: *const Context) debug_inspector.State {
        if (!self.debug_mode_enabled) return .{};
        var state = debug_inspector.State{
            .enabled = true,
            .selected_element_id = self.debug_selected_element_id,
            .row_count = std.math.cast(i32, self.debug_rows.items.len) orelse
                std.math.maxInt(i32),
        };
        for (self.debug_rows.items) |row| {
            if (row.kind != .element) continue;
            if (row.element_id != self.debug_selected_element_id) continue;
            state.selected_row_index = row.row_index;
            break;
        }
        return state;
    }

    pub fn setCullingEnabled(self: *Context, enabled: bool) void {
        if (self.application_callback_phase != .none) return;
        self.culling_enabled = enabled;
    }

    pub fn setExternalScrollHandlingEnabled(self: *Context, enabled: bool) void {
        if (self.application_callback_phase != .none) return;
        self.external_scroll_handling_enabled = enabled;
    }

    pub fn getMaxElementCount(self: *const Context) usize {
        return self.options.max_element_count;
    }

    pub fn setMaxElementCount(self: *Context, count: usize) void {
        if (self.application_callback_phase != .none) return;
        const normalized_count = @min(count, max_public_array_capacity);
        self.options.max_element_count = normalized_count;
        // Clay's pointer-over array is persistent storage allocated from the
        // maximum in effect at initialization. Raising the declaration limit
        // may grow ZLAY's native list, but lowering it must not make already
        // published array metadata claim less capacity than it has length.
        self.pointer_over_capacity = @max(self.pointer_over_capacity, normalized_count);
    }

    pub fn getMaxMeasureTextCacheWordCount(self: *const Context) usize {
        return self.options.max_text_cache_word_count;
    }

    pub fn setMaxMeasureTextCacheWordCount(self: *Context, count: usize) void {
        if (self.application_callback_phase != .none) return;
        self.options.max_text_cache_word_count = count;
        self.text_cache.setMaxWordCount(count);
    }

    pub fn beginLayout(self: *Context) !void {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        if (self.layout_open) return Error.LayoutAlreadyOpen;

        try self.releaseParagraphLayoutsFallible();
        self.clearParagraphIntrinsicCache();
        try self.snapshotMutableFrameState();

        self.pending_debug_mode_enabled = self.debug_mode_enabled;
        self.pending_debug_selected_element_id = self.debug_selected_element_id;
        self.pending_debug_collapse_id = null;

        self.nodes.clearRetainingCapacity();
        self.child_indices.clearRetainingCapacity();
        self.child_buffer.clearRetainingCapacity();
        self.open_stack.clearRetainingCapacity();
        self.roots.clearRetainingCapacity();
        self.texts.clearRetainingCapacity();
        self.wrapped_lines.clearRetainingCapacity();
        self.render_commands.clearRetainingCapacity();
        self.pending_hit_records.clearRetainingCapacity();
        self.pending_scroll_query_ids.clearRetainingCapacity();
        self.id_to_index.clearRetainingCapacity();
        var root_dimensions = self.layout_dimensions;
        if (self.debug_mode_enabled) root_dimensions.width = debug_inspector.contentWidth(
            root_dimensions.width,
            true,
            self.debug_view_width,
        );
        const root_id = hashes.string(types.String.literal("Clay__RootContainer"), 0);
        var declaration = types.ElementDeclaration{};
        declaration.layout.sizing.width = types.fixed(root_dimensions.width);
        declaration.layout.sizing.height = types.fixed(root_dimensions.height);

        try self.nodes.ensureTotalCapacity(self.allocator, 1);
        try self.open_stack.ensureTotalCapacity(self.allocator, 1);
        try self.roots.ensureTotalCapacity(self.allocator, 1);
        try self.id_to_index.ensureTotalCapacity(1);

        self.nodes.appendAssumeCapacity(.{
            .element_id = root_id,
            .config = declaration,
            .dimensions = root_dimensions,
            .min_dimensions = root_dimensions,
            .configured = true,
        });
        self.id_to_index.putAssumeCapacity(root_id.id, 0);
        self.open_stack.appendAssumeCapacity(.{ .node_index = 0 });
        self.roots.appendAssumeCapacity(.{ .element_index = 0 });
        self.generation +%= 1;
        self.warned_missing_measure = false;
        self.warned_text_capacity = false;
        self.warned_element_capacity = false;
        self.warned_render_capacity = false;
        self.debug_dynamic_strings.clearRetainingCapacity();
        self.debug_collision_ids.clearRetainingCapacity();
        self.debug_warnings.clearRetainingCapacity();
        self.frame_rollback_snapshot_active = true;
        self.layout_open = true;
    }

    /// Exact native mapping of `Clay_GetElementId`, retaining the supplied
    /// string lifetime metadata and backing identity in the result.
    pub fn getElementId(_: *const Context, value: types.String) types.ElementId {
        return hashes.string(value, 0);
    }

    /// Exact native mapping of `Clay_GetElementIdWithIndex`.
    pub fn getElementIdWithIndex(_: *const Context, value: types.String, index: u32) types.ElementId {
        return hashes.stringWithOffset(value, index, 0);
    }

    pub fn id(self: *const Context, label: []const u8) types.ElementId {
        return self.getElementId(types.String.fromSlice(label));
    }

    pub fn staticId(self: *const Context, comptime label: []const u8) types.ElementId {
        return self.getElementId(types.String.literal(label));
    }

    pub fn indexedId(self: *const Context, label: []const u8, index: u32) types.ElementId {
        return self.getElementIdWithIndex(types.String.fromSlice(label), index);
    }

    pub fn staticIndexedId(self: *const Context, comptime label: []const u8, index: u32) types.ElementId {
        return self.getElementIdWithIndex(types.String.literal(label), index);
    }

    pub fn getLocalElementId(self: *const Context, value: types.String) !types.ElementId {
        return hashes.string(value, try self.getOpenElementId());
    }

    pub fn getLocalElementIdWithIndex(self: *const Context, value: types.String, index: u32) !types.ElementId {
        return hashes.stringWithOffset(value, index, try self.getOpenElementId());
    }

    pub fn localId(self: *const Context, label: []const u8) !types.ElementId {
        return self.getLocalElementId(types.String.fromSlice(label));
    }

    pub fn indexedLocalId(self: *const Context, label: []const u8, index: u32) !types.ElementId {
        return self.getLocalElementIdWithIndex(types.String.fromSlice(label), index);
    }

    pub fn staticLocalId(self: *const Context, comptime label: []const u8) !types.ElementId {
        return self.getLocalElementId(types.String.literal(label));
    }

    pub fn staticIndexedLocalId(self: *const Context, comptime label: []const u8, index: u32) !types.ElementId {
        return self.getLocalElementIdWithIndex(types.String.literal(label), index);
    }

    pub fn getOpenElementId(self: *const Context) !u32 {
        const entry = self.open_stack.getLastOrNull() orelse return Error.NoOpenElement;
        return self.nodes.items[entry.node_index].element_id.id;
    }

    pub fn openElement(self: *Context, declaration: types.ElementDeclaration) !void {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        const parent_entry = self.open_stack.getLastOrNull() orelse return Error.NoOpenElement;
        const parent = &self.nodes.items[parent_entry.node_index];
        const offset: u32 = @intCast(parent.children_len + parent.floating_children_count);
        try self.openElementWithId(hashes.number(offset, parent.element_id.id), declaration);
    }

    /// Run `body(self)` inside an automatic-ID element and close it even when
    /// the body returns an error. The low-level primitives remain available for
    /// declaration-order-sensitive code.
    pub fn element(self: *Context, declaration: types.ElementDeclaration, body: anytype) !void {
        const parent_depth = self.open_stack.items.len;
        try self.openElement(declaration);
        const parent_node_index = self.open_stack.items[parent_depth - 1].node_index;
        const scoped_node_index = self.open_stack.items[parent_depth].node_index;
        body(self) catch |body_error| {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return body_error;
        };
        if (!self.scopedEntryMatches(parent_depth, scoped_node_index)) {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return Error.ScopedElementUnbalanced;
        }
        self.closeElement() catch |close_error| {
            self.abortLayoutAfterCleanupFailure();
            return close_error;
        };
    }

    /// Explicit-ID counterpart to `element`.
    pub fn elementWithId(
        self: *Context,
        element_id: types.ElementId,
        declaration: types.ElementDeclaration,
        body: anytype,
    ) !void {
        const parent_depth = self.open_stack.items.len;
        try self.openElementWithId(element_id, declaration);
        const parent_node_index = self.open_stack.items[parent_depth - 1].node_index;
        const scoped_node_index = self.open_stack.items[parent_depth].node_index;
        body(self) catch |body_error| {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return body_error;
        };
        if (!self.scopedEntryMatches(parent_depth, scoped_node_index)) {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return Error.ScopedElementUnbalanced;
        }
        self.closeElement() catch |close_error| {
            self.abortLayoutAfterCleanupFailure();
            return close_error;
        };
    }

    /// Scoped automatic-ID declaration whose factory is invoked after the
    /// element is opened. Use this when declaration construction calls
    /// `hovered`, `getScrollOffset`, or another open-element query.
    pub fn elementDeferred(self: *Context, declaration_factory: anytype, body: anytype) !void {
        const parent_depth = self.open_stack.items.len;
        try self.openElementUnconfigured();
        const parent_node_index = self.open_stack.items[parent_depth - 1].node_index;
        const scoped_node_index = self.open_stack.items[parent_depth].node_index;
        const declaration = declaration_factory(self) catch |factory_error| {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return factory_error;
        };
        if (!self.scopedEntryMatches(parent_depth, scoped_node_index)) {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return Error.ScopedElementUnbalanced;
        }
        self.configureOpenElement(declaration) catch |configure_error| {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return configure_error;
        };
        body(self) catch |body_error| {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return body_error;
        };
        if (!self.scopedEntryMatches(parent_depth, scoped_node_index)) {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return Error.ScopedElementUnbalanced;
        }
        self.closeElement() catch |close_error| {
            self.abortLayoutAfterCleanupFailure();
            return close_error;
        };
    }

    /// Explicit-ID counterpart to `elementDeferred`.
    pub fn elementWithIdDeferred(
        self: *Context,
        element_id: types.ElementId,
        declaration_factory: anytype,
        body: anytype,
    ) !void {
        const parent_depth = self.open_stack.items.len;
        try self.openElementWithIdUnconfigured(element_id);
        const parent_node_index = self.open_stack.items[parent_depth - 1].node_index;
        const scoped_node_index = self.open_stack.items[parent_depth].node_index;
        const declaration = declaration_factory(self) catch |factory_error| {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return factory_error;
        };
        if (!self.scopedEntryMatches(parent_depth, scoped_node_index)) {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return Error.ScopedElementUnbalanced;
        }
        self.configureOpenElement(declaration) catch |configure_error| {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return configure_error;
        };
        body(self) catch |body_error| {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return body_error;
        };
        if (!self.scopedEntryMatches(parent_depth, scoped_node_index)) {
            try self.restoreScopedDepth(parent_depth, parent_node_index);
            return Error.ScopedElementUnbalanced;
        }
        self.closeElement() catch |close_error| {
            self.abortLayoutAfterCleanupFailure();
            return close_error;
        };
    }

    fn closeToDepth(self: *Context, depth: usize) !void {
        while (self.open_stack.items.len > depth) {
            try self.closeElement();
        }
    }

    fn scopedEntryMatches(self: *const Context, parent_depth: usize, node_index: usize) bool {
        return self.open_stack.items.len == parent_depth + 1 and
            self.open_stack.items[parent_depth].node_index == node_index;
    }

    fn restoreScopedDepth(self: *Context, depth: usize, parent_node_index: usize) !void {
        if (self.open_stack.items.len < depth) {
            self.abortLayoutAfterCleanupFailure();
            return Error.ScopedElementUnbalanced;
        }
        self.closeToDepth(depth) catch |cleanup_error| {
            self.abortLayoutAfterCleanupFailure();
            return cleanup_error;
        };
        if (depth == 0 or self.open_stack.items[depth - 1].node_index != parent_node_index) {
            self.abortLayoutAfterCleanupFailure();
            return Error.ScopedElementUnbalanced;
        }
    }

    /// A scoped helper cannot safely continue a partially unwound frame when
    /// its automatic close needs storage that the allocator cannot provide.
    /// Close the frame without allocation and restore the transition/scroll
    /// snapshot captured by `beginLayout`. The last completed frame's public
    /// state remains valid, and the next `beginLayout` rebuilds frame-local
    /// collections.
    fn abortLayoutAfterCleanupFailure(self: *Context) void {
        self.open_stack.clearRetainingCapacity();
        self.rollbackMutableFrameState();
        self.apply_transition_overrides = false;
        self.layout_open = false;
    }

    /// Open an automatic-ID element before its declaration is evaluated.
    /// Pair this with `configureOpenElement` to preserve Clay's declaration
    /// evaluation order for `hovered()` and `getScrollOffset()` expressions.
    pub fn openElementUnconfigured(self: *Context) !void {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        const parent_entry = self.open_stack.getLastOrNull() orelse return Error.NoOpenElement;
        const parent = &self.nodes.items[parent_entry.node_index];
        const offset: u32 = @intCast(parent.children_len + parent.floating_children_count);
        try self.openElementWithIdUnconfigured(hashes.number(offset, parent.element_id.id));
    }

    /// Explicit-ID half of the split open/configure primitive.
    pub fn openElementWithIdUnconfigured(self: *Context, element_id: types.ElementId) !void {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        if (!self.layout_open) return Error.LayoutNotOpen;
        if (self.nodes.items.len >= self.options.max_element_count) {
            if (!self.warned_element_capacity) {
                self.warned_element_capacity = true;
                self.emitError(.elements_capacity_exceeded, "Clay ran out of capacity while attempting to create layout elements.");
            }
            return Error.ElementCapacityExceeded;
        }
        const parent_entry = self.open_stack.getLastOrNull() orelse return Error.NoOpenElement;
        const parent_index = parent_entry.node_index;
        const node_index = self.nodes.items.len;

        try self.nodes.ensureTotalCapacity(self.allocator, node_index + 1);
        try self.id_to_index.ensureTotalCapacity(self.id_to_index.count() + 1);
        try self.open_stack.ensureTotalCapacity(self.allocator, self.open_stack.items.len + 1);
        const duplicate_id = self.id_to_index.contains(element_id.id);
        if (duplicate_id) try self.preflightDebugCollision(element_id.id);

        self.nodes.appendAssumeCapacity(.{
            .element_id = element_id,
            .parent_index = parent_index,
            .clip_element_id = parent_entry.active_clip_id,
            .clip_node_index = parent_entry.active_clip_node_index,
        });
        if (duplicate_id) {
            self.emitError(.duplicate_id, "An element with this ID was already previously declared during this layout.");
            self.markDebugCollisionAssumeCapacity(element_id.id);
        } else {
            self.id_to_index.putAssumeCapacity(element_id.id, node_index);
        }
        self.open_stack.appendAssumeCapacity(.{
            .node_index = node_index,
            .active_clip_id = parent_entry.active_clip_id,
            .active_clip_node_index = parent_entry.active_clip_node_index,
        });
    }

    /// Configure the element most recently opened by an unconfigured primitive.
    pub fn configureOpenElement(self: *Context, declaration_value: types.ElementDeclaration) !void {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        if (!self.layout_open) return Error.LayoutNotOpen;
        if (self.open_stack.items.len <= 1) return Error.CannotConfigureRoot;
        const open_index = self.open_stack.items.len - 1;
        const node_index = self.open_stack.items[open_index].node_index;
        if (self.nodes.items[node_index].configured) return Error.ElementAlreadyConfigured;
        const parent_entry = self.open_stack.items[open_index - 1];
        const parent = &self.nodes.items[parent_entry.node_index];
        var declaration = declaration_value;

        const percentage_over_1 =
            (declaration.layout.sizing.width.type == .percent and declaration.layout.sizing.width.size.percent > 1) or
            (declaration.layout.sizing.height.type == .percent and declaration.layout.sizing.height.size.percent > 1);

        var inherited_clip_id = parent_entry.active_clip_id;
        var inherited_clip_node_index = parent_entry.active_clip_node_index;
        var floating_parent_node_index: ?usize = null;
        var floating_parent_missing = false;
        if (declaration.floating.attach_to != .none) {
            switch (declaration.floating.attach_to) {
                .parent => {
                    declaration.floating.parent_id = parent.element_id.id;
                    floating_parent_node_index = parent_entry.node_index;
                    inherited_clip_id = parent_entry.active_clip_id;
                    inherited_clip_node_index = parent_entry.active_clip_node_index;
                },
                .root => {
                    declaration.floating.parent_id = self.nodes.items[0].element_id.id;
                    floating_parent_node_index = 0;
                    inherited_clip_id = 0;
                    inherited_clip_node_index = null;
                },
                .element_with_id => {
                    if (self.id_to_index.get(declaration.floating.parent_id)) |attached_index| {
                        floating_parent_node_index = attached_index;
                        inherited_clip_id = self.nodes.items[attached_index].clip_element_id;
                        inherited_clip_node_index = self.nodes.items[attached_index].clip_node_index;
                    } else {
                        inherited_clip_id = 0;
                        inherited_clip_node_index = null;
                        floating_parent_missing = true;
                    }
                },
                .none => unreachable,
            }
            if (declaration.floating.clip_to == .none) {
                inherited_clip_id = 0;
                inherited_clip_node_index = null;
            }
        }

        if (declaration.floating.attach_to != .none) {
            try self.roots.ensureTotalCapacity(self.allocator, self.roots.items.len + 1);
        }
        const owns_id = self.id_to_index.get(self.nodes.items[node_index].element_id.id) == node_index;
        if (owns_id and (declaration.clip.horizontal or declaration.clip.vertical)) {
            try self.scroll_containers.ensureTotalCapacity(self.allocator, self.scroll_containers.items.len + 1);
            try self.callback_scroll_containers.ensureTotalCapacity(self.allocator, self.scroll_containers.items.len + 1);
            if (self.external_scroll_handling_enabled and self.query_scroll_offset_function != null) {
                try self.pending_scroll_query_ids.ensureTotalCapacity(
                    self.allocator,
                    self.pending_scroll_query_ids.items.len + 1,
                );
            }
        }
        if (owns_id) {
            try self.preflightTransitionRegistration(self.nodes.items[node_index].element_id.id, declaration.transition);
        } else {
            declaration.transition = .{};
        }

        // Diagnostics are externally observable callbacks. Defer them until
        // every fallible declaration preflight has succeeded, while retaining
        // Clay's ordering before the node itself becomes configured.
        if (percentage_over_1) {
            self.emitError(.percentage_over_1, "An element was configured with CLAY_SIZING_PERCENT, but the provided percentage value was over 1.0. Clay expects a value between 0 and 1, i.e. 20% is 0.2.");
        }
        if (floating_parent_missing) {
            self.emitError(.floating_container_parent_not_found, "A floating element was declared with a parentId, but no element with that ID was found.");
        }

        self.nodes.items[node_index].config = declaration;
        self.nodes.items[node_index].clip_element_id = inherited_clip_id;
        self.nodes.items[node_index].clip_node_index = inherited_clip_node_index;
        self.nodes.items[node_index].configured = true;
        if (declaration.clip.horizontal or declaration.clip.vertical) {
            self.open_stack.items[open_index].active_clip_id = self.nodes.items[node_index].element_id.id;
            self.open_stack.items[open_index].active_clip_node_index = node_index;
        } else {
            self.open_stack.items[open_index].active_clip_id = inherited_clip_id;
            self.open_stack.items[open_index].active_clip_node_index = inherited_clip_node_index;
        }

        if (declaration.floating.attach_to != .none) {
            self.roots.appendAssumeCapacity(.{
                .element_index = node_index,
                .parent_id = declaration.floating.parent_id,
                .parent_node_index = floating_parent_node_index,
                .clip_element_id = inherited_clip_id,
                .clip_node_index = inherited_clip_node_index,
                .z_index = declaration.floating.z_index,
            });
        }
        if (owns_id and (declaration.clip.horizontal or declaration.clip.vertical)) {
            self.reopenScrollContainer(self.nodes.items[node_index].element_id.id, declaration.clip);
        }
        if (owns_id) self.configureTransitionForNode(node_index);
    }

    pub fn openElementWithId(self: *Context, element_id: types.ElementId, declaration_value: types.ElementDeclaration) !void {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        if (!self.layout_open) return Error.LayoutNotOpen;
        if (self.nodes.items.len >= self.options.max_element_count) {
            if (!self.warned_element_capacity) {
                self.warned_element_capacity = true;
                self.emitError(.elements_capacity_exceeded, "Clay ran out of capacity while attempting to create layout elements.");
            }
            return Error.ElementCapacityExceeded;
        }
        const parent_entry = self.open_stack.getLastOrNull() orelse return Error.NoOpenElement;
        const parent_index = parent_entry.node_index;
        const parent = &self.nodes.items[parent_index];
        var declaration = declaration_value;

        const percentage_over_1 =
            (declaration.layout.sizing.width.type == .percent and declaration.layout.sizing.width.size.percent > 1) or
            (declaration.layout.sizing.height.type == .percent and declaration.layout.sizing.height.size.percent > 1);

        var inherited_clip_id = parent_entry.active_clip_id;
        var inherited_clip_node_index = parent_entry.active_clip_node_index;
        var floating_parent_node_index: ?usize = null;
        var floating_parent_missing = false;
        if (declaration.floating.attach_to != .none) {
            switch (declaration.floating.attach_to) {
                .parent => {
                    declaration.floating.parent_id = parent.element_id.id;
                    floating_parent_node_index = parent_index;
                    inherited_clip_id = parent_entry.active_clip_id;
                    inherited_clip_node_index = parent_entry.active_clip_node_index;
                },
                .root => {
                    declaration.floating.parent_id = self.nodes.items[0].element_id.id;
                    floating_parent_node_index = 0;
                    inherited_clip_id = 0;
                    inherited_clip_node_index = null;
                },
                .element_with_id => {
                    if (self.id_to_index.get(declaration.floating.parent_id)) |attached_index| {
                        const attached = &self.nodes.items[attached_index];
                        floating_parent_node_index = attached_index;
                        inherited_clip_id = attached.clip_element_id;
                        inherited_clip_node_index = attached.clip_node_index;
                    } else {
                        inherited_clip_id = 0;
                        inherited_clip_node_index = null;
                        floating_parent_missing = true;
                    }
                },
                .none => unreachable,
            }
            if (declaration.floating.clip_to == .none) {
                inherited_clip_id = 0;
                inherited_clip_node_index = null;
            }
        }

        const node_index = self.nodes.items.len;
        const duplicate_id = self.id_to_index.contains(element_id.id);
        try self.nodes.ensureTotalCapacity(self.allocator, node_index + 1);
        try self.id_to_index.ensureTotalCapacity(self.id_to_index.count() + 1);
        try self.open_stack.ensureTotalCapacity(self.allocator, self.open_stack.items.len + 1);
        if (declaration.floating.attach_to != .none) {
            try self.roots.ensureTotalCapacity(self.allocator, self.roots.items.len + 1);
        }
        if (!duplicate_id and (declaration.clip.horizontal or declaration.clip.vertical)) {
            try self.scroll_containers.ensureTotalCapacity(self.allocator, self.scroll_containers.items.len + 1);
            try self.callback_scroll_containers.ensureTotalCapacity(self.allocator, self.scroll_containers.items.len + 1);
            if (self.external_scroll_handling_enabled and self.query_scroll_offset_function != null) {
                try self.pending_scroll_query_ids.ensureTotalCapacity(
                    self.allocator,
                    self.pending_scroll_query_ids.items.len + 1,
                );
            }
        }
        if (!duplicate_id) try self.preflightTransitionRegistration(element_id.id, declaration.transition);
        if (duplicate_id) try self.preflightDebugCollision(element_id.id);
        if (duplicate_id) declaration.transition = .{};

        // Do not report a declaration that a later allocator failure prevents
        // from being committed. There are no fallible operations after these
        // callbacks and before the append sequence below.
        if (percentage_over_1) {
            self.emitError(.percentage_over_1, "An element was configured with CLAY_SIZING_PERCENT, but the provided percentage value was over 1.0. Clay expects a value between 0 and 1, i.e. 20% is 0.2.");
        }
        if (floating_parent_missing) {
            self.emitError(.floating_container_parent_not_found, "A floating element was declared with a parentId, but no element with that ID was found.");
        }

        self.nodes.appendAssumeCapacity(.{
            .element_id = element_id,
            .config = declaration,
            .parent_index = parent_index,
            .clip_element_id = inherited_clip_id,
            .clip_node_index = inherited_clip_node_index,
            .configured = true,
        });

        if (duplicate_id) {
            self.emitError(.duplicate_id, "An element with this ID was already previously declared during this layout.");
            self.markDebugCollisionAssumeCapacity(element_id.id);
        } else {
            self.id_to_index.putAssumeCapacity(element_id.id, node_index);
        }

        var active_clip_id = inherited_clip_id;
        var active_clip_node_index = inherited_clip_node_index;
        if (declaration.clip.horizontal or declaration.clip.vertical) {
            active_clip_id = element_id.id;
            active_clip_node_index = node_index;
        }
        self.open_stack.appendAssumeCapacity(.{
            .node_index = node_index,
            .active_clip_id = active_clip_id,
            .active_clip_node_index = active_clip_node_index,
        });

        if (declaration.floating.attach_to != .none) {
            self.roots.appendAssumeCapacity(.{
                .element_index = node_index,
                .parent_id = declaration.floating.parent_id,
                .parent_node_index = floating_parent_node_index,
                .clip_element_id = inherited_clip_id,
                .clip_node_index = inherited_clip_node_index,
                .z_index = declaration.floating.z_index,
            });
        }

        if (!duplicate_id and (declaration.clip.horizontal or declaration.clip.vertical)) {
            self.reopenScrollContainer(element_id.id, declaration.clip);
        }
        if (!duplicate_id) self.configureTransitionForNode(node_index);
    }

    pub fn closeElement(self: *Context) !void {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        if (!self.layout_open) return Error.LayoutNotOpen;
        if (self.open_stack.items.len <= 1) return Error.CannotCloseRoot;
        try self.closeTop(false);
    }

    fn closeTop(self: *Context, allow_root: bool) !void {
        if (self.open_stack.items.len == 0) return Error.NoOpenElement;
        if (!allow_root and self.open_stack.items.len == 1) return Error.CannotCloseRoot;

        const entry = self.open_stack.items[self.open_stack.items.len - 1];
        const node_index = entry.node_index;
        const child_count = self.nodes.items[node_index].children_len;
        const start = self.child_buffer.items.len - child_count;
        try self.child_indices.ensureTotalCapacity(self.allocator, self.child_indices.items.len + child_count);
        if (self.open_stack.items.len > 1 and self.nodes.items[node_index].config.floating.attach_to == .none) {
            try self.child_buffer.ensureTotalCapacity(self.allocator, self.child_buffer.items.len + 1);
        }
        self.nodes.items[node_index].children_start = self.child_indices.items.len;
        self.child_indices.appendSliceAssumeCapacity(self.child_buffer.items[start..]);
        self.child_buffer.shrinkRetainingCapacity(start);
        layout.finalizeIntrinsic(self.nodes.items, self.child_indices.items, node_index);
        _ = self.open_stack.pop();

        if (self.open_stack.items.len > 0) {
            const parent_index = self.open_stack.items[self.open_stack.items.len - 1].node_index;
            if (self.nodes.items[node_index].config.floating.attach_to != .none) {
                self.nodes.items[parent_index].floating_children_count += 1;
            } else {
                self.nodes.items[parent_index].children_len += 1;
                self.child_buffer.appendAssumeCapacity(node_index);
            }
        }
    }

    fn measureTextGuarded(
        self: *Context,
        value: types.String,
        config: *types.TextElementConfig,
    ) !*const text_engine.CacheItem {
        self.beginApplicationCallback(.measure_text);
        defer self.endApplicationCallback();
        return self.text_cache.measure(
            value,
            config,
            self.measure_text_function,
            self.measure_text_user_data,
            self.generation,
        );
    }
    fn paragraphProviderContractError(self: *Context) ParagraphProviderError {
        self.emitError(.internal_error, "Paragraph provider violated its request or result contract.");
        return error.ParagraphProviderContractViolation;
    }

    fn paragraphProviderFailureError(
        self: *Context,
        failure: paragraph_provider.Failure,
    ) ParagraphProviderError {
        self.last_paragraph_provider_failure = failure;
        self.emitError(.internal_error, "Paragraph provider returned an operational failure.");
        return switch (failure.kind) {
            .limit_exceeded => error.TextMeasurementCapacityExceeded,
            .out_of_memory => error.OutOfMemory,
            .stale_handle => error.ParagraphProviderStaleHandle,
            .invalid_style, .unavailable, .internal => error.ParagraphProviderFailed,
        };
    }

    fn measureParagraphGuarded(
        self: *Context,
        provider: paragraph_provider.Provider,
        value: types.String,
        text_style: paragraph_provider.TextStyle,
    ) ParagraphProviderError!paragraph_provider.IntrinsicMetrics {
        const key = ParagraphCacheKey.init(provider, value, text_style);
        if (self.paragraph_intrinsic_cache_map.get(key)) |index| {
            std.debug.assert(index < self.paragraph_intrinsic_cache.items.len);
            return self.paragraph_intrinsic_cache.items[index].metrics;
        }

        try self.paragraph_intrinsic_cache.ensureTotalCapacity(
            self.allocator,
            self.paragraph_intrinsic_cache.items.len + 1,
        );
        try self.paragraph_intrinsic_cache_map.ensureUnusedCapacity(1);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        self.beginApplicationCallback(.paragraph_provider);
        const outcome = provider.measureIntrinsic(scratch.allocator(), .{
            .text = value.asSlice(),
            .text_style = text_style,
        }) catch {
            self.endApplicationCallback();
            return self.paragraphProviderContractError();
        };
        self.endApplicationCallback();
        const measured = switch (outcome) {
            .value => |metrics| metrics,
            .failure => |failure| return self.paragraphProviderFailureError(failure),
        };
        const index = self.paragraph_intrinsic_cache.items.len;
        self.paragraph_intrinsic_cache.appendAssumeCapacity(.{ .metrics = measured });
        self.paragraph_intrinsic_cache_map.putAssumeCapacityNoClobber(key, index);
        return measured;
    }

    fn layoutParagraphGuarded(
        self: *Context,
        provider: paragraph_provider.Provider,
        record: *const TextRecord,
        available_width_px: f32,
    ) ParagraphProviderError!usize {
        const key = ParagraphLayoutKey.init(
            provider,
            record.text,
            record.paragraph_style,
            available_width_px,
        );
        if (self.paragraph_layout_cache_map.get(key)) |index| {
            std.debug.assert(index < self.paragraph_layout_cache.items.len);
            return index;
        }

        try self.paragraph_layout_cache.ensureTotalCapacity(
            self.allocator,
            self.paragraph_layout_cache.items.len + 1,
        );
        try self.paragraph_layout_cache_map.ensureUnusedCapacity(1);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        self.beginApplicationCallback(.paragraph_provider);
        const outcome = provider.layoutParagraph(scratch.allocator(), .{
            .text = record.text.asSlice(),
            .text_style = record.paragraph_style,
            .available_width_px = available_width_px,
        }) catch {
            self.endApplicationCallback();
            return self.paragraphProviderContractError();
        };
        self.endApplicationCallback();
        const lease = switch (outcome) {
            .value => |value| value,
            .failure => |failure| return self.paragraphProviderFailureError(failure),
        };
        const index = self.paragraph_layout_cache.items.len;
        self.paragraph_layout_cache.appendAssumeCapacity(.{
            .provider = provider,
            .render_data = .{
                .lease = lease,
                .available_width_px = available_width_px,
            },
        });
        self.paragraph_layout_cache_map.putAssumeCapacityNoClobber(key, index);
        return index;
    }

    fn releaseParagraphLayoutsFallible(self: *Context) ParagraphProviderError!void {
        var first_failure: ?paragraph_provider.Failure = null;
        var contract_failed = false;
        for (self.paragraph_layout_cache.items) |entry| {
            self.beginApplicationCallback(.paragraph_provider);
            const outcome = entry.provider.releaseParagraph(entry.render_data.lease.key()) catch {
                contract_failed = true;
                self.endApplicationCallback();
                continue;
            };
            self.endApplicationCallback();
            switch (outcome) {
                .value => {},
                .failure => |failure| if (first_failure == null) {
                    first_failure = failure;
                },
            }
        }
        self.paragraph_layout_cache.clearRetainingCapacity();
        self.paragraph_layout_cache_map.clearRetainingCapacity();
        if (contract_failed) return self.paragraphProviderContractError();
        if (first_failure) |failure| return self.paragraphProviderFailureError(failure);
    }

    fn releaseParagraphLayoutsBestEffort(self: *Context) void {
        self.releaseParagraphLayoutsFallible() catch |release_error| switch (release_error) {
            error.ParagraphProviderFailed,
            error.ParagraphProviderContractViolation,
            error.ParagraphProviderStaleHandle,
            error.TextMeasurementCapacityExceeded,
            error.OutOfMemory,
            => {},
        };
    }

    fn clearParagraphIntrinsicCache(self: *Context) void {
        self.paragraph_intrinsic_cache.clearRetainingCapacity();
        self.paragraph_intrinsic_cache_map.clearRetainingCapacity();
    }

    fn wrapTextGuarded(
        self: *Context,
        record: *const TextRecord,
        node: *layout.Node,
    ) !types.Dimensions {
        self.beginApplicationCallback(.measure_text);
        defer self.endApplicationCallback();
        return self.text_cache.wrapWithPreferredDimensions(
            record.text,
            &node.text_config,
            self.measure_text_function,
            self.measure_text_user_data,
            self.generation,
            record.preferred_dimensions,
            node.dimensions.width,
            &self.wrapped_lines,
            self.options.max_element_count,
        );
    }

    pub fn text(self: *Context, value: types.String, config: types.TextElementConfig) !void {
        return self.textWithParagraphStyleInternal(
            value,
            config,
            paragraph_provider.TextStyle.fromLegacy(config),
        );
    }

    /// Declare text with provider-native typography. This is the escape hatch
    /// for shaping features that the Clay-compatible config cannot represent.
    /// A paragraph provider must be installed before calling this method.
    pub fn textWithParagraphStyle(
        self: *Context,
        value: types.String,
        config: types.TextElementConfig,
        paragraph_style: paragraph_provider.TextStyle,
    ) !void {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        if (!self.layout_open) return Error.LayoutNotOpen;
        if (self.paragraph_provider == null) return Error.ParagraphProviderNotInstalled;
        return self.textWithParagraphStyleInternal(value, config, paragraph_style);
    }

    /// The style's language, feature, and variation slices must remain valid
    /// until `endLayout` completes.
    pub fn textSliceWithParagraphStyle(
        self: *Context,
        value: []const u8,
        config: types.TextElementConfig,
        paragraph_style: paragraph_provider.TextStyle,
    ) !void {
        return self.textWithParagraphStyle(
            types.String.fromSlice(value),
            config,
            paragraph_style,
        );
    }

    fn textWithParagraphStyleInternal(
        self: *Context,
        value: types.String,
        config: types.TextElementConfig,
        paragraph_style: paragraph_provider.TextStyle,
    ) !void {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        if (!self.layout_open) return Error.LayoutNotOpen;
        if (self.nodes.items.len >= self.options.max_element_count) {
            if (!self.warned_element_capacity) {
                self.warned_element_capacity = true;
                self.emitError(.elements_capacity_exceeded, "Clay ran out of capacity while attempting to create a text element.");
            }
            return Error.ElementCapacityExceeded;
        }
        const parent_entry = self.open_stack.getLastOrNull() orelse return Error.NoOpenElement;
        const parent_index = parent_entry.node_index;
        const parent = &self.nodes.items[parent_index];
        const offset: u32 = @intCast(parent.children_len + parent.floating_children_count);
        const element_id = hashes.number(offset, parent.element_id.id);
        const text_index = self.texts.items.len;
        const node_index = self.nodes.items.len;
        try self.texts.ensureTotalCapacity(self.allocator, text_index + 1);
        try self.nodes.ensureTotalCapacity(self.allocator, node_index + 1);
        try self.id_to_index.ensureTotalCapacity(self.id_to_index.count() + 1);
        try self.child_buffer.ensureTotalCapacity(self.allocator, self.child_buffer.items.len + 1);
        const duplicate_id = self.id_to_index.contains(element_id.id);
        if (duplicate_id) try self.preflightDebugCollision(element_id.id);

        var mutable_config = config;
        var preferred_dimensions = types.Dimensions{};
        var minimum_width: f32 = 0;
        const provider_active = self.paragraph_provider != null;
        if (self.paragraph_provider) |provider| {
            const measured = try self.measureParagraphGuarded(provider, value, paragraph_style);
            preferred_dimensions = .{
                .width = measured.max_content_width,
                .height = measured.height,
            };
            minimum_width = measured.min_content_width;
        } else {
            if (self.measureTextGuarded(value, &mutable_config)) |measured| {
                preferred_dimensions = measured.unwrapped_dimensions;
                minimum_width = measured.min_width;
            } else |measure_error| switch (measure_error) {
                error.MeasureTextFunctionNotProvided => {
                    if (!self.warned_missing_measure) {
                        self.warned_missing_measure = true;
                        self.emitError(.text_measurement_function_not_provided, "Clay's internal MeasureText function is null. You may have forgotten to call Clay_SetMeasureTextFunction(), or passed a NULL function pointer by mistake.");
                    }
                },
                error.TextMeasurementCapacityExceeded => {
                    if (!self.warned_text_capacity) {
                        self.warned_text_capacity = true;
                        self.emitError(.text_measurement_capacity_exceeded, "Clay ran out of measured-word cache capacity.");
                    }
                    return Error.TextMeasurementCapacityExceeded;
                },
                else => return measure_error,
            }
        }
        // The callback mutates the by-value function parameter in pinned Clay;
        // that callback-local lineHeight controls the initial element height.
        const final_height: f32 = if (provider_active)
            preferred_dimensions.height
        else if (mutable_config.line_height > 0)
            @floatFromInt(mutable_config.line_height)
        else
            preferred_dimensions.height;
        self.texts.appendAssumeCapacity(.{
            .text = value,
            .config = config,
            .paragraph_style = paragraph_style,
            .preferred_dimensions = preferred_dimensions,
            .min_width = minimum_width,
        });
        var node = layout.Node{
            .element_id = element_id,
            .text_config = config,
            .dimensions = .{ .width = preferred_dimensions.width, .height = final_height },
            .min_dimensions = .{ .width = minimum_width, .height = final_height },
            .parent_index = parent_index,
            .clip_element_id = parent_entry.active_clip_id,
            .clip_node_index = parent_entry.active_clip_node_index,
            .text_index = text_index,
            .configured = true,
            .is_text = true,
        };
        layout.normalizeSizing(&node);
        self.nodes.appendAssumeCapacity(node);
        if (duplicate_id) {
            self.emitError(.duplicate_id, "An element with this ID was already previously declared during this layout.");
            self.markDebugCollisionAssumeCapacity(element_id.id);
        } else {
            self.id_to_index.putAssumeCapacity(element_id.id, node_index);
        }
        self.nodes.items[parent_index].children_len += 1;
        self.child_buffer.appendAssumeCapacity(node_index);
    }

    pub fn textSlice(self: *Context, value: []const u8, config: types.TextElementConfig) !void {
        try self.text(types.String.fromSlice(value), config);
    }

    pub fn hovered(self: *const Context) bool {
        const id_value = self.getOpenElementId() catch return false;
        for (self.pointer_over_ids.items) |element_id| if (element_id.id == id_value) return true;
        return false;
    }

    pub fn onHover(self: *Context, function: ?types.HoverFunction, user_data: ?*anyopaque) !void {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        const entry = self.open_stack.getLastOrNull() orelse return Error.NoOpenElement;
        self.nodes.items[entry.node_index].on_hover = function;
        self.nodes.items[entry.node_index].hover_user_data = user_data;
    }

    pub fn pointerOver(self: *const Context, element_id: types.ElementId) bool {
        for (self.pointer_over_ids.items) |over_id| if (over_id.id == element_id.id) return true;
        return false;
    }

    pub fn getPointerOverIds(self: *Context) types.ElementIdArray {
        return .{
            // This is a persistent logical capacity, matching Clay's
            // initialization-time pointer array. It never shrinks below a
            // previously published hit count when the declaration ceiling is
            // lowered at runtime.
            .capacity = @intCast(@max(self.pointer_over_capacity, self.pointer_over_ids.items.len)),
            .length = @intCast(self.pointer_over_ids.items.len),
            .internal_array = self.pointer_over_ids.items,
        };
    }

    pub fn getPointerState(self: *const Context) types.PointerData {
        return self.pointer_info;
    }

    pub fn updateScrollContainers(
        self: *Context,
        enable_drag_scrolling: bool,
        scroll_delta: types.Vector2,
        delta_time: f32,
    ) void {
        // Input/frame mutation from an application callback would invalidate
        // the callback's source snapshot. This API is intentionally `void` for
        // Clay parity, so callback-time updates are ignored rather than
        // partially applied.
        if (self.application_callback_phase != .none) return;
        const result = scroll_engine.update(self.scroll_containers.items, .{
            .enable_drag_scrolling = enable_drag_scrolling,
            .scroll_delta = scroll_delta,
            .delta_time = delta_time,
            .pointer = self.pointer_info,
            .pointer_over_ids = self.pointer_over_ids.items,
        });
        self.scroll_containers.shrinkRetainingCapacity(result.containers.len);
    }

    pub fn getScrollOffset(self: *Context) types.Vector2 {
        const open_id = self.getOpenElementId() catch return .{};
        return self.getScrollOffsetForId(open_id);
    }

    pub fn getScrollOffsetFor(self: *Context, element_id: types.ElementId) types.Vector2 {
        return self.getScrollOffsetForId(element_id.id);
    }

    fn getScrollOffsetForId(self: *Context, id_value: u32) types.Vector2 {
        for (self.scroll_containers.items) |*container| {
            if (container.id == id_value) return container.scroll_position;
        }
        return .{};
    }

    pub fn getScrollContainerData(self: *Context, element_id: types.ElementId) types.ScrollContainerData {
        for (self.scroll_containers.items) |*container| {
            if (container.id != element_id.id) continue;
            var data = container.publicData();
            if (self.application_callback_phase != .none) {
                // The Clay-shaped result retains a mutable pointer, but an
                // application callback may only inspect engine state. Return
                // detached scratch so writes cannot bypass the callback guard.
                self.callback_scroll_position = container.scroll_position;
                data.scroll_position = &self.callback_scroll_position;
            }
            return data;
        }
        return .{};
    }

    pub fn setPointerState(self: *Context, position: types.Vector2, is_pointer_down: bool) !void {
        if (self.pointer_update_active) return Error.PointerUpdateAlreadyActive;
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        // Allocate for the worst-case hit set before changing observable
        // pointer state or invoking callbacks. Every append below is then
        // infallible, so an allocator failure leaves the previous pointer
        // position, interaction state, hit list, and callbacks untouched.
        try self.pointer_over_ids.ensureTotalCapacity(self.allocator, self.hit_records.items.len);
        self.pointer_update_active = true;
        defer self.pointer_update_active = false;
        self.pointer_info.position = position;
        self.pointer_over_ids.clearRetainingCapacity();

        // Hit records belong to the last committed frame. Derive their root
        // range from that same snapshot instead of the current declaration
        // tree, which may belong to a frame that later failed `endLayout`.
        var root_sequence: usize = 0;
        for (self.hit_records.items) |hit| {
            root_sequence = @max(root_sequence, hit.root_sequence + 1);
        }
        while (root_sequence > 0) {
            root_sequence -= 1;
            var found = false;
            var capture = false;
            for (self.hit_records.items) |hit| {
                if (hit.root_sequence != root_sequence) continue;
                if (!pointInside(position, hit.bounding_box)) continue;
                if (hit.clip_box) |clip_box| {
                    if (!self.external_scroll_handling_enabled and !pointInside(position, clip_box)) continue;
                }
                if (self.persistent_elements.get(hit.element_id.id)) |persistent| {
                    if (persistent.on_hover) |function| {
                        self.beginApplicationCallback(.hover);
                        function(persistent.element_id, self.pointer_info, persistent.hover_user_data);
                        self.endApplicationCallback();
                    }
                }
                self.pointer_over_ids.appendAssumeCapacity(hit.element_id);
                found = true;
                capture = hit.capture_root;
            }
            if (found and capture) break;
        }

        if (is_pointer_down) {
            if (self.pointer_info.state == .pressed_this_frame) {
                self.pointer_info.state = .pressed;
            } else if (self.pointer_info.state != .pressed) {
                self.pointer_info.state = .pressed_this_frame;
            }
        } else {
            if (self.pointer_info.state == .released_this_frame) {
                self.pointer_info.state = .released;
            } else if (self.pointer_info.state != .released) {
                self.pointer_info.state = .released_this_frame;
            }
        }
        self.pointer_over_capacity = @max(self.pointer_over_capacity, self.pointer_over_ids.items.len);
    }

    fn debugCloseHover(_: types.ElementId, pointer: types.PointerData, user_data: ?*anyopaque) void {
        if (pointer.state != .pressed_this_frame) return;
        const self: *Context = @ptrCast(@alignCast(user_data orelse return));
        self.debug_mode_enabled = false;
        if (self.layout_open) self.pending_debug_mode_enabled = false;
    }

    fn debugCollapsedLookup(raw_context: ?*const anyopaque, element_id: u32) bool {
        const self: *const Context = @ptrCast(@alignCast(raw_context orelse return false));
        const persistent = self.persistent_elements.get(element_id) orelse return false;
        return persistent.debug_data.collapsed;
    }

    fn debugHasCollision(self: *const Context, element_id: u32) bool {
        for (self.debug_collision_ids.items) |collision_id| {
            if (collision_id == element_id) return true;
        }
        const persistent = self.persistent_elements.get(element_id) orelse return false;
        return persistent.debug_data.collision;
    }

    fn debugTextConfig(self: *const Context, offscreen: bool, title: bool) types.TextElementConfig {
        return .{
            .text_color = if (offscreen or title) self.debug_theme.muted_text_color else self.debug_theme.text_color,
            .font_size = self.debug_theme.font_size,
            .wrap_mode = .none,
        };
    }

    fn debugRowHeight(self: *const Context) f32 {
        return @floatFromInt(self.debug_theme.row_height);
    }

    fn debugTextLiteral(self: *Context, comptime value: []const u8, config: types.TextElementConfig) !void {
        try self.text(types.String.literal(value), config);
    }

    fn debugIntString(self: *Context, value: anytype) !types.String {
        var buffer: [48]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buffer, "{d}", .{value});
        if (self.debug_dynamic_strings.capacity - self.debug_dynamic_strings.items.len < bytes.len) {
            return Error.DebugStringCapacityExceeded;
        }
        const start = self.debug_dynamic_strings.items.len;
        self.debug_dynamic_strings.appendSliceAssumeCapacity(bytes);
        return types.String.fromSlice(self.debug_dynamic_strings.items[start..][0..bytes.len]);
    }

    fn debugFloatAsIntString(self: *Context, value: f32) !types.String {
        return self.debugIntString(truncateDebugFloat(value));
    }

    fn emitDebugConfigBadge(self: *Context, config_type: debug_inspector.ConfigType, offscreen: bool) !void {
        const label = debug_inspector.configLabel(config_type);
        var background = label.color;
        background.a = 90;
        try self.openElement(.{
            .layout = .{ .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 } },
            .background_color = background,
            .corner_radius = types.cornerRadius(4),
            .border = .{ .color = label.color, .width = types.borderOutside(1) },
        });
        try self.text(label.label, self.debugTextConfig(offscreen, false));
        try self.closeElement();
    }

    fn emitDebugElementRow(self: *Context, row: debug_inspector.Row) !void {
        const node_index = row.element_index orelse return;
        const node = self.nodes.items[node_index];
        const tree_control_size: f32 = @floatFromInt(self.debug_theme.tree_control_size);
        const offscreen = debug_inspector.isOffscreen(self.debugBoundingBox(node), self.layout_dimensions, self.culling_enabled);
        const row_id = hashes.stringWithOffset(types.String.literal("Clay__DebugView_ElementOuter"), node.element_id.id, 0);
        try self.openElementWithId(row_id, .{ .layout = .{
            .sizing = .{ .height = types.fixed(self.debugRowHeight()) },
            .child_gap = 6,
            .child_alignment = .{ .y = .center },
        } });

        if (!node.is_text and node.children_len > 0) {
            const collapse_id = hashes.stringWithOffset(types.String.literal("Clay__DebugView_CollapseElement"), node.element_id.id, 0);
            try self.openElementWithId(collapse_id, .{
                .layout = .{
                    .sizing = .{
                        .width = types.fixed(tree_control_size),
                        .height = types.fixed(tree_control_size),
                    },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .corner_radius = types.cornerRadius(4),
                .border = .{ .color = debug_inspector.color_3, .width = types.borderOutside(1) },
            });
            const collapsed = debugCollapsedLookup(self, node.element_id.id);
            if (collapsed) {
                try self.debugTextLiteral("+", self.debugTextConfig(false, false));
            } else {
                try self.debugTextLiteral("-", self.debugTextConfig(false, false));
            }
            try self.closeElement();
        } else {
            try self.openElement(.{ .layout = .{
                .sizing = .{
                    .width = types.fixed(tree_control_size),
                    .height = types.fixed(tree_control_size),
                },
                .child_alignment = .{ .x = .center, .y = .center },
            } });
            try self.openElement(.{
                .layout = .{ .sizing = .{ .width = types.fixed(8), .height = types.fixed(8) } },
                .background_color = debug_inspector.color_3,
                .corner_radius = types.cornerRadius(2),
            });
            try self.closeElement();
            try self.closeElement();
        }

        if (self.debugHasCollision(node.element_id.id)) {
            try self.openElement(.{
                .layout = .{ .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 } },
                .border = .{ .color = .{ .r = 177, .g = 147, .b = 8, .a = 255 }, .width = types.borderOutside(1) },
            });
            try self.debugTextLiteral("Duplicate ID", self.debugTextConfig(true, false));
            try self.closeElement();
        }
        if (offscreen) {
            try self.openElement(.{
                .layout = .{ .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 } },
                .border = .{ .color = debug_inspector.color_3, .width = types.borderOutside(1) },
            });
            try self.debugTextLiteral("Offscreen", self.debugTextConfig(true, false));
            try self.closeElement();
        }

        if (node.element_id.string_id.length > 0) {
            try self.openElement(.{});
            const name_config = self.debugTextConfig(offscreen, false);
            try self.text(node.element_id.string_id, name_config);
            if (node.element_id.offset != 0) {
                try self.debugTextLiteral(" (", name_config);
                try self.text(try self.debugIntString(node.element_id.offset), name_config);
                try self.debugTextLiteral(")", name_config);
            }
            try self.closeElement();
        }

        var badge_storage: [10]debug_inspector.ConfigType = undefined;
        for (debug_inspector.elementConfigTypes(node, &badge_storage)) |config_type| {
            try self.emitDebugConfigBadge(config_type, offscreen);
        }
        try self.closeElement();
    }

    fn emitDebugTextContentsRow(self: *Context, row: debug_inspector.Row) !void {
        const node_index = row.element_index orelse return;
        const node = self.nodes.items[node_index];
        const text_index = node.text_index orelse return;
        const preview = debug_inspector.rawTextPreview(self.texts.items[text_index].text);
        const offscreen = debug_inspector.isOffscreen(self.debugBoundingBox(node), self.layout_dimensions, self.culling_enabled);
        const config = self.debugTextConfig(offscreen, false);

        try self.openElement(.{ .layout = .{
            .sizing = .{ .height = types.fixed(self.debugRowHeight()) },
            .child_alignment = .{ .y = .center },
        } });
        try self.openElement(.{ .layout = .{ .sizing = .{ .width = types.fixed(debug_inspector.indent_width + 16) } } });
        try self.closeElement();
        try self.debugTextLiteral("\"", config);
        try self.text(types.String.fromSlice(preview.text), config);
        if (preview.truncated) try self.debugTextLiteral("...", config);
        try self.debugTextLiteral("\"", config);
        try self.closeElement();
    }

    fn openDebugIndent(self: *Context) !void {
        try self.openElement(.{ .layout = .{ .padding = .{ .left = 8 } } });
        try self.openElement(.{
            .layout = .{ .padding = .{ .left = debug_inspector.indent_width } },
            .border = .{ .color = debug_inspector.color_3, .width = .{ .left = 1 } },
        });
        try self.openElement(.{ .layout = .{ .layout_direction = .top_to_bottom } });
    }

    fn closeDebugIndent(self: *Context) !void {
        try self.closeElement();
        try self.closeElement();
        try self.closeElement();
    }

    fn emitDebugRootSeparator(self: *Context, root_index: usize) !void {
        const outer_id = hashes.stringWithOffset(types.String.literal("Clay__DebugView_EmptyRowOuter"), @intCast(root_index), 0);
        try self.openElementWithId(outer_id, .{ .layout = .{
            .sizing = .{ .width = types.grow() },
            .padding = .{ .left = @intCast(debug_inspector.indent_width / 2) },
        } });
        const inner_id = hashes.stringWithOffset(types.String.literal("Clay__DebugView_EmptyRow"), @intCast(root_index), 0);
        try self.openElementWithId(inner_id, .{
            .layout = .{ .sizing = .{
                .width = types.grow(),
                .height = types.fixed(self.debugRowHeight()),
            } },
            .border = .{ .color = debug_inspector.color_3, .width = .{ .top = 1 } },
        });
        try self.closeElement();
        try self.closeElement();
    }

    fn emitDebugHighlight(self: *Context, element_id: u32) !void {
        if (element_id == 0) return;
        try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugView_ElementHighlight"), 0), .{
            .layout = .{ .sizing = .{ .width = types.grow(), .height = types.grow() } },
            .floating = .{
                .parent_id = element_id,
                .z_index = 32767,
                .pointer_capture_mode = .passthrough,
                .attach_to = .element_with_id,
            },
        });
        try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugView_ElementHighlightRectangle"), 0), .{
            .layout = .{ .sizing = .{ .width = types.grow(), .height = types.grow() } },
            .background_color = self.debug_highlight_color,
        });
        try self.closeElement();
        try self.closeElement();
    }

    fn emitDebugConfigHeader(self: *Context, config_type: debug_inspector.ConfigType) !void {
        const label = debug_inspector.configLabel(config_type);
        var background = label.color;
        background.a = 90;
        try self.openElement(.{
            .layout = .{ .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 } },
            .background_color = background,
            .corner_radius = types.cornerRadius(4),
            .border = .{ .color = label.color, .width = types.borderOutside(1) },
        });
        try self.text(label.label, self.debugTextConfig(false, false));
        try self.closeElement();
    }

    fn emitDebugLayoutSizing(self: *Context, sizing: types.SizingAxis, config: types.TextElementConfig) !void {
        try self.text(types.String.fromSlice(debug_inspector.sizingTypeName(sizing.type)), config);
        if (sizing.type == .percent) {
            try self.debugTextLiteral("(", config);
            try self.text(try self.debugFloatAsIntString(sizing.size.percent * 100), config);
            try self.debugTextLiteral("%)", config);
            return;
        }

        try self.debugTextLiteral("(", config);
        const min_max = sizing.size.min_max;
        if (min_max.min != 0) {
            try self.debugTextLiteral("min: ", config);
            try self.text(try self.debugFloatAsIntString(min_max.min), config);
            if (min_max.max != std.math.floatMax(f32)) try self.debugTextLiteral(", ", config);
        }
        if (min_max.max != std.math.floatMax(f32)) {
            try self.debugTextLiteral("max: ", config);
            try self.text(try self.debugFloatAsIntString(min_max.max), config);
        }
        try self.debugTextLiteral(")", config);
    }

    fn emitDebugColor(self: *Context, color: types.Color, config: types.TextElementConfig) !void {
        try self.openElement(.{ .layout = .{ .child_alignment = .{ .y = .center } } });
        try self.debugTextLiteral("{ r: ", config);
        try self.text(try self.debugFloatAsIntString(color.r), config);
        try self.debugTextLiteral(", g: ", config);
        try self.text(try self.debugFloatAsIntString(color.g), config);
        try self.debugTextLiteral(", b: ", config);
        try self.text(try self.debugFloatAsIntString(color.b), config);
        try self.debugTextLiteral(", a: ", config);
        try self.text(try self.debugFloatAsIntString(color.a), config);
        try self.debugTextLiteral(" }", config);
        try self.openElement(.{ .layout = .{ .sizing = .{ .width = types.fixed(10) } } });
        try self.closeElement();
        const swatch_size = @max(self.debugRowHeight() - 8, 1);
        try self.openElement(.{
            .layout = .{ .sizing = .{
                .width = types.fixed(swatch_size),
                .height = types.fixed(swatch_size),
            } },
            .background_color = color,
            .corner_radius = types.cornerRadius(4),
            .border = .{ .color = debug_inspector.color_4, .width = types.borderOutside(1) },
        });
        try self.closeElement();
        try self.closeElement();
    }

    fn emitDebugCornerRadius(self: *Context, radius: types.CornerRadius, config: types.TextElementConfig) !void {
        try self.openElement(.{ .layout = .{ .child_alignment = .{ .y = .center } } });
        try self.debugTextLiteral("{ topLeft: ", config);
        try self.text(try self.debugFloatAsIntString(radius.top_left), config);
        try self.debugTextLiteral(", topRight: ", config);
        try self.text(try self.debugFloatAsIntString(radius.top_right), config);
        try self.debugTextLiteral(", bottomLeft: ", config);
        try self.text(try self.debugFloatAsIntString(radius.bottom_left), config);
        try self.debugTextLiteral(", bottomRight: ", config);
        try self.text(try self.debugFloatAsIntString(radius.bottom_right), config);
        try self.debugTextLiteral(" }", config);
        try self.closeElement();
    }

    fn emitDebugSelectedPane(
        self: *Context,
        selected_index: usize,
        details_height: f32,
    ) !void {
        const selected_node = self.nodes.items[selected_index];
        const selected_box = self.debugBoundingBox(selected_node);
        const info = self.debugTextConfig(false, false);
        const title = self.debugTextConfig(false, true);
        try self.openElementUnconfigured();
        const scroll_offset = self.getScrollOffset();
        try self.configureOpenElement(.{
            .layout = .{
                .sizing = .{ .width = types.grow(), .height = types.fixed(details_height) },
                .layout_direction = .top_to_bottom,
            },
            .background_color = debug_inspector.color_2,
            .clip = .{ .vertical = true, .child_offset = scroll_offset },
            .border = .{ .color = debug_inspector.color_3, .width = .{ .between_children = 1 } },
        });
        try self.openElement(.{ .layout = .{
            .sizing = .{ .width = types.grow(), .height = types.fixed(self.debugRowHeight() + 8) },
            .padding = .{ .left = debug_inspector.outer_padding, .right = debug_inspector.outer_padding },
            .child_alignment = .{ .y = .center },
        } });
        try self.debugTextLiteral("Element Configuration", info);
        try self.openElement(.{ .layout = .{ .sizing = .{ .width = types.grow() } } });
        try self.closeElement();
        if (selected_node.element_id.string_id.length != 0) {
            try self.text(selected_node.element_id.string_id, title);
            if (selected_node.element_id.offset != 0) {
                try self.debugTextLiteral(" (", title);
                try self.text(try self.debugIntString(selected_node.element_id.offset), title);
                try self.debugTextLiteral(")", title);
            }
        }
        try self.closeElement();

        const attribute_padding = types.Padding{ .left = debug_inspector.outer_padding, .right = debug_inspector.outer_padding, .top = 8, .bottom = 8 };
        try self.openElement(.{ .layout = .{
            .padding = attribute_padding,
            .child_gap = 8,
            .layout_direction = .top_to_bottom,
        } });
        try self.openElement(.{
            .layout = .{ .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 } },
            .background_color = .{ .r = 200, .g = 200, .b = 200, .a = 120 },
            .corner_radius = types.cornerRadius(4),
            .border = .{ .color = .{ .r = 200, .g = 200, .b = 200, .a = 255 }, .width = types.borderOutside(1) },
        });
        try self.debugTextLiteral("Layout", info);
        try self.closeElement();
        try self.debugTextLiteral("Bounding Box", title);
        try self.openElement(.{ .layout = .{ .layout_direction = .left_to_right } });
        try self.debugTextLiteral("{ x: ", info);
        try self.text(try self.debugFloatAsIntString(selected_box.x), info);
        try self.debugTextLiteral(", y: ", info);
        try self.text(try self.debugFloatAsIntString(selected_box.y), info);
        try self.debugTextLiteral(", width: ", info);
        try self.text(try self.debugFloatAsIntString(selected_box.width), info);
        try self.debugTextLiteral(", height: ", info);
        try self.text(try self.debugFloatAsIntString(selected_box.height), info);
        try self.debugTextLiteral(" }", info);
        try self.closeElement();

        if (!selected_node.is_text) {
            const layout_config = selected_node.config.layout;
            try self.debugTextLiteral("Layout Direction", title);
            try self.text(types.String.fromSlice(debug_inspector.layoutDirectionName(layout_config.layout_direction)), info);
            try self.debugTextLiteral("Sizing", title);
            try self.openElement(.{ .layout = .{ .layout_direction = .left_to_right } });
            try self.debugTextLiteral("width: ", info);
            try self.emitDebugLayoutSizing(layout_config.sizing.width, info);
            try self.closeElement();
            try self.openElement(.{ .layout = .{ .layout_direction = .left_to_right } });
            try self.debugTextLiteral("height: ", info);
            try self.emitDebugLayoutSizing(layout_config.sizing.height, info);
            try self.closeElement();
            try self.debugTextLiteral("Padding", title);
            try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugViewElementInfoPadding"), 0), .{});
            try self.debugTextLiteral("{ left: ", info);
            try self.text(try self.debugIntString(layout_config.padding.left), info);
            try self.debugTextLiteral(", right: ", info);
            try self.text(try self.debugIntString(layout_config.padding.right), info);
            try self.debugTextLiteral(", top: ", info);
            try self.text(try self.debugIntString(layout_config.padding.top), info);
            try self.debugTextLiteral(", bottom: ", info);
            try self.text(try self.debugIntString(layout_config.padding.bottom), info);
            try self.debugTextLiteral(" }", info);
            try self.closeElement();
            try self.debugTextLiteral("Child Gap", title);
            try self.text(try self.debugIntString(layout_config.child_gap), info);
            try self.debugTextLiteral("Child Alignment", title);
            try self.openElement(.{ .layout = .{ .layout_direction = .left_to_right } });
            try self.debugTextLiteral("{ x: ", info);
            try self.text(types.String.fromSlice(debug_inspector.alignmentXName(layout_config.child_alignment.x)), info);
            try self.debugTextLiteral(", y: ", info);
            try self.text(types.String.fromSlice(debug_inspector.alignmentYName(layout_config.child_alignment.y)), info);
            try self.debugTextLiteral(" }", info);
            try self.closeElement();
        }
        try self.closeElement();

        if (selected_node.is_text) {
            const text_config = selected_node.text_config;
            try self.openElement(.{ .layout = .{ .padding = attribute_padding, .child_gap = 8, .layout_direction = .top_to_bottom } });
            try self.emitDebugConfigHeader(.text);
            try self.debugTextLiteral("Font Size", title);
            try self.text(try self.debugIntString(text_config.font_size), info);
            try self.debugTextLiteral("Font ID", title);
            try self.text(try self.debugIntString(text_config.font_id), info);
            try self.debugTextLiteral("Line Height", title);
            if (text_config.line_height == 0) {
                try self.debugTextLiteral("auto", info);
            } else {
                try self.text(try self.debugIntString(text_config.line_height), info);
            }
            try self.debugTextLiteral("Letter Spacing", title);
            try self.text(try self.debugIntString(text_config.letter_spacing), info);
            try self.debugTextLiteral("Wrap Mode", title);
            try self.text(types.String.fromSlice(debug_inspector.wrapModeName(text_config.wrap_mode)), info);
            try self.debugTextLiteral("Text Alignment", title);
            try self.text(types.String.fromSlice(debug_inspector.textAlignmentName(text_config.text_alignment)), info);
            try self.debugTextLiteral("Text Color", title);
            try self.emitDebugColor(text_config.text_color, info);
            try self.closeElement();
        } else {
            try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugViewElementInfoSharedBody"), 0), .{ .layout = .{
                .padding = attribute_padding,
                .child_gap = 8,
                .layout_direction = .top_to_bottom,
            } });
            var color_header = debug_inspector.configLabel(.background_color).color;
            color_header.a = 90;
            try self.openElement(.{
                .layout = .{ .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 } },
                .background_color = color_header,
                .corner_radius = types.cornerRadius(4),
                .border = .{ .color = debug_inspector.configLabel(.background_color).color, .width = types.borderOutside(1) },
            });
            try self.debugTextLiteral("Color & Radius", info);
            try self.closeElement();
            if (selected_node.config.background_color.a > 0) {
                try self.debugTextLiteral("Background Color", title);
                try self.emitDebugColor(selected_node.config.background_color, info);
            }
            var radius_badges: [10]debug_inspector.ConfigType = undefined;
            const selected_badges = debug_inspector.elementConfigTypes(selected_node, &radius_badges);
            if (std.mem.indexOfScalar(debug_inspector.ConfigType, selected_badges, .corner_radius) != null) {
                try self.debugTextLiteral("Corner Radius", title);
                try self.emitDebugCornerRadius(selected_node.config.corner_radius, info);
            }
            if (selected_node.config.overlay_color.a > 0) {
                try self.debugTextLiteral("Overlay Color", title);
                try self.emitDebugColor(selected_node.config.overlay_color, info);
            }
            try self.closeElement();

            if (selected_node.config.aspect_ratio.aspect_ratio > 0) {
                try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugViewElementInfoAspectRatioBody"), 0), .{ .layout = .{
                    .padding = attribute_padding,
                    .child_gap = 8,
                    .layout_direction = .top_to_bottom,
                } });
                try self.emitDebugConfigHeader(.aspect);
                try self.debugTextLiteral("Aspect Ratio", title);
                try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugViewElementInfoAspectRatio"), 0), .{});
                const aspect_ratio = selected_node.config.aspect_ratio.aspect_ratio;
                try self.text(try self.debugFloatAsIntString(aspect_ratio), info);
                try self.debugTextLiteral(".", info);
                const whole = truncateDebugFloat(aspect_ratio);
                const fractional = (aspect_ratio - @as(f32, @floatFromInt(whole))) * 100;
                if (truncateDebugFloat(fractional) < 10) try self.debugTextLiteral("0", info);
                try self.text(try self.debugFloatAsIntString(fractional), info);
                try self.closeElement();
                try self.closeElement();
            }
            if (selected_node.config.image.image_data != null) {
                try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugViewElementInfoImageBody"), 0), .{ .layout = .{
                    .padding = attribute_padding,
                    .child_gap = 8,
                    .layout_direction = .top_to_bottom,
                } });
                try self.emitDebugConfigHeader(.image);
                try self.debugTextLiteral("Preview", title);
                try self.openElement(.{
                    .layout = .{ .sizing = .{
                        .width = types.growMinMax(64, 128),
                        .height = types.growMinMax(64, 128),
                    } },
                    .aspect_ratio = .{ .aspect_ratio = if (selected_node.config.aspect_ratio.aspect_ratio > 0)
                        selected_node.config.aspect_ratio.aspect_ratio
                    else
                        1 },
                    .image = selected_node.config.image,
                });
                try self.closeElement();
                try self.closeElement();
            }
            if (selected_node.config.floating.attach_to != .none) {
                const floating = selected_node.config.floating;
                try self.openElement(.{ .layout = .{
                    .padding = attribute_padding,
                    .child_gap = 8,
                    .layout_direction = .top_to_bottom,
                } });
                try self.emitDebugConfigHeader(.floating);
                try self.debugTextLiteral("Offset", title);
                try self.openElement(.{ .layout = .{ .layout_direction = .left_to_right } });
                try self.debugTextLiteral("{ x: ", info);
                try self.text(try self.debugFloatAsIntString(floating.offset.x), info);
                try self.debugTextLiteral(", y: ", info);
                try self.text(try self.debugFloatAsIntString(floating.offset.y), info);
                try self.debugTextLiteral(" }", info);
                try self.closeElement();
                try self.debugTextLiteral("Expand", title);
                try self.openElement(.{ .layout = .{ .layout_direction = .left_to_right } });
                try self.debugTextLiteral("{ width: ", info);
                try self.text(try self.debugFloatAsIntString(floating.expand.width), info);
                try self.debugTextLiteral(", height: ", info);
                try self.text(try self.debugFloatAsIntString(floating.expand.height), info);
                try self.debugTextLiteral(" }", info);
                try self.closeElement();
                try self.debugTextLiteral("z-index", title);
                try self.text(try self.debugIntString(floating.z_index), info);
                try self.debugTextLiteral("Parent", title);
                if (self.id_to_index.get(floating.parent_id)) |parent_index| {
                    const parent_name = self.nodes.items[parent_index].element_id.string_id;
                    if (parent_name.length > 0) try self.text(parent_name, info);
                }
                try self.debugTextLiteral("Attach Points", title);
                try self.openElement(.{ .layout = .{ .layout_direction = .left_to_right } });
                try self.debugTextLiteral("{ element: ", info);
                try self.text(types.String.fromSlice(debug_inspector.attachPointName(floating.attach_points.element)), info);
                try self.debugTextLiteral(", parent: ", info);
                try self.text(types.String.fromSlice(debug_inspector.attachPointName(floating.attach_points.parent)), info);
                try self.debugTextLiteral(" }", info);
                try self.closeElement();
                try self.debugTextLiteral("Pointer Capture Mode", title);
                try self.text(types.String.fromSlice(debug_inspector.pointerCaptureModeName(floating.pointer_capture_mode)), info);
                try self.debugTextLiteral("Attach To", title);
                try self.text(types.String.fromSlice(debug_inspector.attachToName(floating.attach_to)), info);
                try self.debugTextLiteral("Clip To", title);
                try self.text(types.String.fromSlice(debug_inspector.clipToName(floating.clip_to)), info);
                try self.closeElement();
            }
            if (selected_node.config.clip.horizontal or selected_node.config.clip.vertical) {
                try self.openElement(.{ .layout = .{ .padding = attribute_padding, .child_gap = 8, .layout_direction = .top_to_bottom } });
                try self.emitDebugConfigHeader(.clip);
                try self.debugTextLiteral("Vertical", title);
                if (selected_node.config.clip.vertical) try self.debugTextLiteral("true", info) else try self.debugTextLiteral("false", info);
                try self.debugTextLiteral("Horizontal", title);
                if (selected_node.config.clip.horizontal) try self.debugTextLiteral("true", info) else try self.debugTextLiteral("false", info);
                try self.closeElement();
            }
            if (debug_inspector.borderHasAnyWidth(selected_node.config.border)) {
                try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugViewElementInfoBorderBody"), 0), .{ .layout = .{
                    .padding = attribute_padding,
                    .child_gap = 8,
                    .layout_direction = .top_to_bottom,
                } });
                try self.emitDebugConfigHeader(.border);
                try self.debugTextLiteral("Border Widths", title);
                try self.openElement(.{ .layout = .{ .layout_direction = .left_to_right } });
                try self.debugTextLiteral("{ left: ", info);
                try self.text(try self.debugIntString(selected_node.config.border.width.left), info);
                try self.debugTextLiteral(", right: ", info);
                try self.text(try self.debugIntString(selected_node.config.border.width.right), info);
                try self.debugTextLiteral(", top: ", info);
                try self.text(try self.debugIntString(selected_node.config.border.width.top), info);
                try self.debugTextLiteral(", bottom: ", info);
                try self.text(try self.debugIntString(selected_node.config.border.width.bottom), info);
                try self.debugTextLiteral(" }", info);
                try self.closeElement();
                try self.debugTextLiteral("Border Color", title);
                try self.emitDebugColor(selected_node.config.border.color, info);
                try self.closeElement();
            }
        }
        try self.closeElement();
    }

    fn emitDebugWarningsPane(self: *Context, details_height: f32) !void {
        const warning_config = self.debugTextConfig(false, false);
        const warning_id = hashes.string(types.String.literal("Clay__DebugViewWarningsScrollPane"), 0);
        const scroll_offset = self.getScrollOffsetForId(warning_id.id);
        try self.openElementWithId(warning_id, .{
            .layout = .{
                .sizing = .{ .width = types.grow(), .height = types.fixed(details_height) },
                .child_gap = 6,
                .layout_direction = .top_to_bottom,
            },
            .background_color = debug_inspector.color_2,
            .clip = .{ .horizontal = true, .vertical = true, .child_offset = scroll_offset },
        });
        try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugViewWarningItemHeader"), 0), .{ .layout = .{
            .sizing = .{ .height = types.fixed(self.debugRowHeight()) },
            .padding = .{ .left = debug_inspector.outer_padding, .right = debug_inspector.outer_padding },
            .child_gap = 8,
            .child_alignment = .{ .y = .center },
        } });
        try self.debugTextLiteral("Warnings", warning_config);
        try self.closeElement();
        try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugViewWarningsTopBorder"), 0), .{
            .layout = .{ .sizing = .{ .width = types.grow(), .height = types.fixed(1) } },
            .background_color = .{ .r = 200, .g = 200, .b = 200, .a = 255 },
        });
        try self.closeElement();
        for (self.debug_warnings.items, 0..) |warning, index| {
            try self.openElementWithId(hashes.stringWithOffset(types.String.literal("Clay__DebugViewWarningItem"), @intCast(index), 0), .{ .layout = .{
                .sizing = .{ .height = types.fixed(self.debugRowHeight()) },
                .padding = .{ .left = debug_inspector.outer_padding, .right = debug_inspector.outer_padding },
                .child_gap = 8,
                .child_alignment = .{ .y = .center },
            } });
            try self.text(warning.base_message, warning_config);
            if (warning.dynamic_message.length > 0) try self.text(warning.dynamic_message, warning_config);
            try self.closeElement();
        }
        try self.closeElement();
    }

    /// Declare Clay's built-in inspector into the live frame. `initial_*`
    /// delimit the user's tree (plus any reinserted exit roots), preventing
    /// the inspector from recursively inspecting its own declarations.
    fn renderDebugView(self: *Context, initial_roots_length: usize, initial_elements_length: usize) !bool {
        const action_requests_close = if (self.debug_view_action) |action|
            action == .close
        else
            false;
        if (action_requests_close or
            debug_inspector.closeRequested(self.pointer_info.state, self.pointer_over_ids.items))
        {
            self.pending_debug_mode_enabled = false;
            return false;
        }

        // All dynamic numeric strings must remain stable until command
        // generation. Reserve before the first slice is handed to `text`.
        // Each list element can contribute at most one decimal u32 offset (10
        // bytes). The selected-element pane contributes fewer than 512 bytes
        // across every numeric field currently emitted. Six bytes per row and
        // 7.5 KiB of slack make the capacity a strict upper bound, not merely
        // an allocation hint. `debugIntString` therefore never reallocates
        // after returning its first slice.
        const dynamic_capacity = initial_elements_length *| 16 +| 8192;
        try self.debug_dynamic_strings.ensureTotalCapacity(self.allocator, dynamic_capacity);

        const scroll_id = hashes.string(types.String.literal("Clay__DebugViewOuterScrollPane"), 0);
        var scroll_offset = self.getScrollOffsetForId(scroll_id.id);
        var reveal_selection = false;
        const view_width = debug_inspector.effectiveViewWidth(
            self.layout_dimensions.width,
            self.debug_view_width,
        );
        const details_height = debug_inspector.effectiveDetailsHeightForRow(
            self.layout_dimensions.height,
            self.debugRowHeight(),
        );
        var highlighted_row = debug_inspector.highlightedRow(.{
            .pointer = self.pointer_info.position,
            .layout_dimensions = self.layout_dimensions,
            .view_width = view_width,
            .details_pane_height = details_height,
            .row_height = self.debugRowHeight(),
            .scroll_position = scroll_offset,
            .external_scroll_handling_enabled = self.external_scroll_handling_enabled,
        });
        var list_data = try debug_inspector.collectRows(
            self.allocator,
            self.nodes.items[0..initial_elements_length],
            self.child_indices.items,
            self.roots.items,
            initial_roots_length,
            .{ .context = self, .function = debugCollapsedLookup },
            self.pending_debug_selected_element_id,
            highlighted_row,
            self.pointer_info.state,
            &self.debug_rows,
            &self.debug_traversal,
        );
        if (self.debug_view_action) |action| {
            if (debug_inspector.movedSelection(
                self.debug_rows.items,
                list_data.selected_element_id,
                action,
            )) |selection| {
                list_data.selected_element_id = selection.element_id;
                list_data.selected_element_row_index = selection.row_index;
                list_data.highlighted_element_id = selection.element_id;
                highlighted_row = selection.row_index;
                if (!self.external_scroll_handling_enabled) {
                    const list_view_height = @max(
                        self.layout_dimensions.height - self.debugRowHeight() -
                            details_height - 2,
                        0,
                    );
                    scroll_offset.y = debug_inspector.revealRowScrollY(
                        scroll_offset.y,
                        selection.row_index,
                        list_data.row_count,
                        self.debugRowHeight(),
                        list_view_height,
                    );
                    reveal_selection = true;
                }
            }
        }
        self.pending_debug_selected_element_id = list_data.selected_element_id;
        const selected_index = if (self.id_to_index.get(list_data.selected_element_id)) |index|
            if (index < initial_elements_length) index else null
        else
            null;

        const starting_depth = self.open_stack.items.len;
        errdefer self.closeToDepth(starting_depth) catch self.abortLayoutAfterCleanupFailure();
        try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugView"), 0), .{
            .layout = .{
                .sizing = .{
                    .width = types.fixed(view_width),
                    .height = types.fixed(self.layout_dimensions.height),
                },
                .layout_direction = .top_to_bottom,
            },
            .floating = .{
                .offset = .{
                    .x = self.layout_dimensions.width - view_width -
                        self.nodes.items[0].dimensions.width,
                },
                .z_index = 32765,
                .attach_points = .{ .element = .left_center, .parent = .right_center },
                .attach_to = .root,
                .clip_to = .attached_parent,
            },
            .border = .{ .color = debug_inspector.color_3, .width = .{ .bottom = 1 } },
        });
        try self.openElement(.{
            .layout = .{
                .sizing = .{ .width = types.grow(), .height = types.fixed(self.debugRowHeight()) },
                .padding = .{ .left = debug_inspector.outer_padding, .right = debug_inspector.outer_padding },
                .child_alignment = .{ .y = .center },
            },
            .background_color = debug_inspector.color_2,
        });
        try self.debugTextLiteral("Clay Debug Tools", self.debugTextConfig(false, false));
        try self.openElement(.{ .layout = .{ .sizing = .{ .width = types.grow() } } });
        try self.closeElement();
        const close_control_size: f32 = @floatFromInt(self.debug_theme.close_control_size);
        try self.openElement(.{
            .layout = .{
                .sizing = .{
                    .width = types.fixed(close_control_size),
                    .height = types.fixed(close_control_size),
                },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = .{ .r = 217, .g = 91, .b = 67, .a = 80 },
            .corner_radius = types.cornerRadius(4),
            .border = .{ .color = .{ .r = 217, .g = 91, .b = 67, .a = 255 }, .width = types.borderOutside(1) },
        });
        try self.onHover(debugCloseHover, self);
        try self.debugTextLiteral("x", self.debugTextConfig(false, false));
        try self.closeElement();
        try self.closeElement();

        try self.openElement(.{
            .layout = .{ .sizing = .{ .width = types.grow(), .height = types.fixed(1) } },
            .background_color = debug_inspector.color_3,
        });
        try self.closeElement();

        try self.openElementWithId(scroll_id, .{
            .layout = .{ .sizing = .{ .width = types.grow(), .height = types.grow() } },
            .clip = .{ .horizontal = true, .vertical = true, .child_offset = scroll_offset },
        });
        if (reveal_selection) {
            for (self.scroll_containers.items) |*container| {
                if (container.id != scroll_id.id) continue;
                container.scroll_position = scroll_offset;
                container.scroll_momentum = .{};
                break;
            }
        }
        try self.openElement(.{
            .layout = .{
                .sizing = .{ .width = types.grow(), .height = types.grow() },
                .layout_direction = .top_to_bottom,
            },
            .background_color = if (((initial_elements_length + initial_roots_length) & 1) == 0)
                debug_inspector.color_2
            else
                debug_inspector.color_1,
        });

        const pane_index = self.nodes.items.len;
        try self.openElementWithId(hashes.string(types.String.literal("Clay__DebugViewPaneOuter"), 0), .{
            .layout = .{ .sizing = .{ .width = types.grow(), .height = types.grow() } },
            .floating = .{
                .z_index = 32766,
                .pointer_capture_mode = .passthrough,
                .attach_to = .parent,
                .clip_to = .attached_parent,
            },
        });
        try self.openElement(.{ .layout = .{
            .sizing = .{ .width = types.grow(), .height = types.grow() },
            .padding = .{ .left = debug_inspector.outer_padding, .right = debug_inspector.outer_padding },
            .layout_direction = .top_to_bottom,
        } });

        var indent_depth: usize = 0;
        for (self.debug_rows.items) |row| {
            const target_depth = if (row.kind == .element) row.depth else indent_depth;
            while (indent_depth > target_depth) {
                try self.closeDebugIndent();
                indent_depth -= 1;
            }
            switch (row.kind) {
                .root_separator => {
                    while (indent_depth > 0) {
                        try self.closeDebugIndent();
                        indent_depth -= 1;
                    }
                    try self.emitDebugRootSeparator(row.root_index);
                },
                .text_contents => try self.emitDebugTextContentsRow(row),
                .element => {
                    try self.emitDebugElementRow(row);
                    const node = self.nodes.items[row.element_index.?];
                    if (!node.is_text and node.children_len > 0) {
                        try self.openDebugIndent();
                        indent_depth += 1;
                    }
                },
            }
        }
        while (indent_depth > 0) {
            try self.closeDebugIndent();
            indent_depth -= 1;
        }

        // Upstream performs this lookup after declaring the list, so collapse
        // clicks affect the following frame's row set rather than this one.
        if (debug_inspector.collapseTarget(self.pointer_info.state, self.pointer_over_ids.items)) |target_id| {
            self.pending_debug_collapse_id = target_id;
        }
        if (self.debug_view_action == .toggle_collapse) {
            if (selected_index) |index| {
                const selected_node = self.nodes.items[index];
                if (!selected_node.is_text and selected_node.children_len > 0) {
                    self.pending_debug_collapse_id = selected_node.element_id.id;
                }
            }
        }
        try self.emitDebugHighlight(list_data.highlighted_element_id);
        try self.closeElement();
        try self.closeElement();

        const content_width = self.nodes.items[pane_index].dimensions.width;
        try self.openElement(.{ .layout = .{
            .sizing = .{ .width = types.fixed(content_width) },
            .layout_direction = .top_to_bottom,
        } });
        try self.closeElement();
        var row_index: i32 = 0;
        while (row_index < list_data.row_count) : (row_index += 1) {
            try self.openElement(.{
                .layout = .{
                    .sizing = .{
                        .width = types.grow(),
                        .height = types.fixed(self.debugRowHeight()),
                    },
                    .layout_direction = .top_to_bottom,
                },
                .background_color = debug_inspector.rowColor(
                    row_index,
                    list_data.selected_element_row_index,
                    highlighted_row,
                ),
            });
            try self.closeElement();
        }
        try self.closeElement();
        try self.closeElement();

        try self.openElement(.{
            .layout = .{ .sizing = .{ .width = types.grow(), .height = types.fixed(1) } },
            .background_color = debug_inspector.color_3,
        });
        try self.closeElement();
        if (selected_index) |index| {
            try self.emitDebugSelectedPane(index, details_height);
        } else {
            try self.emitDebugWarningsPane(details_height);
        }
        try self.closeElement();
        return true;
    }

    pub fn endLayout(self: *Context, delta_time: f32) !types.RenderCommandArray {
        if (self.application_callback_phase != .none) return Error.CallbackReentryNotAllowed;
        if (!self.layout_open) return Error.LayoutNotOpen;
        errdefer {
            self.layout_open = false;
            self.releaseParagraphLayoutsBestEffort();
            self.clearParagraphIntrinsicCache();
            self.render_commands.clearRetainingCapacity();
            self.pending_hit_records.clearRetainingCapacity();
            self.apply_transition_overrides = false;
            self.rollbackMutableFrameState();
        }

        if (self.open_stack.items.len > 1) {
            self.emitError(.unbalanced_open_close, "There were still open layout elements when EndLayout was called. This results from an unequal number of calls to Clay__OpenElement and Clay__CloseElement.");
            while (self.open_stack.items.len > 1) try self.closeTop(false);
        }
        const root_entry = self.open_stack.items[0];
        try self.closeTop(true);
        try self.reinsertExitingSubtrees();

        // Pinned Clay lays out before building the inspector only when
        // transition data exists. Without transitions, the inspector reads
        // retained boxes plus the current declarations, then both trees are
        // laid out together. That order is observable when layout mutates a
        // declaration (notably aspect-ratio sizing bounds).
        const had_transition_data = self.transition_order.items.len > 0;
        var transitions_active = false;
        if (had_transition_data) {
            try self.calculateFinalLayout();
            self.render_commands.clearRetainingCapacity();
            self.pending_hit_records.clearRetainingCapacity();
            self.apply_transition_overrides = false;
            self.resetBoundingBoxValidity();
            for (self.roots.items, 0..) |root, root_sequence| {
                try self.renderRoot(root, root_sequence);
            }
            try self.rejectUnbalancedRenderPrefix();
        }
        if (self.debug_mode_enabled) {
            const initial_roots_length = self.roots.items.len;
            const initial_elements_length = self.nodes.items.len;
            try self.open_stack.ensureTotalCapacity(self.allocator, 1);
            self.open_stack.appendAssumeCapacity(root_entry);
            self.debug_warnings_enabled = false;
            _ = self.renderDebugView(initial_roots_length, initial_elements_length) catch |render_error| {
                // `renderDebugView` unwinds its declarations to the synthetic
                // root sentinel before propagating an error.
                self.debug_warnings_enabled = true;
                if (self.layout_open) _ = self.open_stack.pop();
                return render_error;
            };
            self.debug_warnings_enabled = true;
            _ = self.open_stack.pop();
        }
        if (had_transition_data) {
            // Debug declarations and the target-state preliminary render are
            // complete. Reserve every possible final-layout/render/commit
            // growth before the first externally visible transition callback.
            try self.preflightPostTransitionWork();
            transitions_active = try self.updateTransitions(delta_time);
        }
        // This is the sole layout/render pass for ordinary frames, and the
        // second pass for transition frames, matching Clay's two branches.
        try self.calculateFinalLayout();
        self.render_commands.clearRetainingCapacity();
        self.pending_hit_records.clearRetainingCapacity();
        self.apply_transition_overrides = transitions_active;
        self.resetBoundingBoxValidity();
        for (self.roots.items, 0..) |root, root_sequence| {
            try self.renderRoot(root, root_sequence);
        }
        self.apply_transition_overrides = false;
        try self.rejectUnbalancedRenderPrefix();
        if (!had_transition_data) try self.preflightFrameCommit();
        self.stageCurrentFrameSnapshot();
        self.commitPersistentElements();
        self.commitDebugFrameState();
        self.applyPendingExternalScrollQueries();
        self.commitStagedFrameState();
        self.frame_rollback_snapshot_active = false;
        self.layout_open = false;
        self.root_resized_last_frame = false;

        return .{
            // The public capacity matches Clay's configured command-array
            // capacity. `addRenderCommand` reserves its final slot, exactly as
            // the pinned implementation does.
            .capacity = @intCast(self.renderCommandCapacity()),
            .length = @intCast(self.render_commands.items.len),
            .internal_array = self.render_commands.items,
        };
    }

    fn calculateFinalLayout(self: *Context) !void {
        // Pinned Clay reads its writable CLAY_LAYOUT_DEFAULT global for every
        // text node during the final tree walk, after declarations have ended.
        for (self.nodes.items) |*node| {
            if (node.is_text) node.config.layout = globals.layout_default;
        }
        self.layout_aspect_ratios.clearRetainingCapacity();
        try layout.sizeContainersAlongAxisWithScratch(
            self.allocator,
            self.nodes.items,
            self.child_indices.items,
            self.roots.items,
            &self.id_to_index,
            true,
            &self.layout_bfs,
            &self.layout_resizable,
            &self.layout_aspect_ratios,
        );
        try self.wrapTextElements();

        for (self.layout_aspect_ratios.items) |node_index| {
            const node = &self.nodes.items[node_index];
            node.dimensions.height = (1 / node.config.aspect_ratio.aspect_ratio) * node.dimensions.width;
            // Pinned Clay writes the second float of its C sizing union even
            // when the active member is `percent`. Preserve that value without
            // touching Zig's inactive `min_max` union field in safety builds.
            if (node.config.layout.sizing.height.type == .percent) {
                node.percent_height_max = node.dimensions.height;
            } else {
                node.config.layout.sizing.height.size.min_max.max = node.dimensions.height;
            }
        }
        try layout.propagateHeights(self.nodes.items, self.child_indices.items, self.roots.items);
        try layout.sizeContainersAlongAxisWithScratch(
            self.allocator,
            self.nodes.items,
            self.child_indices.items,
            self.roots.items,
            &self.id_to_index,
            false,
            &self.layout_bfs,
            &self.layout_resizable,
            null,
        );
        for (self.layout_aspect_ratios.items) |node_index| {
            const node = &self.nodes.items[node_index];
            node.dimensions.width = node.config.aspect_ratio.aspect_ratio * node.dimensions.height;
        }
        layout.sortRootsByZ(self.roots.items);
    }

    fn resetBoundingBoxValidity(self: *Context) void {
        for (self.nodes.items) |*node| node.bounding_box_valid = false;
    }

    fn frameHasExitTransition(self: *const Context) bool {
        for (self.nodes.items) |node| {
            if (node.config.transition.handler != null and node.config.transition.exit.set_final_state != null) {
                return true;
            }
        }
        return false;
    }

    /// Reserve the retained and persistent commit storage without publishing
    /// or mutating any committed surface. Transition frames run this before
    /// application callbacks so no allocator failure can follow one.
    fn preflightFrameCommit(self: *Context) !void {
        if (self.frameHasExitTransition()) {
            try self.pending_retained_nodes.ensureTotalCapacity(self.allocator, self.nodes.items.len);
            try self.pending_retained_child_indices.ensureTotalCapacity(self.allocator, self.child_indices.items.len);
            try self.pending_retained_texts.ensureTotalCapacity(self.allocator, self.texts.items.len);
            try self.pending_retained_id_to_index.ensureTotalCapacity(@intCast(self.nodes.items.len));
        }

        var new_persistent_count: u32 = 0;
        for (self.nodes.items) |node| {
            if (!self.persistent_elements.contains(node.element_id.id)) new_persistent_count += 1;
        }
        try self.persistent_elements.ensureUnusedCapacity(new_persistent_count);
        const maximum_stale_count = @as(usize, self.persistent_elements.count()) + new_persistent_count;
        try self.stale_ids.ensureTotalCapacity(self.allocator, maximum_stale_count);
    }

    fn wrappedLineUpperBound(self: *const Context) usize {
        var bound: usize = 0;
        for (self.texts.items) |record| {
            var text_bound: usize = 1;
            for (record.text.asSlice()) |byte| {
                if (byte == ' ') text_bound +|= 1;
                if (byte == '\n') text_bound +|= 2;
            }
            bound +|= text_bound;
        }
        return @min(bound, self.options.max_element_count);
    }

    /// The preliminary transition layout may let the measurement callback
    /// mutate a text node's configuration after the cache key was selected.
    /// Pin every key already present and reserve item/word nodes for every key
    /// that the final pass can miss. The final pass may still invoke the
    /// application callback for parity, but it cannot allocate cache storage.
    fn preflightFinalTextCache(self: *Context) !void {
        if (self.measure_text_function == null or self.texts.items.len == 0) return;

        self.text_cache_preflight_keys.clearRetainingCapacity();
        try self.text_cache_preflight_keys.ensureTotalCapacity(@intCast(self.nodes.items.len));
        var required_items: usize = 0;
        var required_words: usize = 0;
        for (self.nodes.items) |node| {
            const text_index = node.text_index orelse continue;
            const record = &self.texts.items[text_index];
            const key = text_engine.MeasurementKey.init(record.text, node.text_config);
            const seen = self.text_cache_preflight_keys.getOrPutAssumeCapacity(key);
            if (seen.found_existing) continue;
            seen.value_ptr.* = {};
            if (self.text_cache.refreshIfPresent(
                record.text,
                node.text_config,
                self.generation,
            )) continue;
            required_items = std.math.add(usize, required_items, 1) catch
                return error.OutOfMemory;
            required_words = std.math.add(
                usize,
                required_words,
                text_engine.measuredWordCount(record.text),
            ) catch return error.OutOfMemory;
        }
        try self.text_cache.ensureFreeCapacity(required_items, required_words);
    }

    const RenderCommandUpperBound = struct {
        count: usize,
        has_scope: bool,
    };

    fn renderCommandUpperBound(self: *const Context, wrapped_line_bound: usize) RenderCommandUpperBound {
        var result = RenderCommandUpperBound{
            .count = wrapped_line_bound,
            .has_scope = false,
        };
        for (self.roots.items) |root| {
            if (root.clip_element_id == 0) continue;
            result.count +|= 2;
            result.has_scope = true;
        }
        for (self.nodes.items) |node| {
            if (node.is_text) continue;
            const properties = node.config.transition.properties;
            if (node.config.image.image_data != null) result.count +|= 1;
            if (node.config.custom.custom_data != null) result.count +|= 1;
            if (node.config.clip.horizontal or node.config.clip.vertical) {
                result.count +|= 2;
                result.has_scope = true;
            }
            if (node.config.background_color.a > 0 or
                transitions.intersects(properties, .background_color))
            {
                result.count +|= 1;
            }
            if (node.config.overlay_color.a > 0 or
                transitions.intersects(properties, .overlay_color))
            {
                result.count +|= 2;
                result.has_scope = true;
            }
            const may_have_border_width = borderHasAnyWidth(node.config.border.width) or
                transitions.intersects(properties, .border_width);
            const may_have_border_color = node.config.border.color.a > 0 or
                transitions.intersects(properties, .border_color);
            if (may_have_border_width) {
                result.count +|= 1;
                if (may_have_border_color and
                    (node.config.border.width.between_children > 0 or
                        transitions.intersects(properties, .border_width)))
                {
                    result.count +|= node.children_len -| 1;
                }
            }
        }
        return result;
    }

    /// Reserve every collection that the final transition-applied layout and
    /// render can grow. The bounds deliberately ignore culling and use the
    /// maximum command contribution of every declared node and text byte.
    fn preflightPostTransitionWork(self: *Context) !void {
        const node_count = self.nodes.items.len;
        try self.layout_bfs.ensureTotalCapacity(self.allocator, node_count);
        try self.layout_resizable.ensureTotalCapacity(self.allocator, node_count);
        try self.layout_aspect_ratios.ensureTotalCapacity(self.allocator, node_count);
        try self.render_stack.ensureTotalCapacity(self.allocator, node_count);
        try self.pending_hit_records.ensureTotalCapacity(self.allocator, node_count);

        const wrapped_line_bound = self.wrappedLineUpperBound();
        try self.wrapped_lines.ensureTotalCapacity(self.allocator, wrapped_line_bound);
        try self.preflightFinalTextCache();
        if (self.paragraph_provider != null) {
            const layout_count_max = std.math.add(
                usize,
                self.paragraph_layout_cache.items.len,
                self.texts.items.len,
            ) catch return error.OutOfMemory;
            try self.paragraph_layout_cache.ensureTotalCapacity(
                self.allocator,
                layout_count_max,
            );
            try self.paragraph_layout_cache_map.ensureUnusedCapacity(
                @intCast(self.texts.items.len),
            );
        }

        const command_bound = self.renderCommandUpperBound(wrapped_line_bound);
        const command_capacity = self.renderCommandCapacity();
        const effective_command_limit = if (command_capacity > 0) command_capacity - 1 else 0;
        if (command_bound.has_scope and effective_command_limit > 0 and
            command_bound.count > effective_command_limit)
        {
            return Error.RenderCommandCapacityExceeded;
        }
        try self.render_commands.ensureTotalCapacity(
            self.allocator,
            @min(command_bound.count, effective_command_limit),
        );
        try self.preflightFrameCommit();
    }

    /// Build the next retained snapshot without touching the last completed
    /// frame. Every destination was reserved by `preflightFrameCommit`.
    fn stageCurrentFrameSnapshot(self: *Context) void {
        var has_exit_transition = false;
        for (self.nodes.items) |node| {
            if (node.config.transition.handler != null and node.config.transition.exit.set_final_state != null) {
                has_exit_transition = true;
                break;
            }
        }

        self.pending_retained_nodes.clearRetainingCapacity();
        self.pending_retained_child_indices.clearRetainingCapacity();
        self.pending_retained_texts.clearRetainingCapacity();
        self.pending_retained_id_to_index.clearRetainingCapacity();
        if (!has_exit_transition) return;

        self.pending_retained_nodes.appendSliceAssumeCapacity(self.nodes.items);
        self.pending_retained_child_indices.appendSliceAssumeCapacity(self.child_indices.items);
        self.pending_retained_texts.appendSliceAssumeCapacity(self.texts.items);
        for (self.pending_retained_nodes.items, 0..) |node, index| {
            if (!self.pending_retained_id_to_index.contains(node.element_id.id)) {
                self.pending_retained_id_to_index.putAssumeCapacity(node.element_id.id, index);
            }
        }
    }

    fn commitStagedFrameState(self: *Context) void {
        std.mem.swap(std.ArrayList(HitRecord), &self.hit_records, &self.pending_hit_records);
        std.mem.swap(std.ArrayList(layout.Node), &self.retained_nodes, &self.pending_retained_nodes);
        std.mem.swap(std.ArrayList(usize), &self.retained_child_indices, &self.pending_retained_child_indices);
        std.mem.swap(std.ArrayList(TextRecord), &self.retained_texts, &self.pending_retained_texts);
        std.mem.swap(
            std.AutoHashMap(u32, usize),
            &self.retained_id_to_index,
            &self.pending_retained_id_to_index,
        );
    }

    /// Copy the committed transition and scroll state before declarations begin.
    /// Frame construction mutates the live collections for exact Clay ordering;
    /// a failed frame swaps these allocation-owned backups back into place.
    fn snapshotMutableFrameState(self: *Context) !void {
        try self.rollback_transition_order.ensureTotalCapacity(
            self.allocator,
            self.transition_order.items.len,
        );
        try self.rollback_scroll_containers.ensureTotalCapacity(
            self.allocator,
            self.scroll_containers.items.len,
        );
        try self.rollback_transition_states.ensureTotalCapacity(self.transition_states.count());

        self.rollback_transition_order.clearRetainingCapacity();
        self.rollback_transition_order.appendSliceAssumeCapacity(self.transition_order.items);
        self.rollback_scroll_containers.clearRetainingCapacity();
        self.rollback_scroll_containers.appendSliceAssumeCapacity(self.scroll_containers.items);
        self.rollback_transition_states.clearRetainingCapacity();
        var iterator = self.transition_states.iterator();
        while (iterator.next()) |entry| {
            self.rollback_transition_states.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn rollbackMutableFrameState(self: *Context) void {
        if (!self.frame_rollback_snapshot_active) return;
        std.mem.swap(
            std.ArrayList(u32),
            &self.transition_order,
            &self.rollback_transition_order,
        );
        std.mem.swap(
            std.AutoHashMap(u32, TransitionRuntime),
            &self.transition_states,
            &self.rollback_transition_states,
        );
        std.mem.swap(
            std.ArrayList(scroll_engine.Container),
            &self.scroll_containers,
            &self.rollback_scroll_containers,
        );
        self.pending_scroll_query_ids.clearRetainingCapacity();
        self.frame_rollback_snapshot_active = false;
    }

    fn rejectUnbalancedRenderPrefix(self: *Context) !void {
        if (!self.warned_render_capacity) return;
        _ = renderer.validate(self.render_commands.items) catch
            return Error.RenderCommandCapacityExceeded;
    }

    fn reinsertExitingSubtrees(self: *Context) !void {
        self.exit_removal_ids.clearRetainingCapacity();
        var transition_index: usize = 0;
        while (transition_index < self.transition_order.items.len) {
            const id_value = self.transition_order.items[transition_index];
            const runtime = self.transition_states.getPtr(id_value) orelse {
                _ = self.transition_order.swapRemove(transition_index);
                continue;
            };

            if (self.id_to_index.get(id_value)) |node_index| {
                // The pinned C array prunes handler-less non-exit entries with
                // swapback and immediately revisits the swapped-in slot.
                if (runtime.config.exit.set_final_state == null and
                    self.nodes.items[node_index].config.transition.handler == null)
                {
                    self.removeTransitionAt(transition_index);
                    continue;
                }
                transition_index += 1;
                continue;
            }

            if (runtime.config.handler == null or
                runtime.config.exit.set_final_state == null or
                !self.retained_id_to_index.contains(id_value))
            {
                self.removeTransitionAt(transition_index);
                continue;
            }
            const parent_missing = runtime.parent_id != 0 and !self.id_to_index.contains(runtime.parent_id);
            if (parent_missing and runtime.config.exit.trigger == .skip_when_parent_exits) {
                self.removeTransitionAt(transition_index);
                continue;
            }
            if (runtime.state != .exiting) {
                runtime.state = .exiting;
                runtime.elapsed_time = 0;
                runtime.active_properties = runtime.config.properties;
                runtime.exit_final_state_pending = true;
            }
            try self.cloneRetainedSubtree(id_value, runtime);
            transition_index += 1;
        }

        // Clay removes nested transition entries only after every exiting
        // subtree has been cloned. Each removal is a swapback lookup by ID.
        for (self.exit_removal_ids.items) |id_value| {
            if (self.transitionOrderIndex(id_value)) |index| self.removeTransitionAt(index);
        }
    }

    fn cloneRetainedSubtree(self: *Context, id_value: u32, runtime: *TransitionRuntime) !void {
        const retained_root_index = self.retained_id_to_index.get(id_value) orelse return;
        self.clone_old_indices.clearRetainingCapacity();
        self.clone_old_to_new.clearRetainingCapacity();
        try self.clone_old_indices.append(self.allocator, retained_root_index);

        var cursor: usize = 0;
        while (cursor < self.clone_old_indices.items.len) : (cursor += 1) {
            const old_node = &self.retained_nodes.items[self.clone_old_indices.items[cursor]];
            for (old_node.children(self.retained_child_indices.items)) |child_old_index| {
                const child_id = self.retained_nodes.items[child_old_index].element_id.id;
                if (self.id_to_index.contains(child_id)) continue;
                try self.clone_old_indices.append(self.allocator, child_old_index);
            }
        }

        const node_base = self.nodes.items.len;
        try self.clone_old_to_new.ensureTotalCapacity(@intCast(self.clone_old_indices.items.len));
        for (self.clone_old_indices.items, 0..) |old_index, index| {
            self.clone_old_to_new.putAssumeCapacity(old_index, node_base + index);
        }

        var edge_count: usize = 0;
        var text_count: usize = 0;
        for (self.clone_old_indices.items) |old_index| {
            const old_node = &self.retained_nodes.items[old_index];
            if (old_node.text_index != null) text_count += 1;
            for (old_node.children(self.retained_child_indices.items)) |child_old_index| {
                if (self.clone_old_to_new.contains(child_old_index)) edge_count += 1;
            }
        }

        const retained_root = &self.retained_nodes.items[retained_root_index];
        const originally_floating = retained_root.config.floating.attach_to != .none;
        const current_parent_index: ?usize = if (!originally_floating)
            self.id_to_index.get(runtime.parent_id)
        else
            null;
        const reattach_as_child = current_parent_index != null;
        const parent_rebuild_count = if (current_parent_index) |parent_index|
            self.nodes.items[parent_index].children_len + 1
        else
            0;

        try self.nodes.ensureTotalCapacity(self.allocator, self.nodes.items.len + self.clone_old_indices.items.len);
        try self.texts.ensureTotalCapacity(self.allocator, self.texts.items.len + text_count);
        try self.child_indices.ensureTotalCapacity(
            self.allocator,
            self.child_indices.items.len + edge_count + parent_rebuild_count,
        );
        try self.id_to_index.ensureTotalCapacity(self.id_to_index.count() + @as(u32, @intCast(self.clone_old_indices.items.len)));
        if (!reattach_as_child) try self.roots.ensureTotalCapacity(self.allocator, self.roots.items.len + 1);

        for (self.clone_old_indices.items, 0..) |old_index, clone_index| {
            const old_node = &self.retained_nodes.items[old_index];
            var cloned = old_node.*;
            cloned.clip_node_index = if (old_node.clip_node_index) |old_clip_index|
                self.clone_old_to_new.get(old_clip_index) orelse self.id_to_index.get(old_node.clip_element_id)
            else
                null;
            cloned.children_start = self.child_indices.items.len;
            cloned.children_len = 0;
            cloned.floating_children_count = 0;
            cloned.bounding_box_valid = true;
            cloned.exiting = clone_index == 0;
            if (clone_index == 0) {
                cloned.parent_index = current_parent_index orelse 0;
                cloned.config.layout.sizing.width = types.fixed(cloned.dimensions.width);
                cloned.config.layout.sizing.height = types.fixed(cloned.dimensions.height);
                cloned.min_dimensions = cloned.dimensions;
                if (!reattach_as_child and !originally_floating) {
                    cloned.config.floating.attach_to = .root;
                    cloned.config.floating.parent_id = self.nodes.items[0].element_id.id;
                    cloned.config.floating.attach_points = .{};
                    cloned.config.floating.offset = .{
                        .x = cloned.bounding_box.x,
                        .y = cloned.bounding_box.y,
                    };
                    cloned.config.floating.expand = .{};
                    cloned.config.floating.clip_to = .none;
                    cloned.clip_element_id = 0;
                    cloned.clip_node_index = null;
                }
            } else {
                if (old_node.config.transition.handler != null) {
                    try self.exit_removal_ids.append(self.allocator, old_node.element_id.id);
                }
                cloned.config.transition = .{};
                if (old_node.parent_index) |old_parent_index| {
                    cloned.parent_index = self.clone_old_to_new.get(old_parent_index);
                }
            }

            if (old_node.text_index) |old_text_index| {
                cloned.text_index = self.texts.items.len;
                self.texts.appendAssumeCapacity(self.retained_texts.items[old_text_index]);
            }
            for (old_node.children(self.retained_child_indices.items)) |child_old_index| {
                if (self.clone_old_to_new.get(child_old_index)) |child_new_index| {
                    self.child_indices.appendAssumeCapacity(child_new_index);
                    cloned.children_len += 1;
                }
            }
            const new_index = self.nodes.items.len;
            self.nodes.appendAssumeCapacity(cloned);
            if (!self.id_to_index.contains(cloned.element_id.id)) {
                self.id_to_index.putAssumeCapacity(cloned.element_id.id, new_index);
            }
        }

        if (current_parent_index) |parent_index| {
            const old_start = self.nodes.items[parent_index].children_start;
            const old_len = self.nodes.items[parent_index].children_len;
            const insertion_index = switch (runtime.config.exit.sibling_ordering) {
                .underneath_siblings => 0,
                .natural_order => @min(runtime.sibling_index, old_len),
                .above_siblings => old_len,
            };
            const new_start = self.child_indices.items.len;
            var index: usize = 0;
            while (index <= old_len) : (index += 1) {
                if (index == insertion_index) self.child_indices.appendAssumeCapacity(node_base);
                if (index < old_len) {
                    self.child_indices.appendAssumeCapacity(self.child_indices.items[old_start + index]);
                }
            }
            self.nodes.items[parent_index].children_start = new_start;
            self.nodes.items[parent_index].children_len = old_len + 1;
            self.nodes.items[node_base].parent_index = parent_index;
        } else {
            const root_node = &self.nodes.items[node_base];
            self.roots.appendAssumeCapacity(.{
                .element_index = node_base,
                .parent_id = root_node.config.floating.parent_id,
                .parent_node_index = self.id_to_index.get(root_node.config.floating.parent_id),
                .clip_element_id = root_node.clip_element_id,
                .clip_node_index = root_node.clip_node_index,
                .z_index = root_node.config.floating.z_index,
            });
        }
    }

    pub fn getElementData(self: *const Context, element_id: types.ElementId) types.ElementData {
        if (self.persistent_elements.get(element_id.id)) |persistent| {
            return .{ .bounding_box = persistent.bounding_box, .found = true };
        }
        // Clay installs the hash-map entry as soon as an element opens. A
        // first-frame query therefore reports `found` with its zeroed box even
        // though final layout has not run yet.
        if (self.layout_open and self.id_to_index.contains(element_id.id)) {
            return .{ .found = true };
        }
        return .{};
    }

    pub fn renderCommand(self: *Context, index: i32) ?*types.RenderCommand {
        if (index < 0) return null;
        const array_index: usize = @intCast(index);
        if (array_index >= self.render_commands.items.len) return null;
        if (self.application_callback_phase != .none) {
            // Preserve callback-time inspection without exposing a mutable
            // alias to a stream that has already passed structural validation
            // and may be returned immediately after the callback.
            self.callback_render_command = self.render_commands.items[array_index];
            return &self.callback_render_command;
        }
        return &self.render_commands.items[array_index];
    }

    fn wrapTextElements(self: *Context) !void {
        self.wrapped_lines.clearRetainingCapacity();
        for (self.nodes.items) |*node| {
            const text_index = node.text_index orelse continue;
            const record = &self.texts.items[text_index];
            record.paragraph_layout_index = null;
            record.wrapped_start = self.wrapped_lines.items.len;
            if (self.paragraph_provider) |provider| {
                const layout_index = try self.layoutParagraphGuarded(
                    provider,
                    record,
                    node.dimensions.width,
                );
                record.paragraph_layout_index = layout_index;
                node.dimensions.height = self.paragraph_layout_cache.items[layout_index]
                    .render_data.lease.paragraph_metrics.logical.advance.y;
            } else {
                if (self.wrapTextGuarded(record, node)) |dimensions| {
                    node.dimensions.height = dimensions.height;
                } else |wrap_error| switch (wrap_error) {
                    error.MeasureTextFunctionNotProvided => {
                        // Clay's null measurement callback returns its zeroed
                        // default cache item. The fast-path wrapper still retains
                        // the complete source string as one zero-width line, so a
                        // renderer receives a text command with the configured
                        // line height even though no glyph metrics are available.
                        if (self.wrapped_lines.items.len < self.options.max_element_count) {
                            try self.wrapped_lines.append(self.allocator, .{
                                .dimensions = node.dimensions,
                                .line = types.StringSlice.fromSlice(record.text.asSlice()),
                            });
                        }
                    },
                    error.TextMeasurementCapacityExceeded => {
                        if (!self.warned_text_capacity) {
                            self.warned_text_capacity = true;
                            self.emitError(.text_measurement_capacity_exceeded, "Clay ran out of measured-word cache capacity.");
                        }
                        return Error.TextMeasurementCapacityExceeded;
                    },
                    else => return wrap_error,
                }
            }
            record.wrapped_len = self.wrapped_lines.items.len - record.wrapped_start;
        }
    }

    fn renderRoot(self: *Context, root: layout.Root, root_sequence: usize) !void {
        const root_node = &self.nodes.items[root.element_index];
        var root_position = types.Vector2{};
        if (root_node.config.floating.attach_to != .none) {
            const parent_box = if (root.parent_node_index) |parent_index|
                self.boundingBoxForNode(parent_index)
            else
                self.boundingBoxForId(root.parent_id);
            if (parent_box) |box| {
                root_position = floatingPosition(box, root_node.dimensions, root_node.config.floating);
            }
        }

        var opened_root_clip = false;
        if (root.clip_element_id != 0) {
            const clip_box_optional = if (root.clip_node_index) |clip_index|
                self.boundingBoxForNode(clip_index)
            else
                self.boundingBoxForId(root.clip_element_id);
            if (clip_box_optional) |clip_box| {
                if (!self.isOffscreen(clip_box)) {
                    if (self.external_scroll_handling_enabled) {
                        const clip_index_optional = root.clip_node_index orelse self.id_to_index.get(root.clip_element_id);
                        if (clip_index_optional) |clip_index| {
                            const clip_config = self.nodes.items[clip_index].config.clip;
                            if (clip_config.horizontal) root_position.x += clip_config.child_offset.x;
                            if (clip_config.vertical) root_position.y += clip_config.child_offset.y;
                        }
                    }
                    try self.addRenderCommand(.{
                        .bounding_box = clip_box,
                        .render_data = .{ .clip = .{} },
                        .id = hashes.number(root_node.element_id.id, @intCast(root_node.children_len + 10)).id,
                        .z_index = root.z_index,
                        .command_type = .scissor_start,
                    });
                    opened_root_clip = true;
                }
            }
        }

        const capture_root = root_node.config.floating.attach_to != .none and
            root_node.config.floating.pointer_capture_mode == .capture;
        try self.renderNode(
            root.element_index,
            root_position,
            root.z_index,
            root_sequence,
            capture_root,
            root_node.children_len,
            false,
        );

        if (opened_root_clip) {
            try self.addRenderCommand(.{
                .id = hashes.number(root_node.element_id.id, @intCast(root_node.children_len + 11)).id,
                .command_type = .scissor_end,
            });
        }
    }

    fn renderNode(
        self: *Context,
        node_index: usize,
        position: types.Vector2,
        z_index: i16,
        root_sequence: usize,
        capture_root: bool,
        root_child_count: usize,
        ancestor_blocks_interactions: bool,
    ) !void {
        self.render_stack.clearRetainingCapacity();
        try self.render_stack.ensureTotalCapacity(self.allocator, self.nodes.items.len);
        self.render_stack.appendAssumeCapacity(.{
            .node_index = node_index,
            .position = position,
            .z_index = z_index,
            .root_sequence = root_sequence,
            .capture_root = capture_root,
            .root_child_count = root_child_count,
            .ancestor_blocks_interactions = ancestor_blocks_interactions,
        });
        // This intentionally mirrors the pinned clay.h `skipTree` lifetime:
        // once a transitioning node blocks pointer input, the flag remains set
        // for every later DFS node in that root, including sibling subtrees.
        var root_blocks_interactions = ancestor_blocks_interactions;

        while (self.render_stack.items.len > 0) {
            const frame_index = self.render_stack.items.len - 1;
            switch (self.render_stack.items[frame_index].phase) {
                .pre => {
                    const frame = self.render_stack.items[frame_index];
                    const node = &self.nodes.items[frame.node_index];
                    const owns_id = self.id_to_index.get(node.element_id.id) == frame.node_index;
                    const skip_render = frame.skip_render or
                        (node.exiting and !self.transition_states.contains(node.element_id.id));

                    var bounding_box = types.BoundingBox{
                        .x = frame.position.x,
                        .y = frame.position.y,
                        .width = node.dimensions.width,
                        .height = node.dimensions.height,
                    };
                    if (owns_id and self.apply_transition_overrides) if (self.transition_states.get(node.element_id.id)) |runtime| {
                        if (runtime.state != .idle) {
                            if (transitions.intersects(runtime.active_properties, .x)) bounding_box.x = runtime.current.bounding_box.x;
                            if (transitions.intersects(runtime.active_properties, .y)) bounding_box.y = runtime.current.bounding_box.y;
                            if (transitions.intersects(runtime.active_properties, .width)) bounding_box.width = runtime.current.bounding_box.width;
                            if (transitions.intersects(runtime.active_properties, .height)) bounding_box.height = runtime.current.bounding_box.height;
                        }
                    };
                    if (!node.is_text and node.config.floating.attach_to != .none) {
                        bounding_box.x -= node.config.floating.expand.width;
                        bounding_box.y -= node.config.floating.expand.height;
                        bounding_box.width += node.config.floating.expand.width * 2;
                        bounding_box.height += node.config.floating.expand.height * 2;
                    }
                    node.bounding_box = bounding_box;
                    node.bounding_box_valid = true;

                    const clip_box: ?types.BoundingBox = if (node.clip_node_index) |clip_index|
                        self.boundingBoxForNode(clip_index)
                    else if (node.clip_element_id != 0)
                        self.boundingBoxForId(node.clip_element_id)
                    else
                        null;
                    if (owns_id and self.transitionBlocksInteractions(node.element_id.id)) {
                        root_blocks_interactions = true;
                    }
                    const blocks_interactions = frame.ancestor_blocks_interactions or root_blocks_interactions;
                    if (owns_id and !blocks_interactions) {
                        try self.pending_hit_records.append(self.allocator, .{
                            .element_id = node.element_id,
                            .bounding_box = bounding_box,
                            .clip_box = clip_box,
                            .root_sequence = frame.root_sequence,
                            .capture_root = frame.capture_root,
                        });
                    }

                    const offscreen = self.isOffscreen(bounding_box);
                    if (node.is_text) {
                        if (!offscreen and !skip_render) try self.renderTextNode(node, bounding_box, frame.z_index);
                        _ = self.render_stack.pop();
                        continue;
                    }

                    if (!offscreen and !skip_render) {
                        if (node.config.overlay_color.a > 0) {
                            try self.addRenderCommand(.{
                                .render_data = .{ .overlay_color = .{ .color = node.config.overlay_color } },
                                .user_data = node.config.user_data,
                                .id = node.element_id.id,
                                .z_index = frame.z_index,
                                .command_type = .overlay_color_start,
                            });
                        }
                        if (node.config.image.image_data != null) {
                            try self.addRenderCommand(.{
                                .bounding_box = bounding_box,
                                .render_data = .{ .image = .{
                                    .background_color = node.config.background_color,
                                    .corner_radius = node.config.corner_radius,
                                    .image_data = node.config.image.image_data,
                                } },
                                .user_data = node.config.user_data,
                                .id = node.element_id.id,
                                .z_index = frame.z_index,
                                .command_type = .image,
                            });
                        }
                        if (node.config.custom.custom_data != null) {
                            try self.addRenderCommand(.{
                                .bounding_box = bounding_box,
                                .render_data = .{ .custom = .{
                                    .background_color = node.config.background_color,
                                    .corner_radius = node.config.corner_radius,
                                    .custom_data = node.config.custom.custom_data,
                                } },
                                .user_data = node.config.user_data,
                                .id = node.element_id.id,
                                .z_index = frame.z_index,
                                .command_type = .custom,
                            });
                        }
                        if (node.config.clip.horizontal or node.config.clip.vertical) {
                            try self.addRenderCommand(.{
                                .bounding_box = bounding_box,
                                .render_data = .{ .clip = .{
                                    .horizontal = node.config.clip.horizontal,
                                    .vertical = node.config.clip.vertical,
                                } },
                                .user_data = node.config.user_data,
                                .id = node.element_id.id,
                                .z_index = frame.z_index,
                                .command_type = .scissor_start,
                            });
                        }
                        if (node.config.background_color.a > 0) {
                            try self.addRenderCommand(.{
                                .bounding_box = bounding_box,
                                .render_data = .{ .rectangle = .{
                                    .background_color = node.config.background_color,
                                    .corner_radius = node.config.corner_radius,
                                } },
                                .user_data = node.config.user_data,
                                .id = node.element_id.id,
                                .z_index = frame.z_index,
                                .command_type = .rectangle,
                            });
                        }
                    }

                    const content_dimensions = contentDimensions(node, self.nodes.items, self.child_indices.items);
                    if (owns_id and (node.config.clip.horizontal or node.config.clip.vertical)) {
                        for (self.scroll_containers.items) |*container| {
                            if (container.id == node.element_id.id) {
                                container.markOpen(bounding_box, node.dimensions, content_dimensions, node.config.clip);
                                break;
                            }
                        }
                    }

                    var next_offset = types.Vector2{
                        .x = @floatFromInt(node.config.layout.padding.left),
                        .y = @floatFromInt(node.config.layout.padding.top),
                    };
                    applyOnAxisAlignment(node, content_dimensions, &next_offset);
                    var scroll_offset = node.config.clip.child_offset;
                    if (self.external_scroll_handling_enabled) scroll_offset = .{};

                    const stored_frame = &self.render_stack.items[frame_index];
                    stored_frame.bounding_box = bounding_box;
                    stored_frame.offscreen = offscreen or skip_render;
                    stored_frame.skip_render = skip_render;
                    stored_frame.blocks_interactions = blocks_interactions;
                    stored_frame.next_offset = next_offset;
                    stored_frame.scroll_offset = scroll_offset;
                    stored_frame.phase = .children;
                },
                .children => {
                    const frame = &self.render_stack.items[frame_index];
                    const node = &self.nodes.items[frame.node_index];
                    const children = node.children(self.child_indices.items);
                    if (frame.next_child >= children.len) {
                        frame.phase = .post;
                        continue;
                    }

                    const child_index = children[frame.next_child];
                    const child = &self.nodes.items[child_index];
                    frame.next_child += 1;
                    applyOffAxisAlignment(node, child, &frame.next_offset);
                    const child_position = types.Vector2{
                        .x = frame.bounding_box.x + frame.next_offset.x + frame.scroll_offset.x,
                        .y = frame.bounding_box.y + frame.next_offset.y + frame.scroll_offset.y,
                    };
                    if (!child.exiting) {
                        if (node.config.layout.layout_direction == .left_to_right) {
                            frame.next_offset.x += child.dimensions.width + @as(f32, @floatFromInt(node.config.layout.child_gap));
                        } else {
                            frame.next_offset.y += child.dimensions.height + @as(f32, @floatFromInt(node.config.layout.child_gap));
                        }
                    }

                    const child_frame = RenderFrame{
                        .node_index = child_index,
                        .position = child_position,
                        .z_index = frame.z_index,
                        .root_sequence = frame.root_sequence,
                        .capture_root = frame.capture_root,
                        .root_child_count = frame.root_child_count,
                        .ancestor_blocks_interactions = frame.blocks_interactions,
                        .skip_render = frame.skip_render,
                    };
                    self.render_stack.appendAssumeCapacity(child_frame);
                },
                .post => {
                    const frame = self.render_stack.items[frame_index];
                    const node = &self.nodes.items[frame.node_index];
                    if (!frame.offscreen) {
                        if (borderHasAnyWidth(node.config.border.width)) {
                            try self.addRenderCommand(.{
                                .bounding_box = frame.bounding_box,
                                .render_data = .{ .border = .{
                                    .color = node.config.border.color,
                                    .corner_radius = node.config.corner_radius,
                                    .width = node.config.border.width,
                                } },
                                .user_data = node.config.user_data,
                                .id = hashes.number(node.element_id.id, @intCast(node.children_len)).id,
                                .command_type = .border,
                            });
                            try self.renderBetweenChildBorders(node, frame.bounding_box, frame.scroll_offset);
                        }
                        if (node.config.overlay_color.a > 0) {
                            try self.addRenderCommand(.{
                                .user_data = node.config.user_data,
                                .id = node.element_id.id,
                                .z_index = frame.z_index,
                                .command_type = .overlay_color_end,
                            });
                        }
                        if (node.config.clip.horizontal or node.config.clip.vertical) {
                            try self.addRenderCommand(.{
                                .id = hashes.number(node.element_id.id, @intCast(frame.root_child_count + 11)).id,
                                .command_type = .scissor_end,
                            });
                        }
                    }
                    _ = self.render_stack.pop();
                },
            }
        }
    }

    fn renderTextNode(self: *Context, node: *const layout.Node, bounding_box: types.BoundingBox, z_index: i16) !void {
        const text_index = node.text_index.?;
        const record = &self.texts.items[text_index];
        if (record.paragraph_layout_index) |layout_index| {
            const provider_data = &self.paragraph_layout_cache.items[layout_index].render_data;
            const logical = provider_data.lease.paragraph_metrics.logical;
            try self.addRenderCommand(.{
                .bounding_box = .{
                    .x = bounding_box.x,
                    .y = bounding_box.y,
                    .width = logical.advance.x,
                    .height = logical.advance.y,
                },
                .render_data = .{ .custom = .{
                    .background_color = node.text_config.text_color,
                    .custom_data = @ptrCast(provider_data),
                } },
                .user_data = node.text_config.user_data,
                .id = node.element_id.id,
                .z_index = z_index,
                .command_type = .custom,
            });
            return;
        }
        const natural_height = record.preferred_dimensions.height;
        const config = node.text_config;
        const line_height: f32 = if (config.line_height > 0) @floatFromInt(config.line_height) else natural_height;
        var y_position = (line_height - natural_height) / 2;
        const lines = self.wrapped_lines.items[record.wrapped_start .. record.wrapped_start + record.wrapped_len];
        for (lines, 0..) |line, line_index| {
            if (line.line.length == 0) {
                y_position += line_height;
                continue;
            }
            try self.addRenderCommand(.{
                .bounding_box = .{
                    .x = bounding_box.x + line.alignment_offset,
                    .y = bounding_box.y + y_position,
                    .width = line.dimensions.width,
                    .height = line.dimensions.height,
                },
                .render_data = .{ .text = .{
                    .string_contents = line.line,
                    .text_color = config.text_color,
                    .font_id = config.font_id,
                    .font_size = config.font_size,
                    .letter_spacing = config.letter_spacing,
                    .line_height = config.line_height,
                } },
                .user_data = config.user_data,
                .id = hashes.number(@intCast(line_index), node.element_id.id).id,
                .z_index = z_index,
                .command_type = .text,
            });
            y_position += line_height;
            if (self.culling_enabled and bounding_box.y + y_position > self.layout_dimensions.height) break;
        }
    }

    fn renderBetweenChildBorders(
        self: *Context,
        node: *const layout.Node,
        bounding_box: types.BoundingBox,
        scroll_offset: types.Vector2,
    ) !void {
        const width = node.config.border.width.between_children;
        if (width == 0 or node.config.border.color.a <= 0) return;
        const half_gap: f32 = @floatFromInt(node.config.layout.child_gap / 2);
        const half_width: f32 = @floatFromInt(width / 2);
        var offset = types.Vector2{
            .x = @as(f32, @floatFromInt(node.config.layout.padding.left)) - half_gap,
            .y = @as(f32, @floatFromInt(node.config.layout.padding.top)) - half_gap,
        };
        for (node.children(self.child_indices.items), 0..) |child_index, index| {
            const child = &self.nodes.items[child_index];
            if (index > 0) {
                const box = if (node.config.layout.layout_direction == .left_to_right)
                    types.BoundingBox{
                        .x = bounding_box.x + offset.x + scroll_offset.x - half_width,
                        .y = bounding_box.y + scroll_offset.y,
                        .width = @floatFromInt(width),
                        .height = node.dimensions.height,
                    }
                else
                    types.BoundingBox{
                        .x = bounding_box.x + scroll_offset.x,
                        .y = bounding_box.y + offset.y + scroll_offset.y - half_width,
                        .width = node.dimensions.width,
                        .height = @floatFromInt(width),
                    };
                try self.addRenderCommand(.{
                    .bounding_box = box,
                    .render_data = .{ .rectangle = .{ .background_color = node.config.border.color } },
                    .user_data = node.config.user_data,
                    .id = hashes.number(node.element_id.id, @intCast(node.children_len + 1 + index)).id,
                    .command_type = .rectangle,
                });
            }
            if (node.config.layout.layout_direction == .left_to_right) {
                offset.x += child.dimensions.width + @as(f32, @floatFromInt(node.config.layout.child_gap));
            } else {
                offset.y += child.dimensions.height + @as(f32, @floatFromInt(node.config.layout.child_gap));
            }
        }
    }

    fn addRenderCommand(self: *Context, command: types.RenderCommand) !void {
        const capacity = self.renderCommandCapacity();
        // Pinned Clay allocates `maxElementCount` command slots but reserves
        // the final slot in Clay__AddRenderCommand. Preserve that observable
        // capacity/effective-limit split for both the derived and explicit
        // native limits.
        if (capacity == 0 or self.render_commands.items.len >= capacity - 1) {
            if (!self.warned_render_capacity) {
                self.warned_render_capacity = true;
                self.emitError(
                    .elements_capacity_exceeded,
                    "Clay ran out of capacity while attempting to create render commands. This is usually caused by a large amount of wrapping text elements while close to the max element capacity. Try using Clay_SetMaxElementCount() with a higher value.",
                );
            }
            return;
        }
        try self.render_commands.append(self.allocator, command);
    }

    fn renderCommandCapacity(self: *const Context) usize {
        return if (self.options.max_render_command_count > 0)
            self.options.max_render_command_count
        else
            self.options.max_element_count;
    }

    fn isOffscreen(self: *const Context, box: types.BoundingBox) bool {
        if (!self.culling_enabled) return false;
        return box.x > self.layout_dimensions.width or box.y > self.layout_dimensions.height or
            box.x + box.width < 0 or box.y + box.height < 0;
    }

    fn boundingBoxForNode(self: *const Context, node_index: usize) ?types.BoundingBox {
        if (node_index >= self.nodes.items.len) return null;
        const node = &self.nodes.items[node_index];
        if (node.bounding_box_valid) return node.bounding_box;
        // A negative-z floating root can render before its unique attachment
        // in the current pass. Preserve the prior committed fallback that the
        // ID lookup historically supplied, but never substitute the first
        // owner's box for an exact later-duplicate node.
        if (self.id_to_index.get(node.element_id.id) == node_index) {
            if (self.persistent_elements.get(node.element_id.id)) |persistent| {
                return persistent.bounding_box;
            }
        }
        return null;
    }

    fn boundingBoxForId(self: *const Context, id_value: u32) ?types.BoundingBox {
        if (self.id_to_index.get(id_value)) |index| {
            const node = &self.nodes.items[index];
            if (node.bounding_box_valid) return node.bounding_box;
        }
        if (self.persistent_elements.get(id_value)) |persistent| return persistent.bounding_box;
        return null;
    }

    fn debugBoundingBox(self: *const Context, node: layout.Node) types.BoundingBox {
        if (node.bounding_box_valid) return node.bounding_box;
        if (self.persistent_elements.get(node.element_id.id)) |persistent| return persistent.bounding_box;
        return node.bounding_box;
    }

    fn transitionBlocksInteractions(self: *const Context, id_value: u32) bool {
        const runtime = self.transition_states.get(id_value) orelse return false;
        if (runtime.state == .exiting) return true;
        if (runtime.config.interaction_handling == .allow_interactions_while_transitioning_position) return false;
        return runtime.state == .entering or
            (runtime.state == .transitioning and transitions.intersects(runtime.active_properties, .position));
    }

    fn preflightTransitionRegistration(
        self: *Context,
        element_id: u32,
        config: types.TransitionElementConfig,
    ) !void {
        if (config.handler == null or self.transition_states.contains(element_id)) return;
        try self.transition_order.ensureTotalCapacity(self.allocator, self.transition_order.items.len + 1);
        try self.transition_states.ensureUnusedCapacity(1);
    }

    fn configureTransitionForNode(self: *Context, node_index: usize) void {
        const node = &self.nodes.items[node_index];
        if (node.config.transition.handler == null) return;

        const parent_index = node.parent_index orelse 0;
        const parent_id = self.nodes.items[parent_index].element_id.id;
        const sibling_index = self.nodes.items[parent_index].children_len;
        const element_id = node.element_id.id;
        const config = node.config.transition;

        const runtime = self.transition_states.getPtr(element_id) orelse {
            self.transition_states.putAssumeCapacityNoClobber(element_id, .{
                .element_id = element_id,
                .parent_id = parent_id,
                .sibling_index = sibling_index,
                .appeared_this_frame = !self.persistent_elements.contains(element_id),
                .config = config,
            });
            self.transition_order.appendAssumeCapacity(element_id);
            return;
        };

        // Clay keeps reparenting sticky until a transition completes. It also
        // treats a reappearing exiting element as an existing, idle element.
        if (runtime.state == .exiting) {
            runtime.state = .idle;
            runtime.appeared_this_frame = false;
            runtime.exit_final_state_pending = false;
        } else {
            runtime.appeared_this_frame = false;
        }
        if (runtime.parent_id != parent_id) runtime.reparented = true;
        runtime.parent_id = parent_id;
        runtime.sibling_index = sibling_index;
        runtime.config = config;
    }

    fn transitionOrderIndex(self: *const Context, element_id: u32) ?usize {
        for (self.transition_order.items, 0..) |candidate, index| {
            if (candidate == element_id) return index;
        }
        return null;
    }

    fn removeTransitionAt(self: *Context, index: usize) void {
        const element_id = self.transition_order.items[index];
        _ = self.transition_states.remove(element_id);
        _ = self.transition_order.swapRemove(index);
    }

    /// Publish persistent element data using storage reserved by
    /// `preflightFrameCommit`.
    fn commitPersistentElements(self: *Context) void {
        for (self.nodes.items) |node| {
            const parent_id = if (node.parent_index) |parent_index| self.nodes.items[parent_index].element_id.id else 0;
            var value = PersistentElement{
                .element_id = node.element_id,
                .bounding_box = node.bounding_box,
                .clip_element_id = node.clip_element_id,
                .parent_id = parent_id,
                .on_hover = node.on_hover,
                .hover_user_data = node.hover_user_data,
                .generation = self.generation,
            };
            if (self.persistent_elements.getPtr(node.element_id.id)) |persistent| {
                value.debug_data.collapsed = persistent.debug_data.collapsed;
                if (persistent.generation != self.generation) persistent.* = value;
            } else {
                self.persistent_elements.putAssumeCapacity(node.element_id.id, value);
            }
        }

        // Clay clears the collision bit on the first declaration in a new
        // generation and sets it again only if that ID is declared twice in
        // the current frame. Applying the recorded duplicates after the main
        // commit reproduces that behavior for both new and persistent IDs.
        for (self.debug_collision_ids.items) |id_value| {
            if (self.persistent_elements.getPtr(id_value)) |persistent| {
                persistent.debug_data.collision = true;
            }
        }

        self.stale_ids.clearRetainingCapacity();
        var iterator = self.persistent_elements.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.generation != self.generation) self.stale_ids.appendAssumeCapacity(entry.key_ptr.*);
        }
        for (self.stale_ids.items) |id_value| _ = self.persistent_elements.remove(id_value);
    }

    fn commitDebugFrameState(self: *Context) void {
        self.debug_mode_enabled = self.pending_debug_mode_enabled;
        self.debug_selected_element_id = self.pending_debug_selected_element_id;
        if (self.pending_debug_collapse_id) |target_id| {
            if (self.persistent_elements.getPtr(target_id)) |persistent| {
                persistent.debug_data.collapsed = !persistent.debug_data.collapsed;
            }
        }
        self.pending_debug_collapse_id = null;
        self.debug_view_action = null;
    }

    fn updateTransitions(self: *Context, delta_time: f32) !bool {
        const frame_delta = if (std.math.isFinite(delta_time) and delta_time > 0)
            delta_time
        else
            0;
        const had_transition_data = self.transition_order.items.len > 0;
        var transition_index: usize = 0;
        while (transition_index < self.transition_order.items.len) {
            const element_id = self.transition_order.items[transition_index];
            const node_index = self.id_to_index.get(element_id) orelse {
                self.removeTransitionAt(transition_index);
                continue;
            };
            const runtime = self.transition_states.getPtr(element_id) orelse {
                _ = self.transition_order.swapRemove(transition_index);
                continue;
            };
            const node = &self.nodes.items[node_index];
            const config = if (node.config.transition.handler != null)
                node.config.transition
            else
                runtime.config;
            const handler = config.handler orelse {
                self.removeTransitionAt(transition_index);
                continue;
            };

            if (runtime.state == .exiting and runtime.exit_final_state_pending) {
                const set_final_state = config.exit.set_final_state orelse {
                    self.removeTransitionAt(transition_index);
                    continue;
                };
                self.beginApplicationCallback(.transition);
                runtime.target = set_final_state(runtime.target, config.properties);
                self.endApplicationCallback();
                runtime.exit_final_state_pending = false;
            }

            const old_target = runtime.target;
            const target = if (runtime.state == .exiting)
                runtime.target
            else
                transitionDataForNode(node.*);
            runtime.target = target;

            if (runtime.appeared_this_frame) {
                const parent_appeared = runtime.parent_id != 0 and
                    !self.persistent_elements.contains(runtime.parent_id);
                const should_enter = config.enter.set_initial_state != null and
                    !(parent_appeared and config.enter.trigger == .skip_on_first_parent_frame);
                if (should_enter) {
                    runtime.state = .entering;
                    self.beginApplicationCallback(.transition);
                    runtime.initial = config.enter.set_initial_state.?(target, config.properties);
                    self.endApplicationCallback();
                    runtime.current = runtime.initial;
                    runtime.active_properties = config.properties;
                    applyTransitionToNode(node, runtime.*);
                } else {
                    runtime.initial = target;
                    runtime.current = target;
                    runtime.active_properties = .none;
                }
                runtime.appeared_this_frame = false;
                transition_index += 1;
                continue;
            }

            if (runtime.state != .exiting) {
                const parent_box = self.boundingBoxForId(runtime.parent_id) orelse types.BoundingBox{};
                const parent_scroll = if (self.id_to_index.get(runtime.parent_id)) |parent_index|
                    self.nodes.items[parent_index].config.clip.child_offset
                else
                    types.Vector2{};
                const relative_position = types.Vector2{
                    .x = target.bounding_box.x - parent_box.x - parent_scroll.x,
                    .y = target.bounding_box.y - parent_box.y - parent_scroll.y,
                };
                const changed = transitions.changedProperties(
                    config.properties,
                    old_target,
                    target,
                    .{
                        .old_parent_relative_position = runtime.old_parent_relative_position,
                        .new_parent_relative_position = relative_position,
                        .reparented = runtime.reparented,
                        .root_resized_last_frame = self.root_resized_last_frame,
                    },
                );
                runtime.old_parent_relative_position = relative_position;
                if (@intFromEnum(changed) != 0) {
                    runtime.elapsed_time = 0;
                    runtime.initial = runtime.current;
                    runtime.state = .transitioning;
                    runtime.active_properties = runtime.active_properties.merge(changed);
                }
            }

            if (runtime.state == .idle) {
                runtime.initial = target;
                runtime.current = target;
                runtime.target = target;
                runtime.active_properties = .none;
                transition_index += 1;
                continue;
            }

            self.beginApplicationCallback(.transition);
            const complete = handler(.{
                .transition_state = runtime.state,
                .initial = runtime.initial,
                .current = &runtime.current,
                .target = target,
                .elapsed_time = runtime.elapsed_time,
                .duration = config.duration,
                .properties = runtime.active_properties,
            });
            self.endApplicationCallback();
            applyTransitionToNode(node, runtime.*);
            runtime.elapsed_time += frame_delta;

            if (complete) {
                if (runtime.state == .exiting) {
                    // Pinned Clay removes in-loop without decrementing the
                    // index. The tail is swapped into this slot and is skipped
                    // until the next frame when the loop increments normally.
                    self.removeTransitionAt(transition_index);
                    transition_index += 1;
                    continue;
                }
                runtime.state = .idle;
                runtime.elapsed_time = 0;
                runtime.reparented = false;
                runtime.active_properties = .none;
            }
            transition_index += 1;
        }
        return had_transition_data;
    }

    fn emitError(self: *Context, error_type: types.ErrorType, message: []const u8) void {
        if (self.options.error_handler.error_handler_function) |function| {
            self.beginApplicationCallback(.error_handler);
            defer self.endApplicationCallback();
            function(.{
                .error_type = error_type,
                // Every internal call site passes a program-lifetime string
                // literal, matching Clay's CLAY_STRING error payloads.
                .error_text = .{
                    .is_statically_allocated = true,
                    .length = @intCast(message.len),
                    .chars = message,
                },
                .user_data = self.options.error_handler.user_data,
            });
        }
    }

    fn debugCollisionRecorded(self: *const Context, id_value: u32) bool {
        for (self.debug_collision_ids.items) |existing| {
            if (existing == id_value) return true;
        }
        return false;
    }

    fn preflightDebugCollision(self: *Context, id_value: u32) !void {
        if (!self.debug_mode_enabled) return;
        if (self.debugCollisionRecorded(id_value)) return;
        try self.debug_collision_ids.ensureTotalCapacity(
            self.allocator,
            self.debug_collision_ids.items.len + 1,
        );
    }

    fn markDebugCollisionAssumeCapacity(self: *Context, id_value: u32) void {
        if (!self.debug_mode_enabled or self.debugCollisionRecorded(id_value)) return;
        self.debug_collision_ids.appendAssumeCapacity(id_value);
    }

    fn reopenScrollContainer(self: *Context, id_value: u32, config: types.ClipElementConfig) void {
        for (self.scroll_containers.items) |*container| {
            if (container.id != id_value) continue;
            container.reopen();
            container.config = config;
            if (self.external_scroll_handling_enabled and self.query_scroll_offset_function != null) {
                self.pending_scroll_query_ids.appendAssumeCapacity(id_value);
            }
            return;
        }
        const container = scroll_engine.Container.init(id_value, .{}, .{}, config);
        if (self.external_scroll_handling_enabled and self.query_scroll_offset_function != null) {
            self.pending_scroll_query_ids.appendAssumeCapacity(id_value);
        }
        self.scroll_containers.appendAssumeCapacity(container);
    }

    /// External queries are observable user callbacks. Defer them until every
    /// fallible frame-commit operation has succeeded so rejected frames neither
    /// publish offsets nor invoke application code.
    fn applyPendingExternalScrollQueries(self: *Context) void {
        const query = self.query_scroll_offset_function orelse return;
        if (!self.external_scroll_handling_enabled) return;
        self.beginApplicationCallback(.external_scroll);
        defer self.endApplicationCallback();
        for (self.pending_scroll_query_ids.items) |id_value| {
            const offset = query(id_value, self.query_scroll_offset_user_data);
            for (self.scroll_containers.items) |*container| {
                if (container.id != id_value) continue;
                container.applyExternalOffset(offset);
                break;
            }
        }
    }

    /// Application callbacks may retain a mutable scroll-position pointer
    /// obtained before the callback starts. Run callbacks against an
    /// allocation-free value clone, then copy the protected state back over the
    /// original storage before restoring it as the live array. This keeps those
    /// previously borrowed pointers stable outside callbacks while making any
    /// callback-time writes unobservable after callback return.
    fn beginApplicationCallback(self: *Context, phase: ApplicationCallbackPhase) void {
        std.debug.assert(phase != .none);
        std.debug.assert(self.application_callback_phase == .none);
        std.debug.assert(self.callback_scroll_containers.capacity >= self.scroll_containers.items.len);
        self.callback_scroll_containers.clearRetainingCapacity();
        self.callback_scroll_containers.appendSliceAssumeCapacity(self.scroll_containers.items);
        std.mem.swap(
            std.ArrayList(scroll_engine.Container),
            &self.scroll_containers,
            &self.callback_scroll_containers,
        );
        self.application_callback_phase = phase;
    }

    fn endApplicationCallback(self: *Context) void {
        std.debug.assert(self.application_callback_phase != .none);
        std.debug.assert(self.callback_scroll_containers.items.len == self.scroll_containers.items.len);
        @memcpy(self.callback_scroll_containers.items, self.scroll_containers.items);
        std.mem.swap(
            std.ArrayList(scroll_engine.Container),
            &self.scroll_containers,
            &self.callback_scroll_containers,
        );
        self.application_callback_phase = .none;
    }
};

fn truncateDebugFloat(value: f32) i32 {
    if (std.math.isNan(value)) return 0;
    if (value >= @as(f32, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    if (value <= @as(f32, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    return @intFromFloat(value);
}

fn pointInside(point: types.Vector2, box: types.BoundingBox) bool {
    return point.x >= box.x and point.x <= box.x + box.width and
        point.y >= box.y and point.y <= box.y + box.height;
}

fn horizontalAttach(box: types.BoundingBox, point: types.FloatingAttachPointType) f32 {
    return switch (point) {
        .left_top, .left_center, .left_bottom => box.x,
        .center_top, .center_center, .center_bottom => box.x + box.width / 2,
        .right_top, .right_center, .right_bottom => box.x + box.width,
    };
}

fn verticalAttach(box: types.BoundingBox, point: types.FloatingAttachPointType) f32 {
    return switch (point) {
        .left_top, .center_top, .right_top => box.y,
        .left_center, .center_center, .right_center => box.y + box.height / 2,
        .left_bottom, .center_bottom, .right_bottom => box.y + box.height,
    };
}

fn elementHorizontalOffset(dimensions: types.Dimensions, point: types.FloatingAttachPointType) f32 {
    return switch (point) {
        .left_top, .left_center, .left_bottom => 0,
        .center_top, .center_center, .center_bottom => dimensions.width / 2,
        .right_top, .right_center, .right_bottom => dimensions.width,
    };
}

fn elementVerticalOffset(dimensions: types.Dimensions, point: types.FloatingAttachPointType) f32 {
    return switch (point) {
        .left_top, .center_top, .right_top => 0,
        .left_center, .center_center, .right_center => dimensions.height / 2,
        .left_bottom, .center_bottom, .right_bottom => dimensions.height,
    };
}

fn floatingPosition(parent_box: types.BoundingBox, dimensions: types.Dimensions, config: types.FloatingElementConfig) types.Vector2 {
    return .{
        .x = horizontalAttach(parent_box, config.attach_points.parent) -
            elementHorizontalOffset(dimensions, config.attach_points.element) + config.offset.x,
        .y = verticalAttach(parent_box, config.attach_points.parent) -
            elementVerticalOffset(dimensions, config.attach_points.element) + config.offset.y,
    };
}

fn borderHasAnyWidth(width: types.BorderWidth) bool {
    return width.left > 0 or width.right > 0 or width.top > 0 or
        width.bottom > 0 or width.between_children > 0;
}

fn childGapSize(child_count: usize, child_gap: u16) f32 {
    const gap_count = child_count -| 1;
    const total: u128 = @as(u128, gap_count) * @as(u128, child_gap);
    return @floatFromInt(total);
}

fn contentDimensions(node: *const layout.Node, nodes: []const layout.Node, child_indices: []const usize) types.Dimensions {
    var result = types.Dimensions{};
    for (node.children(child_indices)) |child_index| {
        const child = &nodes[child_index];
        if (child.exiting) continue;
        if (node.config.layout.layout_direction == .left_to_right) {
            result.width += child.dimensions.width;
            result.height = @max(result.height, child.dimensions.height);
        } else {
            result.width = @max(result.width, child.dimensions.width);
            result.height += child.dimensions.height;
        }
    }
    if (node.config.layout.layout_direction == .left_to_right) {
        result.width += childGapSize(node.children_len, node.config.layout.child_gap);
    } else {
        result.height += childGapSize(node.children_len, node.config.layout.child_gap);
    }
    result.width += @floatFromInt(@as(u32, node.config.layout.padding.left) + node.config.layout.padding.right);
    result.height += @floatFromInt(@as(u32, node.config.layout.padding.top) + node.config.layout.padding.bottom);
    return result;
}

fn applyOnAxisAlignment(node: *const layout.Node, content: types.Dimensions, offset: *types.Vector2) void {
    if (node.config.layout.layout_direction == .left_to_right) {
        var extra = node.dimensions.width -
            @as(f32, @floatFromInt(@as(u32, node.config.layout.padding.left) + node.config.layout.padding.right)) -
            (content.width - @as(f32, @floatFromInt(@as(u32, node.config.layout.padding.left) + node.config.layout.padding.right)));
        switch (node.config.layout.child_alignment.x) {
            .left => extra = 0,
            .center => extra /= 2,
            .right => {},
        }
        offset.x += @max(0, extra);
    } else {
        var extra = node.dimensions.height -
            @as(f32, @floatFromInt(@as(u32, node.config.layout.padding.top) + node.config.layout.padding.bottom)) -
            (content.height - @as(f32, @floatFromInt(@as(u32, node.config.layout.padding.top) + node.config.layout.padding.bottom)));
        switch (node.config.layout.child_alignment.y) {
            .top => extra = 0,
            .center => extra /= 2,
            .bottom => {},
        }
        offset.y += @max(0, extra);
    }
}

fn applyOffAxisAlignment(parent: *const layout.Node, child: *const layout.Node, offset: *types.Vector2) void {
    if (parent.config.layout.layout_direction == .left_to_right) {
        offset.y = @floatFromInt(parent.config.layout.padding.top);
        const whitespace = parent.dimensions.height -
            @as(f32, @floatFromInt(@as(u32, parent.config.layout.padding.top) + parent.config.layout.padding.bottom)) -
            child.dimensions.height;
        switch (parent.config.layout.child_alignment.y) {
            .top => {},
            .center => offset.y += whitespace / 2,
            .bottom => offset.y += whitespace,
        }
    } else {
        offset.x = @floatFromInt(parent.config.layout.padding.left);
        const whitespace = parent.dimensions.width -
            @as(f32, @floatFromInt(@as(u32, parent.config.layout.padding.left) + parent.config.layout.padding.right)) -
            child.dimensions.width;
        switch (parent.config.layout.child_alignment.x) {
            .left => {},
            .center => offset.x += whitespace / 2,
            .right => offset.x += whitespace,
        }
    }
}

fn transitionDataForNode(node: layout.Node) types.TransitionData {
    return .{
        .bounding_box = node.bounding_box,
        .background_color = node.config.background_color,
        .overlay_color = node.config.overlay_color,
        .border_color = node.config.border.color,
        .border_width = node.config.border.width,
    };
}

fn applyTransitionToNode(node: *layout.Node, runtime: TransitionRuntime) void {
    const applied = transitions.applyProperties(.{
        .dimensions = node.dimensions,
        .layout = node.config.layout,
        .bounding_box = node.bounding_box,
        .background_color = node.config.background_color,
        .overlay_color = node.config.overlay_color,
        .border = node.config.border,
    }, runtime.active_properties, runtime.current, runtime.reparented);
    node.dimensions = applied.dimensions;
    node.config.layout = applied.layout;
    node.config.background_color = applied.background_color;
    node.config.overlay_color = applied.overlay_color;
    node.config.border = applied.border;
}

fn measureMonospaceForTest(text: types.StringSlice, config: *types.TextElementConfig, _: ?*anyopaque) types.Dimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * @as(f32, @floatFromInt(config.font_size)),
        .height = @floatFromInt(config.font_size),
    };
}

const MeasureCountForTest = struct {
    calls: usize = 0,
};

fn measureCountedMonospaceForTest(
    text: types.StringSlice,
    config: *types.TextElementConfig,
    user_data: ?*anyopaque,
) types.Dimensions {
    const state: *MeasureCountForTest = @ptrCast(@alignCast(user_data.?));
    state.calls += 1;
    return measureMonospaceForTest(text, config, null);
}

fn unexpectedProviderMeasureForTest(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: paragraph_provider.IntrinsicRequest,
) paragraph_provider.IntrinsicOutcome {
    @panic("inactive paragraph provider callback invoked");
}

fn unexpectedProviderLayoutForTest(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: paragraph_provider.LayoutRequest,
) paragraph_provider.LayoutOutcome {
    @panic("inactive paragraph provider callback invoked");
}

fn unexpectedProviderLeaseForTest(
    _: *anyopaque,
    _: paragraph_provider.LeaseKey,
) paragraph_provider.LeaseOutcome {
    @panic("inactive paragraph provider callback invoked");
}

const inactive_provider_vtable_for_test = paragraph_provider.VTable{
    .measure_intrinsic = unexpectedProviderMeasureForTest,
    .layout_paragraph = unexpectedProviderLayoutForTest,
    .retain_paragraph = unexpectedProviderLeaseForTest,
    .release_paragraph = unexpectedProviderLeaseForTest,
};

const ParagraphProviderStateForTest = struct {
    measure_calls: usize = 0,
    layout_calls: usize = 0,
    retain_calls: usize = 0,
    release_calls: usize = 0,
    generation: u64 = 7,
    fail_measure: bool = false,
    fail_layout_call: ?usize = null,
    invalid_metrics: bool = false,
    last_measure_style: paragraph_provider.TextStyle = .{},
    last_layout_style: paragraph_provider.TextStyle = .{},
    released: [16]paragraph_provider.LeaseKey = undefined,

    fn from(context: *anyopaque) *ParagraphProviderStateForTest {
        return @ptrCast(@alignCast(context));
    }

    fn measure(
        context: *anyopaque,
        scratch_allocator: std.mem.Allocator,
        request: paragraph_provider.IntrinsicRequest,
    ) paragraph_provider.IntrinsicOutcome {
        const self = from(context);
        self.measure_calls += 1;
        self.last_measure_style = request.text_style;
        const copy = scratch_allocator.dupe(u8, request.text) catch return .{
            .failure = .{ .kind = .out_of_memory, .provider_code = 90 },
        };
        defer scratch_allocator.free(copy);
        if (self.fail_measure) return .{
            .failure = .{ .kind = .unavailable, .provider_code = 91 },
        };
        return .{ .value = .{
            .min_content_width = 24,
            .max_content_width = 96,
            .height = 12,
            .first_baseline = 9,
            .last_baseline = 9,
        } };
    }

    fn layout(
        context: *anyopaque,
        _: std.mem.Allocator,
        request: paragraph_provider.LayoutRequest,
    ) paragraph_provider.LayoutOutcome {
        const self = from(context);
        self.layout_calls += 1;
        self.last_layout_style = request.text_style;
        if (self.fail_layout_call == self.layout_calls) return .{
            .failure = .{ .kind = .internal, .provider_code = 92 },
        };
        const logical_width = @min(request.available_width_px, 48);
        return .{ .value = .{
            .handle = @enumFromInt(40 + self.layout_calls),
            .generation = self.generation,
            .paragraph_metrics = .{
                .logical = .{
                    .advance = .{
                        .x = if (self.invalid_metrics) std.math.nan(f32) else logical_width,
                        .y = 24,
                    },
                    .ascent = 9,
                    .descent = 3,
                },
                .ink = .{ .min = .{}, .max = .{ .x = logical_width, .y = 24 } },
                .line_count = 2,
            },
        } };
    }

    fn retain(context: *anyopaque, _: paragraph_provider.LeaseKey) paragraph_provider.LeaseOutcome {
        const self = from(context);
        self.retain_calls += 1;
        return .{ .value = {} };
    }

    fn release(context: *anyopaque, key: paragraph_provider.LeaseKey) paragraph_provider.LeaseOutcome {
        const self = from(context);
        if (self.release_calls < self.released.len) self.released[self.release_calls] = key;
        self.release_calls += 1;
        return .{ .value = {} };
    }
};

const paragraph_provider_vtable_for_test = paragraph_provider.VTable{
    .measure_intrinsic = ParagraphProviderStateForTest.measure,
    .layout_paragraph = ParagraphProviderStateForTest.layout,
    .retain_paragraph = ParagraphProviderStateForTest.retain,
    .release_paragraph = ParagraphProviderStateForTest.release,
};

fn unexpectedLegacyMeasureForProviderTest(
    _: types.StringSlice,
    _: *types.TextElementConfig,
    _: ?*anyopaque,
) types.Dimensions {
    @panic("legacy measurement mixed into provider paragraph path");
}

const MutableMeasureMetricsForTest = struct {
    advance: f32,
    height: f32,
};

fn measureMutableMetricsForTest(
    value: types.StringSlice,
    _: *types.TextElementConfig,
    user_data: ?*anyopaque,
) types.Dimensions {
    const metrics: *const MutableMeasureMetricsForTest = @ptrCast(@alignCast(user_data.?));
    return .{
        .width = @as(f32, @floatFromInt(value.asSlice().len)) * metrics.advance,
        .height = metrics.height,
    };
}

fn failScopedElementForTest(context: *Context) !void {
    try context.openElement(.{});
    return error.ScopedBodyFailed;
}

fn emptyScopedElementForTest(_: *Context) !void {}

test "scoped element helper restores the open stack after body errors" {
    var context = Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    try context.beginLayout();
    try std.testing.expectError(
        error.ScopedBodyFailed,
        context.elementWithId(context.staticId("failed"), .{}, failScopedElementForTest),
    );
    try context.element(.{}, emptyScopedElementForTest);
    _ = try context.endLayout(0);
}

test "render content gap totals cannot overflow native word size" {
    const total = childGapSize(std.math.maxInt(usize), std.math.maxInt(u16));
    try std.testing.expect(std.math.isFinite(total));
    try std.testing.expect(total > 0);
}

test "literal and dynamic ID helpers share Clay hashing semantics" {
    var context = Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    try std.testing.expectEqual(context.id("item").id, context.staticId("item").id);
    try std.testing.expectEqual(context.indexedId("item", 7).id, context.staticIndexedId("item", 7).id);
    try std.testing.expectError(Error.NoOpenElement, context.staticLocalId("child"));

    try context.beginLayout();
    const parent_id = context.staticId("parent");
    try context.openElementWithId(parent_id, .{});
    try std.testing.expectEqual(
        hashes.string(types.String.literal("child"), parent_id.id),
        try context.staticLocalId("child"),
    );
    try std.testing.expectEqual(
        hashes.stringWithOffset(types.String.literal("child"), 3, parent_id.id),
        try context.staticIndexedLocalId("child", 3),
    );
    try context.closeElement();
    _ = try context.endLayout(0);
}

test "public ID helpers clamp malformed String lengths" {
    var context = Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    const valid = types.String.fromSlice("item");
    const overlong = types.String{
        .length = std.math.maxInt(i32),
        .chars = "item",
    };
    try std.testing.expectEqual(context.getElementId(valid).id, context.getElementId(overlong).id);
    try std.testing.expectEqual(
        context.getElementIdWithIndex(valid, 7).id,
        context.getElementIdWithIndex(overlong, 7).id,
    );

    try context.beginLayout();
    try context.openElementWithId(context.staticId("parent"), .{});
    try std.testing.expectEqual(
        (try context.getLocalElementId(valid)).id,
        (try context.getLocalElementId(overlong)).id,
    );
    try std.testing.expectEqual(
        (try context.getLocalElementIdWithIndex(valid, 7)).id,
        (try context.getLocalElementIdWithIndex(overlong, 7)).id,
    );
    try context.closeElement();
    _ = try context.endLayout(0);
}

test "context lays out grow children and emits renderer-neutral commands" {
    var context = Context.init(std.testing.allocator, .{ .width = 300, .height = 100 }, .{});
    defer context.deinit();
    context.setMeasureTextFunction(measureMonospaceForTest, null);

    try context.beginLayout();
    try context.openElementWithId(context.id("row"), .{
        .layout = .{
            .sizing = .{ .width = types.grow(), .height = types.grow() },
            .child_gap = 10,
        },
    });
    try context.openElementWithId(context.id("left"), .{
        .layout = .{ .sizing = .{ .width = types.grow(), .height = types.grow() } },
        .background_color = .{ .r = 255, .a = 255 },
    });
    try context.closeElement();
    try context.openElementWithId(context.id("right"), .{
        .layout = .{ .sizing = .{ .width = types.grow(), .height = types.grow() } },
        .background_color = .{ .b = 255, .a = 255 },
    });
    try context.closeElement();
    try context.closeElement();
    const commands = try context.endLayout(0.016);

    try std.testing.expectEqual(@as(i32, 2), commands.length);
    const left = context.getElementData(context.id("left"));
    const right = context.getElementData(context.id("right"));
    try std.testing.expect(left.found and right.found);
    try std.testing.expectEqual(@as(f32, 145), left.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 145), right.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 155), right.bounding_box.x);
}

test "text wraps into separate render commands" {
    var context = Context.init(std.testing.allocator, .{ .width = 60, .height = 100 }, .{});
    defer context.deinit();
    context.setMeasureTextFunction(measureMonospaceForTest, null);

    try context.beginLayout();
    try context.openElementWithId(context.id("column"), .{
        .layout = .{
            .sizing = .{ .width = types.grow(), .height = types.grow() },
            .layout_direction = .top_to_bottom,
        },
    });
    try context.textSlice("one two", .{ .font_size = 10 });
    try context.closeElement();
    const commands = try context.endLayout(0);
    var text_count: usize = 0;
    for (commands.items()) |command| if (command.command_type == .text) {
        text_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), text_count);
}

test "optional paragraph provider is context-local and null preserves legacy text behavior" {
    var context = Context.init(std.testing.allocator, .{ .width = 60, .height = 100 }, .{});
    defer context.deinit();
    var other = Context.init(std.testing.allocator, .{ .width = 60, .height = 100 }, .{});
    defer other.deinit();

    try std.testing.expect(context.getParagraphProvider() == null);
    try std.testing.expect(other.getParagraphProvider() == null);

    var sentinel: u8 = 0;
    context.setParagraphProvider(.{
        .context = &sentinel,
        .vtable = &inactive_provider_vtable_for_test,
    });
    try std.testing.expect(context.getParagraphProvider() != null);
    try std.testing.expect(other.getParagraphProvider() == null);
    context.setParagraphProvider(null);
    try std.testing.expect(context.getParagraphProvider() == null);

    var state = MeasureCountForTest{};
    context.setMeasureTextFunction(measureCountedMonospaceForTest, &state);
    try context.beginLayout();
    try context.textSlice("one two", .{ .font_id = 9, .font_size = 10 });
    const commands = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 4), state.calls);
    try std.testing.expectEqual(@as(usize, 2), commands.items().len);
    try std.testing.expectEqualStrings("one", commands.items()[0].render_data.text.string_contents.asSlice());
    try std.testing.expectEqualStrings("two", commands.items()[1].render_data.text.string_contents.asSlice());
    try std.testing.expectEqual(@as(u16, 9), commands.items()[0].render_data.text.font_id);
    try std.testing.expectEqual(@as(f32, 30), commands.items()[0].bounding_box.width);
    try std.testing.expectEqual(@as(f32, 10), commands.items()[0].bounding_box.height);
}

test "provider path caches one final-width lease and transports it through custom commands" {
    var state = ParagraphProviderStateForTest{};
    var context = Context.init(std.testing.allocator, .{ .width = 60, .height = 100 }, .{});
    defer context.deinit();
    context.setMeasureTextFunction(unexpectedLegacyMeasureForProviderTest, null);
    context.setParagraphProvider(.{ .context = &state, .vtable = &paragraph_provider_vtable_for_test });

    try context.beginLayout();
    try context.openElementWithId(context.id("column"), .{ .layout = .{
        .sizing = .{ .width = types.grow(), .height = types.grow() },
        .layout_direction = .top_to_bottom,
    } });
    const color = types.Color{ .r = 20, .g = 40, .b = 60, .a = 255 };
    try context.textSlice("مرحبا 世界", .{ .font_id = 9, .font_size = 14, .text_color = color });
    try context.textSlice("مرحبا 世界", .{ .font_id = 9, .font_size = 14, .text_color = color });
    try context.openElement(.{
        .layout = .{ .sizing = .{ .width = types.fixed(1), .height = types.fixed(1) } },
        .custom = .{ .custom_data = &state },
    });
    try context.closeElement();
    try context.closeElement();
    const commands = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 1), state.measure_calls);
    try std.testing.expectEqual(@as(usize, 1), state.layout_calls);
    try std.testing.expectEqual(@as(usize, 1), context.paragraph_intrinsic_cache_map.count());
    try std.testing.expectEqual(@as(usize, 1), context.paragraph_layout_cache_map.count());
    try std.testing.expectEqual(@as(usize, 0), state.release_calls);
    try std.testing.expectEqual(@as(usize, 3), commands.items().len);
    const first = &commands.items()[0];
    const second = &commands.items()[1];
    const unrelated = &commands.items()[2];
    try std.testing.expectEqual(types.RenderCommandType.custom, first.command_type);
    try std.testing.expectEqual(color, first.render_data.custom.background_color);
    const first_data = context.paragraphRenderData(first) orelse return error.TestUnexpectedResult;
    const second_data = context.paragraphRenderData(second) orelse return error.TestUnexpectedResult;
    var copied_command = first.*;
    try std.testing.expect(context.paragraphRenderData(&copied_command) == null);
    try std.testing.expectEqual(types.RenderCommandType.custom, unrelated.command_type);
    try std.testing.expect(context.paragraphRenderData(unrelated) == null);
    try std.testing.expectEqual(first_data, second_data);
    try std.testing.expectEqual(@as(u64, 41), @intFromEnum(first_data.lease.handle));
    try std.testing.expectEqual(@as(u64, 7), first_data.lease.generation);
    try std.testing.expectEqual(first_data.lease.paragraph_metrics.logical.advance.x, first.bounding_box.width);
    try std.testing.expectEqual(first_data.lease.paragraph_metrics.logical.advance.y, first.bounding_box.height);
    try std.testing.expectEqual(@as(f32, 24), first.bounding_box.height);

    try context.beginLayout();
    try std.testing.expectEqual(@as(usize, 1), state.release_calls);
    try std.testing.expectEqual(@as(usize, 0), context.paragraph_intrinsic_cache_map.count());
    try std.testing.expectEqual(@as(usize, 0), context.paragraph_layout_cache_map.count());
    try std.testing.expect(context.paragraphRenderData(first) == null);
    _ = try context.endLayout(0);
}

test "provider reset and replacement release generation-bound commands" {
    var state = ParagraphProviderStateForTest{};
    var context = Context.init(std.testing.allocator, .{ .width = 60, .height = 100 }, .{});
    defer context.deinit();
    context.setParagraphProvider(.{ .context = &state, .vtable = &paragraph_provider_vtable_for_test });

    try context.beginLayout();
    try context.textSlice("مرحبا", .{ .font_id = 3, .font_size = 12 });
    _ = try context.endLayout(0);
    context.resetMeasureTextCache();
    try std.testing.expectEqual(@as(usize, 1), state.release_calls);
    try std.testing.expectEqual(@as(u64, 7), state.released[0].generation);
    try std.testing.expect(context.renderCommand(0) == null);

    state.generation = 8;
    try context.beginLayout();
    try context.textSlice("مرحبا", .{ .font_id = 3, .font_size = 12 });
    const commands = try context.endLayout(0);
    const command = &commands.items()[0];
    const data = context.paragraphRenderData(command) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 8), data.lease.generation);
    context.setParagraphProvider(null);
    try std.testing.expectEqual(@as(usize, 2), state.release_calls);
    try std.testing.expectEqual(@as(u64, 8), state.released[1].generation);
    try std.testing.expect(context.paragraphRenderData(command) == null);
}

test "advanced paragraph style reaches both provider passes" {
    const features = [_]paragraph_provider.OpenTypeFeature{.{
        .tag = paragraph_provider.Tag.fromBytes("kern".*),
        .value = 0,
        .byte_start = 0,
        .byte_end = 6,
    }};
    const variations = [_]paragraph_provider.VariationAxis{.{
        .tag = paragraph_provider.Tag.fromBytes("wght".*),
        .value = 612.5,
    }};
    const heavier_variations = [_]paragraph_provider.VariationAxis{.{
        .tag = paragraph_provider.Tag.fromBytes("wght".*),
        .value = 700,
    }};
    const paragraph_style = paragraph_provider.TextStyle{
        .font_stack_id = 0xfedc_ba98,
        .size_px = 17.25,
        .direction = .right_to_left,
        .script = paragraph_provider.Tag.fromBytes("Arab".*),
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
    var state = ParagraphProviderStateForTest{};
    var context = Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    context.setParagraphProvider(.{ .context = &state, .vtable = &paragraph_provider_vtable_for_test });

    try context.beginLayout();
    try context.textSliceWithParagraphStyle("مرحبا", .{}, paragraph_style);
    try context.textSliceWithParagraphStyle("مرحبا", .{}, paragraph_style);
    var heavier_style = paragraph_style;
    heavier_style.variations = &heavier_variations;
    try context.textSliceWithParagraphStyle("مرحبا", .{}, heavier_style);
    const commands = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 2), state.measure_calls);
    try std.testing.expectEqual(@as(usize, 2), state.layout_calls);
    try std.testing.expectEqual(heavier_style.font_stack_id, state.last_measure_style.font_stack_id);
    try std.testing.expectEqual(heavier_style.direction, state.last_layout_style.direction);
    try std.testing.expectEqualStrings("ar-EG", state.last_layout_style.language);
    try std.testing.expectEqual(@as(f32, -1.375), state.last_measure_style.letter_spacing_px);
    try std.testing.expectEqual(heavier_style.features[0], state.last_layout_style.features[0]);
    try std.testing.expectEqual(heavier_style.variations[0], state.last_layout_style.variations[0]);
    try std.testing.expectEqual(types.RenderCommandType.custom, commands.items()[0].command_type);
    const first = context.paragraphRenderData(&commands.items()[0]) orelse
        return error.TestUnexpectedResult;
    const duplicate = context.paragraphRenderData(&commands.items()[1]) orelse
        return error.TestUnexpectedResult;
    const heavier = context.paragraphRenderData(&commands.items()[2]) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(first, duplicate);
    try std.testing.expect(first != heavier);
}

test "advanced paragraph style requires an installed provider" {
    var context = Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();

    try context.beginLayout();
    try std.testing.expectError(
        Error.ParagraphProviderNotInstalled,
        context.textSliceWithParagraphStyle("text", .{}, .{}),
    );
    _ = try context.endLayout(0);
}

test "provider failure never mixes legacy wrapping and releases earlier leases" {
    var state = ParagraphProviderStateForTest{ .fail_layout_call = 2 };
    var context = Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    context.setMeasureTextFunction(unexpectedLegacyMeasureForProviderTest, null);
    context.setParagraphProvider(.{ .context = &state, .vtable = &paragraph_provider_vtable_for_test });

    try context.beginLayout();
    try context.textSlice("same", .{ .font_id = 1, .font_size = 12 });
    try context.textSlice("same", .{ .font_id = 2, .font_size = 12 });
    try std.testing.expectError(Error.ParagraphProviderFailed, context.endLayout(0));
    try std.testing.expectEqual(@as(usize, 2), state.layout_calls);
    try std.testing.expectEqual(@as(usize, 1), state.release_calls);
    try std.testing.expect(context.renderCommand(0) == null);
    const failure = context.getLastParagraphProviderFailure() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(paragraph_provider.FailureKind.internal, failure.kind);
    try std.testing.expectEqual(@as(u32, 92), failure.provider_code);
}

test "provider intrinsic failure is reported without legacy fallback" {
    var state = ParagraphProviderStateForTest{ .fail_measure = true };
    var context = Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    context.setMeasureTextFunction(unexpectedLegacyMeasureForProviderTest, null);
    context.setParagraphProvider(.{ .context = &state, .vtable = &paragraph_provider_vtable_for_test });

    try context.beginLayout();
    try std.testing.expectError(
        Error.ParagraphProviderFailed,
        context.textSlice("مرحبا", .{ .font_id = 1, .font_size = 12 }),
    );
    try std.testing.expectEqual(@as(usize, 1), state.measure_calls);
    try std.testing.expectEqual(@as(usize, 0), state.layout_calls);
    const failure = context.getLastParagraphProviderFailure() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 91), failure.provider_code);
}

test "missing measure callback preserves Clay's zero-width fallback text line" {
    var context = Context.init(std.testing.allocator, .{ .width = 100, .height = 40 }, .{});
    defer context.deinit();

    try context.beginLayout();
    try context.textSlice("fallback", .{
        .font_id = 7,
        .font_size = 8,
        .line_height = 10,
        .wrap_mode = .none,
    });
    try context.textSlice("", .{
        .font_id = 8,
        .font_size = 8,
        .line_height = 10,
        .wrap_mode = .none,
    });
    const commands = try context.endLayout(0);

    try std.testing.expectEqual(@as(usize, 1), commands.items().len);
    const command = commands.items()[0];
    try std.testing.expectEqual(types.RenderCommandType.text, command.command_type);
    try std.testing.expectEqualStrings("fallback", command.render_data.text.string_contents.asSlice());
    try std.testing.expectEqual(@as(f32, 0), command.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 10), command.bounding_box.height);
    try std.testing.expectEqual(@as(f32, 5), command.bounding_box.y);
    try std.testing.expectEqual(@as(u16, 7), command.render_data.text.font_id);
    try std.testing.expectEqual(@as(u16, 10), command.render_data.text.line_height);
}

test "cache reset before final layout preserves declaration-time preferred text metrics" {
    var context = Context.init(std.testing.allocator, .{ .width = 200, .height = 100 }, .{});
    defer context.deinit();
    var metrics = MutableMeasureMetricsForTest{ .advance = 5, .height = 10 };
    context.setMeasureTextFunction(measureMutableMetricsForTest, &metrics);

    try context.beginLayout();
    try context.textSlice("word", .{ .font_size = 12, .wrap_mode = .words });

    // Pinned Clay stores these preferred dimensions on declaration. Clearing
    // the cache may change the measured-word data used by the wrap pass, but it
    // does not replace the preferred width/height used by its fast path.
    context.resetMeasureTextCache();
    metrics = .{ .advance = 25, .height = 30 };

    const commands = try context.endLayout(0);
    try std.testing.expectEqual(@as(usize, 1), commands.items().len);
    const command = commands.items()[0];
    try std.testing.expectEqual(types.RenderCommandType.text, command.command_type);
    try std.testing.expectEqual(@as(f32, 20), command.bounding_box.width);
    try std.testing.expectEqual(@as(f32, 10), command.bounding_box.height);
}

fn drawTransitionFrame(context: *Context, color: types.Color, delta_time: f32) !types.RenderCommandArray {
    try context.beginLayout();
    try context.openElementWithId(context.id("animated"), .{
        .layout = .{ .sizing = .{ .width = types.fixed(20), .height = types.fixed(20) } },
        .background_color = color,
        .transition = .{
            .handler = transitions.easeOut,
            .duration = 1,
            .properties = .background_color,
        },
    });
    try context.closeElement();
    return context.endLayout(delta_time);
}

test "context applies multi-frame property transitions" {
    var context = Context.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .{});
    defer context.deinit();
    const red = types.Color{ .r = 100, .a = 255 };
    const blue = types.Color{ .b = 100, .a = 255 };

    _ = try drawTransitionFrame(&context, red, 0);
    var commands = try drawTransitionFrame(&context, blue, 0.5);
    try std.testing.expectEqual(red, commands.items()[0].render_data.rectangle.background_color);

    commands = try drawTransitionFrame(&context, blue, 0.5);
    const midway = commands.items()[0].render_data.rectangle.background_color;
    try std.testing.expectEqual(@as(f32, 12.5), midway.r);
    try std.testing.expectEqual(@as(f32, 87.5), midway.b);
}
