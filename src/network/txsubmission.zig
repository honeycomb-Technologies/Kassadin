const std = @import("std");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");

pub const TxIdAndSize = struct {
    tx_id: types.TxId,
    size: u32,
};

/// Tx-Submission v2 mini-protocol messages (protocol num 4).
/// CRITICAL: Inner lists MUST use indefinite-length CBOR encoding (0x9f...0xff).
pub const TxSubmissionMsg = union(enum) {
    init: void, // [6]
    request_tx_ids: struct { // [0, blocking, ack, req]
        blocking: bool,
        ack_count: u16,
        req_count: u16,
    },
    reply_tx_ids: []const TxIdAndSize, // [1, [*[txid, size]]]
    request_txs: []const types.TxId, // [2, [*txid]]
    reply_txs: []const []const u8, // [3, [*tx_raw]]
    done: void, // [4]
};

pub fn encodeMsg(allocator: std.mem.Allocator, msg: TxSubmissionMsg) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    switch (msg) {
        .init => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(6);
        },
        .request_tx_ids => |r| {
            try enc.encodeArrayLen(4);
            try enc.encodeUint(0);
            try enc.encodeBool(r.blocking);
            try enc.encodeUint(r.ack_count);
            try enc.encodeUint(r.req_count);
        },
        .reply_tx_ids => |ids| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(1);
            // MUST use indefinite-length list per Haskell codec
            try enc.encodeArrayIndef();
            for (ids) |id_and_size| {
                try enc.encodeArrayLen(2);
                try enc.encodeBytes(&id_and_size.tx_id);
                try enc.encodeUint(id_and_size.size);
            }
            try enc.encodeBreak();
        },
        .request_txs => |ids| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(2);
            try enc.encodeArrayIndef();
            for (ids) |id| {
                try enc.encodeBytes(&id);
            }
            try enc.encodeBreak();
        },
        .reply_txs => |txs| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(3);
            try enc.encodeArrayIndef();
            for (txs) |tx_raw| {
                try enc.writeRaw(tx_raw);
            }
            try enc.encodeBreak();
        },
        .done => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(4);
        },
    }

    return enc.toOwnedSlice();
}

pub fn decodeMsg(allocator: std.mem.Allocator, data: []const u8) !TxSubmissionMsg {
    _ = allocator;
    var dec = Decoder.init(data);
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();

    return switch (tag) {
        6 => .init,
        0 => {
            const blocking = try dec.decodeBool();
            const ack = @as(u16, @intCast(try dec.decodeUint()));
            const req = @as(u16, @intCast(try dec.decodeUint()));
            return .{ .request_tx_ids = .{
                .blocking = blocking,
                .ack_count = ack,
                .req_count = req,
            } };
        },
        1 => {
            // ReplyTxIds — we receive this but don't need to parse fully for Phase 1
            try dec.skipValue();
            return .{ .reply_tx_ids = &[_]TxIdAndSize{} };
        },
        2 => {
            try dec.skipValue();
            return .{ .request_txs = &[_]types.TxId{} };
        },
        3 => {
            try dec.skipValue();
            return .{ .reply_txs = &[_][]const u8{} };
        },
        4 => .done,
        else => error.InvalidCbor,
    };
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "txsubmission: encode MsgInit" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .init);
    defer allocator.free(bytes);
    // [6] = array(1), uint 6
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x06 }, bytes);
}

test "txsubmission: encode MsgDone" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .done);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x04 }, bytes);
}

test "txsubmission: encode empty ReplyTxIds uses indefinite-length" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .reply_tx_ids = &[_]TxIdAndSize{} });
    defer allocator.free(bytes);
    // [1, []] but with indefinite-length inner list
    // Expected: 82 01 9f ff
    //   82 = array(2)
    //   01 = uint 1 (tag)
    //   9f = indefinite-length array start
    //   ff = break (end of indefinite array)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x01, 0x9f, 0xff }, bytes);
}

test "txsubmission: encode empty RequestTxs uses indefinite-length" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .request_txs = &[_]types.TxId{} });
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x02, 0x9f, 0xff }, bytes);
}

test "txsubmission: encode RequestTxIds" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .request_tx_ids = .{
        .blocking = true,
        .ack_count = 0,
        .req_count = 1,
    } });
    defer allocator.free(bytes);

    var dec = Decoder.init(bytes);
    const arr = try dec.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 4), arr);
    try std.testing.expectEqual(@as(u64, 0), try dec.decodeUint()); // tag
    try std.testing.expectEqual(true, try dec.decodeBool()); // blocking
    try std.testing.expectEqual(@as(u64, 0), try dec.decodeUint()); // ack
    try std.testing.expectEqual(@as(u64, 1), try dec.decodeUint()); // req
}

test "txsubmission: decode MsgRequestTxIds" {
    const allocator = std.testing.allocator;
    // Construct [0, false, 5, 10]
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.encodeArrayLen(4);
    try enc.encodeUint(0);
    try enc.encodeBool(false);
    try enc.encodeUint(5);
    try enc.encodeUint(10);

    const msg = try decodeMsg(allocator, enc.getWritten());
    switch (msg) {
        .request_tx_ids => |r| {
            try std.testing.expectEqual(false, r.blocking);
            try std.testing.expectEqual(@as(u16, 5), r.ack_count);
            try std.testing.expectEqual(@as(u16, 10), r.req_count);
        },
        else => return error.InvalidCbor,
    }
}

test "txsubmission: MsgInit tag is 6 (unique among protocols)" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .init);
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(u8, 6), bytes[1]); // tag 6
}
