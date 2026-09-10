//! Dependency-free, caller-storage-backed widget state primitives.
//!
//! These types intentionally contain state only. Rendering and layout remain
//! the caller's responsibility; `ElementId` values can be used with the
//! interaction and retained-layout modules without coupling either module to
//! widget policy.

const std = @import("std");
const interaction = @import("interaction.zig");

pub const ElementId = interaction.ElementId;
pub const Navigation = interaction.Navigation;

pub const Error = error{
    CapacityExceeded,
    InvalidIndex,
    Empty,
};

/// Keyboard inputs understood by the state primitives. Pointer hit-testing is
/// performed by `interaction.Interaction`; a caller reports a resulting
/// activation with `.activate`.
pub const Key = enum(u8) {
    enter,
    space,
    left,
    right,
    up,
    down,
    home,
    end,
    escape,
};

pub const Event = union(enum) {
    key: Key,
    activate,
};

pub const Button = struct {
    id: ElementId,
    enabled: bool = true,
    activated: bool = false,

    pub fn init(id: ElementId) Button {
        return .{ .id = id };
    }

    pub fn setEnabled(self: *Button, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn isEnabled(self: *const Button) bool {
        return self.enabled;
    }

    /// Mark the button activated and return whether the activation was
    /// accepted. Activation is latched until `consumeActivation` or `reset`.
    pub fn activate(self: *Button) bool {
        if (!self.enabled) return false;
        self.activated = true;
        return true;
    }

    pub fn handle(self: *Button, event: Event) bool {
        return switch (event) {
            .activate => self.activate(),
            .key => |key| switch (key) {
                .enter, .space => self.activate(),
                else => false,
            },
        };
    }

    /// Dispatch an interaction event after the caller has registered and
    /// focused/hit-tested this button. Keyboard events are activation signals
    /// here; key-specific handling is available through `handle`.
    pub fn dispatch(
        self: *Button,
        state: *const interaction.Interaction,
        event: interaction.Event,
    ) bool {
        if (!state.shouldDispatch(event, self.id)) return false;
        if (event.kind == .pointer and event.pointer_phase != .up) return false;
        return self.activate();
    }

    pub fn consumeActivation(self: *Button) bool {
        const was_activated = self.activated;
        self.activated = false;
        return was_activated;
    }

    pub fn reset(self: *Button) void {
        self.activated = false;
    }

    pub fn register(self: *const Button, state: *interaction.Interaction) interaction.Error!void {
        try state.register(self.id);
    }
};

/// Renderer-neutral checkbox state driven by keyboard or pointer activation.
pub const Checkbox = struct {
    id: ElementId,
    enabled: bool = true,
    checked: bool = false,

    pub fn init(id: ElementId, checked: bool) Checkbox {
        return .{ .id = id, .checked = checked };
    }

    pub fn setEnabled(self: *Checkbox, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn isChecked(self: *const Checkbox) bool {
        return self.checked;
    }

    pub fn setChecked(self: *Checkbox, checked: bool) void {
        self.checked = checked;
    }

    pub fn toggle(self: *Checkbox) bool {
        if (!self.enabled) return false;
        self.checked = !self.checked;
        return true;
    }

    pub fn handle(self: *Checkbox, event: Event) bool {
        return switch (event) {
            .activate => self.toggle(),
            .key => |key| switch (key) {
                .enter, .space => self.toggle(),
                else => false,
            },
        };
    }

    pub fn dispatch(
        self: *Checkbox,
        state: *const interaction.Interaction,
        event: interaction.Event,
    ) bool {
        if (!state.shouldDispatch(event, self.id)) return false;
        if (event.kind == .pointer and event.pointer_phase != .up) return false;
        return self.toggle();
    }

    pub fn register(self: *const Checkbox, state: *interaction.Interaction) interaction.Error!void {
        try state.register(self.id);
    }
};

/// A bounded ordered collection of tab IDs and its selected index.
pub const Tabs = struct {
    storage: []ElementId,
    count: usize = 0,
    selected_index: ?usize = null,

    /// Borrow caller-owned storage. The slice length is the hard tab limit.
    pub fn init(storage: []ElementId) Tabs {
        return .{ .storage = storage };
    }

    pub fn capacity(self: *const Tabs) usize {
        return self.storage.len;
    }

    pub fn len(self: *const Tabs) usize {
        return self.count;
    }

    pub fn items(self: *const Tabs) []const ElementId {
        return self.storage[0..self.count];
    }

    pub fn append(self: *Tabs, id: ElementId) Error!void {
        if (self.count == self.storage.len) return error.CapacityExceeded;
        self.storage[self.count] = id;
        self.count += 1;
        if (self.selected_index == null) self.selected_index = 0;
    }

    pub const add = append;

    pub fn selectedIndex(self: *const Tabs) ?usize {
        return self.selected_index;
    }

    pub fn selectedId(self: *const Tabs) ?ElementId {
        const index = self.selected_index orelse return null;
        if (index >= self.count) return null;
        return self.storage[index];
    }

    pub fn select(self: *Tabs, index: usize) Error!void {
        if (index >= self.count) return error.InvalidIndex;
        self.selected_index = index;
    }

    pub fn moveNext(self: *Tabs, mode: Navigation) Error!usize {
        if (self.count == 0) return error.Empty;
        const current = self.selected_index orelse 0;
        const next = if (current + 1 < self.count) current + 1 else switch (mode) {
            .wrap => 0,
            .clamp => current,
        };
        self.selected_index = next;
        return next;
    }

    pub fn movePrevious(self: *Tabs, mode: Navigation) Error!usize {
        if (self.count == 0) return error.Empty;
        const current = self.selected_index orelse 0;
        const previous = if (current > 0) current - 1 else switch (mode) {
            .wrap => self.count - 1,
            .clamp => 0,
        };
        self.selected_index = previous;
        return previous;
    }

    pub fn handleKey(self: *Tabs, key: Key, mode: Navigation) Error!bool {
        return switch (key) {
            .left, .up => blk: {
                _ = try self.movePrevious(mode);
                break :blk true;
            },
            .right, .down => blk: {
                _ = try self.moveNext(mode);
                break :blk true;
            },
            .home => blk: {
                if (self.count == 0) return error.Empty;
                self.selected_index = 0;
                break :blk true;
            },
            .end => blk: {
                if (self.count == 0) return error.Empty;
                self.selected_index = self.count - 1;
                break :blk true;
            },
            else => false,
        };
    }

    pub fn register(self: *const Tabs, state: *interaction.Interaction) interaction.Error!void {
        for (self.items()) |id| try state.register(id);
    }
};

/// Single-selection registration-order state for radio controls.
/// The API mirrors `Tabs` because both widgets share selection semantics.
pub const RadioGroup = Tabs;

/// Bounded list selection state. The list values are IDs supplied by the
/// caller, so selection can be handed directly to interaction/layout code.
pub const ListState = struct {
    storage: []ElementId,
    count: usize = 0,
    selected_index: ?usize = null,

    pub fn init(storage: []ElementId) ListState {
        return .{ .storage = storage };
    }

    pub fn capacity(self: *const ListState) usize {
        return self.storage.len;
    }

    pub fn len(self: *const ListState) usize {
        return self.count;
    }

    pub fn items(self: *const ListState) []const ElementId {
        return self.storage[0..self.count];
    }

    pub fn append(self: *ListState, id: ElementId) Error!void {
        if (self.count == self.storage.len) return error.CapacityExceeded;
        self.storage[self.count] = id;
        self.count += 1;
        if (self.selected_index == null) self.selected_index = 0;
    }

    pub const add = append;

    pub fn selectedIndex(self: *const ListState) ?usize {
        return self.selected_index;
    }

    pub fn selectedId(self: *const ListState) ?ElementId {
        const index = self.selected_index orelse return null;
        if (index >= self.count) return null;
        return self.storage[index];
    }

    pub fn select(self: *ListState, index: usize) Error!void {
        if (index >= self.count) return error.InvalidIndex;
        self.selected_index = index;
    }

    pub fn moveNext(self: *ListState, mode: Navigation) Error!usize {
        if (self.count == 0) return error.Empty;
        const current = self.selected_index orelse 0;
        const next = if (current + 1 < self.count) current + 1 else switch (mode) {
            .wrap => 0,
            .clamp => current,
        };
        self.selected_index = next;
        return next;
    }

    pub fn movePrevious(self: *ListState, mode: Navigation) Error!usize {
        if (self.count == 0) return error.Empty;
        const current = self.selected_index orelse 0;
        const previous = if (current > 0) current - 1 else switch (mode) {
            .wrap => self.count - 1,
            .clamp => 0,
        };
        self.selected_index = previous;
        return previous;
    }

    pub fn handleKey(self: *ListState, key: Key, mode: Navigation) Error!bool {
        return switch (key) {
            .up, .left => blk: {
                _ = try self.movePrevious(mode);
                break :blk true;
            },
            .down, .right => blk: {
                _ = try self.moveNext(mode);
                break :blk true;
            },
            .home => blk: {
                if (self.count == 0) return error.Empty;
                self.selected_index = 0;
                break :blk true;
            },
            .end => blk: {
                if (self.count == 0) return error.Empty;
                self.selected_index = self.count - 1;
                break :blk true;
            },
            else => false,
        };
    }

    pub fn register(self: *const ListState, state: *interaction.Interaction) interaction.Error!void {
        for (self.items()) |id| try state.register(id);
    }
};

/// Modal visibility state. Opening and closing are idempotent and report
/// whether the visibility actually changed.
pub const Dialog = struct {
    id: ElementId = .{},
    is_open: bool = false,

    pub fn init(id: ElementId) Dialog {
        return .{ .id = id };
    }

    pub fn open(self: *Dialog) bool {
        if (self.is_open) return false;
        self.is_open = true;
        return true;
    }

    pub fn close(self: *Dialog) bool {
        if (!self.is_open) return false;
        self.is_open = false;
        return true;
    }

    pub fn toggle(self: *Dialog) bool {
        if (self.is_open) return self.close();
        return self.open();
    }

    pub fn isOpen(self: *const Dialog) bool {
        return self.is_open;
    }

    pub fn handleKey(self: *Dialog, key: Key) bool {
        return if (key == .escape and self.is_open) self.close() else false;
    }

    pub fn register(self: *const Dialog, state: *interaction.Interaction) interaction.Error!void {
        try state.register(self.id);
    }
};

test "button activation accepts activation keys and can be consumed" {
    var button = Button.init(.{ .id = 10 });
    try std.testing.expect(button.handle(.{ .key = .enter }));
    try std.testing.expect(button.activated);
    try std.testing.expect(button.consumeActivation());
    try std.testing.expect(!button.consumeActivation());
    button.setEnabled(false);
    try std.testing.expect(!button.handle(.activate));
    try std.testing.expect(!button.handle(.{ .key = .space }));
}

test "button dispatch follows interaction focus and pointer release" {
    var ids: [1]ElementId = undefined;
    var interaction_state = interaction.Interaction.init(&ids);
    const id = ElementId{ .id = 20 };
    try interaction_state.register(id);
    try std.testing.expect(interaction_state.focus(id));
    var button = Button.init(id);
    try std.testing.expect(button.dispatch(&interaction_state, .{ .kind = .keyboard }));
    button.reset();
    try std.testing.expect(!button.dispatch(&interaction_state, .{ .kind = .pointer, .hit_target = id, .pointer_phase = .down }));
    try std.testing.expect(button.dispatch(&interaction_state, .{ .kind = .pointer, .hit_target = id, .pointer_phase = .up }));
}

test "checkbox toggles through keys and pointer release" {
    var checkbox = Checkbox.init(.{ .id = 30 }, false);
    try std.testing.expect(!checkbox.isChecked());
    try std.testing.expect(checkbox.handle(.{ .key = .space }));
    try std.testing.expect(checkbox.isChecked());
    var ids: [1]ElementId = undefined;
    var state = interaction.Interaction.init(&ids);
    try checkbox.register(&state);
    try std.testing.expect(!checkbox.dispatch(&state, .{ .kind = .pointer, .hit_target = checkbox.id, .pointer_phase = .down }));
    try std.testing.expect(checkbox.dispatch(&state, .{ .kind = .pointer, .hit_target = checkbox.id, .pointer_phase = .up }));
    try std.testing.expect(!checkbox.isChecked());
    checkbox.setEnabled(false);
    try std.testing.expect(!checkbox.toggle());
    try std.testing.expect(!checkbox.isChecked());
}

test "tabs select and move with wrap and clamp" {
    var storage: [2]ElementId = undefined;
    var tabs = Tabs.init(&storage);
    try tabs.append(.{ .id = 1 });
    try tabs.append(.{ .id = 2 });
    try std.testing.expectError(error.CapacityExceeded, tabs.append(.{ .id = 3 }));
    try tabs.select(1);
    try std.testing.expectEqual(@as(usize, 0), try tabs.moveNext(.wrap));
    try std.testing.expectEqual(@as(usize, 0), try tabs.movePrevious(.clamp));
    try std.testing.expectError(error.InvalidIndex, tabs.select(2));
    try std.testing.expect(try tabs.handleKey(.end, .clamp));
    try std.testing.expectEqual(@as(usize, 1), tabs.selectedIndex().?);
}

test "radio group preserves single selection semantics" {
    var storage: [2]ElementId = undefined;
    var radios = RadioGroup.init(&storage);
    try radios.append(.{ .id = 11 });
    try radios.append(.{ .id = 22 });
    try radios.select(1);
    try std.testing.expectEqual(@as(u32, 22), radios.selectedId().?.id);
    try std.testing.expectEqual(@as(usize, 0), try radios.movePrevious(.clamp));
}

test "list keyboard movement and empty errors are deterministic" {
    var storage: [3]ElementId = undefined;
    var list = ListState.init(&storage);
    try list.append(.{ .id = 11 });
    try list.append(.{ .id = 22 });
    try list.append(.{ .id = 33 });
    try std.testing.expect(try list.handleKey(.down, .clamp));
    try std.testing.expectEqual(@as(usize, 1), list.selectedIndex().?);
    try std.testing.expectEqual(@as(usize, 2), try list.moveNext(.clamp));
    try std.testing.expectEqual(@as(usize, 2), try list.moveNext(.clamp));
    _ = try list.movePrevious(.wrap);
    try std.testing.expectEqual(@as(u32, 22), list.selectedId().?.id);

    var empty_storage: [0]ElementId = .{};
    var empty = ListState.init(&empty_storage);
    try std.testing.expectError(error.Empty, empty.moveNext(.wrap));
    try std.testing.expectError(error.InvalidIndex, empty.select(0));
}

test "dialog open close and escape handling" {
    var dialog = Dialog.init(.{ .id = 40 });
    try std.testing.expect(!dialog.isOpen());
    try std.testing.expect(dialog.open());
    try std.testing.expect(!dialog.open());
    try std.testing.expect(dialog.handleKey(.escape));
    try std.testing.expect(!dialog.isOpen());
    try std.testing.expect(!dialog.handleKey(.escape));
    try std.testing.expect(!dialog.close());
    try std.testing.expect(dialog.toggle());
    try std.testing.expect(dialog.isOpen());
    try std.testing.expect(dialog.toggle());
    try std.testing.expect(!dialog.isOpen());
}
