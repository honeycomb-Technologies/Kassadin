const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

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

    /// Append a block to the current chunk.
    pub fn appendBlock(self: *ImmutableDB, block_data: []const u8, slot: SlotNo, block_no: BlockNo) !void {
        // Open or create chunk file
        if (self.chunk_file == null) {
            self.chunk_file = try self.openOrCreateChunk(self.current_chunk);
        }

        const file = self.chunk_file.?;
        const offset = try file.getEndPos();

        // Write block with length prefix (4 bytes, big-endian)
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(block_data.len), .big);
        try file.writeAll(&len_buf);
        try file.writeAll(block_data);

        // Compute block hash
        const hash = Blake2b256.hash(block_data);

        // Update secondary index
        try self.secondary_index.put(hash, .{
            .slot = slot,
            .hash = hash,
            .block_no = block_no,
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
        return try self.readBlockAt(self.current_chunk, info.offset, info.size);
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
        _ = chunk_no;
        const file = self.chunk_file orelse return error.FileNotFound;

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
        // Scan for the highest-numbered chunk file
        var chunk_no: u32 = 0;
        while (chunk_no < 100000) : (chunk_no += 1) {
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{ self.base_path, chunk_no }) catch break;
            const stat = std.fs.cwd().statFile(path) catch break;
            _ = stat;
            self.current_chunk = chunk_no;
        }
        // If chunks exist, we'd rebuild the index here.
        // For Phase 2, we start fresh.
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
    try db.appendBlock(block_data, 42, 1);

    // Verify tip
    const tip = db.getTip().?;
    try std.testing.expectEqual(@as(SlotNo, 42), tip.slot);
    try std.testing.expectEqual(@as(BlockNo, 1), tip.block_no);

    // Retrieve by hash
    const hash = Blake2b256.hash(block_data);
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
        try db.appendBlock(&data, @intCast(i * 10), @intCast(i));
    }

    try std.testing.expectEqual(@as(usize, 10), db.blockCount());
    try std.testing.expectEqual(@as(SlotNo, 90), db.getTip().?.slot);
}

test "immutabledb: crash recovery — reopening preserves nothing (fresh start)" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-imm4") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-imm4") catch {};

    // Write blocks
    {
        var db = try ImmutableDB.open(allocator, "/tmp/kassadin-test-imm4");
        defer db.close();
        try db.appendBlock("block1", 10, 1);
        try db.appendBlock("block2", 20, 2);
    }

    // Reopen — for now the in-memory index is lost (full recovery comes later)
    {
        var db = try ImmutableDB.open(allocator, "/tmp/kassadin-test-imm4");
        defer db.close();
        // The chunk file exists but we don't rebuild the index yet
        try std.testing.expect(db.getTip() == null);
        // This is a known limitation for Phase 2 — full recovery will rebuild from chunk files
    }
}
