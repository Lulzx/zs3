const std = @import("std");
const acl = @import("acl.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse (optimize != .Debug);

    const acl_list = b.option([]const u8, "acl-list", "Admin credentials") orelse "admin:minioadmin:minioadmin";
    const all_credentials = try acl.parseCredentials(b.allocator, acl_list);

    var credential_list = try std.ArrayList([]const u8).initCapacity(b.allocator, 20);
    // No defer deinit here if we use toOwnedSlice later

    for (all_credentials) |cred| {
        const role_name = switch (cred.role) {
            .Admin => "admin",
            .Reader => "reader",
            .Writer => "writer",
        };

        const entry_str = try std.fmt.allocPrint(b.allocator, "{s}:{s}:{s}", .{ role_name, cred.access_key, cred.secret_key });
        try credential_list.append(b.allocator, entry_str);
    }

    const cs = try credential_list.toOwnedSlice(b.allocator);
    const joined_acl_list = try std.mem.join(b.allocator, ",", cs);

    const options = b.addOptions();
    options.addOption([]const u8, "acl_list", joined_acl_list);

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
