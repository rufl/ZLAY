//! Renderer-neutral accessibility metadata and reduced-motion policy.
//!
//! This module owns no memory. Metadata strings and registry entries are
//! borrowed from caller-owned storage and remain valid only for their stated
//! lifetimes.

const std = @import("std");
const types = @import("types.zig");

pub const ElementId = types.ElementId;
pub const StringSlice = types.StringSlice;

/// Application-selected motion preference. No environment or platform state
/// is queried here; callers choose the policy and apply the result to their
/// animation machinery.
pub const ReducedMotionPolicy = enum(u8) {
    full,
    reduced,

    pub fn shouldAnimate(self: ReducedMotionPolicy) bool {
        return self == .full;
    }

    /// Return the requested duration, or zero when motion must be reduced.
    /// A zero duration is intentional: reduced-motion callers should apply the
    /// final value instead of starting a timeline that requires a duration.
    pub fn duration(self: ReducedMotionPolicy, normal_duration: f32) f32 {
        return if (self == .reduced) 0 else normal_duration;
    }

    /// Convert elapsed time to clamped normalized progress. Reduced motion
    /// always settles at one, independent of elapsed time or duration.
    pub fn progress(
        self: ReducedMotionPolicy,
        elapsed_seconds: f32,
        duration_seconds: f32,
    ) f32 {
        if (self == .reduced) return 1.0;
        if (!std.math.isFinite(elapsed_seconds)) {
            return if (elapsed_seconds > 0) 1.0 else 0.0;
        }
        if (!std.math.isFinite(duration_seconds) or duration_seconds <= 0) return 1.0;
        return clampProgress(elapsed_seconds / duration_seconds);
    }

    /// Return a normalized progress value suitable for committing an
    /// animation result. Reduced motion deterministically commits the final
    /// progress; full motion preserves the current value after clamping.
    pub fn settle(self: ReducedMotionPolicy, current_progress: f32) f32 {
        return if (self == .reduced) 1.0 else clampProgress(current_progress);
    }

    pub fn decision(self: ReducedMotionPolicy) MotionDecision {
        return if (self.shouldAnimate()) .animate else .settle;
    }
};

pub const MotionDecision = union(enum) {
    animate,
    settle,
};

pub fn shouldAnimate(policy: ReducedMotionPolicy) bool {
    return policy.shouldAnimate();
}

pub fn effectiveDuration(policy: ReducedMotionPolicy, normal_duration: f32) f32 {
    return policy.duration(normal_duration);
}

pub fn progressAt(
    policy: ReducedMotionPolicy,
    elapsed_seconds: f32,
    duration_seconds: f32,
) f32 {
    return policy.progress(elapsed_seconds, duration_seconds);
}

pub fn settleProgress(policy: ReducedMotionPolicy, current_progress: f32) f32 {
    return policy.settle(current_progress);
}

fn clampProgress(progress: f32) f32 {
    if (std.math.isNan(progress)) return 0;
    if (progress <= 0) return 0;
    if (progress >= 1) return 1;
    return progress;
}

/// Semantic role understood by consumers of WidgetMetadata. The values are
/// intentionally renderer-neutral and do not imply an ARIA or OS mapping.
pub const Role = enum(u8) {
    none,
    generic,
    button,
    checkbox,
    combobox,
    dialog,
    heading,
    image,
    link,
    list,
    list_item,
    menu,
    menu_item,
    progress_bar,
    radio,
    radio_group,
    scrollbar,
    search,
    slider,
    spin_button,
    tab,
    tab_list,
    text,
    text_input,
    tooltip,
    tree,
    tree_item,
};

/// Individual semantic state bits carried by State.
pub const StateFlag = enum(u4) {
    disabled,
    focused,
    pressed,
    selected,
    checked,
    expanded,
    modal,
    busy,
    invalid,
    hidden,
};

/// Compact bitfield of semantic widget states.
pub const State = packed struct {
    disabled: bool = false,
    focused: bool = false,
    pressed: bool = false,
    selected: bool = false,
    checked: bool = false,
    expanded: bool = false,
    modal: bool = false,
    busy: bool = false,
    invalid: bool = false,
    hidden: bool = false,

    pub fn has(self: State, flag: StateFlag) bool {
        return switch (flag) {
            .disabled => self.disabled,
            .focused => self.focused,
            .pressed => self.pressed,
            .selected => self.selected,
            .checked => self.checked,
            .expanded => self.expanded,
            .modal => self.modal,
            .busy => self.busy,
            .invalid => self.invalid,
            .hidden => self.hidden,
        };
    }

    pub fn set(self: *State, flag: StateFlag, value: bool) void {
        switch (flag) {
            .disabled => self.disabled = value,
            .focused => self.focused = value,
            .pressed => self.pressed = value,
            .selected => self.selected = value,
            .checked => self.checked = value,
            .expanded => self.expanded = value,
            .modal => self.modal = value,
            .busy => self.busy = value,
            .invalid => self.invalid = value,
            .hidden => self.hidden = value,
        }
    }

    pub fn with(self: State, flag: StateFlag) State {
        var result = self;
        result.set(flag, true);
        return result;
    }

    pub fn without(self: State, flag: StateFlag) State {
        var result = self;
        result.set(flag, false);
        return result;
    }
};

pub const StateSet = State;

/// Semantic metadata whose textual fields borrow their supplied StringSlice
/// storage. An absent label or description is represented by null.
pub const WidgetMetadata = struct {
    id: ElementId,
    role: Role = .none,
    label: ?StringSlice = null,
    description: ?StringSlice = null,
    states: State = .{},

    pub fn init(id: ElementId, role: Role) WidgetMetadata {
        return .{ .id = id, .role = role };
    }

    pub fn hasState(self: *const WidgetMetadata, flag: StateFlag) bool {
        return self.states.has(flag);
    }
};

pub const Error = error{
    CapacityExceeded,
    DuplicateId,
};

/// Fixed-capacity metadata registry backed entirely by caller-owned storage.
pub const Registry = struct {
    storage: []WidgetMetadata,
    count: usize = 0,

    pub fn init(storage: []WidgetMetadata) Registry {
        return .{ .storage = storage };
    }

    pub fn capacity(self: *const Registry) usize {
        return self.storage.len;
    }

    pub fn len(self: *const Registry) usize {
        return self.count;
    }

    pub fn items(self: *const Registry) []const WidgetMetadata {
        return self.storage[0..self.count];
    }

    /// Add metadata in registration order. IDs are unique registry keys.
    pub fn register(self: *Registry, metadata: WidgetMetadata) Error!void {
        if (self.indexOf(metadata.id) != null) return error.DuplicateId;
        if (self.count == self.storage.len) return error.CapacityExceeded;
        self.storage[self.count] = metadata;
        self.count += 1;
    }

    /// Replace an existing entry while retaining its registry identity.
    pub fn update(self: *Registry, id: ElementId, metadata: WidgetMetadata) bool {
        const index = self.indexOf(id) orelse return false;
        var replacement = metadata;
        replacement.id = id;
        self.storage[index] = replacement;
        return true;
    }

    /// Remove an entry and compact later entries without changing order.
    pub fn remove(self: *Registry, id: ElementId) bool {
        const index = self.indexOf(id) orelse return false;
        const last = self.count - 1;
        if (index < last) {
            std.mem.copyForwards(
                WidgetMetadata,
                self.storage[index..last],
                self.storage[index + 1 .. self.count],
            );
        }
        self.count = last;
        return true;
    }

    pub fn query(self: *const Registry, id: ElementId) ?*const WidgetMetadata {
        const index = self.indexOf(id) orelse return null;
        return &self.storage[index];
    }

    /// Return the first registered metadata entry with `role`.
    pub fn firstByRole(self: *const Registry, role: Role) ?*const WidgetMetadata {
        for (self.items()) |*metadata| {
            if (metadata.role == role) return metadata;
        }
        return null;
    }

    pub fn countByRole(self: *const Registry, role: Role) usize {
        var count: usize = 0;
        for (self.items()) |metadata| {
            if (metadata.role == role) count += 1;
        }
        return count;
    }

    pub const find = query;

    pub fn contains(self: *const Registry, id: ElementId) bool {
        return self.indexOf(id) != null;
    }

    pub fn clear(self: *Registry) void {
        self.count = 0;
    }

    fn indexOf(self: *const Registry, id: ElementId) ?usize {
        for (self.storage[0..self.count], 0..) |candidate, index| {
            if (candidate.id.id == id.id) return index;
        }
        return null;
    }
};

test "reduced motion settles and full motion computes bounded progress" {
    try std.testing.expect(ReducedMotionPolicy.full.shouldAnimate());
    try std.testing.expect(!ReducedMotionPolicy.reduced.shouldAnimate());
    try std.testing.expectEqual(@as(f32, 2.5), ReducedMotionPolicy.full.duration(2.5));
    try std.testing.expectEqual(@as(f32, 0), ReducedMotionPolicy.reduced.duration(2.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), ReducedMotionPolicy.full.progress(0.5, 2), 0.0001);
    try std.testing.expectEqual(@as(f32, 1), ReducedMotionPolicy.full.progress(4, 2));
    try std.testing.expectEqual(@as(f32, 1), ReducedMotionPolicy.reduced.progress(0, 2));
    try std.testing.expectEqual(@as(f32, 1), ReducedMotionPolicy.reduced.settle(0.17));
    try std.testing.expectEqual(MotionDecision.settle, ReducedMotionPolicy.reduced.decision());
}

test "state flags are independently set and cleared" {
    var state = State{};
    try std.testing.expect(!state.has(.focused));
    state.set(.focused, true);
    state.set(.disabled, true);
    try std.testing.expect(state.focused);
    try std.testing.expect(state.has(.disabled));
    try std.testing.expect(state.without(.focused).has(.disabled));
    try std.testing.expect(!state.without(.focused).has(.focused));
}

test "metadata registry supports capacity, update, removal, and query" {
    var storage: [2]WidgetMetadata = undefined;
    var registry = Registry.init(&storage);
    const first = ElementId{ .id = 11 };
    const second = ElementId{ .id = 22 };
    try registry.register(.{ .id = first, .role = .button, .label = StringSlice.fromSlice("Save") });
    try registry.register(.{ .id = second, .role = .text_input });
    try std.testing.expectError(error.CapacityExceeded, registry.register(.{ .id = .{ .id = 33 } }));
    try std.testing.expectError(error.DuplicateId, registry.register(.{ .id = first }));
    try std.testing.expect(registry.query(first) != null);
    try std.testing.expect(registry.update(first, .{ .id = first, .role = .link, .states = .{ .focused = true } }));
    try std.testing.expectEqual(Role.link, registry.find(first).?.role);
    try std.testing.expect(registry.remove(first));
    try std.testing.expectEqual(@as(usize, 1), registry.len());
    try std.testing.expectEqual(second, registry.items()[0].id);
    try std.testing.expect(registry.query(first) == null);
    try std.testing.expect(!registry.remove(first));
}

test "metadata role queries preserve registration order" {
    var storage: [3]WidgetMetadata = undefined;
    var registry = Registry.init(&storage);
    const first = ElementId{ .id = 1 };
    const second = ElementId{ .id = 2 };
    const third = ElementId{ .id = 3 };
    try registry.register(.{ .id = first, .role = .button });
    try registry.register(.{ .id = second, .role = .link });
    try registry.register(.{ .id = third, .role = .button });
    try std.testing.expectEqual(first, registry.firstByRole(.button).?.id);
    try std.testing.expectEqual(@as(usize, 2), registry.countByRole(.button));
    try std.testing.expect(registry.firstByRole(.slider) == null);
    try std.testing.expectEqual(@as(usize, 0), registry.countByRole(.slider));
}
