// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "helper",
        .root_source_file = .{ .path = "helper.zig" },
        .target = target,
        .optimize = optimize,
    });

    const version = b.option([]const u8, "version", "application version string") orelse "0.0.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    exe.root_module.addOptions("config", options);

    b.installArtifact(exe);
}
