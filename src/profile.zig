//! Fixed-buffer allocation high-water instrumentation.
//!
//! This is a profiling aid, not a byte-for-byte replacement for Clay's arena
//! partitioning or `Clay_MinMemorySize`. It wraps Zig's fixed-buffer allocator
//! and records the highest live end offset observed after every successful
//! allocation, resize, or remap.

const std = @import("std");

pub const Snapshot = struct {
    capacity_bytes: usize,
    current_bytes: usize,
    peak_bytes: usize,
    successful_allocations: usize,
    failed_allocations: usize,

    pub fn headroomBytes(self: Snapshot) usize {
        return self.capacity_bytes -| self.peak_bytes;
    }
};

pub const FixedBufferProfiler = struct {
    fixed: std.heap.FixedBufferAllocator,
    peak_end_index: usize = 0,
    successful_allocations: usize = 0,
    failed_allocations: usize = 0,

    pub fn init(buffer: []u8) FixedBufferProfiler {
        return .{ .fixed = std.heap.FixedBufferAllocator.init(buffer) };
    }

    pub fn allocator(self: *FixedBufferProfiler) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn snapshot(self: *const FixedBufferProfiler) Snapshot {
        return .{
            .capacity_bytes = self.fixed.buffer.len,
            .current_bytes = self.fixed.end_index,
            .peak_bytes = self.peak_end_index,
            .successful_allocations = self.successful_allocations,
            .failed_allocations = self.failed_allocations,
        };
    }

    /// Invalidates all outstanding allocations and starts a fresh run using
    /// the same storage. Peak and counters are reset as well.
    pub fn reset(self: *FixedBufferProfiler) void {
        self.fixed.end_index = 0;
        self.peak_end_index = 0;
        self.successful_allocations = 0;
        self.failed_allocations = 0;
    }

    fn observe(self: *FixedBufferProfiler) void {
        self.peak_end_index = @max(self.peak_end_index, self.fixed.end_index);
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FixedBufferProfiler = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.alloc(&self.fixed, len, alignment, return_address);
        if (result == null) {
            self.failed_allocations += 1;
        } else {
            self.successful_allocations += 1;
            self.observe();
        }
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *FixedBufferProfiler = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.resize(&self.fixed, memory, alignment, new_len, return_address);
        if (result) self.observe();
        return result;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FixedBufferProfiler = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.remap(&self.fixed, memory, alignment, new_len, return_address);
        if (result != null) self.observe();
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *FixedBufferProfiler = @ptrCast(@alignCast(context));
        std.heap.FixedBufferAllocator.free(&self.fixed, memory, alignment, return_address);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "fixed-buffer profiler retains actual allocation high-water" {
    var storage: [128]u8 = undefined;
    var profiler = FixedBufferProfiler.init(&storage);
    const allocator = profiler.allocator();

    const first = try allocator.alloc(u8, 16);
    const second = try allocator.alloc(u8, 24);
    const at_peak = profiler.snapshot();
    try std.testing.expect(at_peak.peak_bytes >= 40);
    try std.testing.expectEqual(at_peak.current_bytes, at_peak.peak_bytes);
    try std.testing.expectEqual(@as(usize, 2), at_peak.successful_allocations);

    allocator.free(second);
    allocator.free(first);
    const after_free = profiler.snapshot();
    try std.testing.expectEqual(@as(usize, 0), after_free.current_bytes);
    try std.testing.expectEqual(at_peak.peak_bytes, after_free.peak_bytes);
    try std.testing.expectEqual(storage.len - at_peak.peak_bytes, after_free.headroomBytes());
}

test "fixed-buffer profiler counts failed allocation attempts" {
    var storage: [8]u8 = undefined;
    var profiler = FixedBufferProfiler.init(&storage);
    try std.testing.expectError(error.OutOfMemory, profiler.allocator().alloc(u8, 16));
    try std.testing.expectEqual(@as(usize, 1), profiler.snapshot().failed_allocations);

    profiler.reset();
    try std.testing.expectEqual(Snapshot{
        .capacity_bytes = storage.len,
        .current_bytes = 0,
        .peak_bytes = 0,
        .successful_allocations = 0,
        .failed_allocations = 0,
    }, profiler.snapshot());
}
