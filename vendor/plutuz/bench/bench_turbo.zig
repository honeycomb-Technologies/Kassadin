const std = @import("std");
const plutuz = @import("plutuz");

const WARMUP_ITERATIONS = 3;
const MIN_ITERATIONS = 10;
const TIME_BUDGET_NS: u64 = 1 * std.time.ns_per_s;

const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    mean_ns: u64,
    median_ns: u64,
    min_ns: u64,
    max_ns: u64,
    stddev_ns: u64,
};

fn computeStats(samples: []u64) struct { mean: u64, median: u64, min: u64, max: u64, stddev: u64 } {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    var sum: u128 = 0;
    var min_val: u64 = std.math.maxInt(u64);
    var max_val: u64 = 0;

    for (samples) |s| {
        sum += s;
        min_val = @min(min_val, s);
        max_val = @max(max_val, s);
    }

    const mean: u64 = @intCast(sum / samples.len);
    const median = if (samples.len % 2 == 0)
        (samples[samples.len / 2 - 1] + samples[samples.len / 2]) / 2
    else
        samples[samples.len / 2];

    var variance_sum: u128 = 0;
    for (samples) |s| {
        const diff: i128 = @as(i128, s) - @as(i128, mean);
        variance_sum += @intCast(diff * diff);
    }
    const variance = variance_sum / samples.len;
    const stddev: u64 = std.math.sqrt(variance);

    return .{
        .mean = mean,
        .median = median,
        .min = min_val,
        .max = max_val,
        .stddev = stddev,
    };
}

fn formatNs(ns: u64) struct { value: f64, unit: []const u8 } {
    if (ns >= std.time.ns_per_s) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)), .unit = "s " };
    } else if (ns >= std.time.ns_per_ms) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms)), .unit = "ms" };
    } else if (ns >= std.time.ns_per_us) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_us)), .unit = "us" };
    } else {
        return .{ .value = @floatFromInt(ns), .unit = "ns" };
    }
}

const SemanticsVariant = plutuz.SemanticsVariant;

const PlutusVersion = enum {
    v1,
    v2,
    v3,
    unknown,

    fn fromFilename(name: []const u8) PlutusVersion {
        if (std.mem.endsWith(u8, name, ".v1.flat")) return .v1;
        if (std.mem.endsWith(u8, name, ".v2.flat")) return .v2;
        if (std.mem.endsWith(u8, name, ".v3.flat")) return .v3;
        return .unknown;
    }

    fn toSemantics(self: PlutusVersion) SemanticsVariant {
        return switch (self) {
            .v1, .v2 => .b, // post-Chang semantics for V1/V2
            .v3, .unknown => .c, // V3+ semantics
        };
    }
};

/// Unwrap a single CBOR byte string to get the inner flat bytes.
/// Turbo files are CBOR-wrapped: major type 2 (byte string) header + flat payload.
fn unwrapCbor(file_bytes: []const u8) ?[]const u8 {
    if (file_bytes.len == 0) return null;
    const major = file_bytes[0] >> 5;
    if (major != 2) return null; // not a byte string
    const additional = file_bytes[0] & 0x1f;
    if (additional < 24) {
        // 1-byte header, length = additional
        return file_bytes[1..];
    } else if (additional == 24 and file_bytes.len >= 2) {
        // 2-byte header (0x58 LL)
        return file_bytes[2..];
    } else if (additional == 25 and file_bytes.len >= 3) {
        // 3-byte header (0x59 LL LL)
        return file_bytes[3..];
    } else if (additional == 26 and file_bytes.len >= 5) {
        // 5-byte header (0x5a LL LL LL LL)
        return file_bytes[5..];
    }
    return null;
}

fn runBenchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    file_bytes: []const u8,
    version: PlutusVersion,
    quiet: bool,
) !BenchResult {
    const semantics = version.toSemantics();

    // Unwrap CBOR byte string to get flat bytes
    const flat_bytes = unwrapCbor(file_bytes) orelse {
        if (!quiet) std.debug.print("  {s}: CBOR unwrap failed\n", .{name});
        return .{ .name = name, .iterations = 0, .mean_ns = 0, .median_ns = 0, .min_ns = 0, .max_ns = 0, .stddev_ns = 0 };
    };

    // Verify the file decodes before benchmarking
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = plutuz.decodeFlatDeBruijn(arena.allocator(), flat_bytes) catch |err| {
            if (!quiet) std.debug.print("  {s}: decode error: {}\n", .{ name, err });
            return .{ .name = name, .iterations = 0, .mean_ns = 0, .median_ns = 0, .min_ns = 0, .max_ns = 0, .stddev_ns = 0 };
        };
    }

    // Reusable arena for warmup + measured iterations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Warmup: decode + eval each iteration
    for (0..WARMUP_ITERATIONS) |_| {
        const program = plutuz.decodeFlatDeBruijn(arena.allocator(), flat_bytes) catch continue;
        _ = plutuz.evalVersion(arena.allocator(), program, semantics) catch {};
        _ = arena.reset(.retain_capacity);
    }

    // Measured iterations: decode + eval per iteration
    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(allocator);

    var timer = try std.time.Timer.start();
    var total_elapsed: u64 = 0;

    while (samples.items.len < MIN_ITERATIONS or total_elapsed < TIME_BUDGET_NS) {
        timer.reset();
        const program = plutuz.decodeFlatDeBruijn(arena.allocator(), flat_bytes) catch break;
        _ = plutuz.evalVersion(arena.allocator(), program, semantics) catch {};
        const elapsed = timer.read();
        _ = arena.reset(.retain_capacity);
        try samples.append(allocator, elapsed);
        total_elapsed += elapsed;

        if (samples.items.len >= 100) break;
    }

    const stats = computeStats(samples.items);

    return .{
        .name = name,
        .iterations = samples.items.len,
        .mean_ns = stats.mean,
        .median_ns = stats.median,
        .min_ns = stats.min,
        .max_ns = stats.max,
        .stddev_ns = stats.stddev,
    };
}

fn writeJsonResults(allocator: std.mem.Allocator, results: []const BenchResult, path: []const u8) !void {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);

    const epoch = std.time.timestamp();

    try json.appendSlice(allocator, "{\n  \"timestamp\": ");
    var epoch_buf: [20]u8 = undefined;
    const epoch_str = std.fmt.bufPrint(&epoch_buf, "{d}", .{epoch}) catch "0";
    try json.appendSlice(allocator, epoch_str);
    try json.appendSlice(allocator, ",\n  \"benchmarks\": [\n");

    for (results, 0..) |r, i| {
        try json.appendSlice(allocator, "    {\n");

        try json.appendSlice(allocator, "      \"name\": \"");
        try json.appendSlice(allocator, r.name);
        try json.appendSlice(allocator, "\",\n");

        var buf: [64]u8 = undefined;

        try json.appendSlice(allocator, "      \"iterations\": ");
        try json.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{r.iterations}) catch "0");
        try json.appendSlice(allocator, ",\n");

        try json.appendSlice(allocator, "      \"mean_ns\": ");
        try json.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{r.mean_ns}) catch "0");
        try json.appendSlice(allocator, ",\n");

        try json.appendSlice(allocator, "      \"median_ns\": ");
        try json.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{r.median_ns}) catch "0");
        try json.appendSlice(allocator, ",\n");

        try json.appendSlice(allocator, "      \"min_ns\": ");
        try json.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{r.min_ns}) catch "0");
        try json.appendSlice(allocator, ",\n");

        try json.appendSlice(allocator, "      \"max_ns\": ");
        try json.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{r.max_ns}) catch "0");
        try json.appendSlice(allocator, ",\n");

        try json.appendSlice(allocator, "      \"stddev_ns\": ");
        try json.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{r.stddev_ns}) catch "0");
        try json.appendSlice(allocator, "\n");

        if (i < results.len - 1) {
            try json.appendSlice(allocator, "    },\n");
        } else {
            try json.appendSlice(allocator, "    }\n");
        }
    }

    try json.appendSlice(allocator, "  ]\n}\n");

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(json.items);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse args
    var quiet = false;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        }
    }

    const bench_dir = "bench/turbo";
    const results_path = "bench/results/turbo.json";

    var top_dir = std.fs.cwd().openDir(bench_dir, .{ .iterate = true }) catch {
        std.debug.print("error: cannot open {s}\n", .{bench_dir});
        std.debug.print("hint: run `zig build download-bench` to download turbo benchmark data\n", .{});
        std.process.exit(1);
    };
    defer top_dir.close();

    var subdir_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (subdir_names.items) |name| allocator.free(name);
        subdir_names.deinit(allocator);
    }

    {
        var iter = top_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            try subdir_names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    std.mem.sort([]const u8, subdir_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    if (subdir_names.items.len == 0) {
        std.debug.print("No subdirectories found in {s}\n", .{bench_dir});
        std.debug.print("hint: run `zig build download-bench` to download turbo benchmark data\n", .{});
        std.process.exit(1);
    }

    if (!quiet) {
        std.debug.print("Found {d} turbo benchmark directories\n", .{subdir_names.items.len});
        std.debug.print("\nturbo benchmarks\n", .{});
        std.debug.print("{s}\n", .{"=" ** 75});
    }

    var results: std.ArrayList(BenchResult) = .empty;
    defer results.deinit(allocator);

    for (subdir_names.items) |subdir_name| {
        const subdir_path = try std.fs.path.join(allocator, &.{ bench_dir, subdir_name });
        defer allocator.free(subdir_path);

        var subdir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch continue;
        defer subdir.close();

        var sub_iter = subdir.iterate();
        while (try sub_iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".flat")) continue;

            const file_path = try std.fs.path.join(allocator, &.{ subdir_path, entry.name });
            defer allocator.free(file_path);

            const file_bytes = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch continue;
            defer allocator.free(file_bytes);

            const version = PlutusVersion.fromFilename(entry.name);

            const bench_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ subdir_name, entry.name });
            defer allocator.free(bench_name);

            const result = try runBenchmark(allocator, bench_name, file_bytes, version, quiet);
            try results.append(allocator, result);

            if (!quiet) {
                const mean = formatNs(result.mean_ns);
                const stddev = formatNs(result.stddev_ns);
                const min = formatNs(result.min_ns);
                const max = formatNs(result.max_ns);
                std.debug.print("  {s:<30} {d:>5} runs  {d:>8.2}{s} +/- {d:>6.2}{s}  [{d:>6.2}{s} .. {d:>6.2}{s}]\n", .{
                    result.name,
                    result.iterations,
                    mean.value,
                    mean.unit,
                    stddev.value,
                    stddev.unit,
                    min.value,
                    min.unit,
                    max.value,
                    max.unit,
                });
            }
        }
    }

    if (!quiet) {
        std.debug.print("{s}\n", .{"=" ** 75});
    }

    // Ensure results directory exists and write JSON
    std.fs.cwd().makePath("bench/results") catch {};
    try writeJsonResults(allocator, results.items, results_path);
    if (!quiet) {
        std.debug.print("Results saved to {s}\n", .{results_path});
    }
}
