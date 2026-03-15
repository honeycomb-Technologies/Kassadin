const std = @import("std");

const vrf_c_flags: []const []const u8 = &.{"-DHAVE_TI_MODE"};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Plutuz dependency (UPLC evaluator) ---
    const plutuz_dep = b.dependency("plutuz", .{
        .target = target,
        .optimize = optimize,
    });
    const plutuz_mod = plutuz_dep.module("plutuz");

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "kassadin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plutuz", .module = plutuz_mod },
            },
            .link_libc = true,
        }),
    });

    addVrfSources(b, exe.root_module);
    b.installArtifact(exe);

    // --- Run command ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run kassadin node").dependOn(&run_cmd.step);

    // --- Tests ---
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plutuz", .module = plutuz_mod },
            },
            .link_libc = true,
        }),
    });

    addVrfSources(b, lib_tests.root_module);
    const run_tests = b.addRunArtifact(lib_tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // --- Live tests (require internet) ---
    const kassadin_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "plutuz", .module = plutuz_mod },
        },
        .link_libc = true,
    });

    inline for (.{
        .{ "test-live", "tests/test_live_handshake.zig", "Run live handshake test" },
        .{ "test-blocks", "tests/test_real_blocks.zig", "Run real block parsing" },
        .{ "test-fetch", "tests/test_fetch_blocks.zig", "Fetch and parse real blocks" },
        .{ "test-dolos", "tests/test_dolos.zig", "Test N2C with local Dolos node" },
    }) |entry| {
        const t = b.addExecutable(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "kassadin", .module = kassadin_mod },
                },
                .link_libc = true,
            }),
        });
        addVrfSources(b, t.root_module);
        b.installArtifact(t);
        const run = b.addRunArtifact(t);
        run.step.dependOn(b.getInstallStep());
        b.step(entry[0], entry[2]).dependOn(&run.step);
    }
}

fn addVrfSources(b: *std.Build, mod: *std.Build.Module) void {
    const sources: []const []const u8 = &.{
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

    mod.addIncludePath(b.path("vendor/vrf"));
    mod.addIncludePath(b.path("vendor/vrf/private"));
    for (sources) |src| {
        mod.addCSourceFile(.{
            .file = b.path(src),
            .flags = vrf_c_flags,
        });
    }
    mod.linkSystemLibrary("sodium", .{});
}
