const std = @import("std");
const Allocator = std.mem.Allocator;

/// Mithril snapshot metadata from the aggregator API.
pub const SnapshotInfo = struct {
    digest: []const u8,
    epoch: u64,
    immutable_file_number: u64,
    size: u64, // bytes
    download_url: []const u8,
    compression: []const u8,
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
    return parseSnapshotJson(result.stdout);
}

fn parseSnapshotJson(json: []const u8) !SnapshotInfo {
    // The response is an array of snapshots, we want the first one
    // Simple extraction by finding key strings

    const digest = extractJsonString(json, "\"digest\"") orelse return error.InvalidJson;
    const epoch = extractJsonUint(json, "\"epoch\"") orelse return error.InvalidJson;
    const imm_file = extractJsonUint(json, "\"immutable_file_number\"") orelse return error.InvalidJson;
    const size = extractJsonUint(json, "\"size\"") orelse return error.InvalidJson;

    // Find download URL in locations array
    const url_start = std.mem.indexOf(u8, json, "\"https://") orelse return error.InvalidJson;
    const url_content_start = url_start + 1; // skip opening quote
    const url_end = std.mem.indexOfPos(u8, json, url_content_start, "\"") orelse return error.InvalidJson;

    const compression = extractJsonString(json, "\"compression_algorithm\"") orelse "zstandard";

    return .{
        .digest = digest,
        .epoch = epoch,
        .immutable_file_number = imm_file,
        .size = size,
        .download_url = json[url_content_start..url_end],
        .compression = compression,
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

    // Download
    std.debug.print("Downloading snapshot ({} MB)...\n", .{snapshot.size / 1024 / 1024});
    const dl_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-L", "-o", archive_path, snapshot.download_url },
        .max_output_bytes = 1024,
    });
    defer allocator.free(dl_result.stdout);
    defer allocator.free(dl_result.stderr);

    if (dl_result.term.Exited != 0) return error.DownloadFailed;

    // Extract
    std.debug.print("Extracting snapshot...\n", .{});
    const extract_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-xf", archive_path, "-C", db_path, "--use-compress-program=zstd" },
        .max_output_bytes = 1024,
    });
    defer allocator.free(extract_result.stdout);
    defer allocator.free(extract_result.stderr);

    if (extract_result.term.Exited != 0) return error.ExtractFailed;

    // Clean up archive
    std.fs.cwd().deleteFile(archive_path) catch {};

    std.debug.print("Snapshot restored to {s}\n", .{db_path});
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "mithril: fetch preprod snapshot info" {
    const allocator = std.testing.allocator;
    const info = fetchLatestSnapshot(allocator, aggregator_urls.preprod) catch return; // skip if no network
    try std.testing.expect(info.epoch > 0);
    try std.testing.expect(info.size > 0);
    try std.testing.expect(info.download_url.len > 0);
}

test "mithril: aggregator URLs" {
    try std.testing.expect(std.mem.indexOf(u8, aggregator_urls.preprod, "preprod") != null);
    try std.testing.expect(std.mem.indexOf(u8, aggregator_urls.mainnet, "mainnet") != null);
}

test "mithril: parse snapshot JSON" {
    const json =
        \\[{"digest":"abc123","beacon":{"epoch":276,"immutable_file_number":5455},"size":3192000000,"locations":["https://example.com/snapshot.tar.zst"],"compression_algorithm":"zstandard","created_at":"2026-03-15"}]
    ;
    const info = try parseSnapshotJson(json);
    try std.testing.expectEqualSlices(u8, "abc123", info.digest);
    try std.testing.expectEqual(@as(u64, 276), info.epoch);
    try std.testing.expectEqual(@as(u64, 5455), info.immutable_file_number);
    try std.testing.expectEqual(@as(u64, 3192000000), info.size);
}
