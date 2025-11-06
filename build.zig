// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const Targets = struct {
    target: std.Build.ResolvedTarget,
    name: []const u8,
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Define all targets to build
    const targets: [4]Targets = .{
        .{ .target = b.resolveTargetQuery(.{ .os_tag = .windows, .cpu_arch = .x86_64 }), .name = "helper" },
        .{ .target = b.resolveTargetQuery(.{ .os_tag = .linux, .cpu_arch = .x86_64 }), .name = "helper-linux" },
        .{ .target = b.resolveTargetQuery(.{ .os_tag = .macos, .cpu_arch = .aarch64 }), .name = "helper-macos-arm64" },
        .{ .target = b.resolveTargetQuery(.{ .os_tag = .macos, .cpu_arch = .x86_64 }), .name = "helper-macos-x64" },
    };

    const version = b.option([]const u8, "version", "application version string") orelse "0.0.0";

    for (targets) |target_info| {
        const root_module = b.createModule(.{
            .root_source_file = b.path("helper.zig"),
            .target = target_info.target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = target_info.name,
            .root_module = root_module,
        });

        const options = b.addOptions();
        options.addOption([]const u8, "version", version);

        root_module.addOptions("config", options);

        b.installArtifact(exe);
    }
}
