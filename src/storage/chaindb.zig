const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;
const ImmutableDB = @import("immutable.zig").ImmutableDB;
const VolatileDB = @import("volatile.zig").VolatileDB;
const LedgerDB = @import("ledger.zig").LedgerDB;

pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;
pub const HeaderHash = types.HeaderHash;

/// Result of adding a block to the ChainDB.
pub const AddBlockResult = enum {
    added_to_current_chain,
    added_to_fork,
    already_known,
    invalid,
};

/// Unified interface combining ImmutableDB + VolatileDB + LedgerDB.
/// Manages the full block storage lifecycle: volatile → immutable promotion,
/// chain selection, and ledger state tracking.
pub const ChainDB = struct {
    allocator: Allocator,
    immutable: ImmutableDB,
    @"volatile": VolatileDB,
    ledger: LedgerDB,

    /// Current chain tip (from volatile or immutable).
    tip_slot: SlotNo,
    tip_hash: HeaderHash,
    tip_block_no: BlockNo,

    /// Security parameter k — blocks deeper than this are finalized.
    security_param: u64,

    pub fn open(allocator: Allocator, db_path: []const u8, security_param: u64) !ChainDB {
        var imm_path_buf: [256]u8 = undefined;
        const imm_path = try std.fmt.bufPrint(&imm_path_buf, "{s}/immutable", .{db_path});

        var ledger_path_buf: [256]u8 = undefined;
        const ledger_path = try std.fmt.bufPrint(&ledger_path_buf, "{s}/ledger", .{db_path});

        return .{
            .allocator = allocator,
            .immutable = try ImmutableDB.open(allocator, imm_path),
            .@"volatile" = VolatileDB.init(allocator),
            .ledger = try LedgerDB.init(allocator, ledger_path),
            .tip_slot = 0,
            .tip_hash = [_]u8{0} ** 32,
            .tip_block_no = 0,
            .security_param = security_param,
        };
    }

    pub fn close(self: *ChainDB) void {
        self.immutable.close();
        self.@"volatile".deinit();
        self.ledger.deinit();
    }

    /// Add a block to the chain database.
    /// First validates it's not a duplicate, then stores in volatile DB.
    pub fn addBlock(self: *ChainDB, block_data: []const u8, slot: SlotNo, block_no: BlockNo, prev_hash: ?HeaderHash) !AddBlockResult {
        const hash = Blake2b256.hash(block_data);

        // Check if already known
        if (self.@"volatile".getBlock(hash) != null) return .already_known;
        if (self.immutable.getBlock(hash) catch null != null) return .already_known;

        // Add to volatile DB
        try self.@"volatile".putBlock(block_data, slot, block_no, prev_hash);

        // Update tip if this extends the current chain
        if (prev_hash) |ph| {
            if (std.mem.eql(u8, &ph, &self.tip_hash) and block_no > self.tip_block_no) {
                self.tip_slot = slot;
                self.tip_hash = hash;
                self.tip_block_no = block_no;
                return .added_to_current_chain;
            }
        } else if (self.tip_block_no == 0) {
            // Genesis block
            self.tip_slot = slot;
            self.tip_hash = hash;
            self.tip_block_no = block_no;
            return .added_to_current_chain;
        }

        return .added_to_fork;
    }

    /// Promote finalized blocks from volatile to immutable.
    /// Blocks deeper than k from the tip are considered final.
    pub fn promoteFinalized(self: *ChainDB) !u32 {
        var promoted: u32 = 0;
        const vol = &self.@"volatile";

        var to_promote: std.ArrayList(HeaderHash) = .empty;
        defer to_promote.deinit(self.allocator);

        var it = vol.blocks.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr;
            if (self.tip_block_no > self.security_param and
                info.block_no <= self.tip_block_no - self.security_param)
            {
                try to_promote.append(self.allocator, info.hash);
            }
        }

        for (to_promote.items) |hash| {
            if (vol.getBlock(hash)) |info| {
                try self.immutable.appendBlock(info.data, info.slot, info.block_no);
                promoted += 1;
            }
        }

        // GC promoted blocks from volatile
        if (self.tip_block_no > self.security_param) {
            const min_slot = self.tip_slot -| (self.security_param * 2); // conservative
            try vol.garbageCollect(min_slot);
        }

        return promoted;
    }

    /// Get current tip.
    pub fn getTip(self: *const ChainDB) struct { slot: SlotNo, hash: HeaderHash, block_no: BlockNo } {
        return .{
            .slot = self.tip_slot,
            .hash = self.tip_hash,
            .block_no = self.tip_block_no,
        };
    }

    /// Total blocks across volatile + immutable.
    pub fn totalBlocks(self: *const ChainDB) usize {
        return self.@"volatile".count() + self.immutable.blockCount();
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "chaindb: open and close" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb", 2160);
    defer db.close();
    try std.testing.expectEqual(@as(usize, 0), db.totalBlocks());
}

test "chaindb: add blocks extends tip" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb2") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb2") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb2", 2160);
    defer db.close();

    // Add genesis-like block
    const result1 = try db.addBlock("block0", 0, 0, null);
    try std.testing.expect(result1 == .added_to_current_chain);

    // Add next block (extends chain)
    const prev_hash = Blake2b256.hash("block0");
    const result2 = try db.addBlock("block1", 10, 1, prev_hash);
    try std.testing.expect(result2 == .added_to_current_chain);

    try std.testing.expectEqual(@as(BlockNo, 1), db.getTip().block_no);
    try std.testing.expectEqual(@as(SlotNo, 10), db.getTip().slot);
}

test "chaindb: duplicate block returns already_known" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb3") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb3") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb3", 2160);
    defer db.close();

    _ = try db.addBlock("block0", 0, 0, null);
    const result = try db.addBlock("block0", 0, 0, null);
    try std.testing.expect(result == .already_known);
}

test "chaindb: fork block returns added_to_fork" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb4") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb4") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb4", 2160);
    defer db.close();

    _ = try db.addBlock("block0", 0, 0, null);
    const prev = Blake2b256.hash("block0");
    _ = try db.addBlock("block1a", 10, 1, prev);

    // Fork: different block at same height, same parent
    const result = try db.addBlock("block1b", 11, 1, prev);
    try std.testing.expect(result == .added_to_fork);

    try std.testing.expectEqual(@as(usize, 3), db.totalBlocks());
}
