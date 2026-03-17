const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");

pub const SlotNo = types.SlotNo;
pub const TxIn = types.TxIn;
pub const Coin = types.Coin;
pub const HeaderHash = types.HeaderHash;
pub const Credential = types.Credential;
pub const KeyHash = types.KeyHash;

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
    consumed: []const UtxoEntry, // UTxOs consumed (full entries for rollback)
    produced: []const UtxoEntry, // UTxOs produced (outputs)
    stake_deposit_changes: []const StakeDepositChange = &.{},
    pool_deposit_changes: []const PoolDepositChange = &.{},
    drep_deposit_changes: []const DRepDepositChange = &.{},
};

pub const StakeDepositChange = struct {
    credential: Credential,
    previous: ?Coin,
    next: ?Coin,
};

pub const PoolDepositChange = struct {
    pool: KeyHash,
    previous: ?Coin,
    next: ?Coin,
};

pub const DRepDepositChange = struct {
    credential: Credential,
    previous: ?Coin,
    next: ?Coin,
};

/// Manages the ledger state: UTxO set, stake distribution, protocol parameters.
/// For Phase 2, this is a simplified in-memory UTxO set with diff-based rollback.
/// Full LMDB-backed storage comes when we need mainnet-scale UTxO sets.
pub const LedgerDB = struct {
    allocator: Allocator,

    /// Current UTxO set (in-memory for now — LMDB for production).
    utxo_set: std.AutoHashMap(TxIn, UtxoEntry),
    stake_deposits: std.AutoHashMap(Credential, Coin),
    pool_deposits: std.AutoHashMap(KeyHash, Coin),
    drep_deposits: std.AutoHashMap(Credential, Coin),

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
            .stake_deposits = std.AutoHashMap(Credential, Coin).init(allocator),
            .pool_deposits = std.AutoHashMap(KeyHash, Coin).init(allocator),
            .drep_deposits = std.AutoHashMap(Credential, Coin).init(allocator),
            .diffs = .empty,
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
        self.stake_deposits.deinit();
        self.pool_deposits.deinit();
        self.drep_deposits.deinit();

        // Diffs own their consumed/produced slices
        for (self.diffs.items) |diff| {
            freeEntries(self.allocator, diff.consumed);
            freeEntries(self.allocator, diff.produced);
            freeStakeChanges(self.allocator, diff.stake_deposit_changes);
            freePoolChanges(self.allocator, diff.pool_deposit_changes);
            freeDRepChanges(self.allocator, diff.drep_deposit_changes);
        }
        self.diffs.deinit(self.allocator);
    }

    /// Apply a ledger diff (from a validated block).
    /// Takes ownership of the diff's consumed and produced slices.
    pub fn applyDiff(self: *LedgerDB, diff: LedgerDiff) !void {
        // Remove consumed UTxOs
        for (diff.consumed) |entry| {
            if (self.utxo_set.fetchRemove(entry.tx_in)) |removed| {
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

        applyStakeDepositChanges(&self.stake_deposits, diff.stake_deposit_changes);
        applyPoolDepositChanges(&self.pool_deposits, diff.pool_deposit_changes);
        applyDRepDepositChanges(&self.drep_deposits, diff.drep_deposit_changes);

        // Store diff for rollback (we take ownership of consumed/produced slices)
        try self.diffs.append(self.allocator, diff);

        // Trim diffs to k=2160
        const max_diffs = 2160;
        while (self.diffs.items.len > max_diffs) {
            const old = self.diffs.orderedRemove(0);
            freeEntries(self.allocator, old.consumed);
            freeEntries(self.allocator, old.produced);
            freeStakeChanges(self.allocator, old.stake_deposit_changes);
            freePoolChanges(self.allocator, old.pool_deposit_changes);
            freeDRepChanges(self.allocator, old.drep_deposit_changes);
        }

        self.tip_slot = diff.slot;
    }

    /// Rollback the last n diffs.
    pub fn rollback(self: *LedgerDB, n: usize) !void {
        var i: usize = 0;
        while (i < n and self.diffs.items.len > 0) : (i += 1) {
            const diff = self.diffs.pop().?;

            // Undo: remove produced UTxOs
            for (diff.produced) |entry| {
                if (self.utxo_set.fetchRemove(entry.tx_in)) |removed| {
                    self.allocator.free(removed.value.raw_cbor);
                }
            }

            // Undo: re-add consumed UTxOs with their original values.
            for (diff.consumed) |entry| {
                const owned_cbor = try self.allocator.dupe(u8, entry.raw_cbor);
                try self.utxo_set.put(entry.tx_in, .{
                    .tx_in = entry.tx_in,
                    .value = entry.value,
                    .raw_cbor = owned_cbor,
                });
            }

            // Free diff-owned slices
            freeEntries(self.allocator, diff.consumed);
            freeEntries(self.allocator, diff.produced);
            rollbackStakeDepositChanges(&self.stake_deposits, diff.stake_deposit_changes);
            rollbackPoolDepositChanges(&self.pool_deposits, diff.pool_deposit_changes);
            rollbackDRepDepositChanges(&self.drep_deposits, diff.drep_deposit_changes);
            freeStakeChanges(self.allocator, diff.stake_deposit_changes);
            freePoolChanges(self.allocator, diff.pool_deposit_changes);
            freeDRepChanges(self.allocator, diff.drep_deposit_changes);
        }

        // Update tip
        if (self.diffs.items.len > 0) {
            self.tip_slot = self.diffs.items[self.diffs.items.len - 1].slot;
        } else {
            self.tip_slot = null;
        }
    }

    /// Seed base UTxOs without recording a diff.
    /// Used when hydrating state from an external snapshot/query source.
    pub fn primeUtxos(self: *LedgerDB, entries: []const UtxoEntry) !u32 {
        var inserted: u32 = 0;

        for (entries) |entry| {
            if (self.utxo_set.contains(entry.tx_in)) continue;

            const owned_cbor = try self.allocator.dupe(u8, entry.raw_cbor);
            try self.utxo_set.put(entry.tx_in, .{
                .tx_in = entry.tx_in,
                .value = entry.value,
                .raw_cbor = owned_cbor,
            });
            inserted += 1;
        }

        return inserted;
    }

    /// Insert a UTxO entry loaded from an external snapshot.
    /// Snapshot imports use empty raw bytes to keep memory usage down.
    pub fn importUtxo(self: *LedgerDB, tx_in: TxIn, value: Coin) !void {
        if (self.utxo_set.contains(tx_in)) return;

        try self.utxo_set.put(tx_in, .{
            .tx_in = tx_in,
            .value = value,
            .raw_cbor = try self.allocator.alloc(u8, 0),
        });
    }

    pub fn setTipSlot(self: *LedgerDB, slot: ?SlotNo) void {
        self.tip_slot = slot;
    }

    /// Lookup a UTxO by TxIn.
    pub fn lookupUtxo(self: *const LedgerDB, txin: TxIn) ?*const UtxoEntry {
        return self.utxo_set.getPtr(txin);
    }

    pub fn lookupStakeDeposit(self: *const LedgerDB, credential: Credential) ?Coin {
        return self.stake_deposits.get(credential);
    }

    pub fn lookupPoolDeposit(self: *const LedgerDB, pool: KeyHash) ?Coin {
        return self.pool_deposits.get(pool);
    }

    pub fn lookupDRepDeposit(self: *const LedgerDB, credential: Credential) ?Coin {
        return self.drep_deposits.get(credential);
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

fn freeEntries(allocator: Allocator, entries: []const UtxoEntry) void {
    for (entries) |entry| {
        allocator.free(entry.raw_cbor);
    }
    allocator.free(entries);
}

fn freeStakeChanges(allocator: Allocator, changes: []const StakeDepositChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freePoolChanges(allocator: Allocator, changes: []const PoolDepositChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freeDRepChanges(allocator: Allocator, changes: []const DRepDepositChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn applyStakeDepositChanges(
    map: *std.AutoHashMap(Credential, Coin),
    changes: []const StakeDepositChange,
) void {
    for (changes) |change| {
        if (change.next) |deposit| {
            map.put(change.credential, deposit) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn rollbackStakeDepositChanges(
    map: *std.AutoHashMap(Credential, Coin),
    changes: []const StakeDepositChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |deposit| {
            map.put(change.credential, deposit) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn applyPoolDepositChanges(
    map: *std.AutoHashMap(KeyHash, Coin),
    changes: []const PoolDepositChange,
) void {
    for (changes) |change| {
        if (change.next) |deposit| {
            map.put(change.pool, deposit) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn rollbackPoolDepositChanges(
    map: *std.AutoHashMap(KeyHash, Coin),
    changes: []const PoolDepositChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |deposit| {
            map.put(change.pool, deposit) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn applyDRepDepositChanges(
    map: *std.AutoHashMap(Credential, Coin),
    changes: []const DRepDepositChange,
) void {
    for (changes) |change| {
        if (change.next) |deposit| {
            map.put(change.credential, deposit) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn rollbackDRepDepositChanges(
    map: *std.AutoHashMap(Credential, Coin),
    changes: []const DRepDepositChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |deposit| {
            map.put(change.credential, deposit) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

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
    produced[0] = .{ .tx_in = makeTxIn(0x01, 0), .value = 1_000_000, .raw_cbor = try allocator.dupe(u8, "utxo1") };
    produced[1] = .{ .tx_in = makeTxIn(0x01, 1), .value = 2_000_000, .raw_cbor = try allocator.dupe(u8, "utxo2") };

    const consumed = try allocator.alloc(UtxoEntry, 0);

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

test "ledgerdb: apply diff tracks and rolls back stake deposits" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-stake-deposits");
    defer db.deinit();

    const cred = Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xcc} ** 28,
    };

    try db.applyDiff(.{
        .slot = 10,
        .block_hash = [_]u8{0x11} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = try allocator.alloc(UtxoEntry, 0),
        .stake_deposit_changes = try allocator.dupe(StakeDepositChange, &[_]StakeDepositChange{
            .{
                .credential = cred,
                .previous = null,
                .next = 2_000_000,
            },
        }),
    });

    try std.testing.expectEqual(@as(?Coin, 2_000_000), db.lookupStakeDeposit(cred));

    try db.rollback(1);
    try std.testing.expect(db.lookupStakeDeposit(cred) == null);
}

test "ledgerdb: apply diff consumes utxos" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger3");
    defer db.deinit();

    // First, produce some UTxOs
    const produced1 = try allocator.alloc(UtxoEntry, 2);
    produced1[0] = .{ .tx_in = makeTxIn(0x01, 0), .value = 5_000_000, .raw_cbor = try allocator.dupe(u8, "out1") };
    produced1[1] = .{ .tx_in = makeTxIn(0x01, 1), .value = 3_000_000, .raw_cbor = try allocator.dupe(u8, "out2") };
    try db.applyDiff(.{
        .slot = 100,
        .block_hash = [_]u8{0xaa} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = produced1,
    });

    try std.testing.expectEqual(@as(usize, 2), db.utxoCount());

    // Now consume one UTxO and produce a new one
    const consumed2 = try allocator.alloc(UtxoEntry, 1);
    consumed2[0] = .{
        .tx_in = makeTxIn(0x01, 0),
        .value = 5_000_000,
        .raw_cbor = try allocator.dupe(u8, "out1"),
    };
    const produced2 = try allocator.alloc(UtxoEntry, 1);
    produced2[0] = .{ .tx_in = makeTxIn(0x02, 0), .value = 4_000_000, .raw_cbor = try allocator.dupe(u8, "out3") };

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
    produced[0] = .{ .tx_in = makeTxIn(0x01, 0), .value = 1_000_000, .raw_cbor = try allocator.dupe(u8, "x") };
    try db.applyDiff(.{
        .slot = 100,
        .block_hash = [_]u8{0xaa} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = produced,
    });

    try std.testing.expectEqual(@as(usize, 1), db.utxoCount());

    // Rollback
    try db.rollback(1);

    try std.testing.expectEqual(@as(usize, 0), db.utxoCount());
    try std.testing.expect(db.getTipSlot() == null);
}

test "ledgerdb: rollback restores consumed utxos" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger5");
    defer db.deinit();

    const original = try allocator.alloc(UtxoEntry, 1);
    original[0] = .{ .tx_in = makeTxIn(0x09, 0), .value = 7_000_000, .raw_cbor = try allocator.dupe(u8, "seed") };
    try db.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = original,
    });

    const consumed = try allocator.alloc(UtxoEntry, 1);
    consumed[0] = .{ .tx_in = makeTxIn(0x09, 0), .value = 7_000_000, .raw_cbor = try allocator.dupe(u8, "seed") };
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{ .tx_in = makeTxIn(0x0a, 0), .value = 6_000_000, .raw_cbor = try allocator.dupe(u8, "new") };

    try db.applyDiff(.{
        .slot = 10,
        .block_hash = [_]u8{0xaa} ** 32,
        .consumed = consumed,
        .produced = produced,
    });

    try std.testing.expect(db.lookupUtxo(makeTxIn(0x09, 0)) == null);
    try db.rollback(1);
    try std.testing.expect(db.lookupUtxo(makeTxIn(0x09, 0)) != null);
    try std.testing.expect(db.lookupUtxo(makeTxIn(0x0a, 0)) == null);
}
