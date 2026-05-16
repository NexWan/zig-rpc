const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_rpc = b.addModule("zig_rpc", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const module_tests = b.addTest(.{
        .root_module = zig_rpc,
    });
    const run_module_tests = b.addRunArtifact(module_tests);

    const zig_echo_server = b.addExecutable(.{
        .name = "zig-rpc-zig-echo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fixtures/zig_echo_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_rpc", .module = zig_rpc },
            },
        }),
    });

    const integration = b.addExecutable(.{
        .name = "zig-rpc-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_rpc", .module = zig_rpc },
            },
        }),
    });

    const run_integration = b.addRunArtifact(integration);
    run_integration.addArtifactArg(zig_echo_server);
    run_integration.addFileArg(b.path("test/fixtures/python_echo_server.py"));

    const test_step = b.step("test", "Run unit and STDIO integration tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_integration.step);
}
