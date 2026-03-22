const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;
const block_mod = @import("../ledger/block.zig");

pub const SlotNo = types.SlotNo;
pub const HeaderHash = types.HeaderHash;
pub const BlockNo = types.BlockNo;

/// Tip of the immutable chain.
pub const ImmutableTip = struct {
    slot: SlotNo,
    hash: HeaderHash,
    block_no: BlockNo,
    chunk_no: u32,
};

/// Block info stored in the secondary index.
pub const BlockInfo = struct {
    slot: SlotNo,
    hash: HeaderHash,
    block_no: BlockNo,
    chunk_no: u32,
    offset: u64, // byte offset in chunk file
    size: u32, // block size in bytes
    header_offset: u16, // offset of header within block
    header_size: u16, // header size in bytes
    is_ebb: bool, // epoch boundary block
};

/// Append-only storage for finalized blocks, organized in epoch-sized chunks.
///
/// Layout on disk:
///   db/immutable/NNNNN.chunk    — concatenated block CBOR
///   db/immutable/NNNNN.primary  — slot → offset index
///   db/immutable/NNNNN.secondary — hash → block info
pub const ImmutableDB = struct {
    allocator: Allocator,
    base_path: []const u8,
    current_chunk: u32,
    tip: ?ImmutableTip,
    // In-memory secondary index for the current chunk
    secondary_index: std.AutoHashMap(HeaderHash, BlockInfo),
    // Current chunk file handle
    chunk_file: ?std.fs.File,
    /// When set, appendBlock() will skip to boundary+1 instead of writing
    /// into Mithril snapshot chunks (which use different framing).
    mithril_boundary_chunk: ?u32 = null,

    pub fn open(allocator: Allocator, base_path: []const u8) !ImmutableDB {
        // Ensure directory exists
        std.fs.cwd().makePath(base_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var db = ImmutableDB{
            .allocator = allocator,
            .base_path = base_path,
            .current_chunk = 0,
            .tip = null,
            .secondary_index = std.AutoHashMap(HeaderHash, BlockInfo).init(allocator),
            .chunk_file = null,
        };

        // Scan for existing chunks to find the tip
        try db.recoverState();

        return db;
    }

    pub fn close(self: *ImmutableDB) void {
        if (self.chunk_file) |f| f.close();
        self.secondary_index.deinit();
    }

    /// Mark the highest Mithril snapshot chunk so appendBlock() won't corrupt it.
    pub fn setMithrilBoundary(self: *ImmutableDB, last_chunk: u32) void {
        self.mithril_boundary_chunk = last_chunk;
    }

    /// Clean up state for Mithril snapshot coexistence.
    /// Deletes any chunks WE wrote beyond the boundary, and clears the
    /// in-memory secondary index so Mithril blocks (parsed with wrong
    /// framing assumptions) don't cause false `already_known` rejections.
    pub fn truncateAfterBoundary(self: *ImmutableDB, boundary_chunk: u32) !void {
        // Close current chunk handle if open
        if (self.chunk_file) |f| {
            f.close();
            self.chunk_file = null;
        }

        // Delete chunk files beyond the boundary
        var path_buf: [256]u8 = undefined;
        var chunk_no = boundary_chunk + 1;
        while (chunk_no <= self.current_chunk + 1) : (chunk_no += 1) {
            const path = std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{ self.base_path, chunk_no }) catch continue;
            std.fs.cwd().deleteFile(path) catch {};
        }

        // Clear the in-memory index entirely. Our recoverChunk uses
        // length-prefix framing, but Mithril chunks are raw CBOR — some
        // blocks parse by coincidence and create false index entries.
        // New blocks written after the boundary will re-populate the index.
        self.secondary_index.clearRetainingCapacity();
        self.tip = null;
        self.current_chunk = boundary_chunk + 1;
    }

    /// Append a block to the current chunk.
    pub fn appendBlock(self: *ImmutableDB, hash: HeaderHash, block_data: []const u8, slot: SlotNo, block_no: BlockNo) !void {
        // Skip past Mithril snapshot chunks to avoid corrupting them.
        if (self.mithril_boundary_chunk) |boundary| {
            if (self.current_chunk <= boundary) {
                if (self.chunk_file) |f| {
                    f.close();
                    self.chunk_file = null;
                }
                self.current_chunk = boundary + 1;
            }
        }

        // Open or create chunk file
        if (self.chunk_file == null) {
            self.chunk_file = try self.openOrCreateChunk(self.current_chunk);
        }

        const file = self.chunk_file.?;
        const offset = try file.getEndPos();
        try file.seekTo(offset);

        // Write block with length prefix (4 bytes, big-endian)
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(block_data.len), .big);
        try file.writeAll(&len_buf);
        try file.writeAll(block_data);

        // Update secondary index
        try self.secondary_index.put(hash, .{
            .slot = slot,
            .hash = hash,
            .block_no = block_no,
            .chunk_no = self.current_chunk,
            .offset = offset,
            .size = @intCast(block_data.len),
            .header_offset = 0, // TODO: parse header offset from block
            .header_size = 0,
            .is_ebb = false,
        });

        // Update tip
        self.tip = .{
            .slot = slot,
            .hash = hash,
            .block_no = block_no,
            .chunk_no = self.current_chunk,
        };
    }

    /// Get a block by its hash.
    pub fn getBlock(self: *ImmutableDB, hash: HeaderHash) !?[]const u8 {
        const info = self.secondary_index.get(hash) orelse return null;
        return try self.readBlockAt(info.chunk_no, info.offset, info.size);
    }

    /// Get the current tip.
    pub fn getTip(self: *const ImmutableDB) ?ImmutableTip {
        return self.tip;
    }

    /// Count blocks stored.
    pub fn blockCount(self: *const ImmutableDB) usize {
        return self.secondary_index.count();
    }

    // ── Internal ──

    fn openOrCreateChunk(self: *ImmutableDB, chunk_no: u32) !std.fs.File {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{ self.base_path, chunk_no });
        return std.fs.cwd().createFile(path, .{ .read = true, .truncate = false }) catch |err| {
            if (err == error.PathAlreadyExists) {
                return std.fs.cwd().openFile(path, .{ .mode = .read_write });
            }
            return err;
        };
    }

    fn readBlockAt(self: *ImmutableDB, chunk_no: u32, offset: u64, size: u32) ![]const u8 {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{ self.base_path, chunk_no });
        var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        try file.seekTo(offset);

        // Read length prefix
        var len_buf: [4]u8 = undefined;
        const len_read = try file.readAll(&len_buf);
        if (len_read != 4) return error.UnexpectedEndOfFile;

        const block_len = std.mem.readInt(u32, &len_buf, .big);
        if (block_len != size) return error.CorruptedData;

        // Read block data
        const block = try self.allocator.alloc(u8, block_len);
        const data_read = try file.readAll(block);
        if (data_read != block_len) {
            self.allocator.free(block);
            return error.UnexpectedEndOfFile;
        }

        return block;
    }

    fn recoverState(self: *ImmutableDB) !void {
        var dir = std.fs.cwd().openDir(self.base_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var discovered: std.ArrayList(u32) = .empty;
        defer discovered.deinit(self.allocator);

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".chunk")) continue;
            const chunk_str = entry.name[0 .. entry.name.len - ".chunk".len];
            const chunk_no = std.fmt.parseInt(u32, chunk_str, 10) catch continue;
            try discovered.append(self.allocator, chunk_no);
        }

        if (discovered.items.len == 0) {
            self.current_chunk = 0;
            self.tip = null;
            return;
        }

        std.mem.sort(u32, discovered.items, {}, comptime std.sort.asc(u32));
        self.current_chunk = discovered.items[discovered.items.len - 1];

        for (discovered.items) |chunk_no| {
            try self.recoverChunk(chunk_no);
        }
    }

    fn recoverChunk(self: *ImmutableDB, chunk_no: u32) !void {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{ self.base_path, chunk_no });
        var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        const end_pos = try file.getEndPos();
        var offset: u64 = 0;

        while (offset < end_pos) {
            try file.seekTo(offset);

            var len_buf: [4]u8 = undefined;
            const len_read = try file.readAll(&len_buf);
            if (len_read == 0) break;
            if (len_read != len_buf.len) break;

            const block_len = std.mem.readInt(u32, &len_buf, .big);
            const remaining = end_pos - offset - len_buf.len;
            if (block_len == 0 or block_len > remaining) break;

            const block_data = try self.allocator.alloc(u8, block_len);
            defer self.allocator.free(block_data);

            const data_read = try file.readAll(block_data);
            if (data_read != block_len) break;

            const block = block_mod.parseBlock(block_data) catch break;
            const hash = block.hash();
            try self.secondary_index.put(hash, .{
                .slot = block.header.slot,
                .hash = hash,
                .block_no = block.header.block_no,
                .chunk_no = chunk_no,
                .offset = offset,
                .size = block_len,
                .header_offset = 0,
                .header_size = 0,
                .is_ebb = false,
            });
            self.tip = .{
                .slot = block.header.slot,
                .hash = hash,
                .block_no = block.header.block_no,
                .chunk_no = chunk_no,
            };

            offset += len_buf.len + block_len;
        }
    }

    pub const Error = error{
        FileNotFound,
        UnexpectedEndOfFile,
        CorruptedData,
    };
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "immutabledb: open and close" {
    const allocator = std.testing.allocator;
    var db = try ImmutableDB.open(allocator, "/tmp/kassadin-test-imm");
    defer db.close();
    try std.testing.expect(db.getTip() == null);
}

test "immutabledb: append and retrieve block" {
    const allocator = std.testing.allocator;

    // Clean up from previous runs
    std.fs.cwd().deleteTree("/tmp/kassadin-test-imm2") catch {};

    var db = try ImmutableDB.open(allocator, "/tmp/kassadin-test-imm2");
    defer db.close();
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-imm2") catch {};

    // Append a fake block
    const block_data = "fake block data for testing";
    const hash = Blake2b256.hash(block_data);
    try db.appendBlock(hash, block_data, 42, 1);

    // Verify tip
    const tip = db.getTip().?;
    try std.testing.expectEqual(@as(SlotNo, 42), tip.slot);
    try std.testing.expectEqual(@as(BlockNo, 1), tip.block_no);

    // Retrieve by hash
    const retrieved = try db.getBlock(hash);
    try std.testing.expect(retrieved != null);
    defer allocator.free(retrieved.?);
    try std.testing.expectEqualSlices(u8, block_data, retrieved.?);
}

test "immutabledb: multiple blocks" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-imm3") catch {};

    var db = try ImmutableDB.open(allocator, "/tmp/kassadin-test-imm3");
    defer db.close();
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-imm3") catch {};

    // Append 10 blocks
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var data: [32]u8 = undefined;
        std.mem.writeInt(u32, data[0..4], i, .big);
        @memset(data[4..], 0xab);
        try db.appendBlock(Blake2b256.hash(&data), &data, @intCast(i * 10), @intCast(i));
    }

    try std.testing.expectEqual(@as(usize, 10), db.blockCount());
    try std.testing.expectEqual(@as(SlotNo, 90), db.getTip().?.slot);
}

test "immutabledb: crash recovery rebuilds tip and index" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-imm4") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-imm4") catch {};

    const block1_data = std.fs.cwd().readFileAlloc(
        allocator,
        "tests/vectors/golden_block_babbage.cbor",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(block1_data);

    const block2_data = std.fs.cwd().readFileAlloc(
        allocator,
        "tests/vectors/golden_block_conway.cbor",
        10 * 1024 * 1024,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(block2_data);

    const block1 = try block_mod.parseBlock(block1_data);
    const block2 = try block_mod.parseBlock(block2_data);

    // Write blocks
    {
        var db = try ImmutableDB.open(allocator, "/tmp/kassadin-test-imm4");
        defer db.close();
        try db.appendBlock(block1.hash(), block1_data, block1.header.slot, block1.header.block_no);
        try db.appendBlock(block2.hash(), block2_data, block2.header.slot, block2.header.block_no);
    }

    // Reopen — the in-memory index is reconstructed from chunk files.
    {
        var db = try ImmutableDB.open(allocator, "/tmp/kassadin-test-imm4");
        defer db.close();

        const tip = db.getTip().?;
        try std.testing.expectEqual(block2.header.slot, tip.slot);
        try std.testing.expectEqual(block2.header.block_no, tip.block_no);

        const block = try db.getBlock(block2.hash());
        try std.testing.expect(block != null);
        defer allocator.free(block.?);
        try std.testing.expectEqualSlices(u8, block2_data, block.?);
    }
}
