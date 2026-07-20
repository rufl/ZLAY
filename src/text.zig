//! Native text measurement cache and wrapping pass.
//!
//! This ports the observable behavior of Clay's text cache and wrapping logic
//! at upstream commit e6cc36941ab2af5d81107617039d6f527a1c660b. Storage is
//! allocator-owned here so a future Context can place the cache behind its own
//! arena policy without coupling the text algorithm to C-shaped arrays.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const hash = @import("hash.zig");

const Allocator = std.mem.Allocator;

/// Upstream's default hash bucket count is
/// `maxMeasureTextCacheWordCount / 32`, or 16384 / 32.
pub const default_bucket_count: usize = 512;

pub const MeasuredWord = struct {
    start_offset: i32 = 0,
    length: i32 = 0,
    width: f32 = 0,
    next: ?*MeasuredWord = null,
};

/// Collision-resistant identity for the subset of text and configuration that
/// participates in measurement caching. The public Clay-compatible cache hash
/// remains 32-bit, but cache hits must not treat that compact hash as proof of
/// identity: ordinary birthday-bound collisions can otherwise reuse word
/// offsets from an unrelated string.
///
/// Dynamic strings use an independent SHA-256 digest so the key remains valid
/// after the caller's borrowed bytes go out of scope without allocating or
/// retaining them. Static strings retain Clay's pointer-identity semantics,
/// strengthened to the complete native pointer rather than its truncated hash
/// input.
pub const MeasurementKey = struct {
    content_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = @splat(0),
    static_pointer: usize = 0,
    length: i32 = 0,
    accessible_length: usize = 0,
    font_id: u16 = 0,
    font_size: u16 = 0,
    letter_spacing: u16 = 0,
    is_statically_allocated: bool = false,

    pub fn init(text: types.String, config: types.TextElementConfig) MeasurementKey {
        var result = MeasurementKey{
            .length = if (text.is_statically_allocated)
                text.length
            else
                @intCast(text.asSlice().len),
            .accessible_length = text.asSlice().len,
            .font_id = config.font_id,
            .font_size = config.font_size,
            .letter_spacing = config.letter_spacing,
            .is_statically_allocated = text.is_statically_allocated,
        };
        if (text.is_statically_allocated) {
            result.static_pointer = @intFromPtr(text.chars.ptr);
        } else {
            std.crypto.hash.sha2.Sha256.hash(text.asSlice(), &result.content_digest, .{});
        }
        return result;
    }

    pub fn eql(left: MeasurementKey, right: MeasurementKey) bool {
        if (left.is_statically_allocated != right.is_statically_allocated or
            left.length != right.length or
            left.accessible_length != right.accessible_length or
            left.font_id != right.font_id or
            left.font_size != right.font_size or
            left.letter_spacing != right.letter_spacing)
        {
            return false;
        }
        if (left.is_statically_allocated) return left.static_pointer == right.static_pointer;
        return std.mem.eql(u8, &left.content_digest, &right.content_digest);
    }
};

pub const CacheItem = struct {
    unwrapped_dimensions: types.Dimensions = .{},
    measured_words_start: ?*MeasuredWord = null,
    min_width: f32 = 0,
    contains_newlines: bool = false,
    id: u32 = 0,
    measurement_key: MeasurementKey = .{},
    next: ?*CacheItem = null,
    generation: u32 = 0,
};

/// A line borrows its bytes from the `types.String` supplied to `Cache.wrap`.
/// The caller must keep that string alive while consuming the output.
pub const WrappedLine = struct {
    dimensions: types.Dimensions = .{},
    line: types.StringSlice = .{},
    /// Relative horizontal offset calculated using `text_alignment` and the
    /// width passed to `wrap`. Upstream applies this during command emission.
    alignment_offset: f32 = 0,
};

/// Exact number of measured-word nodes produced for the current text bytes.
/// This is public for Context's allocation preflight; callers normally do not
/// need it.
pub fn measuredWordCount(value: types.String) usize {
    const bytes = value.asSlice();
    var count: usize = 0;
    var start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte == ' ') {
            count += 1;
            start = index + 1;
        } else if (byte == '\n') {
            if (index > start) count += 1;
            count += 1;
            start = index + 1;
        }
    }
    if (bytes.len > start) count += 1;
    return count;
}

fn wrappedLineCapacityUpperBound(value: types.String) usize {
    var bound: usize = 1;
    for (value.asSlice()) |byte| {
        if (byte == ' ') bound +|= 1;
        if (byte == '\n') bound +|= 2;
    }
    return bound;
}

fn activeBucketCountForLimit(max_word_count: usize, configured_bucket_count: usize) usize {
    return @min(@max(max_word_count / 32, 1), @max(configured_bucket_count, 1));
}

pub const Cache = struct {
    allocator: Allocator,
    configured_bucket_count: usize = default_bucket_count,
    active_bucket_count: usize = default_bucket_count,
    max_word_count: usize = std.math.maxInt(usize),
    buckets: []?*CacheItem = &.{},
    owned_items: std.ArrayList(*CacheItem) = .empty,
    owned_words: std.ArrayList(*MeasuredWord) = .empty,
    free_items: ?*CacheItem = null,
    free_words: ?*MeasuredWord = null,
    callback_active: bool = false,

    pub fn init(allocator: Allocator) Cache {
        return .{ .allocator = allocator };
    }

    /// Primarily useful when Context exposes a non-default measured-word
    /// limit. A zero bucket count is normalized to one.
    pub fn initWithBucketCount(allocator: Allocator, bucket_count: usize) Cache {
        const normalized_bucket_count = @max(bucket_count, 1);
        return .{
            .allocator = allocator,
            .configured_bucket_count = normalized_bucket_count,
            .active_bucket_count = normalized_bucket_count,
        };
    }

    /// Configure both the hash buckets and the maximum number of measured-word
    /// nodes this cache may ever own. Recycled nodes remain reusable at the
    /// limit, matching Clay's fixed measured-word array.
    pub fn initWithLimits(allocator: Allocator, bucket_count: usize, max_word_count: usize) Cache {
        const normalized_bucket_count = @max(bucket_count, 1);
        return .{
            .allocator = allocator,
            .configured_bucket_count = normalized_bucket_count,
            .active_bucket_count = activeBucketCountForLimit(
                max_word_count,
                normalized_bucket_count,
            ),
            .max_word_count = max_word_count,
        };
    }

    /// Changes Clay's public measured-word limit and the hash topology used by
    /// subsequent lookups without reallocating the initialization-time bucket
    /// array. Clay derives the active divisor from `limit / 32`; the divisor is
    /// clamped here to keep limits below 32 and limits above the allocated
    /// topology memory-safe. Entries in inactive buckets remain available if a
    /// later setter call restores their topology.
    pub fn setMaxWordCount(self: *Cache, max_word_count: usize) void {
        // Changing the active divisor while `measure` still owns a bucket
        // index can strand the new item in an inactive bucket and make an
        // identical follow-up lookup allocate a duplicate cache entry.
        if (self.callback_active) return;
        self.max_word_count = max_word_count;
        self.active_bucket_count = activeBucketCountForLimit(
            max_word_count,
            self.configured_bucket_count,
        );
    }

    pub fn deinit(self: *Cache) void {
        if (self.callback_active) return;
        for (self.owned_words.items) |word| self.allocator.destroy(word);
        for (self.owned_items.items) |item| self.allocator.destroy(item);
        self.owned_words.deinit(self.allocator);
        self.owned_items.deinit(self.allocator);
        if (self.buckets.len > 0) self.allocator.free(self.buckets);
        self.* = undefined;
    }

    /// Clears all cached measurements while retaining allocator-owned nodes for
    /// reuse. Pointers returned by `measure` become invalid for use after reset.
    pub fn reset(self: *Cache) void {
        if (self.callback_active) return;
        if (self.buckets.len > 0) @memset(self.buckets, null);

        self.free_words = null;
        for (self.owned_words.items) |word| {
            word.* = .{ .next = self.free_words };
            self.free_words = word;
        }

        self.free_items = null;
        for (self.owned_items.items) |item| {
            item.* = .{ .next = self.free_items };
            self.free_items = item;
        }
    }

    /// Counts active cache entries. Intended for diagnostics and parity tests.
    pub fn entryCount(self: *const Cache) usize {
        var count: usize = 0;
        for (self.buckets) |bucket| {
            var current = bucket;
            while (current) |item| : (current = item.next) count += 1;
        }
        return count;
    }

    /// Refresh an already-cached key before an allocation-free phase. Unlike
    /// `measure`, this never invokes application code and never prunes a
    /// colliding entry. Refreshing the generation prevents another lookup in
    /// the same phase from recycling an entry that a later text node needs.
    pub fn refreshIfPresent(
        self: *Cache,
        value: types.String,
        config: types.TextElementConfig,
        generation: u32,
    ) bool {
        if (self.callback_active) return false;
        if (self.buckets.len == 0) return false;
        const id = hash.textWithConfig(value, config);
        const measurement_key = MeasurementKey.init(value, config);
        var current = self.buckets[self.bucketIndex(id)];
        while (current) |item| : (current = item.next) {
            if (item.id != id or !item.measurement_key.eql(measurement_key)) continue;
            item.generation = generation;
            return true;
        }
        return false;
    }

    /// Ensure later cache misses can acquire their item and word nodes without
    /// touching the allocator. Partially completed reservation remains on the
    /// free lists if allocation fails, making a retry safe and useful.
    pub fn ensureFreeCapacity(
        self: *Cache,
        required_items: usize,
        required_words: usize,
    ) !void {
        if (self.callback_active) return error.CallbackReentryNotAllowed;
        try self.ensureBuckets();

        var free_item_count: usize = 0;
        var free_item = self.free_items;
        while (free_item) |item| : (free_item = item.next) free_item_count += 1;

        var free_word_count: usize = 0;
        var free_word = self.free_words;
        while (free_word) |word| : (free_word = word.next) free_word_count += 1;

        const additional_items = required_items -| free_item_count;
        const additional_words = required_words -| free_word_count;
        if (additional_words > self.max_word_count -| self.owned_words.items.len) {
            return error.TextMeasurementCapacityExceeded;
        }

        const item_capacity = std.math.add(
            usize,
            self.owned_items.items.len,
            additional_items,
        ) catch return error.OutOfMemory;
        const word_capacity = std.math.add(
            usize,
            self.owned_words.items.len,
            additional_words,
        ) catch return error.OutOfMemory;
        try self.owned_items.ensureTotalCapacity(self.allocator, item_capacity);
        try self.owned_words.ensureTotalCapacity(self.allocator, word_capacity);

        for (0..additional_items) |_| {
            const item = try self.allocator.create(CacheItem);
            self.owned_items.appendAssumeCapacity(item);
            item.* = .{ .next = self.free_items };
            self.free_items = item;
        }
        for (0..additional_words) |_| {
            const word = try self.allocator.create(MeasuredWord);
            self.owned_words.appendAssumeCapacity(word);
            word.* = .{ .next = self.free_words };
            self.free_words = word;
        }
    }

    /// Measures text or returns a cached result. As upstream does, an exact ID
    /// match refreshes even an old entry; generation pruning only removes stale
    /// non-matching entries encountered in the same hash bucket.
    pub fn measure(
        self: *Cache,
        text: types.String,
        config: *types.TextElementConfig,
        measure_fn_optional: ?types.MeasureTextFunction,
        user_data: ?*anyopaque,
        generation: u32,
    ) !*const CacheItem {
        if (self.callback_active) return error.CallbackReentryNotAllowed;
        const measure_fn = measure_fn_optional orelse
            return error.MeasureTextFunctionNotProvided;
        try self.ensureBuckets();

        const id = hash.textWithConfig(text, config.*);
        const measurement_key = MeasurementKey.init(text, config.*);
        const bucket_index = self.bucketIndex(id);
        var previous: ?*CacheItem = null;
        var current = self.buckets[bucket_index];

        while (current) |item| {
            if (item.id == id and item.measurement_key.eql(measurement_key)) {
                item.generation = generation;
                return item;
            }

            const next = item.next;
            if (generation -% item.generation > 2) {
                if (previous) |previous_item| {
                    previous_item.next = next;
                } else {
                    self.buckets[bucket_index] = next;
                }
                self.recycleWordChain(item.measured_words_start);
                self.recycleItem(item);
                current = next;
            } else {
                previous = item;
                current = next;
            }
        }

        // Reserve the complete miss before invoking application measurement.
        // Every later item/word acquisition is therefore allocation-free and
        // a capacity/OOM error cannot follow an observable callback.
        try self.ensureFreeCapacity(1, measuredWordCount(text));
        const item = try self.acquireItem();
        item.* = .{
            .id = id,
            .measurement_key = measurement_key,
            .generation = generation,
        };
        errdefer self.recycleItem(item);

        const text_bytes = text.asSlice();
        const space_width = self.invokeMeasure(
            measure_fn,
            types.StringSlice.fromSlice(" "),
            config,
            user_data,
        ).width;

        var first_word: ?*MeasuredWord = null;
        var last_word: ?*MeasuredWord = null;
        errdefer self.recycleWordChain(first_word);

        var start: usize = 0;
        var end: usize = 0;
        var line_width: f32 = 0;
        var measured_width: f32 = 0;
        var measured_height: f32 = 0;

        while (end < text_bytes.len) : (end += 1) {
            const current_byte = text_bytes[end];
            if (current_byte != ' ' and current_byte != '\n') continue;

            const length = end - start;
            var dimensions: types.Dimensions = .{};
            if (length > 0) {
                dimensions = self.invokeMeasure(
                    measure_fn,
                    stringSlice(text_bytes, start, length),
                    config,
                    user_data,
                );
            }

            item.min_width = maxF32(dimensions.width, item.min_width);
            measured_height = maxF32(measured_height, dimensions.height);

            if (current_byte == ' ') {
                dimensions.width += space_width;
                try self.appendWord(&first_word, &last_word, .{
                    .start_offset = @intCast(start),
                    .length = @intCast(length + 1),
                    .width = dimensions.width,
                });
                line_width += dimensions.width;
            }

            if (current_byte == '\n') {
                if (length > 0) {
                    try self.appendWord(&first_word, &last_word, .{
                        .start_offset = @intCast(start),
                        .length = @intCast(length),
                        .width = dimensions.width,
                    });
                }
                try self.appendWord(&first_word, &last_word, .{
                    .start_offset = @intCast(end + 1),
                    .length = 0,
                    .width = 0,
                });
                line_width += dimensions.width;
                measured_width = maxF32(line_width, measured_width);
                item.contains_newlines = true;
                line_width = 0;
            }
            start = end + 1;
        }

        if (end - start > 0) {
            const dimensions = self.invokeMeasure(
                measure_fn,
                stringSlice(text_bytes, start, end - start),
                config,
                user_data,
            );
            try self.appendWord(&first_word, &last_word, .{
                .start_offset = @intCast(start),
                .length = @intCast(end - start),
                .width = dimensions.width,
            });
            line_width += dimensions.width;
            measured_height = maxF32(measured_height, dimensions.height);
            item.min_width = maxF32(dimensions.width, item.min_width);
        }

        const letter_spacing: f32 = @floatFromInt(config.letter_spacing);
        measured_width = maxF32(line_width, measured_width) - letter_spacing;
        item.measured_words_start = first_word;
        item.unwrapped_dimensions = .{
            .width = measured_width,
            .height = measured_height,
        };

        if (previous) |previous_item| {
            previous_item.next = item;
        } else {
            self.buckets[bucket_index] = item;
        }
        return item;
    }

    /// Appends wrapped lines to `output` and returns the text element's final
    /// dimensions. For NEWLINES and NONE, width compression is disabled just as
    /// it is in upstream's sizing pass; explicit newline markers still produce
    /// line breaks in both modes.
    pub fn wrap(
        self: *Cache,
        text: types.String,
        config: *types.TextElementConfig,
        measure_fn_optional: ?types.MeasureTextFunction,
        user_data: ?*anyopaque,
        generation: u32,
        max_width: f32,
        output: *std.ArrayList(WrappedLine),
        output_limit: usize,
    ) !types.Dimensions {
        return self.wrapInternal(
            text,
            config,
            measure_fn_optional,
            user_data,
            generation,
            null,
            max_width,
            output,
            output_limit,
        );
    }

    /// Context variant of `wrap` that preserves Clay's declaration-time
    /// `preferredDimensions`. A cache reset between declaration and final
    /// layout may produce new word measurements, but upstream still uses the
    /// stored preferred width for the no-wrap fast path and the stored height
    /// for natural line height.
    pub fn wrapWithPreferredDimensions(
        self: *Cache,
        text: types.String,
        config: *types.TextElementConfig,
        measure_fn_optional: ?types.MeasureTextFunction,
        user_data: ?*anyopaque,
        generation: u32,
        preferred_dimensions: types.Dimensions,
        max_width: f32,
        output: *std.ArrayList(WrappedLine),
        output_limit: usize,
    ) !types.Dimensions {
        return self.wrapInternal(
            text,
            config,
            measure_fn_optional,
            user_data,
            generation,
            preferred_dimensions,
            max_width,
            output,
            output_limit,
        );
    }

    fn wrapInternal(
        self: *Cache,
        text: types.String,
        config: *types.TextElementConfig,
        measure_fn_optional: ?types.MeasureTextFunction,
        user_data: ?*anyopaque,
        generation: u32,
        preferred_dimensions_optional: ?types.Dimensions,
        max_width: f32,
        output: *std.ArrayList(WrappedLine),
        output_limit: usize,
    ) !types.Dimensions {
        if (self.callback_active) return error.CallbackReentryNotAllowed;
        const measure_fn = measure_fn_optional orelse
            return error.MeasureTextFunctionNotProvided;
        const additional_limit = output_limit -| output.items.len;
        const additional_lines = @min(
            wrappedLineCapacityUpperBound(text),
            additional_limit,
        );
        const required_output_capacity = std.math.add(
            usize,
            output.items.len,
            additional_lines,
        ) catch return error.OutOfMemory;
        try output.ensureTotalCapacity(self.allocator, required_output_capacity);
        const measured = try self.measure(
            text,
            config,
            measure_fn,
            user_data,
            generation,
        );
        const preferred_dimensions = preferred_dimensions_optional orelse
            measured.unwrapped_dimensions;
        const text_bytes = text.asSlice();
        const natural_line_height = preferred_dimensions.height;
        const line_height: f32 = if (config.line_height > 0)
            @floatFromInt(config.line_height)
        else
            natural_line_height;

        // Clay prevents NEWLINES and NONE text from being compressed during
        // X-axis sizing. Apply that invariant here so this pure wrapper remains
        // correct when called independently from the future layout pass.
        const container_width = if (config.wrap_mode == .words)
            max_width
        else
            maxF32(max_width, preferred_dimensions.width);

        var reported_line_count: usize = 0;
        if (!measured.contains_newlines and
            preferred_dimensions.width <= container_width)
        {
            if (output.items.len < output_limit) {
                try self.appendLine(
                    output,
                    text_bytes,
                    0,
                    text_bytes.len,
                    container_width,
                    line_height,
                    container_width,
                    config.text_alignment,
                );
            }
            return dimensionsForLines(container_width, line_height, 1);
        }

        const space_width = self.invokeMeasure(
            measure_fn,
            types.StringSlice.fromSlice(" "),
            config,
            user_data,
        ).width;
        const letter_spacing: f32 = @floatFromInt(config.letter_spacing);
        var word = measured.measured_words_start;
        var line_width: f32 = 0;
        var line_length_chars: usize = 0;
        var line_start_offset: usize = 0;

        while (word) |measured_word| {
            if (output.items.len >= output_limit) break;
            const word_start: usize = @intCast(measured_word.start_offset);
            const word_length: usize = @intCast(measured_word.length);

            // Only word on the line is too large: render it without splitting.
            if (line_length_chars == 0 and
                line_width + measured_word.width > container_width)
            {
                try self.appendLine(
                    output,
                    text_bytes,
                    word_start,
                    word_length,
                    measured_word.width,
                    line_height,
                    container_width,
                    config.text_alignment,
                );
                reported_line_count += 1;
                word = measured_word.next;
                line_start_offset = word_start + word_length;
            } else if (measured_word.length == 0 or
                line_width + measured_word.width > container_width)
            {
                const final_char_is_space = finalCharacterIsSpace(
                    text_bytes,
                    line_start_offset,
                    line_length_chars,
                );
                const output_width = line_width +
                    (if (final_char_is_space) -space_width else 0);
                // Upstream indexes byte zero for an empty accumulated line.
                // If that byte is a space, its signed arithmetic produces a
                // line length of -1. Native Zig keeps the intended empty line
                // and avoids exposing an invalid slice length.
                const output_length = line_length_chars -
                    @intFromBool(final_char_is_space and line_length_chars > 0);
                try self.appendLine(
                    output,
                    text_bytes,
                    line_start_offset,
                    output_length,
                    output_width,
                    line_height,
                    container_width,
                    config.text_alignment,
                );
                reported_line_count += 1;
                if (line_length_chars == 0 or measured_word.length == 0) {
                    word = measured_word.next;
                }
                line_width = 0;
                line_length_chars = 0;
                line_start_offset = word_start;
            } else {
                line_width += measured_word.width + letter_spacing;
                line_length_chars += word_length;
                word = measured_word.next;
            }
        }

        if (line_length_chars > 0) {
            if (output.items.len < output_limit) {
                try self.appendLine(
                    output,
                    text_bytes,
                    line_start_offset,
                    line_length_chars,
                    line_width - letter_spacing,
                    line_height,
                    container_width,
                    config.text_alignment,
                );
            }
            // Pinned Clay increments the element-local slice length even when
            // this final append lands just beyond the shared arena ceiling.
            reported_line_count += 1;
        }

        return dimensionsForLines(container_width, line_height, reported_line_count);
    }

    fn invokeMeasure(
        self: *Cache,
        measure_fn: types.MeasureTextFunction,
        value: types.StringSlice,
        config: *types.TextElementConfig,
        user_data: ?*anyopaque,
    ) types.Dimensions {
        std.debug.assert(!self.callback_active);
        self.callback_active = true;
        defer self.callback_active = false;
        return measure_fn(value, config, user_data);
    }

    fn ensureBuckets(self: *Cache) !void {
        if (self.buckets.len > 0) return;
        self.buckets = try self.allocator.alloc(
            ?*CacheItem,
            self.configured_bucket_count,
        );
        @memset(self.buckets, null);
    }

    fn bucketIndex(self: *const Cache, id: u32) usize {
        std.debug.assert(self.active_bucket_count > 0);
        std.debug.assert(self.active_bucket_count <= self.buckets.len);
        return @as(usize, id) % self.active_bucket_count;
    }

    fn acquireItem(self: *Cache) !*CacheItem {
        if (self.free_items) |item| {
            self.free_items = item.next;
            item.* = .{};
            return item;
        }

        const item = try self.allocator.create(CacheItem);
        errdefer self.allocator.destroy(item);
        try self.owned_items.append(self.allocator, item);
        item.* = .{};
        return item;
    }

    fn acquireWord(self: *Cache) !*MeasuredWord {
        if (self.free_words) |word| {
            self.free_words = word.next;
            word.* = .{};
            return word;
        }

        if (self.owned_words.items.len >= self.max_word_count) {
            return error.TextMeasurementCapacityExceeded;
        }

        const word = try self.allocator.create(MeasuredWord);
        errdefer self.allocator.destroy(word);
        try self.owned_words.append(self.allocator, word);
        word.* = .{};
        return word;
    }

    fn appendWord(
        self: *Cache,
        first: *?*MeasuredWord,
        last: *?*MeasuredWord,
        value: MeasuredWord,
    ) !void {
        const word = try self.acquireWord();
        word.* = value;
        if (last.*) |previous| {
            previous.next = word;
        } else {
            first.* = word;
        }
        last.* = word;
    }

    fn recycleWordChain(self: *Cache, first: ?*MeasuredWord) void {
        var current = first;
        while (current) |word| {
            const next = word.next;
            word.* = .{ .next = self.free_words };
            self.free_words = word;
            current = next;
        }
    }

    fn recycleItem(self: *Cache, item: *CacheItem) void {
        item.* = .{ .next = self.free_items };
        self.free_items = item;
    }

    fn appendLine(
        self: *Cache,
        output: *std.ArrayList(WrappedLine),
        base: []const u8,
        start: usize,
        length: usize,
        width: f32,
        height: f32,
        container_width: f32,
        alignment: types.TextAlignment,
    ) !void {
        try output.append(self.allocator, .{
            .dimensions = .{ .width = width, .height = height },
            .line = stringSlice(base, start, length),
            .alignment_offset = alignmentOffset(
                container_width,
                width,
                alignment,
            ),
        });
    }
};

fn maxF32(left: f32, right: f32) f32 {
    return if (left > right) left else right;
}

fn stringSlice(base: []const u8, start: usize, length: usize) types.StringSlice {
    std.debug.assert(start <= base.len);
    std.debug.assert(length <= base.len - start);
    return .{
        .length = @intCast(length),
        .chars = base[start .. start + length],
        .base_chars = base,
    };
}

fn finalCharacterIsSpace(
    text: []const u8,
    line_start: usize,
    line_length: usize,
) bool {
    if (text.len == 0 or line_length == 0) return false;
    const index = if (line_length > 0)
        line_start + line_length - 1
    else
        0;
    return index < text.len and text[index] == ' ';
}

fn alignmentOffset(
    container_width: f32,
    line_width: f32,
    alignment: types.TextAlignment,
) f32 {
    var offset = container_width - line_width;
    if (alignment == .left) offset = 0;
    if (alignment == .center) offset /= 2;
    return offset;
}

fn dimensionsForLines(
    width: f32,
    line_height: f32,
    line_count: usize,
) types.Dimensions {
    return .{
        .width = width,
        .height = line_height * @as(f32, @floatFromInt(line_count)),
    };
}

const MonoState = struct {
    calls: usize = 0,
    glyph_width: f32 = 10,
    glyph_height: f32 = 20,
};

const ByteSumState = struct {
    calls: usize = 0,
};

fn measureByteSum(
    value: types.StringSlice,
    _: *types.TextElementConfig,
    user_data: ?*anyopaque,
) types.Dimensions {
    const state: *ByteSumState = @ptrCast(@alignCast(user_data.?));
    state.calls += 1;
    var width: usize = 0;
    for (value.asSlice()) |byte| width += byte;
    return .{ .width = @floatFromInt(width), .height = 1 };
}

fn measureMonospace(
    text: types.StringSlice,
    _: *types.TextElementConfig,
    user_data: ?*anyopaque,
) types.Dimensions {
    const state: *MonoState = @ptrCast(@alignCast(user_data.?));
    state.calls += 1;
    return .{
        .width = @as(f32, @floatFromInt(text.asSlice().len)) * state.glyph_width,
        .height = state.glyph_height,
    };
}

const ReentrantCacheProbe = struct {
    cache: *Cache,
    nested_error: ?anyerror = null,
    calls: usize = 0,
};

fn reentrantCacheMeasure(
    value: types.StringSlice,
    config: *types.TextElementConfig,
    user_data: ?*anyopaque,
) types.Dimensions {
    const probe: *ReentrantCacheProbe = @ptrCast(@alignCast(user_data.?));
    probe.calls += 1;
    probe.cache.reset();
    probe.cache.deinit();
    probe.cache.setMaxWordCount(1);
    _ = probe.cache.measure(
        types.String.literal("nested"),
        config,
        reentrantCacheMeasure,
        probe,
        1,
    ) catch |nested_error| {
        probe.nested_error = nested_error;
        return .{ .width = @floatFromInt(value.asSlice().len), .height = 1 };
    };
    return .{ .width = @floatFromInt(value.asSlice().len), .height = 1 };
}

test "measurement callbacks cannot reset destroy retune or recursively mutate their cache" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var probe = ReentrantCacheProbe{ .cache = &cache };
    var config = types.TextElementConfig{};
    const initial_max_word_count = cache.max_word_count;
    const initial_bucket_count = cache.active_bucket_count;

    _ = try cache.measure(
        types.String.literal("outer"),
        &config,
        reentrantCacheMeasure,
        &probe,
        1,
    );

    try std.testing.expectEqual(error.CallbackReentryNotAllowed, probe.nested_error.?);
    try std.testing.expect(probe.calls > 0);
    try std.testing.expectEqual(@as(usize, 1), cache.entryCount());
    try std.testing.expect(cache.free_items == null);
    try std.testing.expectEqual(initial_max_word_count, cache.max_word_count);
    try std.testing.expectEqual(initial_bucket_count, cache.active_bucket_count);
}

test "cache reservation rejects item-count overflow without panicking" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var state = MonoState{};
    var config = types.TextElementConfig{};

    _ = try cache.measure(
        types.String.literal(""),
        &config,
        measureMonospace,
        &state,
        1,
    );
    try std.testing.expectError(
        error.OutOfMemory,
        cache.ensureFreeCapacity(std.math.maxInt(usize), 0),
    );
    try std.testing.expectEqual(@as(usize, 1), cache.entryCount());
}

test "measurement caches words and preserves upstream width order" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var state = MonoState{};
    var config = types.TextElementConfig{ .letter_spacing = 2 };
    const text = types.String.fromSlice("hello world");

    const first = try cache.measure(
        text,
        &config,
        measureMonospace,
        &state,
        1,
    );
    try std.testing.expectEqual(@as(f32, 108), first.unwrapped_dimensions.width);
    try std.testing.expectEqual(@as(f32, 20), first.unwrapped_dimensions.height);
    try std.testing.expectEqual(@as(f32, 50), first.min_width);
    try std.testing.expect(!first.contains_newlines);
    try std.testing.expectEqual(@as(usize, 3), state.calls);

    const first_word = first.measured_words_start.?;
    try std.testing.expectEqual(@as(i32, 0), first_word.start_offset);
    try std.testing.expectEqual(@as(i32, 6), first_word.length);
    try std.testing.expectEqual(@as(f32, 60), first_word.width);
    const second_word = first_word.next.?;
    try std.testing.expectEqual(@as(i32, 6), second_word.start_offset);
    try std.testing.expectEqual(@as(i32, 5), second_word.length);
    try std.testing.expectEqual(@as(f32, 50), second_word.width);
    try std.testing.expect(second_word.next == null);

    const second = try cache.measure(
        text,
        &config,
        measureMonospace,
        &state,
        2,
    );
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u32, 2), second.generation);
    try std.testing.expectEqual(@as(usize, 3), state.calls);
}

test "full cache hash collisions retain distinct measurements" {
    var cache = Cache.initWithBucketCount(std.testing.allocator, 1);
    defer cache.deinit();
    var state = ByteSumState{};
    var config = types.TextElementConfig{};
    const first_text = types.String.fromSlice("zlay-fixed-000008");
    const second_text = types.String.fromSlice("zlay-fixed-000400");

    if (builtin.target.cpu.arch == .x86_64) {
        try std.testing.expectEqual(
            hash.textWithConfig(first_text, config),
            hash.textWithConfig(second_text, config),
        );
    }
    try std.testing.expect(!MeasurementKey.init(first_text, config).eql(
        MeasurementKey.init(second_text, config),
    ));

    const first = try cache.measure(first_text, &config, measureByteSum, &state, 1);
    try std.testing.expectEqual(@as(f32, 1362), first.unwrapped_dimensions.width);
    const calls_after_first = state.calls;
    // Preserve a target-independent regression for the full-ID collision path.
    // The pair above is a concrete x86-64 collision; seeding the retained ID
    // makes the same lookup condition executable under every supported target.
    cache.buckets[0].?.id = hash.textWithConfig(second_text, config);

    const second = try cache.measure(second_text, &config, measureByteSum, &state, 1);
    try std.testing.expectEqual(@as(f32, 1358), second.unwrapped_dimensions.width);
    try std.testing.expect(state.calls > calls_after_first);
    try std.testing.expectEqual(@as(usize, 2), cache.entryCount());
}

test "different-length cache hash collisions cannot corrupt wrapping offsets" {
    var cache = Cache.initWithBucketCount(std.testing.allocator, 1);
    defer cache.deinit();
    var lines: std.ArrayList(WrappedLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var state = MonoState{ .glyph_width = 1, .glyph_height = 1 };
    var config = types.TextElementConfig{};
    const longer = types.String.fromSlice("zlay-collision-20000");
    const shorter = types.String.fromSlice("zlay-collision-6080");

    if (builtin.target.cpu.arch == .x86_64) {
        try std.testing.expectEqual(
            hash.textWithConfig(longer, config),
            hash.textWithConfig(shorter, config),
        );
    }
    _ = try cache.measure(longer, &config, measureMonospace, &state, 1);
    cache.buckets[0].?.id = hash.textWithConfig(shorter, config);
    _ = try cache.wrap(
        shorter,
        &config,
        measureMonospace,
        &state,
        1,
        1,
        &lines,
        std.math.maxInt(usize),
    );

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings(shorter.asSlice(), lines.items[0].line.asSlice());
    try std.testing.expectEqual(@as(usize, 2), cache.entryCount());
}

test "malformed static strings with one pointer and declared length remain distinct" {
    var cache = Cache.initWithBucketCount(std.testing.allocator, 1);
    defer cache.deinit();
    var lines: std.ArrayList(WrappedLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var state = MonoState{ .glyph_width = 1, .glyph_height = 1 };
    var config = types.TextElementConfig{};
    const storage = "abcdefghij";
    const complete = types.String{
        .is_statically_allocated = true,
        .length = 10,
        .chars = storage[0..10],
    };
    const truncated = types.String{
        .is_statically_allocated = true,
        .length = 10,
        .chars = storage[0..5],
    };

    try std.testing.expectEqual(
        @intFromPtr(complete.chars.ptr),
        @intFromPtr(truncated.chars.ptr),
    );
    try std.testing.expectEqual(
        hash.textWithConfig(complete, config),
        hash.textWithConfig(truncated, config),
    );
    try std.testing.expect(!MeasurementKey.init(complete, config).eql(
        MeasurementKey.init(truncated, config),
    ));

    _ = try cache.measure(complete, &config, measureMonospace, &state, 1);
    const calls_after_complete = state.calls;
    _ = try cache.wrap(
        truncated,
        &config,
        measureMonospace,
        &state,
        1,
        1,
        &lines,
        std.math.maxInt(usize),
    );

    try std.testing.expect(state.calls > calls_after_complete);
    try std.testing.expectEqual(@as(usize, 2), cache.entryCount());
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("abcde", lines.items[0].line.asSlice());
}

test "wrap output allocation failure precedes measurement callbacks" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var cache = Cache.init(allocator);
    defer cache.deinit();
    var lines: std.ArrayList(WrappedLine) = .empty;
    defer lines.deinit(allocator);
    var state = MonoState{ .glyph_width = 1, .glyph_height = 1 };
    var config = types.TextElementConfig{};
    const value = types.String.fromSlice("a b");

    _ = try cache.measure(value, &config, measureMonospace, &state, 1);
    const calls_before_wrap = state.calls;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(
        error.OutOfMemory,
        cache.wrap(
            value,
            &config,
            measureMonospace,
            &state,
            1,
            1,
            &lines,
            std.math.maxInt(usize),
        ),
    );
    try std.testing.expectEqual(calls_before_wrap, state.calls);
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
}

test "word wrapping preserves spaces letter spacing and center alignment" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var lines: std.ArrayList(WrappedLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var state = MonoState{};
    var config = types.TextElementConfig{
        .letter_spacing = 2,
        .text_alignment = .center,
    };

    const dimensions = try cache.wrap(
        types.String.fromSlice("one two three"),
        &config,
        measureMonospace,
        &state,
        1,
        75,
        &lines,
        std.math.maxInt(usize),
    );

    try std.testing.expectEqual(types.Dimensions{ .width = 75, .height = 60 }, dimensions);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("one", lines.items[0].line.asSlice());
    try std.testing.expectEqualStrings("two", lines.items[1].line.asSlice());
    try std.testing.expectEqualStrings("three", lines.items[2].line.asSlice());
    try std.testing.expectEqual(@as(f32, 32), lines.items[0].dimensions.width);
    try std.testing.expectEqual(@as(f32, 32), lines.items[1].dimensions.width);
    try std.testing.expectEqual(@as(f32, 50), lines.items[2].dimensions.width);
    try std.testing.expectEqual(@as(f32, 21.5), lines.items[0].alignment_offset);
    try std.testing.expectEqual(@as(f32, 12.5), lines.items[2].alignment_offset);
    // One space measurement plus three word measurements during cache fill,
    // followed by Clay's second space measurement during wrapping.
    try std.testing.expectEqual(@as(usize, 5), state.calls);
}

test "newlines and none modes disable width compression but keep explicit breaks" {
    const input = "a b\nc d";
    inline for (.{
        types.TextElementConfigWrapMode.newlines,
        types.TextElementConfigWrapMode.none,
    }) |wrap_mode| {
        var cache = Cache.init(std.testing.allocator);
        defer cache.deinit();
        var lines: std.ArrayList(WrappedLine) = .empty;
        defer lines.deinit(std.testing.allocator);
        var state = MonoState{};
        var config = types.TextElementConfig{ .wrap_mode = wrap_mode };

        const dimensions = try cache.wrap(
            types.String.fromSlice(input),
            &config,
            measureMonospace,
            &state,
            1,
            15,
            &lines,
            std.math.maxInt(usize),
        );

        try std.testing.expectEqual(@as(f32, 30), dimensions.width);
        try std.testing.expectEqual(@as(f32, 40), dimensions.height);
        try std.testing.expectEqual(@as(usize, 2), lines.items.len);
        try std.testing.expectEqualStrings("a b", lines.items[0].line.asSlice());
        try std.testing.expectEqualStrings("c d", lines.items[1].line.asSlice());
    }
}

test "explicit leading newline and configured line height retain an empty line" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var lines: std.ArrayList(WrappedLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var state = MonoState{};
    var config = types.TextElementConfig{
        .line_height = 30,
        .wrap_mode = .none,
        .text_alignment = .right,
    };

    const dimensions = try cache.wrap(
        types.String.fromSlice("\na"),
        &config,
        measureMonospace,
        &state,
        1,
        10,
        &lines,
        std.math.maxInt(usize),
    );
    try std.testing.expectEqual(types.Dimensions{ .width = 10, .height = 60 }, dimensions);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("", lines.items[0].line.asSlice());
    try std.testing.expectEqualStrings("a", lines.items[1].line.asSlice());
    try std.testing.expectEqual(@as(f32, 10), lines.items[0].alignment_offset);
    try std.testing.expectEqual(@as(f32, 0), lines.items[1].alignment_offset);
    try std.testing.expectEqual(@as(f32, 30), lines.items[1].dimensions.height);
}

test "oversized leading space before newline keeps a safe empty line" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var lines: std.ArrayList(WrappedLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    var state = MonoState{};
    var config = types.TextElementConfig{};

    _ = try cache.wrap(
        types.String.fromSlice(" \n"),
        &config,
        measureMonospace,
        &state,
        1,
        1,
        &lines,
        std.math.maxInt(usize),
    );
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings(" ", lines.items[0].line.asSlice());
    try std.testing.expectEqual(@as(i32, 0), lines.items[1].line.length);
    try std.testing.expectEqualStrings("", lines.items[1].line.asSlice());
}

test "generation pruning reuses stale colliding cache nodes" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var state = MonoState{};
    var config = types.TextElementConfig{};
    var storage: [256][16]u8 = undefined;
    var labels: [256][]const u8 = undefined;
    var first_text_optional: ?types.String = null;
    var colliding_text_optional: ?types.String = null;
    collision_search: for (&storage, 0..) |*buffer, index| {
        labels[index] = try std.fmt.bufPrint(buffer, "cache-{d}", .{index});
        const candidate = types.String.fromSlice(labels[index]);
        const candidate_bucket = hash.textWithConfig(candidate, config) % default_bucket_count;
        for (labels[0..index]) |previous_label| {
            const previous = types.String.fromSlice(previous_label);
            if (hash.textWithConfig(previous, config) % default_bucket_count == candidate_bucket) {
                first_text_optional = previous;
                colliding_text_optional = candidate;
                break :collision_search;
            }
        }
    }
    const first_text = first_text_optional orelse return error.NoHashCollisionFound;
    const colliding_text = colliding_text_optional orelse return error.NoHashCollisionFound;

    try std.testing.expectEqual(
        hash.textWithConfig(first_text, config) % default_bucket_count,
        hash.textWithConfig(colliding_text, config) % default_bucket_count,
    );
    _ = try cache.measure(first_text, &config, measureMonospace, &state, 1);
    try std.testing.expectEqual(@as(usize, 1), cache.entryCount());
    _ = try cache.measure(colliding_text, &config, measureMonospace, &state, 4);
    try std.testing.expectEqual(@as(usize, 1), cache.entryCount());
    try std.testing.expectEqual(@as(usize, 4), state.calls);

    _ = try cache.measure(first_text, &config, measureMonospace, &state, 4);
    try std.testing.expectEqual(@as(usize, 2), cache.entryCount());
    try std.testing.expectEqual(@as(usize, 6), state.calls);

    cache.reset();
    try std.testing.expectEqual(@as(usize, 0), cache.entryCount());
    _ = try cache.measure(first_text, &config, measureMonospace, &state, 5);
    try std.testing.expectEqual(@as(usize, 1), cache.entryCount());
    try std.testing.expectEqual(@as(usize, 8), state.calls);
}

test "exact cache hit refreshes even after the usual prune age" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var state = MonoState{};
    var config = types.TextElementConfig{};
    const text = types.String.fromSlice("persistent");

    _ = try cache.measure(text, &config, measureMonospace, &state, 1);
    const cached = try cache.measure(text, &config, measureMonospace, &state, 100);
    try std.testing.expectEqual(@as(u32, 100), cached.generation);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
}

test "runtime word limit restores cache entries through the original bucket topology" {
    var cache = Cache.initWithLimits(std.testing.allocator, 3, 96);
    defer cache.deinit();
    var state = MonoState{};
    var config = types.TextElementConfig{
        .font_id = 7,
        .font_size = 24,
        .letter_spacing = 3,
    };
    const value = types.String.fromSlice("Clay");
    const id = hash.textWithConfig(value, config);

    try std.testing.expect(@as(usize, id) % 3 != @as(usize, id) % 2);
    _ = try cache.measure(value, &config, measureMonospace, &state, 1);
    try std.testing.expectEqual(@as(usize, 3), cache.buckets.len);
    try std.testing.expectEqual(@as(usize, 3), cache.active_bucket_count);
    try std.testing.expectEqual(@as(usize, 2), state.calls);

    cache.setMaxWordCount(64);
    _ = try cache.measure(value, &config, measureMonospace, &state, 2);
    try std.testing.expectEqual(@as(usize, 3), cache.buckets.len);
    try std.testing.expectEqual(@as(usize, 2), cache.active_bucket_count);
    try std.testing.expectEqual(@as(usize, 2), cache.entryCount());
    try std.testing.expectEqual(@as(usize, 4), state.calls);

    cache.setMaxWordCount(96);
    _ = try cache.measure(value, &config, measureMonospace, &state, 3);
    try std.testing.expectEqual(@as(usize, 3), cache.buckets.len);
    try std.testing.expectEqual(@as(usize, 3), cache.active_bucket_count);
    try std.testing.expectEqual(@as(usize, 2), cache.entryCount());
    try std.testing.expectEqual(@as(usize, 4), state.calls);
}

test "runtime word limit clamps active topology to allocated buckets" {
    var cache = Cache.initWithLimits(std.testing.allocator, 3, 96);
    defer cache.deinit();
    var state = MonoState{};
    var config = types.TextElementConfig{};

    cache.setMaxWordCount(31);
    _ = try cache.measure(types.String.fromSlice(""), &config, measureMonospace, &state, 1);
    try std.testing.expectEqual(@as(usize, 31), cache.max_word_count);
    try std.testing.expectEqual(@as(usize, 1), cache.active_bucket_count);
    try std.testing.expectEqual(@as(usize, 3), cache.buckets.len);

    cache.setMaxWordCount(128);
    _ = try cache.measure(types.String.fromSlice("x"), &config, measureMonospace, &state, 2);
    try std.testing.expectEqual(@as(usize, 128), cache.max_word_count);
    try std.testing.expectEqual(@as(usize, 3), cache.active_bucket_count);
    try std.testing.expectEqual(@as(usize, 3), cache.buckets.len);
}

test "measured-word limit is exact and failed measurements recycle their chain" {
    var cache = Cache.initWithLimits(std.testing.allocator, 1, 2);
    defer cache.deinit();
    var state = MonoState{};
    var config = types.TextElementConfig{};

    const exact = try cache.measure(types.String.fromSlice("a b"), &config, measureMonospace, &state, 1);
    try std.testing.expect(exact.measured_words_start != null);
    try std.testing.expectEqual(@as(usize, 2), cache.owned_words.items.len);

    cache.reset();
    try std.testing.expectError(
        error.TextMeasurementCapacityExceeded,
        cache.measure(types.String.fromSlice("a b c"), &config, measureMonospace, &state, 2),
    );
    try std.testing.expectEqual(@as(usize, 0), cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), cache.owned_words.items.len);

    const recovered = try cache.measure(types.String.fromSlice("z"), &config, measureMonospace, &state, 3);
    try std.testing.expect(recovered.measured_words_start != null);
    try std.testing.expectEqual(@as(usize, 1), cache.entryCount());
    cache.reset();
    _ = try cache.measure(types.String.fromSlice("x y"), &config, measureMonospace, &state, 4);
    try std.testing.expectEqual(@as(usize, 2), cache.owned_words.items.len);
}

test "zero measured-word capacity still permits an empty cached string" {
    var cache = Cache.initWithLimits(std.testing.allocator, 1, 0);
    defer cache.deinit();
    var state = MonoState{};
    var config = types.TextElementConfig{};

    _ = try cache.measure(types.String.fromSlice(""), &config, measureMonospace, &state, 1);
    try std.testing.expectEqual(@as(usize, 1), cache.entryCount());
    const calls_before_failure = state.calls;
    try std.testing.expectError(
        error.TextMeasurementCapacityExceeded,
        cache.measure(types.String.fromSlice("x"), &config, measureMonospace, &state, 1),
    );
    try std.testing.expectEqual(calls_before_failure, state.calls);
}

test "missing measurement callback is reported to Context" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var config = types.TextElementConfig{};

    try std.testing.expectError(
        error.MeasureTextFunctionNotProvided,
        cache.measure(types.String.fromSlice("text"), &config, null, null, 1),
    );
}
