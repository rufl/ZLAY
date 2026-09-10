//! Dependency-free, caller-storage-backed interaction state.
//!
//! `Interaction` owns no memory. The caller supplies an `ElementId` slice that
//! is used as the registration list. Registration order is the keyboard focus
//! order; unregistering an element compacts the list without changing the
//! relative order of the remaining elements.

const std = @import("std");
const types = @import("types.zig");

pub const ElementId = types.ElementId;

pub const Error = error{
    CapacityExceeded,
    NotRegistered,
};

pub const Navigation = enum(u8) {
    wrap,
    clamp,
};

pub const EventKind = enum(u8) {
    keyboard,
    pointer,
};

pub const PointerPhase = enum(u8) {
    down,
    move,
    up,
    cancel,
};

pub const Event = struct {
    kind: EventKind,
    /// Hit-test result used when no pointer capture is active.
    hit_target: ?ElementId = null,
    pointer_phase: PointerPhase = .move,
};

pub const DispatchKind = enum(u8) {
    none,
    focused,
    captured,
    hit_test,
};

pub const DispatchDecision = struct {
    target: ?ElementId = null,
    kind: DispatchKind = .none,

    pub fn handled(self: DispatchDecision) bool {
        return self.target != null;
    }
};

pub const Interaction = struct {
    storage: []ElementId,
    count: usize = 0,
    focused_id: ?ElementId = null,
    hovered_id: ?ElementId = null,
    captured_id: ?ElementId = null,
    /// Borrow `storage`; it must remain alive and unmoved for this state.
    pub fn init(storage: []ElementId) Interaction {
        return .{ .storage = storage };
    }

    pub fn capacity(self: *const Interaction) usize {
        return self.storage.len;
    }

    pub fn len(self: *const Interaction) usize {
        return self.count;
    }

    pub fn registered(self: *const Interaction) []const ElementId {
        return self.storage[0..self.count];
    }

    pub fn contains(self: *const Interaction, id: ElementId) bool {
        return self.indexOf(id) != null;
    }

    /// Add a focusable element at the end of registration order. Re-registering
    /// an existing ID is idempotent and does not move it.
    pub fn register(self: *Interaction, id: ElementId) Error!void {
        if (self.indexOf(id) != null) return;
        if (self.count == self.storage.len) return error.CapacityExceeded;
        self.storage[self.count] = id;
        self.count += 1;
    }

    pub fn unregister(self: *Interaction, id: ElementId) bool {
        const index = self.indexOf(id) orelse return false;
        const last = self.count - 1;
        if (index < last) {
            std.mem.copyForwards(ElementId, self.storage[index..last], self.storage[index + 1 .. self.count]);
        }
        self.count = last;
        if (sameId(self.focused_id, id)) self.focused_id = null;
        if (sameId(self.captured_id, id)) self.captured_id = null;
        if (sameId(self.hovered_id, id)) self.hovered_id = null;
        return true;
    }

    /// Start a frame with no registered elements or stale interaction state.
    /// The caller then registers the frame's focusable elements in order.
    pub fn resetFrame(self: *Interaction) void {
        self.count = 0;
        self.focused_id = null;
        self.captured_id = null;
        self.hovered_id = null;
    }

    pub fn reset(self: *Interaction) void {
        self.resetFrame();
    }

    pub fn focused(self: *const Interaction) ?ElementId {
        if (self.focused_id) |id| {
            if (self.contains(id)) return id;
        }
        return null;
    }

    pub fn hovered(self: *const Interaction) ?ElementId {
        if (self.hovered_id) |id| {
            if (self.contains(id)) return id;
        }
        return null;
    }

    /// Set the current hover target; null clears it.
    pub fn setHovered(self: *Interaction, id: ?ElementId) bool {
        if (id) |value| {
            if (!self.contains(value)) return false;
        }
        self.hovered_id = id;
        return true;
    }

    pub fn focus(self: *Interaction, id: ElementId) bool {
        if (!self.contains(id)) return false;
        self.focused_id = id;
        return true;
    }

    pub fn clearFocus(self: *Interaction) void {
        self.focused_id = null;
    }

    pub fn focusedIndex(self: *const Interaction) ?usize {
        return self.focusIndex();
    }

    /// Focus the registered element at `index`; out-of-range clears focus.
    pub fn focusAt(self: *Interaction, index: usize) ?ElementId {
        if (index >= self.count) {
            self.focused_id = null;
            return null;
        }
        self.focused_id = self.storage[index];
        return self.focused_id;
    }

    pub fn focusFirst(self: *Interaction) ?ElementId {
        if (self.count == 0) {
            self.focused_id = null;
            return null;
        }
        self.focused_id = self.storage[0];
        return self.focused_id;
    }

    pub fn focusLast(self: *Interaction) ?ElementId {
        if (self.count == 0) {
            self.focused_id = null;
            return null;
        }
        self.focused_id = self.storage[self.count - 1];
        return self.focused_id;
    }

    /// Move forward, wrapping from the last element to the first.
    pub fn focusNext(self: *Interaction) ?ElementId {
        return self.focusNextWithMode(.wrap);
    }

    /// Move backward, wrapping from the first element to the last.
    pub fn focusPrevious(self: *Interaction) ?ElementId {
        return self.focusPreviousWithMode(.wrap);
    }

    pub fn focusNextClamped(self: *Interaction) ?ElementId {
        return self.focusNextWithMode(.clamp);
    }

    pub fn focusPreviousClamped(self: *Interaction) ?ElementId {
        return self.focusPreviousWithMode(.clamp);
    }

    pub fn focusNextWithMode(self: *Interaction, mode: Navigation) ?ElementId {
        if (self.count == 0) {
            self.focused_id = null;
            return null;
        }
        const current = self.focusIndex();
        const next = if (current) |index| blk: {
            if (index + 1 < self.count) break :blk index + 1;
            break :blk switch (mode) {
                .wrap => 0,
                .clamp => index,
            };
        } else 0;
        self.focused_id = self.storage[next];
        return self.focused_id;
    }

    pub fn focusPreviousWithMode(self: *Interaction, mode: Navigation) ?ElementId {
        if (self.count == 0) {
            self.focused_id = null;
            return null;
        }
        const current = self.focusIndex();
        const previous = if (current) |index| blk: {
            if (index > 0) break :blk index - 1;
            break :blk switch (mode) {
                .wrap => self.count - 1,
                .clamp => 0,
            };
        } else self.count - 1;
        self.focused_id = self.storage[previous];
        return self.focused_id;
    }

    /// Capture pointer events for a registered element.
    pub fn capturePointer(self: *Interaction, id: ElementId) Error!void {
        if (!self.contains(id)) return error.NotRegistered;
        self.captured_id = id;
    }

    pub fn releasePointer(self: *Interaction) ?ElementId {
        const previous = self.captured_id;
        self.captured_id = null;
        return previous;
    }

    pub fn pointerCaptureOwner(self: *const Interaction) ?ElementId {
        if (self.captured_id) |id| {
            if (self.contains(id)) return id;
        }
        return null;
    }

    /// Decide which registered element receives an event. Keyboard events use
    /// focus; pointer events use capture first and then the hit-test result.
    /// This helper does not mutate capture state; release it explicitly after a
    /// pointer-up/cancel event with `releasePointer`.
    pub fn dispatch(self: *const Interaction, event: Event) DispatchDecision {
        return switch (event.kind) {
            .keyboard => if (self.focused()) |id|
                .{ .target = id, .kind = .focused }
            else
                .{},
            .pointer => if (self.pointerCaptureOwner()) |id|
                .{ .target = id, .kind = .captured }
            else if (event.hit_target) |id| if (self.contains(id))
                .{ .target = id, .kind = .hit_test }
            else
                .{} else .{},
        };
    }

    /// Update hover from a pointer hit and dispatch using current capture.
    /// Invalid or absent hits clear hover; capture still takes precedence.
    pub fn dispatchPointer(self: *Interaction, event: Event) DispatchDecision {
        std.debug.assert(event.kind == .pointer);
        const hover_target = if (event.hit_target) |id| if (self.contains(id)) id else null else null;
        _ = self.setHovered(hover_target);
        return self.dispatch(event);
    }

    pub fn dispatchTarget(self: *const Interaction, event: Event) ?ElementId {
        return self.dispatch(event).target;
    }

    pub fn shouldDispatch(self: *const Interaction, event: Event, id: ElementId) bool {
        const decision = self.dispatch(event);
        return if (decision.target) |target| sameId(target, id) else false;
    }

    fn indexOf(self: *const Interaction, id: ElementId) ?usize {
        for (self.storage[0..self.count], 0..) |candidate, index| {
            if (sameId(candidate, id)) return index;
        }
        return null;
    }

    fn focusIndex(self: *const Interaction) ?usize {
        const id = self.focused_id orelse return null;
        return self.indexOf(id);
    }
};

fn sameId(left: ?ElementId, right: ElementId) bool {
    return if (left) |value| value.id == right.id else false;
}

test "registration preserves order and duplicate IDs are stable" {
    var storage: [3]ElementId = undefined;
    var state = Interaction.init(&storage);
    const first = ElementId{ .id = 11 };
    const second = ElementId{ .id = 22 };
    const third = ElementId{ .id = 33 };
    try state.register(first);
    try state.register(second);
    try state.register(first);
    try state.register(third);
    try std.testing.expectEqualSlices(ElementId, &.{ first, second, third }, state.registered());
}

test "focus navigation wraps and clamps" {
    var storage: [3]ElementId = undefined;
    var state = Interaction.init(&storage);
    const first = ElementId{ .id = 1 };
    const second = ElementId{ .id = 2 };
    const third = ElementId{ .id = 3 };
    try state.register(first);
    try state.register(second);
    try state.register(third);

    try std.testing.expectEqual(first, state.focusNext());
    try std.testing.expectEqual(second, state.focusNext());
    try std.testing.expectEqual(third, state.focusNext());
    try std.testing.expectEqual(first, state.focusNext());
    try std.testing.expectEqual(third, state.focusPrevious());
    try std.testing.expectEqual(third, state.focusNextClamped());
    try std.testing.expectEqual(third, state.focusNextClamped());
    try std.testing.expectEqual(second, state.focusPreviousClamped());
}

test "unregister clears stale focus and capture while preserving order" {
    var storage: [3]ElementId = undefined;
    var state = Interaction.init(&storage);
    const first = ElementId{ .id = 1 };
    const second = ElementId{ .id = 2 };
    const third = ElementId{ .id = 3 };
    try state.register(first);
    try state.register(second);
    try state.register(third);
    try std.testing.expect(state.focus(second));
    try state.capturePointer(second);
    try std.testing.expect(state.unregister(second));
    try std.testing.expect(state.focused() == null);
    try std.testing.expect(state.pointerCaptureOwner() == null);
    try std.testing.expectEqualSlices(ElementId, &.{ first, third }, state.registered());
}

test "capture routes before hit testing and releases" {
    var storage: [2]ElementId = undefined;
    var state = Interaction.init(&storage);
    const captured = ElementId{ .id = 7 };
    const hit = ElementId{ .id = 8 };
    try state.register(captured);
    try state.register(hit);
    try state.capturePointer(captured);
    const captured_decision = state.dispatch(.{ .kind = .pointer, .hit_target = hit });
    try std.testing.expectEqual(captured, captured_decision.target.?);
    try std.testing.expectEqual(DispatchKind.captured, captured_decision.kind);
    try std.testing.expectEqual(captured, state.releasePointer().?);
    const hit_decision = state.dispatch(.{ .kind = .pointer, .hit_target = hit });
    try std.testing.expectEqual(hit, hit_decision.target.?);
    try std.testing.expectEqual(DispatchKind.hit_test, hit_decision.kind);
}

test "hover-aware pointer dispatch tracks valid hits and preserves capture" {
    var storage: [3]ElementId = undefined;
    var state = Interaction.init(&storage);
    const captured = ElementId{ .id = 7 };
    const hit = ElementId{ .id = 8 };
    const stale = ElementId{ .id = 99 };
    try state.register(captured);
    try state.register(hit);
    try state.capturePointer(captured);
    const captured_decision = state.dispatchPointer(.{ .kind = .pointer, .hit_target = hit });
    try std.testing.expectEqual(captured, captured_decision.target.?);
    try std.testing.expectEqual(hit, state.hovered().?);
    const invalid_decision = state.dispatchPointer(.{ .kind = .pointer, .hit_target = stale });
    try std.testing.expectEqual(captured, invalid_decision.target.?);
    try std.testing.expect(state.hovered() == null);
    try std.testing.expectEqual(DispatchKind.captured, invalid_decision.kind);
}

test "keyboard dispatch follows focus and invalid hit targets are rejected" {
    var storage: [1]ElementId = undefined;
    var state = Interaction.init(&storage);
    const focused = ElementId{ .id = 4 };
    const stale = ElementId{ .id = 99 };
    try state.register(focused);
    const no_focus = state.dispatch(.{ .kind = .keyboard });
    try std.testing.expect(!no_focus.handled());
    try std.testing.expect(state.focus(focused));
    try std.testing.expect(state.shouldDispatch(.{ .kind = .keyboard }, focused));
    const invalid_hit = state.dispatch(.{ .kind = .pointer, .hit_target = stale });
    try std.testing.expect(!invalid_hit.handled());
}

test "focus first and last handle empty and stale focus" {
    var storage: [2]ElementId = undefined;
    var state = Interaction.init(&storage);
    try std.testing.expect(state.focusFirst() == null);
    const first = ElementId{ .id = 10 };
    const last = ElementId{ .id = 20 };
    try state.register(first);
    try state.register(last);
    try std.testing.expectEqual(first, state.focusFirst().?);
    try std.testing.expectEqual(last, state.focusLast().?);
    state.focused_id = .{ .id = 99 };
    try std.testing.expectEqual(first, state.focusFirst().?);
    state.resetFrame();
    try std.testing.expect(state.focusLast() == null);
}

test "indexed focus selection reports stable registration positions" {
    var storage: [2]ElementId = undefined;
    var state = Interaction.init(&storage);
    const first = ElementId{ .id = 10 };
    const last = ElementId{ .id = 20 };
    try state.register(first);
    try state.register(last);
    try std.testing.expect(state.focusedIndex() == null);
    try std.testing.expectEqual(last, state.focusAt(1).?);
    try std.testing.expectEqual(@as(usize, 1), state.focusedIndex().?);
    try std.testing.expect(state.focusAt(2) == null);
    try std.testing.expect(state.focused() == null);
}

test "hover tracking validates targets and clears with lifecycle" {
    var storage: [2]ElementId = undefined;
    var state = Interaction.init(&storage);
    const first = ElementId{ .id = 1 };
    const second = ElementId{ .id = 2 };
    const stale = ElementId{ .id = 99 };
    try state.register(first);
    try state.register(second);
    try std.testing.expect(!state.setHovered(stale));
    try std.testing.expect(state.hovered() == null);
    try std.testing.expect(state.setHovered(first));
    try std.testing.expectEqual(first, state.hovered().?);
    try std.testing.expect(state.unregister(first));
    try std.testing.expect(state.hovered() == null);
    try std.testing.expect(state.setHovered(second));
    state.resetFrame();
    try std.testing.expect(state.hovered() == null);
}

test "registration capacity is bounded and reset starts a new frame" {
    var storage: [1]ElementId = undefined;
    var state = Interaction.init(&storage);
    try state.register(.{ .id = 1 });
    try std.testing.expectError(error.CapacityExceeded, state.register(.{ .id = 2 }));
    state.resetFrame();
    try std.testing.expectEqual(@as(usize, 0), state.len());
    try std.testing.expect(state.focused() == null);
    try std.testing.expect(state.pointerCaptureOwner() == null);
    try state.register(.{ .id = 2 });
    try std.testing.expectEqual(@as(u32, 2), state.registered()[0].id);
}
