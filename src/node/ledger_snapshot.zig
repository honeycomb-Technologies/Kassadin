const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const block_mod = @import("../ledger/block.zig");
const ledger_apply = @import("../ledger/apply.zig");
const rules = @import("../ledger/rules.zig");
const runtime_control = @import("runtime_control.zig");
const types = @import("../types.zig");
const LedgerDB = @import("../storage/ledger.zig").LedgerDB;

pub const SlotNo = types.SlotNo;
pub const TxIn = types.TxIn;
pub const Coin = types.Coin;

pub const LocalLedgerSnapshot = struct {
    slot: SlotNo,
    path: []u8,

    pub fn deinit(self: *LocalLedgerSnapshot, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

pub const LoadSnapshotResult = struct {
    slot: SlotNo,
    utxos_loaded: u64,
};

pub const ReplayResult = struct {
    blocks_replayed: u64,
    txs_applied: u64,
    txs_failed: u64,
    start_chunk: u32,
};

pub fn findLatestSnapshotAtOrBefore(
    allocator: Allocator,
    ledger_root: []const u8,
    max_slot: SlotNo,
) !?LocalLedgerSnapshot {
    var dir = std.fs.cwd().openDir(ledger_root, .{ .iterate = true }) catch return null;
    defer dir.close();

    var best_slot: ?SlotNo = null;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        const slot = std.fmt.parseInt(SlotNo, entry.name, 10) catch continue;
        if (slot > max_slot) continue;
        if (best_slot != null and slot <= best_slot.?) continue;

        const tvar_path = try std.fmt.allocPrint(allocator, "{s}/{s}/tables/tvar", .{ ledger_root, entry.name });
        defer allocator.free(tvar_path);
        const meta_path = try std.fmt.allocPrint(allocator, "{s}/{s}/meta", .{ ledger_root, entry.name });
        defer allocator.free(meta_path);

        if (!fileExists(tvar_path) or !fileExists(meta_path)) continue;
        best_slot = slot;
    }

    const slot = best_slot orelse return null;
    return .{
        .slot = slot,
        .path = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ ledger_root, slot }),
    };
}

pub fn loadSnapshotIntoLedger(
    allocator: Allocator,
    ledger: *LedgerDB,
    snapshot: LocalLedgerSnapshot,
) !LoadSnapshotResult {
    const meta_path = try std.fmt.allocPrint(allocator, "{s}/meta", .{snapshot.path});
    defer allocator.free(meta_path);
    try validateSnapshotMetadata(allocator, meta_path);

    const tvar_path = try std.fmt.allocPrint(allocator, "{s}/tables/tvar", .{snapshot.path});
    defer allocator.free(tvar_path);

    var file = try std.fs.cwd().openFile(tvar_path, .{});
    defer file.close();

    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(&file_buf);
    var reader = &file_reader.interface;

    const top_len = try readCborContainerLen(reader, 4);
    if (top_len == null or top_len.? != 1) return error.InvalidSnapshotTables;

    const map_len = try readCborContainerLen(reader, 5);

    var key_buf: [34]u8 = undefined;
    var value_buf: std.ArrayList(u8) = .empty;
    defer value_buf.deinit(allocator);

    var loaded: u64 = 0;
    var remaining = map_len;

    while (true) {
        if (runtime_control.stopRequested()) return error.Interrupted;

        if (remaining) |*count| {
            if (count.* == 0) break;
            count.* -= 1;
        } else {
            const next = try reader.takeByte();
            if (next == 0xff) break;
            const key_len = try readCborBytesLenFromFirst(reader, next);
            if (key_len != key_buf.len) return error.InvalidPackedTxIn;
            try readExactly(reader, key_buf[0..]);

            const value_len = try readCborBytesLen(reader);
            try value_buf.resize(allocator, value_len);
            try readExactly(reader, value_buf.items);

            const tx_in = try parsePackedTxIn(&key_buf);
            const coin = try parsePackedTxOutCoin(value_buf.items);
            try ledger.importUtxo(tx_in, coin);
            loaded += 1;

            if (!builtin.is_test and loaded % 100_000 == 0) {
                std.debug.print("  Loaded {} snapshot UTxOs...\n", .{loaded});
            }
            continue;
        }

        const key_len = try readCborBytesLen(reader);
        if (key_len != key_buf.len) return error.InvalidPackedTxIn;
        try readExactly(reader, key_buf[0..]);

        const value_len = try readCborBytesLen(reader);
        try value_buf.resize(allocator, value_len);
        try readExactly(reader, value_buf.items);

        const tx_in = try parsePackedTxIn(&key_buf);
        const coin = try parsePackedTxOutCoin(value_buf.items);
        try ledger.importUtxo(tx_in, coin);
        loaded += 1;

        if (!builtin.is_test and loaded % 100_000 == 0) {
            std.debug.print("  Loaded {} snapshot UTxOs...\n", .{loaded});
        }
    }

    ledger.setTipSlot(snapshot.slot);
    return .{
        .slot = snapshot.slot,
        .utxos_loaded = loaded,
    };
}

pub fn replayImmutableFromSlot(
    allocator: Allocator,
    ledger: *LedgerDB,
    immutable_path: []const u8,
    from_slot: SlotNo,
    pp: rules.ProtocolParams,
) !ReplayResult {
    var result = ReplayResult{
        .blocks_replayed = 0,
        .txs_applied = 0,
        .txs_failed = 0,
        .start_chunk = 0,
    };

    const total_chunks = try countChunks(immutable_path);
    if (total_chunks == 0) return result;

    result.start_chunk = try findReplayStartChunk(allocator, immutable_path, total_chunks, from_slot);

    var chunk_num = result.start_chunk;
    while (chunk_num < total_chunks) : (chunk_num += 1) {
        if (runtime_control.stopRequested()) return error.Interrupted;

        const chunk_data = try readChunkData(allocator, immutable_path, chunk_num);
        defer allocator.free(chunk_data);

        var pos: usize = 0;
        while (pos < chunk_data.len) {
            if (runtime_control.stopRequested()) return error.Interrupted;

            var dec = Decoder.init(chunk_data[pos..]);
            const block_slice = dec.sliceOfNextValue() catch break;
            const raw = chunk_data[pos .. pos + block_slice.len];
            pos += block_slice.len;

            const block = block_mod.parseBlock(raw) catch continue;
            if (block.era == .byron) continue;
            if (block.header.slot <= from_slot) continue;

            var apply_result = try ledger_apply.applyBlock(
                allocator,
                ledger,
                &block,
                pp,
            );
            defer apply_result.deinit(allocator);

            if (apply_result.txs_failed > 0) {
                if (apply_result.txs_applied > 0) {
                    try ledger.rollback(apply_result.txs_applied);
                }
                return error.InvalidImmutableReplay;
            }

            result.blocks_replayed += 1;
            result.txs_applied += apply_result.txs_applied;
            result.txs_failed += apply_result.txs_failed;
            ledger.setTipSlot(block.header.slot);
        }
    }

    return result;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn validateSnapshotMetadata(allocator: Allocator, path: []const u8) !void {
    const meta = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024);
    defer allocator.free(meta);

    if (std.mem.indexOf(u8, meta, "\"backend\":\"utxohd-mem\"") == null) {
        return error.UnsupportedSnapshotBackend;
    }
}

fn countChunks(immutable_path: []const u8) !u32 {
    var dir = try std.fs.cwd().openDir(immutable_path, .{ .iterate = true });
    defer dir.close();

    var max_chunk: ?u32 = null;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".chunk")) continue;

        const num = std.fmt.parseInt(u32, entry.name[0 .. entry.name.len - 6], 10) catch continue;
        max_chunk = if (max_chunk) |current| @max(current, num) else num;
    }

    return if (max_chunk) |num| num + 1 else 0;
}

fn findReplayStartChunk(
    allocator: Allocator,
    immutable_path: []const u8,
    total_chunks: u32,
    from_slot: SlotNo,
) !u32 {
    var chunk_num = total_chunks;
    while (chunk_num > 0) {
        chunk_num -= 1;

        const range = try readChunkSlotRange(allocator, immutable_path, chunk_num);
        if (range == null) continue;

        if (range.?.first_slot <= from_slot and from_slot <= range.?.last_slot) {
            return chunk_num;
        }
        if (range.?.last_slot < from_slot) {
            return @min(chunk_num + 1, total_chunks - 1);
        }
    }

    return 0;
}

fn readChunkSlotRange(
    allocator: Allocator,
    immutable_path: []const u8,
    chunk_num: u32,
) !?struct { first_slot: SlotNo, last_slot: SlotNo } {
    const data = try readChunkData(allocator, immutable_path, chunk_num);
    defer allocator.free(data);

    var pos: usize = 0;
    var first_slot: ?SlotNo = null;
    var last_slot: ?SlotNo = null;

    while (pos < data.len) {
        var dec = Decoder.init(data[pos..]);
        const block_slice = dec.sliceOfNextValue() catch break;
        const raw = data[pos .. pos + block_slice.len];
        pos += block_slice.len;

        const block = block_mod.parseBlock(raw) catch continue;
        if (block.era == .byron) continue;
        if (first_slot == null) first_slot = block.header.slot;
        last_slot = block.header.slot;
    }

    if (first_slot == null or last_slot == null) return null;
    return .{ .first_slot = first_slot.?, .last_slot = last_slot.? };
}

fn readChunkData(allocator: Allocator, immutable_path: []const u8, chunk_num: u32) ![]u8 {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{ immutable_path, chunk_num });
    return std.fs.cwd().readFileAlloc(allocator, path, 512 * 1024 * 1024);
}

fn readCborContainerLen(reader: anytype, expected_major: u3) !?u64 {
    const first = try reader.takeByte();
    const major = @as(u3, @intCast(first >> 5));
    if (major != expected_major) return error.InvalidCbor;

    const ai = first & 0x1f;
    if (ai == 31) return null;
    return try readCborArg(reader, ai);
}

fn readExactly(reader: anytype, dest: []u8) !void {
    var offset: usize = 0;
    while (offset < dest.len) {
        const step = @min(dest.len - offset, 32 * 1024);
        const chunk = try reader.take(step);
        @memcpy(dest[offset .. offset + step], chunk);
        offset += step;
    }
}

fn readCborBytesLen(reader: anytype) !usize {
    const first = try reader.takeByte();
    return readCborBytesLenFromFirst(reader, first);
}

fn readCborBytesLenFromFirst(reader: anytype, first: u8) !usize {
    const major = @as(u3, @intCast(first >> 5));
    if (major != 2) return error.InvalidCbor;
    const ai = first & 0x1f;
    return @intCast(try readCborArg(reader, ai));
}

fn readCborArg(reader: anytype, ai: u8) !u64 {
    return switch (ai) {
        0...23 => ai,
        24 => try reader.takeByte(),
        25 => blk: {
            break :blk @as(u64, try reader.takeInt(u16, .big));
        },
        26 => blk: {
            break :blk @as(u64, try reader.takeInt(u32, .big));
        },
        27 => blk: {
            break :blk try reader.takeInt(u64, .big);
        },
        else => error.InvalidCbor,
    };
}

fn parsePackedTxIn(bytes: *const [34]u8) !TxIn {
    var tx_id: [32]u8 = undefined;
    @memcpy(&tx_id, bytes[0..32]);
    const tx_ix = std.mem.readInt(u16, bytes[32..34], .little);
    return .{
        .tx_id = tx_id,
        .tx_ix = tx_ix,
    };
}

fn parsePackedTxOutCoin(bytes: []const u8) !Coin {
    var pos: usize = 0;
    const tag = try readPackedByte(bytes, &pos);

    switch (tag) {
        0, 1, 4, 5 => {
            try skipPackedShortBytes(bytes, &pos);
            return readPackedCompactValueCoin(bytes, &pos);
        },
        2, 3 => {
            try skipPackedCredential(bytes, &pos);
            try skipPackedFixed(bytes, &pos, 32); // Addr28Extra
            return readPackedCompactCoin(bytes, &pos);
        },
        else => return error.UnsupportedPackedTxOut,
    }
}

fn readPackedCompactValueCoin(bytes: []const u8, pos: *usize) !Coin {
    const tag = try readPackedByte(bytes, pos);
    return switch (tag) {
        0 => try readPackedVarLen(bytes, pos),
        1 => try readPackedVarLen(bytes, pos),
        else => error.UnsupportedCompactValue,
    };
}

fn readPackedCompactCoin(bytes: []const u8, pos: *usize) !Coin {
    const tag = try readPackedByte(bytes, pos);
    if (tag != 0) return error.UnsupportedCompactCoin;
    return readPackedVarLen(bytes, pos);
}

fn skipPackedShortBytes(bytes: []const u8, pos: *usize) !void {
    const len = try readPackedVarLen(bytes, pos);
    try skipPackedFixed(bytes, pos, @intCast(len));
}

fn skipPackedCredential(bytes: []const u8, pos: *usize) !void {
    _ = try readPackedByte(bytes, pos); // key hash vs script hash
    try skipPackedFixed(bytes, pos, 28);
}

fn skipPackedFixed(bytes: []const u8, pos: *usize, len: usize) !void {
    if (pos.* + len > bytes.len) return error.InvalidPackedTxOut;
    pos.* += len;
}

fn readPackedByte(bytes: []const u8, pos: *usize) !u8 {
    if (pos.* >= bytes.len) return error.InvalidPackedTxOut;
    const byte = bytes[pos.*];
    pos.* += 1;
    return byte;
}

fn readPackedVarLen(bytes: []const u8, pos: *usize) !u64 {
    var value: u64 = 0;

    while (true) {
        const byte = try readPackedByte(bytes, pos);
        if (value > (std.math.maxInt(u64) >> 7)) return error.InvalidPackedVarLen;
        value = (value << 7) | @as(u64, byte & 0x7f);
        if ((byte & 0x80) == 0) return value;
    }
}

test "ledger_snapshot: parse packed txin and txout coin from real ancillary sample" {
    const key = [_]u8{
        0x00, 0x00, 0x0c, 0x0c, 0xf6, 0xfe, 0x63, 0x89,
        0x49, 0x2d, 0xd7, 0xfe, 0x7c, 0x8f, 0xf3, 0x04,
        0x0d, 0x70, 0xd1, 0x1b, 0x33, 0x56, 0x09, 0x3c,
        0xf6, 0x51, 0xac, 0x87, 0x6c, 0x6f, 0x66, 0xd9,
        0x00, 0x00,
    };
    const tx_in = try parsePackedTxIn(&key);
    try std.testing.expectEqual(@as(u16, 0), tx_in.tx_ix);

    const value = [_]u8{
        0x00, 0x39, 0x00, 0x6d, 0x5b, 0x57, 0x5d, 0x9d, 0xff, 0xc1, 0xe4, 0xf1,
        0x2b, 0x49, 0x9b, 0x99, 0xbf, 0xe1, 0xd3, 0xe1, 0x75, 0xe5, 0xed, 0x32,
        0x56, 0xcd, 0x28, 0x57, 0x91, 0xaf, 0xb1, 0xd1, 0x98, 0x34, 0xbc, 0x0a,
        0x0d, 0x4f, 0xa1, 0xfd, 0x45, 0xf9, 0xd4, 0x5d, 0x91, 0xed, 0x04, 0xfe,
        0x0f, 0xdf, 0xed, 0x74, 0x8c, 0x44, 0xf5, 0x81, 0xfc, 0xbd, 0xbb, 0x01,
        0xe8, 0xaf, 0x30, 0x0a, 0x81, 0x50, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    const coin = try parsePackedTxOutCoin(&value);
    try std.testing.expectEqual(@as(Coin, 1_710_000), coin);
}

test "ledger_snapshot: parse packed txin uses little-endian tx index in ancillary tables" {
    const key = [_]u8{
        0x22, 0x91, 0x0c, 0x04, 0x02, 0x8d, 0x88, 0xf9,
        0x0d, 0xf7, 0x1e, 0xc0, 0x24, 0x4f, 0x11, 0x1f,
        0xc1, 0xa8, 0xa0, 0xdb, 0x7e, 0x32, 0xc9, 0x5e,
        0x85, 0x60, 0xf8, 0x02, 0x2e, 0xb8, 0x6b, 0xdb,
        0x01, 0x00,
    };
    const tx_in = try parsePackedTxIn(&key);
    try std.testing.expectEqual(@as(u16, 1), tx_in.tx_ix);
}

test "ledger_snapshot: packed varlen matches snapshot output value encoding" {
    const bytes = [_]u8{ 0x81, 0xab, 0xbb, 0xc9, 0x4c };
    var pos: usize = 0;
    const value = try readPackedVarLen(&bytes, &pos);
    try std.testing.expectEqual(@as(u64, 359_589_068), value);
    try std.testing.expectEqual(bytes.len, pos);
}

test "ledger_snapshot: parse packed tag-2 txout coin from real ancillary sample" {
    const value = [_]u8{
        0x02, 0x01, 0xf7, 0x2d, 0x0e, 0x90, 0x15, 0x27, 0xe8, 0xbf, 0x83, 0x8d,
        0x79, 0x88, 0x0f, 0x96, 0x88, 0x23, 0xe7, 0xaa, 0x71, 0x91, 0x96, 0x3f,
        0xf6, 0xa5, 0xf8, 0x01, 0x3f, 0xab, 0x4f, 0x7b, 0xb5, 0x86, 0xa5, 0xf0,
        0x76, 0x1d, 0x85, 0xdd, 0x66, 0x4d, 0x69, 0xf7, 0x08, 0x5e, 0xe6, 0xcb,
        0xf2, 0x1b, 0x74, 0xb6, 0x12, 0xef, 0x01, 0x00, 0x00, 0x00, 0x5b, 0xc2,
        0x2e, 0x4c, 0x00, 0x81, 0x8a, 0x83, 0x17,
    };
    const coin = try parsePackedTxOutCoin(&value);
    try std.testing.expectEqual(@as(Coin, 2_261_399), coin);
}
