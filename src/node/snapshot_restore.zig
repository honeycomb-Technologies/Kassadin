const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");

pub const SlotNo = types.SlotNo;

pub const SnapshotLayout = struct {
    root_path: []u8,
    immutable_path: []u8,
    ledger_path: ?[]u8,

    pub fn deinit(self: *SnapshotLayout, allocator: Allocator) void {
        allocator.free(self.root_path);
        allocator.free(self.immutable_path);
        if (self.ledger_path) |path| allocator.free(path);
    }
};

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
fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn resolveSnapshotLayout(allocator: Allocator, db_path: []const u8) !SnapshotLayout {
    {
        const direct_root = try allocator.dupe(u8, db_path);
        errdefer allocator.free(direct_root);

        const direct_immutable = try std.fmt.allocPrint(allocator, "{s}/immutable", .{db_path});
        errdefer allocator.free(direct_immutable);

        if (dirExists(direct_immutable)) {
            const direct_ledger = std.fmt.allocPrint(allocator, "{s}/ledger", .{db_path}) catch null;
            if (direct_ledger) |path| {
                if (!dirExists(path)) {
                    allocator.free(path);
                    return .{
                        .root_path = direct_root,
                        .immutable_path = direct_immutable,
                        .ledger_path = null,
                    };
                }
            }

            return .{
                .root_path = direct_root,
                .immutable_path = direct_immutable,
                .ledger_path = direct_ledger,
            };
        }

        allocator.free(direct_root);
        allocator.free(direct_immutable);
    }

    var dir = try std.fs.cwd().openDir(db_path, .{ .iterate = true });
    defer dir.close();

    var nested_root: ?[]u8 = null;
    var nested_immutable: ?[]u8 = null;
    errdefer {
        if (nested_root) |path| allocator.free(path);
        if (nested_immutable) |path| allocator.free(path);
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        const candidate_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ db_path, entry.name });
        const candidate_immutable = try std.fmt.allocPrint(allocator, "{s}/immutable", .{candidate_root});

        if (!dirExists(candidate_immutable)) {
            allocator.free(candidate_root);
            allocator.free(candidate_immutable);
            continue;
        }

        if (nested_root != null) {
            allocator.free(candidate_root);
            allocator.free(candidate_immutable);
            return error.AmbiguousSnapshotLayout;
        }

        nested_root = candidate_root;
        nested_immutable = candidate_immutable;
    }

    const root_path = nested_root orelse return error.DirectoryNotFound;
    const immutable_path = nested_immutable.?;
    const ledger_path = std.fmt.allocPrint(allocator, "{s}/ledger", .{root_path}) catch null;
    if (ledger_path) |path| {
        if (!dirExists(path)) {
            allocator.free(path);
            return .{
                .root_path = root_path,
                .immutable_path = immutable_path,
                .ledger_path = null,
            };
        }
    }

    return .{
        .root_path = root_path,
        .immutable_path = immutable_path,
        .ledger_path = ledger_path,
    };
}

pub fn scanSnapshotDir(allocator: Allocator, db_path: []const u8) !SnapshotState {
    var state = SnapshotState{
        .immutable_tip_slot = 0,
        .immutable_tip_hash = [_]u8{0} ** 32,
        .immutable_file_count = 0,
        .ledger_state_slot = null,
        .db_path = db_path,
    };

    var layout = resolveSnapshotLayout(allocator, db_path) catch return state;
    defer layout.deinit(allocator);

    var dir = std.fs.cwd().openDir(layout.immutable_path, .{ .iterate = true }) catch return state;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".chunk")) {
            state.immutable_file_count += 1;
        }
    }

    if (layout.ledger_path) |ledger_path| {
        state.ledger_state_slot = findLatestLedgerSnapshotSlot(ledger_path);
    }

    return state;
}

pub fn findLatestLedgerSnapshotSlot(ledger_path: []const u8) ?SlotNo {
    var dir = std.fs.cwd().openDir(ledger_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var best: ?SlotNo = null;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        const slot = std.fmt.parseInt(SlotNo, entry.name, 10) catch continue;

        var path_buf: [512]u8 = undefined;
        const tvar_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/tables/tvar", .{ ledger_path, entry.name }) catch continue;
        if (!fileExists(tvar_path)) continue;

        best = if (best) |current| @max(current, slot) else slot;
    }

    return best;
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

test "snapshot_restore: resolve nested extracted layout" {
    const allocator = std.testing.allocator;
    const base = "/tmp/kassadin-snap-test3";
    const nested = "/tmp/kassadin-snap-test3/mithril-snapshot";

    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    std.fs.cwd().makePath("/tmp/kassadin-snap-test3/mithril-snapshot/immutable") catch {};
    std.fs.cwd().makePath("/tmp/kassadin-snap-test3/mithril-snapshot/ledger") catch {};

    var layout = try resolveSnapshotLayout(allocator, base);
    defer layout.deinit(allocator);

    try std.testing.expectEqualStrings(nested, layout.root_path);
    try std.testing.expectEqualStrings("/tmp/kassadin-snap-test3/mithril-snapshot/immutable", layout.immutable_path);
    try std.testing.expect(layout.ledger_path != null);
}

test "snapshot_restore: find latest ledger snapshot slot" {
    const base = "/tmp/kassadin-snap-test4";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};

    try std.fs.cwd().makePath("/tmp/kassadin-snap-test4/ledger/100/tables");
    try std.fs.cwd().makePath("/tmp/kassadin-snap-test4/ledger/250/tables");
    try std.fs.cwd().makePath("/tmp/kassadin-snap-test4/ledger/not-a-slot/tables");
    try std.fs.cwd().writeFile(.{ .sub_path = "/tmp/kassadin-snap-test4/ledger/100/tables/tvar", .data = "" });
    try std.fs.cwd().writeFile(.{ .sub_path = "/tmp/kassadin-snap-test4/ledger/250/tables/tvar", .data = "" });

    try std.testing.expectEqual(@as(?SlotNo, 250), findLatestLedgerSnapshotSlot("/tmp/kassadin-snap-test4/ledger"));
}
