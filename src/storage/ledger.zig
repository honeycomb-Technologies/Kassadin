const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

pub const SlotNo = types.SlotNo;
pub const TxIn = types.TxIn;
pub const TxId = types.TxId;
pub const Coin = types.Coin;
pub const HeaderHash = types.HeaderHash;

/// A simplified UTxO entry (full TxOut support comes in Phase 3).
pub const UtxoEntry = struct {
    tx_in: TxIn,
    value: Coin,
    raw_cbor: []const u8, // original CBOR bytes for byte-preserving hashing
};

/// A ledger state diff produced by applying one block.
pub const LedgerDiff = struct {
    slot: SlotNo,
    block_hash: HeaderHash,
    consumed: []const TxIn, // UTxOs consumed (inputs)
    produced: []const UtxoEntry, // UTxOs produced (outputs)
};

/// Manages the ledger state: UTxO set, stake distribution, protocol parameters.
/// For Phase 2, this is a simplified in-memory UTxO set with diff-based rollback.
/// Full LMDB-backed storage comes when we need mainnet-scale UTxO sets.
pub const LedgerDB = struct {
    allocator: Allocator,

    /// Current UTxO set (in-memory for now — LMDB for production).
    utxo_set: std.AutoHashMap(TxIn, UtxoEntry),

    /// Ring buffer of recent diffs for rollback support.
    /// Keeps the last k=2160 diffs.
    diffs: std.ArrayList(LedgerDiff),

    /// Current tip slot.
    tip_slot: ?SlotNo,

    /// Snapshot directory.
    snapshot_path: []const u8,

    pub fn init(allocator: Allocator, snapshot_path: []const u8) !LedgerDB {
        std.fs.cwd().makePath(snapshot_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return .{
            .allocator = allocator,
            .utxo_set = std.AutoHashMap(TxIn, UtxoEntry).init(allocator),
            .diffs = std.ArrayList(LedgerDiff).init(allocator),
            .tip_slot = null,
            .snapshot_path = snapshot_path,
        };
    }

    pub fn deinit(self: *LedgerDB) void {
        // Free UTxO entries (these own their raw_cbor)
        var it = self.utxo_set.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.raw_cbor);
        }
        self.utxo_set.deinit();

        // Diffs own their consumed/produced slices
        for (self.diffs.items) |diff| {
            self.allocator.free(diff.consumed);
            self.allocator.free(diff.produced);
        }
        self.diffs.deinit();
    }

    /// Apply a ledger diff (from a validated block).
    /// Takes ownership of the diff's consumed and produced slices.
    pub fn applyDiff(self: *LedgerDB, diff: LedgerDiff) !void {
        // Remove consumed UTxOs
        for (diff.consumed) |txin| {
            if (self.utxo_set.fetchRemove(txin)) |removed| {
                self.allocator.free(removed.value.raw_cbor);
            }
        }

        // Add produced UTxOs
        for (diff.produced) |entry| {
            const owned_cbor = try self.allocator.dupe(u8, entry.raw_cbor);
            try self.utxo_set.put(entry.tx_in, .{
                .tx_in = entry.tx_in,
                .value = entry.value,
                .raw_cbor = owned_cbor,
            });
        }

        // Store diff for rollback (we take ownership of consumed/produced slices)
        try self.diffs.append(diff);

        // Trim diffs to k=2160
        const max_diffs = 2160;
        while (self.diffs.items.len > max_diffs) {
            const old = self.diffs.orderedRemove(0);
            self.allocator.free(old.consumed);
            self.allocator.free(old.produced);
        }

        self.tip_slot = diff.slot;
    }

    /// Rollback the last n diffs.
    pub fn rollback(self: *LedgerDB, n: usize) !void {
        var i: usize = 0;
        while (i < n and self.diffs.items.len > 0) : (i += 1) {
            const diff = self.diffs.pop();

            // Undo: remove produced UTxOs
            for (diff.produced) |entry| {
                if (self.utxo_set.fetchRemove(entry.tx_in)) |removed| {
                    self.allocator.free(removed.value.raw_cbor);
                }
            }

            // Undo: re-add consumed UTxOs
            // NOTE: In a real implementation, we'd store the consumed UTxO values
            // in the diff. For Phase 2, we just remove the produced ones.
            // Full undo requires storing consumed values, which comes in Phase 3.

            // Free diff-owned slices
            self.allocator.free(diff.consumed);
            self.allocator.free(diff.produced);
        }

        // Update tip
        if (self.diffs.items.len > 0) {
            self.tip_slot = self.diffs.items[self.diffs.items.len - 1].slot;
        } else {
            self.tip_slot = null;
        }
    }

    /// Lookup a UTxO by TxIn.
    pub fn lookupUtxo(self: *const LedgerDB, txin: TxIn) ?*const UtxoEntry {
        return self.utxo_set.getPtr(txin);
    }

    /// Total number of UTxOs in the set.
    pub fn utxoCount(self: *const LedgerDB) usize {
        return self.utxo_set.count();
    }

    /// Current tip slot.
    pub fn getTipSlot(self: *const LedgerDB) ?SlotNo {
        return self.tip_slot;
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

fn makeTxIn(id_byte: u8, ix: u16) TxIn {
    return .{ .tx_id = [_]u8{id_byte} ** 32, .tx_ix = ix };
}

test "ledgerdb: init and deinit" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger");
    defer db.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.utxoCount());
    try std.testing.expect(db.getTipSlot() == null);
}

test "ledgerdb: apply diff adds utxos" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger2");
    defer db.deinit();

    const produced = try allocator.alloc(UtxoEntry, 2);
    produced[0] = .{ .tx_in = makeTxIn(0x01, 0), .value = 1_000_000, .raw_cbor = "utxo1" };
    produced[1] = .{ .tx_in = makeTxIn(0x01, 1), .value = 2_000_000, .raw_cbor = "utxo2" };

    const consumed = try allocator.alloc(TxIn, 0);

    try db.applyDiff(.{
        .slot = 100,
        .block_hash = [_]u8{0xaa} ** 32,
        .consumed = consumed,
        .produced = produced,
    });

    try std.testing.expectEqual(@as(usize, 2), db.utxoCount());
    try std.testing.expectEqual(@as(?SlotNo, 100), db.getTipSlot());

    // Lookup specific UTxO
    const entry = db.lookupUtxo(makeTxIn(0x01, 0)).?;
    try std.testing.expectEqual(@as(Coin, 1_000_000), entry.value);
}

test "ledgerdb: apply diff consumes utxos" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger3");
    defer db.deinit();

    // First, produce some UTxOs
    const produced1 = try allocator.alloc(UtxoEntry, 2);
    produced1[0] = .{ .tx_in = makeTxIn(0x01, 0), .value = 5_000_000, .raw_cbor = "out1" };
    produced1[1] = .{ .tx_in = makeTxIn(0x01, 1), .value = 3_000_000, .raw_cbor = "out2" };
    try db.applyDiff(.{
        .slot = 100,
        .block_hash = [_]u8{0xaa} ** 32,
        .consumed = try allocator.alloc(TxIn, 0),
        .produced = produced1,
    });

    try std.testing.expectEqual(@as(usize, 2), db.utxoCount());

    // Now consume one UTxO and produce a new one
    const consumed2 = try allocator.alloc(TxIn, 1);
    consumed2[0] = makeTxIn(0x01, 0);
    const produced2 = try allocator.alloc(UtxoEntry, 1);
    produced2[0] = .{ .tx_in = makeTxIn(0x02, 0), .value = 4_000_000, .raw_cbor = "out3" };

    try db.applyDiff(.{
        .slot = 200,
        .block_hash = [_]u8{0xbb} ** 32,
        .consumed = consumed2,
        .produced = produced2,
    });

    try std.testing.expectEqual(@as(usize, 2), db.utxoCount()); // 2-1+1 = 2
    try std.testing.expect(db.lookupUtxo(makeTxIn(0x01, 0)) == null); // consumed
    try std.testing.expect(db.lookupUtxo(makeTxIn(0x01, 1)) != null); // still there
    try std.testing.expect(db.lookupUtxo(makeTxIn(0x02, 0)) != null); // newly produced
}

test "ledgerdb: rollback removes produced utxos" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger4");
    defer db.deinit();

    // Apply a diff
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{ .tx_in = makeTxIn(0x01, 0), .value = 1_000_000, .raw_cbor = "x" };
    try db.applyDiff(.{
        .slot = 100,
        .block_hash = [_]u8{0xaa} ** 32,
        .consumed = try allocator.alloc(TxIn, 0),
        .produced = produced,
    });

    try std.testing.expectEqual(@as(usize, 1), db.utxoCount());

    // Rollback
    try db.rollback(1);

    try std.testing.expectEqual(@as(usize, 0), db.utxoCount());
    try std.testing.expect(db.getTipSlot() == null);
}
