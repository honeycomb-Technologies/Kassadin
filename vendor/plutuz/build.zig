const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the blst dependency
    const blst_dep = b.dependency("blst", .{});

    // Create a module for blst C code
    const blst_module = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    // Add include paths to the module
    blst_module.addIncludePath(blst_dep.path("bindings"));
    blst_module.addIncludePath(blst_dep.path("src"));

    // Compile blst's main source file
    blst_module.addCSourceFile(.{
        .file = blst_dep.path("src/server.c"),
        .flags = &.{
            "-fno-builtin",
            "-Wno-unused-function",
        },
    });

    // Add assembly file for x86_64/aarch64 platforms
    const cpu_arch = target.result.cpu.arch;
    if (cpu_arch == .x86_64 or cpu_arch == .aarch64) {
        // Define __BLST_PORTABLE__ to include all code paths (ADX and non-ADX)
        // This ensures compatibility on systems without ADX CPU instructions
        blst_module.addCMacro("__BLST_PORTABLE__", "1");
        blst_module.addAssemblyFile(blst_dep.path("build/assembly.S"));
    } else {
        // Use portable C mode for other architectures
        blst_module.addCMacro("__BLST_PORTABLE__", "1");
    }

    // Build blst as a static library
    const blst_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "blst",
        .root_module = blst_module,
    });

    // Main library module
    const mod = b.addModule("plutuz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Add blst include path and link library to the module
    mod.addIncludePath(blst_dep.path("bindings"));
    mod.linkLibrary(blst_lib);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "plutuz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plutuz", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Library tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Executable tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Test step
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Benchmark: plutus_use_cases
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "plutuz", .module = mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run plutus_use_cases benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Benchmark: turbo
    const bench_turbo_exe = b.addExecutable(.{
        .name = "bench-turbo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_turbo.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "plutuz", .module = mod },
            },
        }),
    });
    const run_bench_turbo = b.addRunArtifact(bench_turbo_exe);
    if (b.args) |args| run_bench_turbo.addArgs(args);
    const bench_turbo_step = b.step("bench-turbo", "Run turbo benchmarks (requires download first)");
    bench_turbo_step.dependOn(&run_bench_turbo.step);

    // Download: turbo benchmark data
    const download_bench = b.addSystemCommand(&.{
        "sh", "-c",
        "curl -fSL -o /tmp/turbo.tar.xz https://pub-2239d82d9a074482b2eb2c886191cb4e.r2.dev/turbo.tar.xz && " ++
            "mkdir -p bench/turbo && " ++
            "tar -xf /tmp/turbo.tar.xz -C bench/turbo && " ++
            "rm /tmp/turbo.tar.xz",
    });
    const download_bench_step = b.step("download-bench", "Download turbo benchmark data");
    download_bench_step.dependOn(&download_bench.step);

    // Download: conformance tests
    const download_conformance = b.addSystemCommand(&.{
        "sh", "-c",
        "curl -fSL -s https://github.com/IntersectMBO/plutus/archive/master.tar.gz | tar xz -C /tmp && " ++
            "rm -rf conformance/tests && " ++
            "mkdir -p conformance/tests && " ++
            "mv /tmp/plutus-master/plutus-conformance/test-cases/uplc/evaluation/* conformance/tests/ && " ++
            "rm -rf /tmp/plutus-master",
    });
    const download_conformance_step = b.step("download-conformance", "Download Plutus conformance tests");
    download_conformance_step.dependOn(&download_conformance.step);

    // Conformance test generator
    const gen_exe = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/generate.zig"),
            .target = b.graph.host,
        }),
    });
    const run_gen = b.addRunArtifact(gen_exe);

    // Format generated file
    const fmt = b.addFmt(.{ .paths = &.{"conformance/tests.zig"} });
    fmt.step.dependOn(&run_gen.step);

    // Conformance tests (auto-generates and formats before compiling)
    const conformance_mod = b.createModule(.{
        .root_source_file = b.path("conformance/tests.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "plutuz", .module = mod },
        },
    });
    const conformance_tests = b.addTest(.{
        .root_module = conformance_mod,
    });
    conformance_tests.step.dependOn(&fmt.step);
    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    const conformance_step = b.step("conformance", "Run conformance tests");
    conformance_step.dependOn(&run_conformance_tests.step);
}
