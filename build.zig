const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "helper",
        .root_source_file = .{ .path = "helper.zig" },
        .target = b.resolveTargetQuery(.{
            .os_tag = .windows,
            .cpu_arch = .x86_64,
        }),
    });

    const version = b.option([]const u8, "version", "application version string") orelse "0.0.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    exe.root_module.addOptions("config", options);

    b.installArtifact(exe);
}
