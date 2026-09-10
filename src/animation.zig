//! Dependency-free, fixed-capacity animation timelines.
//!
//! Timeline storage is always supplied explicitly: `init` borrows caller-owned
//! keyframe storage, while `initWithAllocator` allocates one fixed-capacity
//! keyframe buffer. Evaluation never allocates and interpolates through the
//! existing Clay-compatible transition helpers.

const std = @import("std");
const types = @import("types.zig");
const transition = @import("transition.zig");

pub const Easing = *const fn (progress: f32) f32;

pub fn linear(progress: f32) f32 {
    return progress;
}

pub fn easeInOut(progress: f32) f32 {
    // Smoothstep is deterministic, bounded, and useful as a dependency-free
    // default for callers that do not need a custom easing callback.
    return progress * progress * (3.0 - 2.0 * progress);
}

pub const State = enum(u8) {
    idle,
    running,
    completed,
    cancelled,
};

pub const Error = error{
    InvalidDuration,
    InvalidDelay,
    InvalidTime,
    InvalidKeyframeTime,
    CapacityExceeded,
    EmptyTimeline,
    InvalidState,
    InvalidEasing,
    DurationOverflow,
};

pub const Keyframe = struct {
    /// Time in seconds from the beginning of one cycle.
    time: f32,
    value: types.TransitionData,
};

pub const Config = struct {
    /// Length of each cycle. Must be finite and greater than zero.
    duration: f32,
    /// Time before the first cycle starts. Must be finite and non-negative.
    delay: f32 = 0,
    /// Number of additional cycles after the first cycle.
    repeat_count: u32 = 0,
    /// Start from the final keyframe and play toward the first keyframe.
    reverse: bool = false,
    /// Reverse direction after every repeated cycle.
    alternate: bool = false,
    /// Properties copied/interpolated from each keyframe pair.
    properties: types.TransitionProperty = .bounding_box,
    easing: Easing = linear,
};

pub const Sample = struct {
    value: types.TransitionData,
    state: State,
    /// Elapsed time including delay, clamped to the finite timeline range.
    elapsed: f32,
    /// Zero-based cycle index, clamped to the final cycle after completion.
    cycle: u32,
    /// Eased progress in the selected direction for the current cycle.
    progress: f32,
    delayed: bool,
    complete: bool,
};

pub const Timeline = struct {
    keyframes: []Keyframe,
    keyframe_count: usize = 0,
    config: Config,
    state: State = .idle,
    elapsed_time: f32 = 0,
    allocator: ?std.mem.Allocator = null,

    /// Borrow `storage`; it must remain alive and unmoved for this timeline.
    pub fn init(storage: []Keyframe, options: Config) Error!Timeline {
        try validateConfig(options);
        return .{ .keyframes = storage, .config = options };
    }
    pub fn initWithAllocator(
        allocator: std.mem.Allocator,
        keyframe_capacity: usize,
        options: Config,
    ) (Error || std.mem.Allocator.Error)!Timeline {
        try validateConfig(options);
        const storage = try allocator.alloc(Keyframe, keyframe_capacity);
        return .{
            .keyframes = storage,
            .config = options,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Timeline) void {
        if (self.allocator) |allocator| allocator.free(self.keyframes);
        self.keyframes = &.{};
        self.keyframe_count = 0;
        self.allocator = null;
    }

    pub fn capacity(self: *const Timeline) usize {
        return self.keyframes.len;
    }

    pub fn keyframesSlice(self: *const Timeline) []const Keyframe {
        return self.keyframes[0..self.keyframe_count];
    }

    /// Append a keyframe in non-decreasing time order.
    pub fn addKeyframe(self: *Timeline, keyframe: Keyframe) Error!void {
        if (!std.math.isFinite(keyframe.time) or keyframe.time < 0 or keyframe.time > self.config.duration) {
            return error.InvalidKeyframeTime;
        }
        if (self.keyframe_count == self.keyframes.len) return error.CapacityExceeded;
        if (self.keyframe_count > 0 and keyframe.time < self.keyframes[self.keyframe_count - 1].time) {
            return error.InvalidKeyframeTime;
        }
        self.keyframes[self.keyframe_count] = keyframe;
        self.keyframe_count += 1;
    }

    pub fn append(self: *Timeline, keyframe: Keyframe) Error!void {
        return self.addKeyframe(keyframe);
    }

    pub fn start(self: *Timeline) Error!Sample {
        if (self.keyframe_count == 0) return error.EmptyTimeline;
        if (self.state == .running) return error.InvalidState;
        if (self.state == .completed or self.state == .cancelled) return error.InvalidState;
        self.elapsed_time = 0;
        self.state = .running;
        return self.sampleAt(0);
    }

    pub fn reset(self: *Timeline) void {
        self.elapsed_time = 0;
        self.state = .idle;
    }

    pub fn cancel(self: *Timeline) void {
        if (self.state == .running or self.state == .idle) self.state = .cancelled;
    }

    /// Advance by a non-negative finite delta. A timeline must be started
    /// first; cancelled and completed timelines remain terminal and return
    /// their current sample unchanged.
    pub fn advance(self: *Timeline, delta_seconds: f32) Error!Sample {
        if (!std.math.isFinite(delta_seconds) or delta_seconds < 0) return error.InvalidTime;
        if (self.keyframe_count == 0) return error.EmptyTimeline;
        if (self.state == .idle) return error.InvalidState;
        if (self.state == .cancelled or self.state == .completed) return self.sampleAt(self.elapsed_time);

        const next = @as(f64, self.elapsed_time) + @as(f64, delta_seconds);
        const total = self.totalDuration();
        self.elapsed_time = if (next >= total) self.totalDurationF32() else @floatCast(next);
        if (next >= total) self.state = .completed;
        return self.sampleAt(self.elapsed_time);
    }

    /// Evaluate a timeline position without changing its state or allocating.
    /// Input is elapsed time from the call to `start`, including delay.
    pub fn sampleAt(self: *const Timeline, elapsed_seconds: f32) Error!Sample {
        if (!std.math.isFinite(elapsed_seconds) or elapsed_seconds < 0) return error.InvalidTime;
        if (self.keyframe_count == 0) return error.EmptyTimeline;
        if (!std.math.isFinite(self.config.easing(0.0))) return error.InvalidEasing;

        const total = self.totalDuration();
        const clamped = @min(@as(f64, elapsed_seconds), total);
        const delayed = clamped < @as(f64, self.config.delay);
        const final_cycle = self.totalCycles() - 1;
        var cycle: u32 = 0;
        var local: f32 = 0;
        var complete = false;

        if (delayed) {
            local = 0;
        } else {
            const after_delay = clamped - @as(f64, self.config.delay);
            const cycle_f = @floor(after_delay / @as(f64, self.config.duration));
            cycle = @intFromFloat(@min(cycle_f, @as(f64, @floatFromInt(final_cycle))));
            const in_cycle = after_delay - @as(f64, @floatFromInt(cycle)) * @as(f64, self.config.duration);
            const at_end = clamped >= total;
            local = if (at_end) self.config.duration else @floatCast(in_cycle);
            complete = at_end;
        }

        var backwards = self.config.reverse;
        if (self.config.alternate and (cycle % 2 == 1)) backwards = !backwards;
        const value = self.interpolate(local, backwards);
        const output_state: State = if (self.state == .cancelled) .cancelled else if (self.state == .completed or complete) .completed else .running;
        const progress = if (self.config.duration == 0) 1.0 else local / self.config.duration;
        return .{
            .value = value,
            .state = output_state,
            .elapsed = @floatCast(clamped),
            .cycle = cycle,
            .progress = if (backwards) 1.0 - progress else progress,
            .delayed = delayed,
            .complete = output_state == .completed,
        };
    }

    pub fn evaluate(self: *const Timeline, elapsed_seconds: f32) Error!Sample {
        return self.sampleAt(elapsed_seconds);
    }

    pub fn valueAt(self: *const Timeline, elapsed_seconds: f32) Error!types.TransitionData {
        return (try self.sampleAt(elapsed_seconds)).value;
    }

    fn interpolate(self: *const Timeline, local_time: f32, backwards: bool) types.TransitionData {
        const position = if (backwards) self.config.duration - local_time else local_time;
        if (position <= self.keyframes[0].time) return self.keyframes[0].value;
        const last = self.keyframe_count - 1;
        if (position >= self.keyframes[last].time) return self.keyframes[last].value;

        var upper: usize = 1;
        while (upper < self.keyframe_count and position > self.keyframes[upper].time) : (upper += 1) {}
        const lower = upper - 1;
        const lower_frame = self.keyframes[lower];
        const upper_frame = self.keyframes[upper];
        const span = upper_frame.time - lower_frame.time;
        const ratio = if (span <= 0) 1.0 else (position - lower_frame.time) / span;
        const eased = self.config.easing(ratio);
        // Invalid easing is surfaced by sampleAt before this helper is called
        // for the common initial check; non-finite callback values are mapped
        // to the lower endpoint to keep value evaluation deterministic.
        const safe_eased = if (std.math.isFinite(eased)) eased else 0;
        return transition.interpolateProperties(
            lower_frame.value,
            lower_frame.value,
            upper_frame.value,
            self.config.properties,
            safe_eased,
        );
    }

    fn totalCycles(self: *const Timeline) u32 {
        return self.config.repeat_count + 1;
    }

    fn totalDuration(self: *const Timeline) f64 {
        return @as(f64, self.config.delay) + @as(f64, @floatFromInt(self.totalCycles())) * @as(f64, self.config.duration);
    }

    fn totalDurationF32(self: *const Timeline) f32 {
        return @floatCast(self.totalDuration());
    }

    fn validateConfig(options: Config) Error!void {
        if (!std.math.isFinite(options.duration) or options.duration <= 0) return error.InvalidDuration;
        if (!std.math.isFinite(options.delay) or options.delay < 0) return error.InvalidDelay;
        const total = @as(f64, options.delay) + @as(f64, @floatFromInt(options.repeat_count + 1)) * @as(f64, options.duration);
        if (total > @as(f64, std.math.floatMax(f32))) return error.DurationOverflow;
        if (!std.math.isFinite(options.easing(0.0))) return error.InvalidEasing;
    }
};

fn frame(time: f32, x: f32) Keyframe {
    return .{ .time = time, .value = .{ .bounding_box = .{ .x = x } } };
}

fn testConfig(duration: f32) Config {
    return .{ .duration = duration, .properties = .x };
}

test "timeline interpolates selected TransitionData properties" {
    var storage: [2]Keyframe = undefined;
    var timeline = try Timeline.init(&storage, testConfig(1));
    try timeline.addKeyframe(frame(0, 0));
    try timeline.addKeyframe(frame(1, 100));
    _ = try timeline.start();
    const sample = try timeline.advance(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 50), sample.value.bounding_box.x, 0.001);
    try std.testing.expectEqual(State.running, sample.state);
}

test "delay and completion produce deterministic terminal state" {
    var storage: [2]Keyframe = undefined;
    var timeline = try Timeline.init(&storage, .{ .duration = 1, .delay = 0.25, .properties = .x });
    try timeline.addKeyframe(frame(0, 2));
    try timeline.addKeyframe(frame(1, 8));
    _ = try timeline.start();
    const delayed = try timeline.advance(0.1);
    try std.testing.expect(delayed.delayed);
    try std.testing.expectApproxEqAbs(@as(f32, 2), delayed.value.bounding_box.x, 0.001);
    const done = try timeline.advance(1.2);
    try std.testing.expectEqual(State.completed, done.state);
    try std.testing.expect(done.complete);
    try std.testing.expectApproxEqAbs(@as(f32, 8), done.value.bounding_box.x, 0.001);
}

test "repeat and alternating reverse traverse every cycle" {
    var storage: [2]Keyframe = undefined;
    var timeline = try Timeline.init(&storage, .{ .duration = 1, .repeat_count = 1, .alternate = true, .properties = .x });
    try timeline.addKeyframe(frame(0, 0));
    try timeline.addKeyframe(frame(1, 10));
    _ = try timeline.start();
    _ = try timeline.advance(1.25);
    const first_repeat = try timeline.sampleAt(1.25);
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), first_repeat.value.bounding_box.x, 0.001);
    const second = try timeline.advance(0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 5), second.value.bounding_box.x, 0.001);
    const done = try timeline.advance(0.5);
    try std.testing.expectEqual(State.completed, done.state);
    try std.testing.expectApproxEqAbs(@as(f32, 0), done.value.bounding_box.x, 0.001);
}

test "reverse starts at the final keyframe and rejects non-finite time" {
    var storage: [2]Keyframe = undefined;
    var timeline = try Timeline.init(&storage, .{ .duration = 1, .reverse = true, .properties = .x });
    try timeline.addKeyframe(frame(0, 0));
    try timeline.addKeyframe(frame(1, 10));
    const initial = try timeline.start();
    try std.testing.expectApproxEqAbs(@as(f32, 10), initial.value.bounding_box.x, 0.001);
    try std.testing.expectError(error.InvalidTime, timeline.advance(std.math.nan(f32)));
    try std.testing.expectError(error.InvalidTime, timeline.sampleAt(std.math.inf(f32)));
}

test "caller storage capacity and keyframe ordering are enforced" {
    var storage: [1]Keyframe = undefined;
    var timeline = try Timeline.init(&storage, testConfig(1));
    try timeline.addKeyframe(frame(0, 0));
    try std.testing.expectError(error.CapacityExceeded, timeline.addKeyframe(frame(1, 1)));

    var larger: [2]Keyframe = undefined;
    var ordered = try Timeline.init(&larger, testConfig(1));
    try ordered.addKeyframe(frame(0.75, 1));
    try std.testing.expectError(error.InvalidKeyframeTime, ordered.addKeyframe(frame(0.5, 2)));
}
