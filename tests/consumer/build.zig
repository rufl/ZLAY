const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zlay = b.dependency("zlay", .{
        .target = target,
        .optimize = optimize,
    });

    const consumer = b.addExecutable(.{
        .name = "zlay-consumer-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zlay", .module = zlay.module("zlay") },
            },
        }),
    });

    const check = b.step("check", "Compile the external ZLAY consumer");
    check.dependOn(&consumer.step);

    const run_consumer = b.addRunArtifact(consumer);
    const run = b.step("run", "Run the external ZLAY consumer");
    run.dependOn(&run_consumer.step);
}
