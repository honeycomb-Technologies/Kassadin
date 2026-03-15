const std = @import("std");
const Allocator = std.mem.Allocator;
const block_mod = @import("../ledger/block.zig");
const Decoder = @import("../cbor/decoder.zig").Decoder;

/// Read blocks from Haskell ImmutableDB chunk files.
///
/// Chunk file format: concatenated CBOR-encoded blocks.
/// Each block is a complete CBOR value (HFC-wrapped: [era_id, era_block]).
/// No length prefix — blocks are delimited by CBOR framing.
///
/// File naming: NNNNN.chunk (5-digit zero-padded chunk number)
pub const ChunkReader = struct {
    immutable_path: []const u8,
    total_chunks: u32,

    pub fn init(immutable_path: []const u8) !ChunkReader {
        // Count chunk files to find the range
        var max_chunk: u32 = 0;
        var dir = std.fs.cwd().openDir(immutable_path, .{ .iterate = true }) catch
            return error.DirectoryNotFound;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".chunk")) {
                // Parse chunk number from filename
                const num_str = entry.name[0 .. entry.name.len - 6]; // strip ".chunk"
                const num = std.fmt.parseInt(u32, num_str, 10) catch continue;
                if (num > max_chunk) max_chunk = num;
            }
        }

        return .{
            .immutable_path = immutable_path,
            .total_chunks = max_chunk + 1,
        };
    }

    /// Read all blocks from a single chunk file.
    /// Returns the number of blocks found.
    pub fn readChunk(self: *const ChunkReader, allocator: Allocator, chunk_num: u32, callback: *const fn (block_data: []const u8, block_num: u64) void) !u64 {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{ self.immutable_path, chunk_num });

        const data = try std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024 * 1024); // max 256MB per chunk
        defer allocator.free(data);

        var pos: usize = 0;
        var count: u64 = 0;

        while (pos < data.len) {
            // Use CBOR decoder to find block boundaries
            var dec = Decoder.init(data[pos..]);
            const block_slice = dec.sliceOfNextValue() catch break;

            callback(data[pos .. pos + block_slice.len], count);

            pos += block_slice.len;
            count += 1;
        }

        return count;
    }

    /// Read the last block's raw CBOR bytes from the last chunk.
    /// Caller owns the returned allocation — block slices point into it.
    pub fn readTipRaw(self: *const ChunkReader, allocator: Allocator) !?[]const u8 {
        if (self.total_chunks == 0) return null;

        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{ self.immutable_path, self.total_chunks - 1 });

        const data = try std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024 * 1024);

        // Find the last complete CBOR block
        var pos: usize = 0;
        var last_block_start: usize = 0;
        var last_block_end: usize = 0;

        while (pos < data.len) {
            var dec = Decoder.init(data[pos..]);
            const block_slice = dec.sliceOfNextValue() catch break;
            last_block_start = pos;
            last_block_end = pos + block_slice.len;
            pos = last_block_end;
        }

        if (last_block_end == 0) {
            allocator.free(data);
            return null;
        }

        // Copy just the last block's bytes
        const block_bytes = try allocator.alloc(u8, last_block_end - last_block_start);
        @memcpy(block_bytes, data[last_block_start..last_block_end]);
        allocator.free(data);

        return block_bytes;
    }

    /// Read the last block from the last chunk (the tip of the immutable chain).
    /// The returned block's raw slices point into tip_raw — keep tip_raw alive!
    pub fn readTip(self: *const ChunkReader, allocator: Allocator) !?struct { block: block_mod.Block, raw: []const u8 } {
        const raw = try self.readTipRaw(allocator) orelse return null;
        const block = try block_mod.parseBlock(raw);
        return .{ .block = block, .raw = raw };
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "chunk_reader: read real Mithril chunk" {
    const allocator = std.testing.allocator;

    var reader = ChunkReader.init("db/preprod/immutable") catch return;

    try std.testing.expect(reader.total_chunks > 0);

    const tip_result = try reader.readTip(allocator) orelse return;
    defer allocator.free(tip_result.raw);

    try std.testing.expect(tip_result.block.header.slot > 0);
    try std.testing.expect(tip_result.block.header.block_no > 0);
}

test "chunk_reader: count blocks in last chunk" {
    const allocator = std.testing.allocator;

    var reader = ChunkReader.init("db/preprod/immutable") catch return;

    const count = try reader.readChunk(allocator, reader.total_chunks - 1, &struct {
        fn callback(_: []const u8, _: u64) void {}
    }.callback);

    try std.testing.expect(count > 0);
}
