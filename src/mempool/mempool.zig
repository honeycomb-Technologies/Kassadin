const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

pub const TxId = types.TxId;
pub const Coin = types.Coin;

/// A validated transaction in the mempool.
pub const MempoolTx = struct {
    tx_id: TxId,
    raw_cbor: []const u8, // owned by the mempool
    size_bytes: u32,
    fee: Coin,
    arrival_order: u64,
};

/// Transaction mempool — holds pending transactions for block forging.
pub const Mempool = struct {
    allocator: Allocator,
    txs: std.AutoHashMap(TxId, MempoolTx),
    capacity_bytes: u32,
    current_bytes: u32,
    next_order: u64,

    pub fn init(allocator: Allocator, capacity_bytes: u32) Mempool {
        return .{
            .allocator = allocator,
            .txs = std.AutoHashMap(TxId, MempoolTx).init(allocator),
            .capacity_bytes = capacity_bytes,
            .current_bytes = 0,
            .next_order = 0,
        };
    }

    pub fn deinit(self: *Mempool) void {
        var it = self.txs.valueIterator();
        while (it.next()) |tx| {
            self.allocator.free(tx.raw_cbor);
        }
        self.txs.deinit();
    }

    /// Add a validated transaction to the mempool.
    pub fn addTx(self: *Mempool, raw_cbor: []const u8, fee: Coin) !bool {
        const tx_id = Blake2b256.hash(raw_cbor);
        const size: u32 = @intCast(raw_cbor.len);

        // Already in mempool?
        if (self.txs.contains(tx_id)) return false;

        // Capacity check
        if (self.current_bytes + size > self.capacity_bytes) return false;

        // Copy data (mempool owns it)
        const owned = try self.allocator.dupe(u8, raw_cbor);

        try self.txs.put(tx_id, .{
            .tx_id = tx_id,
            .raw_cbor = owned,
            .size_bytes = size,
            .fee = fee,
            .arrival_order = self.next_order,
        });

        self.current_bytes += size;
        self.next_order += 1;
        return true;
    }

    /// Remove a transaction by ID (e.g., after inclusion in a block).
    pub fn removeTx(self: *Mempool, tx_id: TxId) bool {
        if (self.txs.fetchRemove(tx_id)) |removed| {
            self.current_bytes -= removed.value.size_bytes;
            self.allocator.free(removed.value.raw_cbor);
            return true;
        }
        return false;
    }

    /// Check if a transaction is in the mempool.
    pub fn hasTx(self: *const Mempool, tx_id: TxId) bool {
        return self.txs.contains(tx_id);
    }

    /// Number of transactions in the mempool.
    pub fn count(self: *const Mempool) usize {
        return self.txs.count();
    }

    /// Current size in bytes.
    pub fn sizeBytes(self: *const Mempool) u32 {
        return self.current_bytes;
    }

    /// Get transactions sorted by fee density (fee/size) for block forging.
    /// Returns up to max_bytes worth of transactions.
    pub fn selectForForging(self: *const Mempool, allocator: Allocator, max_bytes: u32) ![]const MempoolTx {
        var result = std.ArrayList(MempoolTx).init(allocator);
        defer result.deinit();

        // Collect all txs
        var it = self.txs.valueIterator();
        while (it.next()) |tx| {
            try result.append(tx.*);
        }

        // Sort by fee density (descending — highest fee/byte first)
        std.sort.pdq(MempoolTx, result.items, {}, struct {
            fn lessThan(_: void, a: MempoolTx, b: MempoolTx) bool {
                // Compare fee density: a.fee/a.size vs b.fee/b.size
                // Cross-multiply to avoid division: a.fee * b.size vs b.fee * a.size
                return (a.fee * @as(u64, b.size_bytes)) > (b.fee * @as(u64, a.size_bytes));
            }
        }.lessThan);

        // Select txs up to max_bytes
        var selected = std.ArrayList(MempoolTx).init(allocator);
        var total_bytes: u32 = 0;
        for (result.items) |tx| {
            if (total_bytes + tx.size_bytes > max_bytes) continue;
            try selected.append(tx);
            total_bytes += tx.size_bytes;
        }

        return selected.toOwnedSlice();
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "mempool: add and remove transactions" {
    const allocator = std.testing.allocator;
    var pool = Mempool.init(allocator, 1_000_000);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.count());

    // Add a tx
    const added = try pool.addTx("fake tx data", 200_000);
    try std.testing.expect(added);
    try std.testing.expectEqual(@as(usize, 1), pool.count());

    // Duplicate rejected
    const dup = try pool.addTx("fake tx data", 200_000);
    try std.testing.expect(!dup);
    try std.testing.expectEqual(@as(usize, 1), pool.count());

    // Remove
    const tx_id = Blake2b256.hash("fake tx data");
    try std.testing.expect(pool.removeTx(tx_id));
    try std.testing.expectEqual(@as(usize, 0), pool.count());
}

test "mempool: capacity enforcement" {
    const allocator = std.testing.allocator;
    var pool = Mempool.init(allocator, 100); // 100 bytes capacity
    defer pool.deinit();

    // Add a tx that fits
    const added1 = try pool.addTx("short", 100_000);
    try std.testing.expect(added1);

    // Add a tx that exceeds remaining capacity
    const big_data = [_]u8{0xaa} ** 200;
    const added2 = try pool.addTx(&big_data, 100_000);
    try std.testing.expect(!added2); // rejected
}

test "mempool: size tracking" {
    const allocator = std.testing.allocator;
    var pool = Mempool.init(allocator, 1_000_000);
    defer pool.deinit();

    _ = try pool.addTx("tx1 (10 bytes)", 100_000);
    _ = try pool.addTx("tx2 (10 bytes)", 200_000);

    try std.testing.expectEqual(@as(u32, 28), pool.sizeBytes()); // 14 + 14 bytes
}

test "mempool: select for forging prioritizes high fee density" {
    const allocator = std.testing.allocator;
    var pool = Mempool.init(allocator, 1_000_000);
    defer pool.deinit();

    // Low fee density: 100 bytes, 1000 lovelace (10 per byte)
    const low_fee = [_]u8{0x11} ** 100;
    _ = try pool.addTx(&low_fee, 1_000);

    // High fee density: 50 bytes, 5000 lovelace (100 per byte)
    const high_fee = [_]u8{0x22} ** 50;
    _ = try pool.addTx(&high_fee, 5_000);

    const selected = try pool.selectForForging(allocator, 200);
    defer allocator.free(selected);

    // High fee density tx should be first
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqual(@as(Coin, 5_000), selected[0].fee);
    try std.testing.expectEqual(@as(Coin, 1_000), selected[1].fee);
}

test "mempool: hasTx" {
    const allocator = std.testing.allocator;
    var pool = Mempool.init(allocator, 1_000_000);
    defer pool.deinit();

    const tx_id = Blake2b256.hash("test tx");
    try std.testing.expect(!pool.hasTx(tx_id));

    _ = try pool.addTx("test tx", 100_000);
    try std.testing.expect(pool.hasTx(tx_id));
}
