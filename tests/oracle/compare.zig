const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("ordinary_manifest.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3 and args.len != 4) return error.InvalidArguments;
    const ReportMode = enum { none, target, qemu_aarch64 };
    const report_mode: ReportMode = if (args.len == 3)
        .none
    else if (args.len == 4 and std.mem.eql(u8, args[3], "--report"))
        .target
    else if (args.len == 4 and std.mem.eql(u8, args[3], "--qemu-aarch64-report"))
        .qemu_aarch64
    else
        return error.InvalidArguments;

    const entry = manifest.entryForPaths(args[1], args[2]) orelse {
        std.debug.print("unknown ordinary oracle fixture pair: C={s}, Zig={s}\n", .{
            std.fs.path.basename(args[1]),
            std.fs.path.basename(args[2]),
        });
        return error.UnknownOracleFixture;
    };
    if (report_mode == .qemu_aarch64 and !std.mem.eql(u8, entry.identity, "hash-default")) {
        return error.InvalidQemuAarch64Identity;
    }

    const expected_file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer expected_file.close(init.io);
    var expected_buffer: [4096]u8 = undefined;
    var expected_reader = expected_file.reader(init.io, &expected_buffer);
    const expected = try expected_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));

    const actual_file = try std.Io.Dir.cwd().openFile(init.io, args[2], .{});
    defer actual_file.close(init.io);
    var actual_buffer: [4096]u8 = undefined;
    var actual_reader = actual_file.reader(init.io, &actual_buffer);
    const actual = try actual_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));

    const contract_arch: std.Target.Cpu.Arch = if (report_mode == .qemu_aarch64)
        .aarch64
    else
        builtin.target.cpu.arch;
    try manifest.verifyTraceForArch(entry, expected, "pinned C", contract_arch);
    try manifest.verifyTraceForArch(entry, actual, "native Zig", contract_arch);
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print("{s} C oracle output:\n{s}\n{s} Zig output:\n{s}\n", .{
            entry.identity,
            expected,
            entry.identity,
            actual,
        });
        return error.OracleMismatch;
    }

    const contract = try manifest.contractForArch(entry, contract_arch);
    switch (report_mode) {
        .none => {},
        .target => std.debug.print(
            "oracle-contract identity={s} arch={s} lines={d} bytes={d} sha256={s}\n",
            .{
                entry.identity,
                @tagName(contract_arch),
                contract.line_count,
                contract.byte_count,
                contract.sha256_hex,
            },
        ),
        .qemu_aarch64 => std.debug.print(
            "oracle-emulation identity={s} target=aarch64-linux-musl cpu=baseline executor=qemu-aarch64 qemu_cpu=max lines={d} bytes={d} sha256={s} certification=false physical_machine_proof=false backlog_closed=false\n",
            .{
                entry.identity,
                contract.line_count,
                contract.byte_count,
                contract.sha256_hex,
            },
        ),
    }
}
