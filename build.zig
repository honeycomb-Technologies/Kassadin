const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- VRF C sources from cardano-crypto-praos/cbits ---
    const vrf_c_sources = [_][]const u8{
        "vendor/vrf/crypto_vrf.c",
        "vendor/vrf/private/core_h2c.c",
        "vendor/vrf/private/ed25519_ref10.c",
        "vendor/vrf/vrf03/prove.c",
        "vendor/vrf/vrf03/verify.c",
        "vendor/vrf/vrf03/vrf.c",
        "vendor/vrf/vrf13_batchcompat/prove.c",
        "vendor/vrf/vrf13_batchcompat/verify.c",
        "vendor/vrf/vrf13_batchcompat/vrf.c",
    };

    const vrf_c_flags = [_][]const u8{
        "-DHAVE_TI_MODE", // 128-bit integer support (x86_64)
        "-I", "vendor/vrf",
        "-I", "vendor/vrf/private",
    };

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "kassadin",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    for (vrf_c_sources) |src| {
        exe.addCSourceFile(.{
            .file = b.path(src),
            .flags = &vrf_c_flags,
        });
    }
    exe.addIncludePath(b.path("vendor/vrf"));
    exe.addIncludePath(b.path("vendor/vrf/private"));
    exe.linkSystemLibrary("sodium");
    exe.linkLibC();

    b.installArtifact(exe);

    // --- Run command ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run kassadin node");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    for (vrf_c_sources) |src| {
        lib_tests.addCSourceFile(.{
            .file = b.path(src),
            .flags = &vrf_c_flags,
        });
    }
    lib_tests.addIncludePath(b.path("vendor/vrf"));
    lib_tests.addIncludePath(b.path("vendor/vrf/private"));
    lib_tests.linkSystemLibrary("sodium");
    lib_tests.linkLibC();

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // --- Live network tests (requires internet) ---
    const kassadin_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
    });

    const live_test = b.addExecutable(.{
        .name = "test-live",
        .root_source_file = b.path("tests/test_live_handshake.zig"),
        .target = target,
        .optimize = optimize,
    });
    live_test.root_module.addImport("kassadin", kassadin_mod);
    live_test.linkSystemLibrary("sodium");
    live_test.linkLibC();
    b.installArtifact(live_test);

    const run_live = b.addRunArtifact(live_test);
    run_live.step.dependOn(b.getInstallStep());
    const live_step = b.step("test-live", "Run live network tests (requires internet)");
    live_step.dependOn(&run_live.step);

    // --- Phase 3 block validation test ---
    const block_test = b.addExecutable(.{
        .name = "test-blocks",
        .root_source_file = b.path("tests/test_real_blocks.zig"),
        .target = target,
        .optimize = optimize,
    });
    block_test.root_module.addImport("kassadin", kassadin_mod);
    block_test.linkSystemLibrary("sodium");
    block_test.linkLibC();
    b.installArtifact(block_test);

    const run_blocks = b.addRunArtifact(block_test);
    run_blocks.step.dependOn(b.getInstallStep());
    const blocks_step = b.step("test-blocks", "Run real block parsing validation");
    blocks_step.dependOn(&run_blocks.step);
}
