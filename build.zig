const std = @import("std");
const acl = @import("acl.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse (optimize != .Debug);

    const acl_list = b.option([]const u8, "acl-list", "Admin credentials") orelse "admin:minioadmin:minioadmin";
    _ = try acl.parseCredentials(b.allocator, acl_list);

    const options = b.addOptions();
    options.addOption([]const u8, "acl_list", acl_list);

    const exe = b.addExecutable(.{
        .name = "zs3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the S3 server");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
