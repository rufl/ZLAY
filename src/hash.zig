//! Native hashing used by Clay IDs and the text measurement cache.
//!
//! This follows the target-selected code paths in Clay 0.14 at commit
//! e6cc36941ab2af5d81107617039d6f527a1c660b. The x86_64 and AArch64 data hashes
//! use portable two-lane operations with the pinned target-specific chunking;
//! other targets use the scalar path. All arithmetic is explicitly wrapping so
//! Debug and release builds have the same `uint32_t`/`uint64_t` behavior as the
//! upstream implementation.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

inline fn mix32(hash: *u32, value: u32) void {
    hash.* +%= value;
    hash.* +%= hash.* << 10;
    hash.* ^= hash.* >> 6;
}

inline fn finish32(hash: u32) u32 {
    var result = hash;
    result +%= result << 3;
    result ^= result >> 11;
    result +%= result << 15;
    return result;
}

inline fn mix64(hash: *u64, value: u64) void {
    hash.* +%= value;
    hash.* +%= hash.* << 10;
    hash.* ^= hash.* >> 6;
}

const LanePair = [2]u64;

const simd_initial_0: LanePair = @splat(0x6a09e667f3bcc908);
const simd_initial_1: LanePair = @splat(0xbb67ae8584caa73b);
const simd_initial_2: LanePair = @splat(0x3c6ef372fe94f82b);
const simd_initial_3: LanePair = @splat(0xa54ff53a5f1d36f1);

inline fn rotateLeft17(value: u64) u64 {
    return (value << 17) | (value >> 47);
}

inline fn laneArxMix(a: *LanePair, b: *LanePair) void {
    for (0..2) |lane| {
        a[lane] +%= b[lane];
        b[lane] = rotateLeft17(b[lane]) ^ a[lane];
    }
}

inline fn laneAdd(a: *LanePair, b: LanePair) void {
    for (0..2) |lane| a[lane] +%= b[lane];
}

inline fn loadLanePair(bytes: *const [16]u8, endian: std.builtin.Endian) LanePair {
    return .{
        std.mem.readInt(u64, bytes[0..8], endian),
        std.mem.readInt(u64, bytes[8..16], endian),
    };
}

inline fn loadLowerLane(bytes: *const [8]u8, endian: std.builtin.Endian) LanePair {
    return .{ std.mem.readInt(u64, bytes, endian), 0 };
}

inline fn simdRound(v0: *LanePair, v1: *LanePair, v2: *LanePair, v3: *LanePair) void {
    laneArxMix(v0, v1);
    laneArxMix(v2, v3);
    laneAdd(v0, v2.*);
    laneAdd(v1, v3.*);
}

inline fn finishSimd(v0: *LanePair, v1: *LanePair, v2: *LanePair, v3: *LanePair) u64 {
    simdRound(v0, v1, v2, v3);
    laneAdd(v0, v1.*);
    return v0[0] ^ v0[1];
}

/// Clay hashes element-ID strings through plain C `char`. Match the default C
/// ABI signedness for the active target before integer promotion so high-bit
/// bytes agree with the pinned implementation on that target.
inline fn cCharValue(byte: u8) u32 {
    if (builtin.target.cCharSignedness() == .unsigned) return byte;
    const signed_byte: i8 = @bitCast(byte);
    const promoted: i32 = signed_byte;
    return @bitCast(promoted);
}

fn stringBytes(value: types.String) []const u8 {
    return value.asSlice();
}

/// Hashes a numeric child offset using the supplied parent/seed ID.
pub fn number(offset: u32, seed: u32) types.ElementId {
    var hash = seed;
    mix32(&hash, offset +% 48);
    hash = finish32(hash);

    return .{
        .id = hash +% 1,
        .offset = offset,
        .base_id = seed,
        .string_id = .{},
    };
}

/// Hashes a string ID with no numeric offset.
pub fn string(key: types.String, seed: u32) types.ElementId {
    var hash = seed;
    for (stringBytes(key)) |byte| {
        mix32(&hash, cCharValue(byte));
    }
    hash = finish32(hash);

    const id = hash +% 1;
    return .{
        .id = id,
        .offset = 0,
        .base_id = id,
        .string_id = key,
    };
}

/// Hashes a string ID and a numeric offset while retaining the un-offset base
/// hash in `ElementId.base_id`.
pub fn stringWithOffset(key: types.String, offset: u32, seed: u32) types.ElementId {
    var base = seed;
    for (stringBytes(key)) |byte| {
        mix32(&base, cCharValue(byte));
    }

    var hash = base;
    mix32(&hash, offset);

    hash +%= hash << 3;
    base +%= base << 3;
    hash ^= hash >> 11;
    base ^= base >> 11;
    hash +%= hash << 15;
    base +%= base << 15;

    return .{
        .id = hash +% 1,
        .offset = offset,
        .base_id = base +% 1,
        .string_id = key,
    };
}

/// Scalar byte hash used when SIMD hashing is disabled upstream.
pub fn dataScalar(bytes: []const u8) u64 {
    var hash: u64 = 0;
    for (bytes) |byte| {
        mix64(&hash, byte);
    }
    return hash;
}

fn dataX86_64(bytes: []const u8) u64 {
    var v0 = simd_initial_0;
    var v1 = simd_initial_1;
    var v2 = simd_initial_2;
    var v3 = simd_initial_3;
    var offset: usize = 0;
    var remaining = bytes.len;

    while (remaining > 0) {
        var overflow_buffer: [16]u8 = @splat(0);
        const msg = if (remaining >= 16) block: {
            const chunk: *const [16]u8 = @ptrCast(bytes[offset..][0..16]);
            offset += 16;
            remaining -= 16;
            break :block loadLanePair(chunk, .little);
        } else block: {
            @memcpy(overflow_buffer[0..remaining], bytes[offset..][0..remaining]);
            remaining = 0;
            break :block loadLanePair(&overflow_buffer, .little);
        };

        v0[0] ^= msg[0];
        v0[1] ^= msg[1];
        simdRound(&v0, &v1, &v2, &v3);
    }

    return finishSimd(&v0, &v1, &v2, &v3);
}

fn dataAarch64(bytes: []const u8, endian: std.builtin.Endian) u64 {
    var v0 = simd_initial_0;
    var v1 = simd_initial_1;
    var v2 = simd_initial_2;
    var v3 = simd_initial_3;
    var offset: usize = 0;
    var remaining = bytes.len;
    var overflow_buffer: [8]u8 = @splat(0);

    while (remaining > 0) {
        const msg = if (remaining > 16) block: {
            const chunk: *const [16]u8 = @ptrCast(bytes[offset..][0..16]);
            offset += 16;
            remaining -= 16;
            break :block loadLanePair(chunk, endian);
        } else if (remaining > 8) block: {
            const chunk: *const [8]u8 = @ptrCast(bytes[offset..][0..8]);
            offset += 8;
            remaining -= 8;
            break :block loadLowerLane(chunk, endian);
        } else block: {
            @memcpy(overflow_buffer[0..remaining], bytes[offset..][0..remaining]);
            remaining = 0;
            break :block loadLowerLane(&overflow_buffer, endian);
        };

        v0[0] ^= msg[0];
        v0[1] ^= msg[1];
        simdRound(&v0, &v1, &v2, &v3);
    }

    return finishSimd(&v0, &v1, &v2, &v3);
}

/// Hash bytes through the same target-default branch selected by pinned Clay.
pub fn data(bytes: []const u8) u64 {
    return switch (builtin.target.cpu.arch) {
        .x86_64 => dataX86_64(bytes),
        .aarch64, .aarch64_be => dataAarch64(bytes, builtin.target.cpu.arch.endian()),
        else => dataScalar(bytes),
    };
}

fn textWithConfigUsingDataHash(
    comptime data_hash: fn ([]const u8) u64,
    text: types.String,
    config: types.TextElementConfig,
) u32 {
    var hash: u32 = 0;

    if (text.is_statically_allocated) {
        const pointer_bits: u32 = @truncate(@intFromPtr(text.chars.ptr));
        mix32(&hash, pointer_bits);
        mix32(&hash, @bitCast(text.length));
    } else {
        const uint32_max: u64 = std.math.maxInt(u32);
        hash = @intCast(data_hash(stringBytes(text)) % uint32_max);
    }

    mix32(&hash, config.font_id);
    mix32(&hash, config.font_size);
    mix32(&hash, config.letter_spacing);
    return finish32(hash) +% 1;
}

/// Hashes text contents and the subset of text configuration that affects
/// glyph measurement in upstream Clay: font ID, font size, and letter spacing.
///
/// Static strings intentionally hash their backing address and length, matching
/// Clay's lifetime-based cache optimization. Non-static strings hash their
/// bytes, which produces deterministic cache IDs across processes.
pub fn textWithConfig(text: types.String, config: types.TextElementConfig) u32 {
    return textWithConfigUsingDataHash(data, text, config);
}

/// Scalar text/config hash used by `CLAY_DISABLE_SIMD` oracle vectors.
pub fn textWithConfigScalar(text: types.String, config: types.TextElementConfig) u32 {
    return textWithConfigUsingDataHash(dataScalar, text, config);
}

test "number matches pinned scalar C oracle vectors" {
    const vectors = [_]struct {
        offset: u32,
        seed: u32,
        id: u32,
    }{
        .{ .offset = 0, .seed = 0, .id = 1_849_449_580 },
        .{ .offset = 1, .seed = 0, .id = 2_154_528_970 },
        .{ .offset = std.math.maxInt(u32), .seed = 0, .id = 1_518_810_370 },
        .{ .offset = 42, .seed = 123_456_789, .id = 1_880_489_172 },
    };

    for (vectors) |vector| {
        const actual = number(vector.offset, vector.seed);
        try std.testing.expectEqual(vector.id, actual.id);
        try std.testing.expectEqual(vector.offset, actual.offset);
        try std.testing.expectEqual(vector.seed, actual.base_id);
        try std.testing.expectEqual(@as(i32, 0), actual.string_id.length);
    }
}

test "string matches pinned scalar C oracle vectors" {
    const vectors = [_]struct {
        bytes: []const u8,
        seed: u32,
        id: u32,
    }{
        .{ .bytes = "", .seed = 0, .id = 1 },
        .{ .bytes = "Clay", .seed = 0, .id = 2_115_332_899 },
        .{ .bytes = "Clay", .seed = 123, .id = 3_306_422_561 },
        .{ .bytes = "Clay__RootContainer", .seed = 0, .id = 2_268_583_112 },
    };

    for (vectors) |vector| {
        const key = types.String.fromSlice(vector.bytes);
        const actual = string(key, vector.seed);
        try std.testing.expectEqual(vector.id, actual.id);
        try std.testing.expectEqual(@as(u32, 0), actual.offset);
        try std.testing.expectEqual(vector.id, actual.base_id);
        try std.testing.expectEqualStrings(vector.bytes, actual.string_id.asSlice());
    }
}

test "string matches target C char signedness for non-ASCII input" {
    const bytes = [_]u8{ 0, 1, 2, 3, 127, 128, 255 };
    const actual = string(types.String.fromSlice(&bytes), 0);

    const expected: u32 = if (builtin.target.cCharSignedness() == .signed)
        1_702_597_795
    else
        1_242_283_590;
    try std.testing.expectEqual(expected, actual.id);
}

test "stringWithOffset matches pinned scalar C oracle vectors" {
    const vectors = [_]struct {
        bytes: []const u8,
        offset: u32,
        seed: u32,
        id: u32,
        base_id: u32,
    }{
        .{ .bytes = "item", .offset = 0, .seed = 0, .id = 843_214_071, .base_id = 3_551_748_293 },
        .{ .bytes = "item", .offset = 1, .seed = 0, .id = 469_975_161, .base_id = 3_551_748_293 },
        .{ .bytes = "item", .offset = 42, .seed = 77, .id = 2_357_917_166, .base_id = 824_282_799 },
        .{ .bytes = "", .offset = std.math.maxInt(u32), .seed = 0, .id = 2_925_896_853, .base_id = 1 },
    };

    for (vectors) |vector| {
        const key = types.String.fromSlice(vector.bytes);
        const actual = stringWithOffset(key, vector.offset, vector.seed);
        try std.testing.expectEqual(vector.id, actual.id);
        try std.testing.expectEqual(vector.offset, actual.offset);
        try std.testing.expectEqual(vector.base_id, actual.base_id);
        try std.testing.expectEqualStrings(vector.bytes, actual.string_id.asSlice());
    }
}

test "malformed public String lengths are clamped before hashing" {
    const bytes = "Clay";
    const valid = types.String.fromSlice(bytes);
    const overlong = types.String{
        .length = std.math.maxInt(i32),
        .chars = bytes,
    };

    const valid_id = string(valid, 123);
    const overlong_id = string(overlong, 123);
    try std.testing.expectEqual(valid_id.id, overlong_id.id);
    try std.testing.expectEqual(valid_id.base_id, overlong_id.base_id);

    const valid_indexed_id = stringWithOffset(valid, 42, 77);
    const overlong_indexed_id = stringWithOffset(overlong, 42, 77);
    try std.testing.expectEqual(valid_indexed_id.id, overlong_indexed_id.id);
    try std.testing.expectEqual(valid_indexed_id.base_id, overlong_indexed_id.base_id);

    const config = types.TextElementConfig{
        .font_id = 7,
        .font_size = 24,
        .letter_spacing = 3,
    };
    try std.testing.expectEqual(
        textWithConfigScalar(valid, config),
        textWithConfigScalar(overlong, config),
    );
    try std.testing.expectEqual(
        textWithConfig(valid, config),
        textWithConfig(overlong, config),
    );

    const empty = types.String.fromSlice("");
    const missing_backing = types.String{
        .length = 1,
        .chars = "",
    };
    try std.testing.expectEqual(string(empty, 0).id, string(missing_backing, 0).id);
    try std.testing.expectEqual(
        textWithConfigScalar(empty, config),
        textWithConfigScalar(missing_backing, config),
    );
}

test "dataScalar matches pinned CLAY_DISABLE_SIMD C oracle vectors" {
    const binary = [_]u8{ 0, 1, 2, 3, 127, 128, 255 };
    const sequence = [_]u8{
        0,  1,  2,  3,  4,  5,  6,  7,
        8,  9,  10, 11, 12, 13, 14, 15,
        16, 17, 18, 19, 20, 21, 22, 23,
        24, 25, 26, 27, 28, 29, 30, 31,
    };

    try std.testing.expectEqual(@as(u64, 0), dataScalar(""));
    try std.testing.expectEqual(@as(u64, 98_928), dataScalar("a"));
    try std.testing.expectEqual(@as(u64, 74_106_900_938_597), dataScalar("Clay"));
    try std.testing.expectEqual(@as(u64, 1_162_438_121_633_678_273), dataScalar(&binary));
    try std.testing.expectEqual(@as(u64, 17_290_512_923_223_784_999), dataScalar(&sequence));
}

test "x86_64 data hash matches pinned default C oracle vectors" {
    var sequence: [64]u8 = undefined;
    for (&sequence, 0..) |*byte, index| byte.* = @intCast(index);
    const vectors = [_]struct {
        length: usize,
        expected: u64,
    }{
        .{ .length = 0, .expected = 0 },
        .{ .length = 4, .expected = 129_691_398_728_704 },
        .{ .length = 8, .expected = 1_303_921_783_522_488_836 },
        .{ .length = 9, .expected = 1_303_921_783_529_828_932 },
        .{ .length = 16, .expected = 1_094_396_494_333_612_528 },
        .{ .length = 17, .expected = 4_486_647_907_394_536_192 },
        .{ .length = 32, .expected = 9_939_569_653_748_619_568 },
        .{ .length = 64, .expected = 10_251_144_956_403_349_713 },
    };

    for (vectors) |vector| {
        try std.testing.expectEqual(vector.expected, dataX86_64(sequence[0..vector.length]));
    }

    const binary = [_]u8{ 0, 1, 2, 3, 127, 128, 255 };
    try std.testing.expectEqual(@as(u64, 4_104_036_501_107_535_511), dataX86_64(&binary));
}

test "AArch64 data hash preserves pinned split-tail behavior" {
    var sequence: [64]u8 = undefined;
    for (&sequence, 0..) |*byte, index| byte.* = @intCast(index);
    const little_endian_vectors = [_]struct {
        length: usize,
        expected: u64,
    }{
        .{ .length = 0, .expected = 0 },
        .{ .length = 8, .expected = 1_303_921_783_522_488_836 },
        .{ .length = 9, .expected = 18_174_341_066_911_135_968 },
        .{ .length = 16, .expected = 18_308_448_450_054_203_108 },
        .{ .length = 17, .expected = 4_486_647_907_394_536_192 },
        .{ .length = 24, .expected = 6_212_722_439_340_698_421 },
        .{ .length = 32, .expected = 1_103_406_062_466_150_603 },
        .{ .length = 64, .expected = 3_753_674_313_972_326_855 },
    };

    for (little_endian_vectors) |vector| {
        try std.testing.expectEqual(vector.expected, dataAarch64(sequence[0..vector.length], .little));
    }

    // The pinned AArch64 implementation splits a final 9-16 bytes into two
    // lower-lane blocks, but loads a 16-byte block when more data follows it.
    try std.testing.expect(dataAarch64(sequence[0..9], .little) != dataX86_64(sequence[0..9]));
    try std.testing.expect(dataAarch64(sequence[0..16], .little) != dataX86_64(sequence[0..16]));
    try std.testing.expectEqual(dataX86_64(sequence[0..17]), dataAarch64(sequence[0..17], .little));
    try std.testing.expectEqual(dataX86_64(sequence[0..24]), dataAarch64(sequence[0..24], .little));
}

test "data selects the pinned target-default algorithm" {
    var sequence: [32]u8 = undefined;
    for (&sequence, 0..) |*byte, index| byte.* = @intCast(index);
    const expected = switch (builtin.target.cpu.arch) {
        .x86_64 => dataX86_64(&sequence),
        .aarch64, .aarch64_be => dataAarch64(&sequence, builtin.target.cpu.arch.endian()),
        else => dataScalar(&sequence),
    };
    try std.testing.expectEqual(expected, data(&sequence));
}

test "textWithConfigScalar matches pinned CLAY_DISABLE_SIMD C oracle vectors" {
    const default_config = types.TextElementConfig{};
    const styled_config = types.TextElementConfig{
        .font_id = 7,
        .font_size = 24,
        .letter_spacing = 3,
        .line_height = 40,
        .wrap_mode = .none,
        .text_alignment = .right,
    };
    const binary = [_]u8{ 0, 1, 2, 3, 127, 128, 255 };

    try std.testing.expectEqual(@as(u32, 1), textWithConfigScalar(types.String.fromSlice(""), default_config));
    try std.testing.expectEqual(@as(u32, 4_241_709_637), textWithConfigScalar(types.String.fromSlice("Clay"), default_config));
    try std.testing.expectEqual(@as(u32, 1_965_268_415), textWithConfigScalar(types.String.fromSlice("Clay"), styled_config));
    try std.testing.expectEqual(@as(u32, 1_950_710_328), textWithConfigScalar(types.String.fromSlice(&binary), styled_config));
}

test "textWithConfig matches pinned x86_64 default C oracle vectors" {
    if (builtin.target.cpu.arch != .x86_64) return error.SkipZigTest;

    const default_config = types.TextElementConfig{};
    const styled_config = types.TextElementConfig{
        .font_id = 7,
        .font_size = 24,
        .letter_spacing = 3,
        .line_height = 40,
        .wrap_mode = .none,
        .text_alignment = .right,
    };
    const binary = [_]u8{ 0, 1, 2, 3, 127, 128, 255 };

    try std.testing.expectEqual(@as(u32, 1), textWithConfig(types.String.fromSlice(""), default_config));
    try std.testing.expectEqual(@as(u32, 4_144_509_781), textWithConfig(types.String.fromSlice("Clay"), default_config));
    try std.testing.expectEqual(@as(u32, 3_043_263_680), textWithConfig(types.String.fromSlice("Clay"), styled_config));
    try std.testing.expectEqual(@as(u32, 3_562_463_298), textWithConfig(types.String.fromSlice(&binary), styled_config));
}

test "text cache hash ignores non-measurement config fields" {
    const text = types.String.fromSlice("same measurement");
    const base = types.TextElementConfig{
        .font_id = 2,
        .font_size = 16,
        .letter_spacing = 1,
    };
    var changed = base;
    changed.line_height = 99;
    changed.wrap_mode = .none;
    changed.text_alignment = .right;
    changed.text_color = .{ .r = 255, .g = 128, .b = 64, .a = 255 };

    try std.testing.expectEqual(textWithConfig(text, base), textWithConfig(text, changed));
}

test "static text cache hash incorporates address and length" {
    const backing = "static text";
    const whole = types.String.literal(backing);
    const shorter = types.String{
        .is_statically_allocated = true,
        .length = whole.length - 1,
        .chars = backing,
    };

    try std.testing.expect(textWithConfig(whole, .{}) != textWithConfig(shorter, .{}));
}
