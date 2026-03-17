const std = @import("std");
const Allocator = std.mem.Allocator;
const snapshot_restore = @import("snapshot_restore.zig");

/// Mithril snapshot metadata from the aggregator API.
pub const SnapshotInfo = struct {
    digest: []const u8,
    epoch: u64,
    immutable_file_number: u64,
    size: u64, // bytes
    ancillary_size: u64, // bytes
    download_url: []const u8,
    ancillary_download_url: ?[]const u8,
    compression: []const u8,
    cardano_node_version: ?[]const u8,

    pub fn deinit(self: SnapshotInfo, allocator: Allocator) void {
        allocator.free(self.digest);
        allocator.free(self.download_url);
        if (self.ancillary_download_url) |url| allocator.free(url);
        allocator.free(self.compression);
        if (self.cardano_node_version) |version| allocator.free(version);
    }
};

/// Mithril aggregator URLs for known networks.
pub const aggregator_urls = struct {
    pub const mainnet = "https://aggregator.release-mainnet.api.mithril.network/aggregator";
    pub const preprod = "https://aggregator.release-preprod.api.mithril.network/aggregator";
    pub const preview = "https://aggregator.release-preview.api.mithril.network/aggregator";
};

/// Fetch the latest snapshot info from a Mithril aggregator.
/// Returns the download URL and metadata.
///
/// This is a simplified implementation that shells out to curl.
/// A proper implementation would use HTTP client directly.
pub fn fetchLatestSnapshot(allocator: Allocator, aggregator_url: []const u8) !SnapshotInfo {
    // Shell out to curl to fetch the API response
    const url = try std.fmt.allocPrint(allocator, "{s}/artifact/snapshots", .{aggregator_url});
    defer allocator.free(url);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-s", url },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) return error.CurlFailed;

    // Parse JSON response (simplified — extract key fields)
    return parseSnapshotJson(allocator, result.stdout);
}

fn parseSnapshotJson(allocator: Allocator, json: []const u8) !SnapshotInfo {
    // The response is an array of snapshots, we want the first one
    // Simple extraction by finding key strings

    const digest = extractJsonString(json, "\"digest\"") orelse return error.InvalidJson;
    const epoch = extractJsonUint(json, "\"epoch\"") orelse return error.InvalidJson;
    const imm_file = extractJsonUint(json, "\"immutable_file_number\"") orelse return error.InvalidJson;
    const size = extractJsonUint(json, "\"size\"") orelse return error.InvalidJson;
    const ancillary_size = extractJsonUint(json, "\"ancillary_size\"") orelse 0;
    const download_url = extractJsonArrayFirstString(json, "\"locations\"") orelse return error.InvalidJson;
    const ancillary_download_url = extractJsonArrayFirstString(json, "\"ancillary_locations\"");

    const compression = extractJsonString(json, "\"compression_algorithm\"") orelse "zstandard";
    const cardano_node_version = extractJsonString(json, "\"cardano_node_version\"");

    return .{
        .digest = try allocator.dupe(u8, digest),
        .epoch = epoch,
        .immutable_file_number = imm_file,
        .size = size,
        .ancillary_size = ancillary_size,
        .download_url = try allocator.dupe(u8, download_url),
        .ancillary_download_url = if (ancillary_download_url) |url| try allocator.dupe(u8, url) else null,
        .compression = try allocator.dupe(u8, compression),
        .cardano_node_version = if (cardano_node_version) |version| try allocator.dupe(u8, version) else null,
    };
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[pos + key.len ..];
    // Skip to value: whitespace, colon, whitespace, opening quote
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\n' or after_key[i] == '\r' or after_key[i] == '\t')) : (i += 1) {}
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
    return after_key[start..i];
}

fn extractJsonUint(json: []const u8, key: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[pos + key.len ..];
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] < '0' or after_key[i] > '9')) : (i += 1) {}
    var end = i;
    while (end < after_key.len and after_key[end] >= '0' and after_key[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u64, after_key[i..end], 10) catch null;
}

fn extractJsonArrayFirstString(json: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[pos + key.len ..];
    const open = std.mem.indexOfScalar(u8, after_key, '[') orelse return null;
    const after_open = after_key[open + 1 ..];

    var i: usize = 0;
    while (i < after_open.len and (after_open[i] == ' ' or after_open[i] == '\n' or after_open[i] == '\r' or after_open[i] == '\t')) : (i += 1) {}
    if (i >= after_open.len or after_open[i] != '"') return null;

    const start = i + 1;
    const end = std.mem.indexOfScalarPos(u8, after_open, start, '"') orelse return null;
    return after_open[start..end];
}

/// Download a Mithril snapshot and extract it to the database path.
///
/// Steps:
/// 1. Download the .tar.zst archive using curl
/// 2. Extract using tar + zstd
/// 3. Verify the immutable files exist
pub fn downloadAndExtract(allocator: Allocator, snapshot: SnapshotInfo, db_path: []const u8) !void {
    std.fs.cwd().makePath(db_path) catch {};

    const archive_path = try std.fmt.allocPrint(allocator, "{s}/snapshot.tar.zst", .{db_path});
    defer allocator.free(archive_path);

    const ancillary_archive_path = try std.fmt.allocPrint(allocator, "{s}/snapshot.ancillary.tar.zst", .{db_path});
    defer allocator.free(ancillary_archive_path);

    const main_chunk_exists = blk: {
        var chunk_buf: [512]u8 = undefined;
        const chunk_path = try std.fmt.bufPrint(&chunk_buf, "{s}/immutable/{d:0>5}.chunk", .{ db_path, snapshot.immutable_file_number });
        break :blk fileExists(chunk_path);
    };

    if (!main_chunk_exists) {
        std.debug.print("Downloading snapshot ({} MB)...\n", .{snapshot.size / 1024 / 1024});
        try downloadArchive(allocator, snapshot.download_url, archive_path);

        std.debug.print("Extracting snapshot...\n", .{});
        try extractArchive(allocator, archive_path, db_path);
        std.fs.cwd().deleteFile(archive_path) catch {};
    } else {
        std.debug.print("Snapshot immutable files already present under {s}; skipping main archive download.\n", .{db_path});
    }

    const state_before_ancillary = try snapshot_restore.scanSnapshotDir(allocator, db_path);
    if (snapshot.ancillary_download_url) |url| {
        if (state_before_ancillary.ledger_state_slot == null) {
            std.debug.print("Downloading ancillary files ({} MB)...\n", .{snapshot.ancillary_size / 1024 / 1024});
            try downloadArchive(allocator, url, ancillary_archive_path);

            std.debug.print("Extracting ancillary files...\n", .{});
            try extractArchive(allocator, ancillary_archive_path, db_path);
            std.fs.cwd().deleteFile(ancillary_archive_path) catch {};
        } else {
            std.debug.print("Ledger ancillary files already present under {s}; skipping ancillary download.\n", .{db_path});
        }
    }

    const state = try snapshot_restore.scanSnapshotDir(allocator, db_path);
    if (state.immutable_file_count == 0) {
        return error.InvalidSnapshotLayout;
    }

    std.debug.print("Snapshot restored to {s} ({} immutable chunks)\n", .{
        db_path,
        state.immutable_file_count,
    });
    if (state.ledger_state_slot) |slot| {
        std.debug.print("Latest local ledger snapshot slot: {}\n", .{slot});
    }
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn downloadArchive(allocator: Allocator, url: []const u8, archive_path: []const u8) !void {
    const dl_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sS", "-L", "-o", archive_path, url },
        .max_output_bytes = 4096,
    });
    defer allocator.free(dl_result.stdout);
    defer allocator.free(dl_result.stderr);

    if (dl_result.term.Exited != 0) return error.DownloadFailed;
}

fn extractArchive(allocator: Allocator, archive_path: []const u8, db_path: []const u8) !void {
    const extract_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-xf", archive_path, "-C", db_path, "--use-compress-program=zstd" },
        .max_output_bytes = 1024,
    });
    defer allocator.free(extract_result.stdout);
    defer allocator.free(extract_result.stderr);

    if (extract_result.term.Exited != 0) return error.ExtractFailed;
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "mithril: fetch preprod snapshot info" {
    const allocator = std.testing.allocator;
    const info = fetchLatestSnapshot(allocator, aggregator_urls.preprod) catch return; // skip if no network
    defer info.deinit(allocator);
    try std.testing.expect(info.epoch > 0);
    try std.testing.expect(info.size > 0);
    try std.testing.expect(info.download_url.len > 0);
    try std.testing.expect(info.ancillary_size > 0);
    try std.testing.expect(info.ancillary_download_url != null);
}

test "mithril: aggregator URLs" {
    try std.testing.expect(std.mem.indexOf(u8, aggregator_urls.preprod, "preprod") != null);
    try std.testing.expect(std.mem.indexOf(u8, aggregator_urls.mainnet, "mainnet") != null);
}

test "mithril: parse snapshot JSON" {
    const json =
        \\[{"digest":"abc123","beacon":{"epoch":276,"immutable_file_number":5455},"size":3192000000,"ancillary_size":1234000,"locations":["https://example.com/snapshot.tar.zst"],"ancillary_locations":["https://example.com/snapshot.ancillary.tar.zst"],"compression_algorithm":"zstandard","cardano_node_version":"10.6.2","created_at":"2026-03-15"}]
    ;
    const info = try parseSnapshotJson(std.testing.allocator, json);
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "abc123", info.digest);
    try std.testing.expectEqual(@as(u64, 276), info.epoch);
    try std.testing.expectEqual(@as(u64, 5455), info.immutable_file_number);
    try std.testing.expectEqual(@as(u64, 3192000000), info.size);
    try std.testing.expectEqual(@as(u64, 1234000), info.ancillary_size);
    try std.testing.expectEqualStrings("https://example.com/snapshot.ancillary.tar.zst", info.ancillary_download_url.?);
}
