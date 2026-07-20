//! Reviewed exact-output contracts for ordinary equality oracle fixtures.
//!
//! Entries are keyed by the captured C/Zig basenames from `build.zig`. Adding a
//! generic equality fixture without adding a reviewed entry makes comparison
//! fail closed. Primary host counts and hashes were generated from `zig build
//! parity` using the exact pinned header; target variants are separately
//! reviewed contracts and still require native target execution for evidence.
//! Updating any value requires reviewing both traces.

const std = @import("std");
const builtin = @import("builtin");

pub const TraceContract = struct {
    line_count: usize,
    byte_count: usize,
    sha256_hex: []const u8,
};

pub const TargetContract = struct {
    cpu_arch: std.Target.Cpu.Arch,
    trace: TraceContract,
};

pub const Entry = struct {
    identity: []const u8,
    c_basename: []const u8,
    zig_basename: []const u8,
    line_count: usize,
    byte_count: usize,
    sha256_hex: []const u8,
    /// Null means the primary trace contract is target-independent. A target-
    /// sensitive fixture names the architecture for its primary contract and
    /// must provide every other accepted architecture explicitly.
    cpu_arch: ?std.Target.Cpu.Arch = null,
    target_contracts: []const TargetContract = &.{},
};

pub const entries = [_]Entry{
    .{
        .identity = "layout",
        .c_basename = "clay-oracle.txt",
        .zig_basename = "zlay-oracle.txt",
        .line_count = 4,
        .byte_count = 175,
        .sha256_hex = "8ebb08e991b08610f2f7925f963d5304791ffe2c354241d70704ab236d050f87",
    },
    .{
        .identity = "layout-scroll-breadth",
        .c_basename = "layout-scroll-breadth-clay-oracle.txt",
        .zig_basename = "layout-scroll-breadth-zig-oracle.txt",
        .line_count = 11,
        .byte_count = 1_098,
        .sha256_hex = "a23128a059e72148fae400e7c7cb69d8ca40ce73824ae05a2e6847a19ea97776",
    },
    .{
        .identity = "text-cache-lifecycle",
        .c_basename = "text-cache-lifecycle-clay-oracle.txt",
        .zig_basename = "text-cache-lifecycle-zig-oracle.txt",
        .line_count = 20,
        .byte_count = 925,
        .sha256_hex = "fae48c8800732d6d26bf290492b259443bb44387f06afcb11312f70ea527b013",
    },
    .{
        .identity = "text-cache-runtime-setter",
        .c_basename = "text-cache-runtime-setter-clay-oracle.txt",
        .zig_basename = "text-cache-runtime-setter-zig-oracle.txt",
        .line_count = 3,
        .byte_count = 163,
        .sha256_hex = "5917ef878afb0b127464af69579b4f6d38222a4b482589c90720e038d3d38a02",
    },
    .{
        .identity = "complex",
        .c_basename = "complex-clay-oracle.txt",
        .zig_basename = "complex-zig-oracle.txt",
        .line_count = 27,
        .byte_count = 2_292,
        .sha256_hex = "dba0ad27bba57620ce11039ce827d5cfa15d33fa26c1b82fc4369d6a39263946",
    },
    .{
        .identity = "transition",
        .c_basename = "transition-clay-oracle.txt",
        .zig_basename = "transition-zig-oracle.txt",
        .line_count = 53,
        .byte_count = 7_846,
        .sha256_hex = "06476a2de14d2eee8964ae2de3496c23ebd8d3bdea5942df95d5b715a161ba8e",
    },
    .{
        .identity = "transition-matrix",
        .c_basename = "transition-matrix-clay-oracle.txt",
        .zig_basename = "transition-matrix-zig-oracle.txt",
        .line_count = 322,
        .byte_count = 45_474,
        .sha256_hex = "e50a7b0735f1bbb36ea82fff95048ee11b1b8d30687d13766412ec2d928144d6",
    },
    .{
        .identity = "pointer",
        .c_basename = "pointer-clay-oracle.txt",
        .zig_basename = "pointer-zig-oracle.txt",
        .line_count = 21,
        .byte_count = 1_472,
        .sha256_hex = "49591cc5515c982ced7c665b6ffeff80ee174ecbd3d7e81713403d84cca6a425",
    },
    .{
        .identity = "floating-pointer-edge",
        .c_basename = "floating-pointer-edge-clay-oracle.txt",
        .zig_basename = "floating-pointer-edge-zig-oracle.txt",
        .line_count = 225,
        .byte_count = 25_759,
        .sha256_hex = "4f3e63f76b1d365676a3e2a47cf6108735e5970dc41ee281eb48de54889ae62c",
    },
    .{
        .identity = "scroll-parity",
        .c_basename = "scroll-parity-clay-oracle.txt",
        .zig_basename = "scroll-parity-zig-oracle.txt",
        .line_count = 9,
        .byte_count = 812,
        .sha256_hex = "ece1cccdcd1b9d1d1c13fc76524e6a0268b035b2e4ce00cf3cb18a58190389b2",
    },
    .{
        .identity = "external-scroll",
        .c_basename = "external-scroll-clay-oracle.txt",
        .zig_basename = "external-scroll-zig-oracle.txt",
        .line_count = 52,
        .byte_count = 5_749,
        .sha256_hex = "ada2db8b97021fb65e98d6c78522b87cdca31b947fe0be8770a2e35cff2c5da5",
    },
    .{
        .identity = "render",
        .c_basename = "render-clay-oracle.txt",
        .zig_basename = "render-zig-oracle.txt",
        .line_count = 35,
        .byte_count = 5_361,
        .sha256_hex = "0ac3ccc53f00a80c101246780776f102516355ab2c33e558e9645c4ecda8e4f7",
    },
    .{
        .identity = "sizing-text",
        .c_basename = "sizing-text-clay-oracle.txt",
        .zig_basename = "sizing-text-zig-oracle.txt",
        .line_count = 73,
        .byte_count = 9_413,
        .sha256_hex = "92587d88baeef79a77bbb2f91e68025da1a34e416a2e32c7a899894a5c807a2f",
    },
    .{
        .identity = "string-text-edge",
        .c_basename = "string-text-edge-clay-oracle.txt",
        .zig_basename = "string-text-edge-zig-oracle.txt",
        .line_count = 110,
        .byte_count = 7_627,
        .sha256_hex = "4d40c2e4024d0a49b538e628578cf77a7cebeca5f14504b3ced6674ce0b474c7",
    },
    .{
        .identity = "declaration-layout",
        .c_basename = "declaration-layout-clay-oracle.txt",
        .zig_basename = "declaration-layout-zig-oracle.txt",
        .line_count = 122,
        .byte_count = 11_110,
        .sha256_hex = "573d8ba165590e0823a21947ddbea08163960990c92a027d7c6eae39e350f733",
    },
    .{
        .identity = "api-diagnostics",
        .c_basename = "api-diagnostics-clay-oracle.txt",
        .zig_basename = "api-diagnostics-zig-oracle.txt",
        .line_count = 16,
        .byte_count = 1_044,
        .sha256_hex = "ec89359d65ddb6cd59c43fc1e18975a953b23b73a8a9d9bd1b1f5026395eab3a",
    },
    .{
        .identity = "debug",
        .c_basename = "debug-clay-oracle.txt",
        .zig_basename = "debug-zig-oracle.txt",
        .line_count = 733,
        .byte_count = 70_836,
        .sha256_hex = "ddc3cd81ca2c1a9f893be102528ebd90faee63fb4d03c519d35086deb0b02dfc",
    },
    .{
        .identity = "id-error",
        .c_basename = "id-error-clay-oracle.txt",
        .zig_basename = "id-error-zig-oracle.txt",
        .line_count = 11,
        .byte_count = 585,
        .sha256_hex = "542177b1f0646644b6881eff89d4cde3f239eb54f4e5b8922d1fe687f975b6c1",
    },
    .{
        .identity = "id-collision",
        .c_basename = "id-collision-clay-oracle.txt",
        .zig_basename = "id-collision-zig-oracle.txt",
        .line_count = 6,
        .byte_count = 215,
        .sha256_hex = "b7f80e08fdb6ac50c83e8f4f4cda72f18de3dc30e6593150b7ba24d930e692c8",
    },
    .{
        .identity = "capacity-match",
        .c_basename = "capacity-match-clay-oracle.txt",
        .zig_basename = "capacity-match-zig-oracle.txt",
        .line_count = 10,
        .byte_count = 332,
        .sha256_hex = "100a93eb5135ab5d4d76da9c71c43366e78d85fabbb4e2bccecaf3681638602b",
    },
    .{
        .identity = "public-metadata",
        .c_basename = "public-metadata-clay-oracle.txt",
        .zig_basename = "public-metadata-zig-oracle.txt",
        .line_count = 3,
        .byte_count = 85,
        .sha256_hex = "5735a988eef820ee75b827a5857f1b18e8aa93961678644e868f6ac43538a0e5",
    },
    .{
        .identity = "ease-out",
        .c_basename = "ease-out-clay-oracle.txt",
        .zig_basename = "ease-out-zig-oracle.txt",
        .line_count = 78,
        .byte_count = 15_927,
        .sha256_hex = "24efa78738a1c95cb9970fc75d8686d4cbfd7dd2a61b8d7506beb5d445b8f459",
    },
    .{
        .identity = "hash-default",
        .c_basename = "hash-default-clay-oracle.txt",
        .zig_basename = "hash-default-zig-oracle.txt",
        .line_count = 18,
        .byte_count = 426,
        .sha256_hex = "d83417b349f8239000193fb4e3ea19fcc3629134a740596e6cc8ab14d74477e4",
        .cpu_arch = .x86_64,
        .target_contracts = &.{.{
            .cpu_arch = .aarch64,
            .trace = .{
                .line_count = 18,
                .byte_count = 426,
                .sha256_hex = "68b1ce5dfef146735d34889f337fa3f73a597b0511a5fc511f9e399d263dc787",
            },
        }},
    },
    .{
        .identity = "parity-regression",
        .c_basename = "parity-regression-clay-oracle.txt",
        .zig_basename = "parity-regression-zig-oracle.txt",
        .line_count = 34,
        .byte_count = 2_491,
        .sha256_hex = "3ed0856967133f005ccf9b921e2259c96d75a04a99c36ffa1f7336b9c3b8869a",
    },
    .{
        .identity = "public-values",
        .c_basename = "public-values-clay-oracle.txt",
        .zig_basename = "public-values-zig-oracle.txt",
        .line_count = 174,
        .byte_count = 10_010,
        .sha256_hex = "e85ce64e4f28b3e17bee35b4230674c8e6a1bd3838e4f35910a3b3fc9be38e8f",
    },
};

pub fn entryForPaths(c_path: []const u8, zig_path: []const u8) ?*const Entry {
    const c_basename = std.fs.path.basename(c_path);
    const zig_basename = std.fs.path.basename(zig_path);
    for (&entries) |*entry| {
        if (std.mem.eql(u8, c_basename, entry.c_basename) and
            std.mem.eql(u8, zig_basename, entry.zig_basename)) return entry;
    }
    return null;
}

fn primaryContract(entry: *const Entry) TraceContract {
    return .{
        .line_count = entry.line_count,
        .byte_count = entry.byte_count,
        .sha256_hex = entry.sha256_hex,
    };
}

pub fn contractForArch(entry: *const Entry, cpu_arch: std.Target.Cpu.Arch) !TraceContract {
    if (entry.cpu_arch == null or entry.cpu_arch.? == cpu_arch) return primaryContract(entry);

    for (entry.target_contracts) |target_contract| {
        if (target_contract.cpu_arch == cpu_arch) return target_contract.trace;
    }

    return error.UnsupportedOracleTarget;
}

fn verifyTraceForArchWithDiagnostics(
    entry: *const Entry,
    contents: []const u8,
    side: []const u8,
    cpu_arch: std.Target.Cpu.Arch,
    print_diagnostics: bool,
) !void {
    const contract = contractForArch(entry, cpu_arch) catch |err| {
        if (print_diagnostics) {
            std.debug.print("{s} has no reviewed trace contract for target architecture {s}\n", .{
                entry.identity,
                @tagName(cpu_arch),
            });
        }
        return err;
    };
    if (contents.len == 0) {
        if (print_diagnostics) std.debug.print("{s} {s} trace is empty\n", .{ entry.identity, side });
        return error.EmptyOracleTrace;
    }

    var line_count: usize = 0;
    var record_start: usize = 0;
    for (contents, 0..) |byte, index| {
        if (byte != '\n') continue;
        if (index == record_start) {
            if (print_diagnostics) {
                std.debug.print("{s} {s} trace contains an empty record at line {d}\n", .{
                    entry.identity,
                    side,
                    line_count + 1,
                });
            }
            return error.EmptyOracleRecord;
        }
        line_count += 1;
        record_start = index + 1;
    }
    if (record_start != contents.len) {
        if (print_diagnostics) {
            std.debug.print("{s} {s} trace ends with an incomplete record\n", .{ entry.identity, side });
        }
        return error.IncompleteOracleTrace;
    }
    if (line_count != contract.line_count) {
        if (print_diagnostics) {
            std.debug.print("{s} {s} trace line count changed: expected {d}, actual {d}\n", .{
                entry.identity,
                side,
                contract.line_count,
                line_count,
            });
        }
        return error.OracleLineCountChanged;
    }
    if (contents.len != contract.byte_count) {
        if (print_diagnostics) {
            std.debug.print("{s} {s} trace byte count changed: expected {d}, actual {d}\n", .{
                entry.identity,
                side,
                contract.byte_count,
                contents.len,
            });
        }
        return error.OracleByteCountChanged;
    }

    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &actual, .{});
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, contract.sha256_hex);
    if (!std.mem.eql(u8, &expected, &actual)) {
        if (print_diagnostics) {
            std.debug.print("{s} {s} trace digest changed\nexpected: {s}\nactual:   {x}\n", .{
                entry.identity,
                side,
                contract.sha256_hex,
                actual,
            });
        }
        return error.OracleDigestChanged;
    }
}

pub fn verifyTraceForArch(
    entry: *const Entry,
    contents: []const u8,
    side: []const u8,
    cpu_arch: std.Target.Cpu.Arch,
) !void {
    return verifyTraceForArchWithDiagnostics(entry, contents, side, cpu_arch, true);
}

pub fn verifyTrace(entry: *const Entry, contents: []const u8, side: []const u8) !void {
    return verifyTraceForArch(entry, contents, side, builtin.target.cpu.arch);
}

fn verifyTraceQuiet(entry: *const Entry, contents: []const u8, side: []const u8) !void {
    return verifyTraceForArchWithDiagnostics(entry, contents, side, builtin.target.cpu.arch, false);
}

fn expectWellFormedContract(contract: TraceContract) !void {
    try std.testing.expect(contract.line_count > 0);
    try std.testing.expect(contract.byte_count > contract.line_count);
    try std.testing.expectEqual(@as(usize, 64), contract.sha256_hex.len);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&digest, contract.sha256_hex);
}

test "ordinary fixture manifest is well formed and identity lookup is exact" {
    try std.testing.expectEqual(@as(usize, 25), entries.len);
    for (&entries, 0..) |*entry, index| {
        try std.testing.expect(entry.identity.len > 0);
        try std.testing.expect(entry.c_basename.len > 0);
        try std.testing.expect(entry.zig_basename.len > 0);
        try expectWellFormedContract(primaryContract(entry));
        try std.testing.expect(entry.cpu_arch != null or entry.target_contracts.len == 0);
        try std.testing.expect(entryForPaths(entry.c_basename, entry.zig_basename).? == entry);
        try std.testing.expect(entryForPaths(entry.zig_basename, entry.c_basename) == null);

        for (entry.target_contracts, 0..) |target_contract, target_index| {
            try std.testing.expect(entry.cpu_arch == null or entry.cpu_arch.? != target_contract.cpu_arch);
            try expectWellFormedContract(target_contract.trace);
            for (entry.target_contracts[target_index + 1 ..]) |other_target| {
                try std.testing.expect(target_contract.cpu_arch != other_target.cpu_arch);
            }
        }

        for (entries[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.identity, other.identity));
            try std.testing.expect(!std.mem.eql(u8, entry.c_basename, other.c_basename));
            try std.testing.expect(!std.mem.eql(u8, entry.zig_basename, other.zig_basename));
        }
    }
}

test "target-sensitive contracts select exact reviewed architecture variants" {
    const entry = entryForPaths(
        "hash-default-clay-oracle.txt",
        "hash-default-zig-oracle.txt",
    ).?;
    const x86_64 = try contractForArch(entry, .x86_64);
    const aarch64 = try contractForArch(entry, .aarch64);

    try std.testing.expectEqualStrings(
        "d83417b349f8239000193fb4e3ea19fcc3629134a740596e6cc8ab14d74477e4",
        x86_64.sha256_hex,
    );
    try std.testing.expectEqualStrings(
        "68b1ce5dfef146735d34889f337fa3f73a597b0511a5fc511f9e399d263dc787",
        aarch64.sha256_hex,
    );
    try std.testing.expectError(error.UnsupportedOracleTarget, contractForArch(entry, .wasm32));
    try std.testing.expectError(error.UnsupportedOracleTarget, contractForArch(entry, .aarch64_be));
    try std.testing.expectError(error.UnsupportedOracleTarget, contractForArch(entry, .riscv64));
}

test "portable AArch64 hash trace is pinned to its target contract" {
    const entry = entryForPaths(
        "hash-default-clay-oracle.txt",
        "hash-default-zig-oracle.txt",
    ).?;
    const trace =
        "data 0 0\n" ++
        "data 1 0\n" ++
        "data 4 129691398728704\n" ++
        "data 7 1303921783522487300\n" ++
        "data 8 1303921783522488836\n" ++
        "data 9 18174341066911135968\n" ++
        "data 15 149934752496362724\n" ++
        "data 16 18308448450054203108\n" ++
        "data 17 4486647907394536192\n" ++
        "data 24 6212722439340698421\n" ++
        "data 31 1103406062466163403\n" ++
        "data 32 1103406062466150603\n" ++
        "data 64 3753674313972326855\n" ++
        "binary 4104036501107535511\n" ++
        "text empty 1\n" ++
        "text clay 4144509781\n" ++
        "text styled 3043263680\n" ++
        "text binary 3562463298\n";

    try verifyTraceForArch(entry, trace, "portable AArch64", .aarch64);
}

test "trace verification rejects vacuity and every form of contract drift" {
    const trace = "alpha\nbeta\n";
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(trace, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const entry = Entry{
        .identity = "synthetic",
        .c_basename = "synthetic-c.txt",
        .zig_basename = "synthetic-zig.txt",
        .line_count = 2,
        .byte_count = trace.len,
        .sha256_hex = &digest_hex,
    };

    try verifyTraceQuiet(&entry, trace, "test");
    try std.testing.expectError(error.EmptyOracleTrace, verifyTraceQuiet(&entry, "", "test"));
    try std.testing.expectError(error.EmptyOracleRecord, verifyTraceQuiet(&entry, "alpha\n\n", "test"));
    try std.testing.expectError(error.IncompleteOracleTrace, verifyTraceQuiet(&entry, "alpha", "test"));
    try std.testing.expectError(error.OracleLineCountChanged, verifyTraceQuiet(&entry, "alpha\n", "test"));
    try std.testing.expectError(error.OracleByteCountChanged, verifyTraceQuiet(&entry, "a\nb\n", "test"));
    try std.testing.expectError(error.OracleDigestChanged, verifyTraceQuiet(&entry, "alphb\nbeta\n", "test"));
}
