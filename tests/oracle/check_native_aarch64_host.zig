const std = @import("std");
const builtin = @import("builtin");

fn isAarch64Machine(machine: []const u8) bool {
    return std.mem.eql(u8, machine, "aarch64") or
        std.mem.eql(u8, machine, "arm64");
}

pub fn main(init: std.process.Init) !void {
    const uts = std.posix.uname();
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    const release = std.mem.sliceTo(&uts.release, 0);
    const machine = std.mem.sliceTo(&uts.machine, 0);
    const word_bits = @bitSizeOf(usize);

    if (builtin.target.cpu.arch != .aarch64) {
        std.debug.print(
            "aarch64-hash-certify requires an AArch64 compile target; target arch={s} kernel machine={s}\n",
            .{ @tagName(builtin.target.cpu.arch), machine },
        );
        return error.NotAarch64CompileTarget;
    }
    if (!isAarch64Machine(machine)) {
        std.debug.print(
            "aarch64-hash-certify requires an AArch64 kernel host; uname machine reported: {s}\n",
            .{machine},
        );
        return error.NotAarch64Kernel;
    }
    if (word_bits != 64) {
        std.debug.print(
            "aarch64-hash-certify requires a 64-bit userspace; word_bits={d}\n",
            .{word_bits},
        );
        return error.Not64BitUserspace;
    }

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.print(
        "native-host sysname={s} release={s} machine={s} word_bits={d}\n",
        .{ sysname, release, machine, word_bits },
    );
    try stdout_writer.interface.flush();
}
