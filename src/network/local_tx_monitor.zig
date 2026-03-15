const std = @import("std");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;

/// Local Tx-Monitor mini-protocol (N2C, protocol num 9).
/// Introspect the local mempool.
pub const LocalTxMonitorMsg = union(enum) {
    done: void, // [0]
    acquire: void, // [1]
    acquired: u64, // [2, slot]
    release: void, // [3]
    next_tx: void, // [5]
    reply_next_tx_empty: void, // [6] (no more txs)
    reply_next_tx: []const u8, // [6, tx_raw]
    has_tx: [32]u8, // [7, txid]
    reply_has_tx: bool, // [8, bool]
    get_sizes: void, // [9]
    reply_get_sizes: struct { // [10, [cap, size, count]]
        capacity: u32,
        size: u32,
        count: u32,
    },
};

pub fn encodeMsg(allocator: std.mem.Allocator, msg: LocalTxMonitorMsg) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    switch (msg) {
        .done => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(0);
        },
        .acquire => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(1);
        },
        .acquired => |slot| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(2);
            try enc.encodeUint(slot);
        },
        .release => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(3);
        },
        .next_tx => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(5);
        },
        .reply_next_tx_empty => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(6);
        },
        .reply_next_tx => |tx| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(6);
            try enc.writeRaw(tx);
        },
        .has_tx => |txid| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(7);
            try enc.encodeBytes(&txid);
        },
        .reply_has_tx => |has| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(8);
            try enc.encodeBool(has);
        },
        .get_sizes => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(9);
        },
        .reply_get_sizes => |sizes| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(10);
            try enc.encodeArrayLen(3);
            try enc.encodeUint(sizes.capacity);
            try enc.encodeUint(sizes.size);
            try enc.encodeUint(sizes.count);
        },
    }

    return enc.toOwnedSlice();
}

pub fn decodeMsg(data: []const u8) !LocalTxMonitorMsg {
    var dec = Decoder.init(data);
    const arr_len = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();

    return switch (tag) {
        0 => .done,
        1 => .acquire,
        2 => .{ .acquired = try dec.decodeUint() },
        3 => .release,
        5 => .next_tx,
        6 => blk: {
            if (arr_len) |len| {
                if (len == 1) break :blk LocalTxMonitorMsg{ .reply_next_tx_empty = {} };
            }
            break :blk LocalTxMonitorMsg{ .reply_next_tx = dec.remaining() };
        },
        7 => {
            const txid_bytes = try dec.decodeBytes();
            if (txid_bytes.len != 32) return error.InvalidCbor;
            return .{ .has_tx = txid_bytes[0..32].* };
        },
        8 => .{ .reply_has_tx = try dec.decodeBool() },
        9 => .get_sizes,
        10 => {
            _ = try dec.decodeArrayLen();
            return .{ .reply_get_sizes = .{
                .capacity = @intCast(try dec.decodeUint()),
                .size = @intCast(try dec.decodeUint()),
                .count = @intCast(try dec.decodeUint()),
            } };
        },
        else => error.InvalidCbor,
    };
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "local_tx_monitor: encode MsgAcquire" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .acquire);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x01 }, bytes);
}

test "local_tx_monitor: encode MsgGetSizes" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .get_sizes);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x09 }, bytes);
}

test "local_tx_monitor: encode and decode ReplyGetSizes" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .reply_get_sizes = .{
        .capacity = 180224,
        .size = 5000,
        .count = 10,
    } });
    defer allocator.free(bytes);

    const decoded = try decodeMsg(bytes);
    switch (decoded) {
        .reply_get_sizes => |sizes| {
            try std.testing.expectEqual(@as(u32, 180224), sizes.capacity);
            try std.testing.expectEqual(@as(u32, 5000), sizes.size);
            try std.testing.expectEqual(@as(u32, 10), sizes.count);
        },
        else => return error.InvalidCbor,
    }
}

test "local_tx_monitor: encode MsgReplyHasTx" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .reply_has_tx = true });
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x08, 0xf5 }, bytes);
}
