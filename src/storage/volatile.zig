const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;
pub const HeaderHash = types.HeaderHash;

/// Info about a block stored in the volatile DB.
pub const BlockInfo = struct {
    hash: HeaderHash,
    slot: SlotNo,
    block_no: BlockNo,
    prev_hash: ?HeaderHash, // null for genesis
    data: []const u8, // raw CBOR block data (owned by VolatileDB)
};

/// In-memory storage for recent blocks within k=2160 slots of the tip.
/// Supports multiple forks. Used for chain selection before blocks are finalized.
pub const VolatileDB = struct {
    allocator: Allocator,

    /// All known blocks by hash.
    blocks: std.AutoHashMap(HeaderHash, BlockInfo),

    /// Successor map: parent_hash → set of child hashes.
    /// Used to construct candidate chains for chain selection.
    successors: std.AutoHashMap(HeaderHash, std.AutoHashMap(HeaderHash, void)),

    /// Maximum slot seen.
    max_slot: SlotNo,

    pub fn init(allocator: Allocator) VolatileDB {
        return .{
            .allocator = allocator,
            .blocks = std.AutoHashMap(HeaderHash, BlockInfo).init(allocator),
            .successors = std.AutoHashMap(HeaderHash, std.AutoHashMap(HeaderHash, void)).init(allocator),
            .max_slot = 0,
        };
    }

    pub fn deinit(self: *VolatileDB) void {
        // Free block data
        var block_it = self.blocks.valueIterator();
        while (block_it.next()) |info| {
            self.allocator.free(info.data);
        }
        self.blocks.deinit();

        // Free successor sets
        var succ_it = self.successors.valueIterator();
        while (succ_it.next()) |set| {
            var s = set.*;
            s.deinit();
        }
        self.successors.deinit();
    }

    /// Add a block to the volatile DB.
    pub fn putBlock(self: *VolatileDB, hash: HeaderHash, data: []const u8, slot: SlotNo, block_no: BlockNo, prev_hash: ?HeaderHash) !void {
        // Already known?
        if (self.blocks.contains(hash)) return;

        // Copy block data (we own it)
        const owned_data = try self.allocator.dupe(u8, data);

        try self.blocks.put(hash, .{
            .hash = hash,
            .slot = slot,
            .block_no = block_no,
            .prev_hash = prev_hash,
            .data = owned_data,
        });

        // Update successor map
        if (prev_hash) |ph| {
            var entry = try self.successors.getOrPut(ph);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.AutoHashMap(HeaderHash, void).init(self.allocator);
            }
            try entry.value_ptr.put(hash, {});
        }

        if (slot > self.max_slot) {
            self.max_slot = slot;
        }
    }

    /// Get a block by hash.
    pub fn getBlock(self: *const VolatileDB, hash: HeaderHash) ?*const BlockInfo {
        return self.blocks.getPtr(hash);
    }

    /// Get all successors (children) of a given block hash.
    pub fn getSuccessors(self: *const VolatileDB, hash: HeaderHash) ?*const std.AutoHashMap(HeaderHash, void) {
        return self.successors.getPtr(hash);
    }

    /// Number of blocks stored.
    pub fn count(self: *const VolatileDB) usize {
        return self.blocks.count();
    }

    /// Garbage collect blocks with slot < given slot.
    pub fn garbageCollect(self: *VolatileDB, min_slot: SlotNo) !void {
        var to_remove: std.ArrayList(HeaderHash) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.blocks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.slot < min_slot) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_remove.items) |hash| {
            if (self.blocks.fetchRemove(hash)) |removed| {
                self.allocator.free(removed.value.data);

                // Remove from successor map
                if (removed.value.prev_hash) |ph| {
                    if (self.successors.getPtr(ph)) |succ_set| {
                        _ = succ_set.remove(hash);
                    }
                }
            }
        }
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "volatiledb: init and deinit" {
    const allocator = std.testing.allocator;
    var db = VolatileDB.init(allocator);
    defer db.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.count());
}

test "volatiledb: put and get block" {
    const allocator = std.testing.allocator;
    var db = VolatileDB.init(allocator);
    defer db.deinit();

    const data = "test block data";
    const hash = Blake2b256.hash(data);
    try db.putBlock(hash, data, 100, 1, null);

    try std.testing.expectEqual(@as(usize, 1), db.count());
    try std.testing.expectEqual(@as(SlotNo, 100), db.max_slot);

    const info = db.getBlock(hash).?;
    try std.testing.expectEqual(@as(SlotNo, 100), info.slot);
    try std.testing.expectEqualSlices(u8, data, info.data);
}

test "volatiledb: successor tracking" {
    const allocator = std.testing.allocator;
    var db = VolatileDB.init(allocator);
    defer db.deinit();

    const parent = "parent block";
    const parent_hash = Blake2b256.hash(parent);
    try db.putBlock(parent_hash, parent, 100, 1, null);

    // Add two children
    try db.putBlock(Blake2b256.hash("child1"), "child1", 110, 2, parent_hash);
    try db.putBlock(Blake2b256.hash("child2"), "child2", 115, 3, parent_hash);

    const successors = db.getSuccessors(parent_hash).?;
    try std.testing.expectEqual(@as(usize, 2), successors.count());
}

test "volatiledb: duplicate block ignored" {
    const allocator = std.testing.allocator;
    var db = VolatileDB.init(allocator);
    defer db.deinit();

    const hash = Blake2b256.hash("same block");
    try db.putBlock(hash, "same block", 100, 1, null);
    try db.putBlock(hash, "same block", 100, 1, null); // duplicate

    try std.testing.expectEqual(@as(usize, 1), db.count());
}

test "volatiledb: garbage collection" {
    const allocator = std.testing.allocator;
    var db = VolatileDB.init(allocator);
    defer db.deinit();

    try db.putBlock(Blake2b256.hash("old block"), "old block", 50, 1, null);
    try db.putBlock(Blake2b256.hash("new block"), "new block", 200, 2, null);

    try std.testing.expectEqual(@as(usize, 2), db.count());

    try db.garbageCollect(100); // remove blocks with slot < 100

    try std.testing.expectEqual(@as(usize, 1), db.count());
    try std.testing.expectEqual(@as(SlotNo, 200), db.max_slot);
}

test "volatiledb: fork tracking (3 competing chains)" {
    const allocator = std.testing.allocator;
    var db = VolatileDB.init(allocator);
    defer db.deinit();

    // Common ancestor
    const ancestor = "ancestor";
    const ancestor_hash = Blake2b256.hash(ancestor);
    try db.putBlock(ancestor_hash, ancestor, 100, 1, null);

    // Fork 1: 2 blocks
    try db.putBlock(Blake2b256.hash("fork1-block1"), "fork1-block1", 110, 2, ancestor_hash);
    const f1b1_hash = Blake2b256.hash("fork1-block1");
    try db.putBlock(Blake2b256.hash("fork1-block2"), "fork1-block2", 120, 3, f1b1_hash);

    // Fork 2: 1 block
    try db.putBlock(Blake2b256.hash("fork2-block1"), "fork2-block1", 111, 2, ancestor_hash);

    // Fork 3: 3 blocks
    try db.putBlock(Blake2b256.hash("fork3-block1"), "fork3-block1", 109, 2, ancestor_hash);
    const f3b1_hash = Blake2b256.hash("fork3-block1");
    try db.putBlock(Blake2b256.hash("fork3-block2"), "fork3-block2", 119, 3, f3b1_hash);
    const f3b2_hash = Blake2b256.hash("fork3-block2");
    try db.putBlock(Blake2b256.hash("fork3-block3"), "fork3-block3", 130, 4, f3b2_hash);

    // Total: 7 blocks
    try std.testing.expectEqual(@as(usize, 7), db.count());

    // Ancestor should have 3 successors (one from each fork)
    const successors = db.getSuccessors(ancestor_hash).?;
    try std.testing.expectEqual(@as(usize, 3), successors.count());
}
