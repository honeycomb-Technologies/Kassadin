const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

pub const SlotNo = types.SlotNo;

/// Information about a restored Mithril snapshot.
pub const SnapshotState = struct {
    immutable_tip_slot: SlotNo,
    immutable_tip_hash: [32]u8,
    immutable_file_count: u32,
    ledger_state_slot: ?SlotNo,
    db_path: []const u8,
};

/// Scan a Mithril snapshot directory to understand what we have.
/// The Haskell node's ImmutableDB stores files as:
///   NNNNN.chunk (block data)
///   NNNNN.primary (slot → offset index)
///   NNNNN.secondary (hash → block info)
///
/// Mithril snapshots may also include:
///   ledger/ directory with ledger state snapshots
pub fn scanSnapshotDir(allocator: Allocator, db_path: []const u8) !SnapshotState {
    _ = allocator;

    var state = SnapshotState{
        .immutable_tip_slot = 0,
        .immutable_tip_hash = [_]u8{0} ** 32,
        .immutable_file_count = 0,
        .ledger_state_slot = null,
        .db_path = db_path,
    };

    // Count chunk files
    var immutable_path_buf: [512]u8 = undefined;
    const immutable_path = std.fmt.bufPrint(&immutable_path_buf, "{s}/immutable", .{db_path}) catch return state;

    var dir = std.fs.cwd().openDir(immutable_path, .{ .iterate = true }) catch return state;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".chunk")) {
            state.immutable_file_count += 1;
        }
    }

    // Check for ledger state
    var ledger_path_buf: [512]u8 = undefined;
    const ledger_path = std.fmt.bufPrint(&ledger_path_buf, "{s}/ledger", .{db_path}) catch return state;
    if (std.fs.cwd().openDir(ledger_path, .{})) |d| {
        var d2 = d;
        d2.close();
        state.ledger_state_slot = 0;
    } else |_| {}

    return state;
}

/// Extract a Mithril snapshot archive to the database directory.
/// Uses system tar + zstd commands.
pub fn extractSnapshot(db_path: []const u8, archive_path: []const u8) !void {
    std.debug.print("Extracting {s} to {s}...\n", .{ archive_path, db_path });

    std.fs.cwd().makePath(db_path) catch {};

    const result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "tar", "-xf", archive_path, "-C", db_path, "--use-compress-program=zstd" },
    });
    std.heap.page_allocator.free(result.stdout);
    std.heap.page_allocator.free(result.stderr);
    if (result.term.Exited != 0) return error.ExtractFailed;

    std.debug.print("Extraction complete.\n", .{});
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "snapshot_restore: scan nonexistent directory" {
    const state = try scanSnapshotDir(std.testing.allocator, "/tmp/nonexistent-kassadin-test");
    try std.testing.expectEqual(@as(u32, 0), state.immutable_file_count);
}

test "snapshot_restore: scan empty directory" {
    std.fs.cwd().makePath("/tmp/kassadin-snap-test/immutable") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-snap-test") catch {};

    const state = try scanSnapshotDir(std.testing.allocator, "/tmp/kassadin-snap-test");
    try std.testing.expectEqual(@as(u32, 0), state.immutable_file_count);
}

test "snapshot_restore: detect chunk files" {
    const test_path = "/tmp/kassadin-snap-test2/immutable";
    std.fs.cwd().makePath(test_path) catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-snap-test2") catch {};

    // Create fake chunk files
    for (0..5) |i| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}/{d:0>5}.chunk", .{ test_path, i }) catch continue;
        const f = std.fs.cwd().createFile(name, .{}) catch continue;
        f.close();
    }

    const state = try scanSnapshotDir(std.testing.allocator, "/tmp/kassadin-snap-test2");
    try std.testing.expectEqual(@as(u32, 5), state.immutable_file_count);
}
