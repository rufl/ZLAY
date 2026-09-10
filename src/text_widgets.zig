//! Dependency-free, caller-storage-backed text input and virtual-list helpers.
//!
//! TextInput borrows a byte buffer supplied by the caller. Editing is byte
//! oriented, which keeps capacity and cursor positions deterministic even when
//! callers are building a UTF-8-aware layer above this primitive. VirtualList
//! performs only finite arithmetic and returns a half-open item range.

const std = @import("std");
const types = @import("types.zig");

pub const Error = error{
    CapacityExceeded,
    InvalidCursor,
    InvalidSelection,
    InvalidItemExtent,
    InvalidViewportExtent,
    InvalidScrollOffset,
    InvalidIndex,
    InvalidRange,
};

pub const Key = enum(u8) {
    left,
    right,
    home,
    end,
    backspace,
    delete,
    select_all,
    escape,
};

pub const Selection = struct {
    start: usize,
    end: usize,

    pub fn isEmpty(self: Selection) bool {
        return self.start == self.end;
    }

    pub fn len(self: Selection) usize {
        return self.end - self.start;
    }
};

pub const TextInput = struct {
    storage: []u8,
    length: usize = 0,
    cursor: usize = 0,
    selection_anchor: ?usize = null,

    /// Borrow caller-owned storage. The slice length is the hard byte limit.
    pub fn init(storage: []u8) TextInput {
        return .{ .storage = storage };
    }

    pub fn capacity(self: *const TextInput) usize {
        return self.storage.len;
    }

    pub fn len(self: *const TextInput) usize {
        return self.length;
    }

    pub fn isEmpty(self: *const TextInput) bool {
        return self.length == 0;
    }

    pub fn bytes(self: *const TextInput) []const u8 {
        return self.storage[0..self.length];
    }

    pub fn string(self: *const TextInput) types.String {
        return types.String.fromSlice(self.bytes());
    }

    pub fn slice(self: *const TextInput) types.StringSlice {
        return types.StringSlice.fromSlice(self.bytes());
    }

    pub fn cursorPosition(self: *const TextInput) usize {
        return self.cursor;
    }

    pub fn selectionRange(self: *const TextInput) Selection {
        const anchor = self.selection_anchor orelse return .{ .start = self.cursor, .end = self.cursor };
        return .{
            .start = @min(anchor, self.cursor),
            .end = @max(anchor, self.cursor),
        };
    }

    pub fn hasSelection(self: *const TextInput) bool {
        return !self.selectionRange().isEmpty();
    }

    pub fn selectedSlice(self: *const TextInput) types.StringSlice {
        const selected = self.selectionRange();
        return types.StringSlice.derive(self.storage, selected.start, selected.len());
    }

    /// Replace the complete value and place the cursor after the new bytes.
    pub fn setText(self: *TextInput, value: types.String) Error!void {
        return self.setSlice(value.asSlice());
    }

    pub fn setSlice(self: *TextInput, value: []const u8) Error!void {
        if (value.len > self.storage.len) return error.CapacityExceeded;
        std.mem.copyForwards(u8, self.storage[0..value.len], value);
        self.length = value.len;
        self.cursor = value.len;
        self.selection_anchor = null;
    }

    pub fn clear(self: *TextInput) void {
        self.length = 0;
        self.cursor = 0;
        self.selection_anchor = null;
    }

    pub fn clearSelection(self: *TextInput) void {
        self.selection_anchor = null;
    }

    pub fn selectAll(self: *TextInput) void {
        self.selection_anchor = 0;
        self.cursor = self.length;
    }

    pub fn setSelection(self: *TextInput, start: usize, end: usize) Error!void {
        if (start > self.length or end > self.length) return error.InvalidSelection;
        self.selection_anchor = start;
        self.cursor = end;
        if (start == end) self.selection_anchor = null;
    }

    pub fn setCursor(self: *TextInput, position: usize) Error!void {
        return self.setCursorWithSelection(position, false);
    }

    pub fn setCursorWithSelection(self: *TextInput, position: usize, extend: bool) Error!void {
        if (position > self.length) return error.InvalidCursor;
        if (extend) {
            if (self.selection_anchor == null) self.selection_anchor = self.cursor;
        } else {
            self.selection_anchor = null;
        }
        self.cursor = position;
    }

    /// Insert bytes at the cursor, replacing a selection when present.
    pub fn insert(self: *TextInput, value: []const u8) Error!void {
        const selected = self.selectionRange();
        const retained = self.length - selected.len();
        if (value.len > self.storage.len - retained) return error.CapacityExceeded;

        const tail_start = selected.end;
        const tail_len = self.length - tail_start;
        if (value.len < selected.len()) {
            std.mem.copyForwards(
                u8,
                self.storage[selected.start + value.len .. selected.start + value.len + tail_len],
                self.storage[tail_start .. tail_start + tail_len],
            );
        } else if (value.len > selected.len()) {
            std.mem.copyBackwards(
                u8,
                self.storage[selected.start + value.len .. selected.start + value.len + tail_len],
                self.storage[tail_start .. tail_start + tail_len],
            );
        }
        std.mem.copyForwards(u8, self.storage[selected.start .. selected.start + value.len], value);
        self.length = retained + value.len;
        self.cursor = selected.start + value.len;
        self.selection_anchor = null;
    }

    pub const insertSlice = insert;

    pub fn deleteSelection(self: *TextInput) bool {
        const selected = self.selectionRange();
        if (selected.isEmpty()) return false;
        self.removeRange(selected.start, selected.end);
        self.cursor = selected.start;
        self.selection_anchor = null;
        return true;
    }

    /// Handle one editing key. Return true when state changed.
    pub fn handleKey(self: *TextInput, key: Key) Error!bool {
        return self.handleKeyWithModifiers(key, false);
    }

    /// Shift extends a cursor movement into a selection. Other keys ignore the
    /// modifier; callers can use `selectAll` for platform-specific shortcuts.
    pub fn handleKeyWithModifiers(self: *TextInput, key: Key, shift: bool) Error!bool {
        return switch (key) {
            .left => self.moveHorizontal(-1, shift),
            .right => self.moveHorizontal(1, shift),
            .home => self.moveBoundary(0, shift),
            .end => self.moveBoundary(self.length, shift),
            .backspace => self.backspace(),
            .delete => self.deleteForward(),
            .select_all => blk: {
                const changed = !self.hasSelection() or self.selectionRange().start != 0 or self.selectionRange().end != self.length;
                self.selectAll();
                break :blk changed;
            },
            .escape => blk: {
                const changed = self.hasSelection();
                self.clearSelection();
                break :blk changed;
            },
        };
    }

    fn moveHorizontal(self: *TextInput, direction: i2, shift: bool) bool {
        if (!shift and self.hasSelection()) {
            const selected = self.selectionRange();
            self.cursor = if (direction < 0) selected.start else selected.end;
            self.selection_anchor = null;
            return true;
        }

        const old_cursor = self.cursor;
        const next = if (direction < 0) self.cursor -| 1 else @min(self.cursor + 1, self.length);
        if (shift) {
            if (self.selection_anchor == null) self.selection_anchor = old_cursor;
        } else {
            self.selection_anchor = null;
        }
        self.cursor = next;
        return next != old_cursor or (shift and self.selection_anchor != null);
    }

    fn moveBoundary(self: *TextInput, position: usize, shift: bool) bool {
        if (!shift and self.hasSelection()) {
            const selected = self.selectionRange();
            self.cursor = if (position == 0) selected.start else selected.end;
            self.selection_anchor = null;
            return true;
        }
        const old_cursor = self.cursor;
        if (shift and self.selection_anchor == null) self.selection_anchor = old_cursor;
        if (!shift) self.selection_anchor = null;
        self.cursor = position;
        return self.cursor != old_cursor or (shift and self.selection_anchor != null);
    }

    fn backspace(self: *TextInput) Error!bool {
        if (self.deleteSelection()) return true;
        if (self.cursor == 0) return false;
        const start = self.cursor - 1;
        self.removeRange(start, self.cursor);
        self.cursor = start;
        return true;
    }

    fn deleteForward(self: *TextInput) Error!bool {
        if (self.deleteSelection()) return true;
        if (self.cursor == self.length) return false;
        self.removeRange(self.cursor, self.cursor + 1);
        return true;
    }

    fn removeRange(self: *TextInput, start: usize, end: usize) void {
        const tail_len = self.length - end;
        if (tail_len > 0) {
            std.mem.copyForwards(u8, self.storage[start .. start + tail_len], self.storage[end .. end + tail_len]);
        }
        self.length -= end - start;
    }
};

pub const VisibleRange = struct {
    /// Half-open item indexes: `[start, end)`.
    start: usize = 0,
    end: usize = 0,

    pub fn len(self: VisibleRange) usize {
        return self.end - self.start;
    }

    pub fn isEmpty(self: VisibleRange) bool {
        return self.start == self.end;
    }
};

pub const VirtualListState = struct {
    item_count: usize,
    item_extent: f32,
    viewport_extent: f32,
    scroll_offset: f32 = 0,
    overscan: usize = 0,

    pub fn init(
        item_count: usize,
        item_extent: f32,
        viewport_extent: f32,
        scroll_offset: f32,
        overscan: usize,
    ) Error!VirtualListState {
        try validateVirtualList(item_extent, viewport_extent, scroll_offset);
        return .{
            .item_count = item_count,
            .item_extent = item_extent,
            .viewport_extent = viewport_extent,
            .scroll_offset = scroll_offset,
            .overscan = overscan,
        };
    }

    pub fn setItemCount(self: *VirtualListState, item_count: usize) void {
        self.item_count = item_count;
    }

    /// Reconciles the current offset after item-count or viewport changes.
    pub fn clampScrollOffset(self: *VirtualListState) Error!void {
        const maximum = try self.maxScrollOffset();
        if (self.scroll_offset > maximum) self.scroll_offset = maximum;
    }

    pub fn setItemExtent(self: *VirtualListState, item_extent: f32) Error!void {
        try validateVirtualList(item_extent, self.viewport_extent, self.scroll_offset);
        self.item_extent = item_extent;
    }

    pub fn setViewportExtent(self: *VirtualListState, viewport_extent: f32) Error!void {
        try validateVirtualList(self.item_extent, viewport_extent, self.scroll_offset);
        self.viewport_extent = viewport_extent;
    }

    pub fn setScrollOffset(self: *VirtualListState, scroll_offset: f32) Error!void {
        try validateVirtualList(self.item_extent, self.viewport_extent, scroll_offset);
        self.scroll_offset = scroll_offset;
    }

    pub fn scrollOffset(self: *const VirtualListState) f32 {
        return self.scroll_offset;
    }

    pub fn maxScrollOffset(self: *const VirtualListState) Error!f32 {
        try validateVirtualList(self.item_extent, self.viewport_extent, self.scroll_offset);
        const extent = @as(f64, @floatFromInt(self.item_count)) * @as(f64, self.item_extent);
        const max_offset = @max(extent - @as(f64, self.viewport_extent), 0);
        if (!std.math.isFinite(max_offset) or max_offset > std.math.floatMax(f32)) {
            return error.InvalidRange;
        }
        return @floatCast(max_offset);
    }

    /// Scrolls only when needed to reveal an item, clamped to content extent.
    pub fn scrollToIndex(self: *VirtualListState, index: usize) Error!void {
        if (index >= self.item_count) return error.InvalidIndex;
        const item_top = @as(f64, @floatFromInt(index)) * @as(f64, self.item_extent);
        const item_bottom = item_top + @as(f64, self.item_extent);
        const current = @as(f64, self.scroll_offset);
        const viewport_end = current + @as(f64, self.viewport_extent);
        const max_offset = @max(
            @as(f64, @floatFromInt(self.item_count)) * @as(f64, self.item_extent) -
                @as(f64, self.viewport_extent),
            0,
        );
        const target = if (item_top < current)
            item_top
        else if (item_bottom > viewport_end)
            item_bottom - @as(f64, self.viewport_extent)
        else
            current;
        const clamped = std.math.clamp(target, 0, max_offset);
        if (!std.math.isFinite(clamped) or clamped > std.math.floatMax(f32)) return error.InvalidRange;
        self.scroll_offset = @floatCast(clamped);
    }

    pub fn pageNext(self: *VirtualListState) Error!f32 {
        const maximum = try self.maxScrollOffset();
        const next = @min(self.scroll_offset + self.viewport_extent, maximum);
        try self.setScrollOffset(next);
        return self.scroll_offset;
    }

    pub fn pagePrevious(self: *VirtualListState) Error!f32 {
        const previous = @max(self.scroll_offset - self.viewport_extent, 0);
        try self.setScrollOffset(previous);
        return self.scroll_offset;
    }

    pub fn setOverscan(self: *VirtualListState, overscan: usize) void {
        self.overscan = overscan;
    }

    pub fn visibleRange(self: *const VirtualListState) Error!VisibleRange {
        return calculateVisibleRange(.{
            .item_count = self.item_count,
            .item_extent = self.item_extent,
            .viewport_extent = self.viewport_extent,
            .scroll_offset = self.scroll_offset,
            .overscan = self.overscan,
        });
    }
};

pub const VisibleRangeInput = struct {
    item_count: usize,
    item_extent: f32,
    viewport_extent: f32,
    scroll_offset: f32 = 0,
    overscan: usize = 0,
};

pub fn calculateVisibleRange(input: VisibleRangeInput) Error!VisibleRange {
    try validateVirtualList(input.item_extent, input.viewport_extent, input.scroll_offset);
    if (input.item_count == 0 or input.viewport_extent == 0) return .{};

    const extent = @as(f64, input.item_extent);
    const offset = @as(f64, input.scroll_offset);
    const viewport = @as(f64, input.viewport_extent);
    const viewport_end = offset + viewport;
    if (!std.math.isFinite(viewport_end)) return error.InvalidRange;

    const raw_start_float = @floor(offset / extent);
    const raw_end_float = @ceil(viewport_end / extent);
    const max_index_float: f64 = @floatFromInt(input.item_count);
    const clamped_start_float = @min(@max(raw_start_float, 0), max_index_float);
    const clamped_end_float = @min(@max(raw_end_float, 0), max_index_float);
    const visible_start: usize = @intFromFloat(clamped_start_float);
    const visible_end: usize = @intFromFloat(clamped_end_float);

    return .{
        .start = visible_start -| input.overscan,
        .end = @min(input.item_count, visible_end +| input.overscan),
    };
}
/// Stateless spelling for callers that do not need to retain list inputs.
pub const visibleRange = calculateVisibleRange;

fn validateVirtualList(item_extent: f32, viewport_extent: f32, scroll_offset: f32) Error!void {
    if (!std.math.isFinite(item_extent) or item_extent <= 0) return error.InvalidItemExtent;
    if (!std.math.isFinite(viewport_extent) or viewport_extent < 0) return error.InvalidViewportExtent;
    if (!std.math.isFinite(scroll_offset) or scroll_offset < 0) return error.InvalidScrollOffset;
}

test "text input inserts, moves, selects, and edits within caller capacity" {
    var storage: [8]u8 = undefined;
    var input = TextInput.init(&storage);
    try input.setSlice("abcd");
    try input.setCursor(0);
    _ = try input.handleKeyWithModifiers(.right, true);
    _ = try input.handleKeyWithModifiers(.right, true);
    try std.testing.expectEqualStrings("ab", input.selectedSlice().asSlice());
    try input.insert("X");
    try std.testing.expectEqualStrings("Xcd", input.bytes());
    try std.testing.expectEqual(@as(usize, 1), input.cursorPosition());
    _ = try input.handleKey(.backspace);
    try std.testing.expectEqualStrings("cd", input.bytes());
    _ = try input.handleKey(.delete);
    try std.testing.expectEqualStrings("d", input.bytes());
}

test "text input preserves state on capacity failure and handles selection deletion" {
    var storage: [3]u8 = undefined;
    var input = TextInput.init(&storage);
    try input.setText(types.String.literal("abc"));
    try std.testing.expectError(error.CapacityExceeded, input.insert("x"));
    try std.testing.expectEqualStrings("abc", input.bytes());
    try input.setSelection(1, 3);
    try std.testing.expect(input.deleteSelection());
    try std.testing.expectEqualStrings("a", input.bytes());
    try std.testing.expectEqual(@as(usize, 1), input.cursorPosition());
    try std.testing.expectError(error.InvalidSelection, input.setSelection(0, 2));
}

test "virtual list range clamps boundaries and applies overscan" {
    const range = try calculateVisibleRange(.{
        .item_count = 100,
        .item_extent = 10,
        .viewport_extent = 25,
        .scroll_offset = 20,
        .overscan = 2,
    });
    try std.testing.expectEqual(@as(usize, 0), range.start);
    try std.testing.expectEqual(@as(usize, 7), range.end);

    const tail = try (try VirtualListState.init(5, 10, 20, 100, 3)).visibleRange();
    try std.testing.expectEqual(@as(usize, 2), tail.start);
    try std.testing.expectEqual(@as(usize, 5), tail.end);
}

test "virtual list scrollToIndex reveals and clamps target items" {
    var list = try VirtualListState.init(10, 20, 60, 0, 0);
    try std.testing.expectEqual(@as(f32, 140), try list.maxScrollOffset());
    try std.testing.expectEqual(@as(f32, 0), list.scrollOffset());
    try list.scrollToIndex(3);
    try std.testing.expectEqual(@as(f32, 20), list.scroll_offset);
    try list.scrollToIndex(4);
    try std.testing.expectEqual(@as(f32, 40), list.scroll_offset);
    try list.scrollToIndex(9);
    try std.testing.expectEqual(@as(f32, 140), list.scroll_offset);
    try std.testing.expectError(error.InvalidIndex, list.scrollToIndex(10));
}

test "virtual list offset reconciliation follows item-count shrink" {
    var list = try VirtualListState.init(10, 20, 60, 140, 0);
    list.setItemCount(2);
    try list.clampScrollOffset();
    try std.testing.expectEqual(@as(f32, 0), list.scrollOffset());
    list.setItemCount(10);
    try list.setScrollOffset(140);
    try list.setViewportExtent(100);
    try list.clampScrollOffset();
    try std.testing.expectEqual(@as(f32, 100), list.scrollOffset());
}

test "virtual list page navigation clamps at both ends" {
    var list = try VirtualListState.init(10, 20, 60, 0, 0);
    try std.testing.expectEqual(@as(f32, 60), try list.pageNext());
    try std.testing.expectEqual(@as(f32, 120), try list.pageNext());
    try std.testing.expectEqual(@as(f32, 140), try list.pageNext());
    try std.testing.expectEqual(@as(f32, 80), try list.pagePrevious());
    try std.testing.expectEqual(@as(f32, 20), try list.pagePrevious());
    try std.testing.expectEqual(@as(f32, 0), try list.pagePrevious());
}

test "virtual list rejects non-finite and non-positive geometry" {
    try std.testing.expectError(error.InvalidItemExtent, VirtualListState.init(1, 0, 10, 0, 0));
    try std.testing.expectError(error.InvalidViewportExtent, VirtualListState.init(1, 10, -1, 0, 0));
    try std.testing.expectError(error.InvalidScrollOffset, VirtualListState.init(1, 10, 10, -1, 0));
    try std.testing.expectError(error.InvalidItemExtent, VirtualListState.init(1, std.math.nan(f32), 10, 0, 0));
    try std.testing.expectError(error.InvalidViewportExtent, VirtualListState.init(1, 10, std.math.inf(f32), 0, 0));
}
