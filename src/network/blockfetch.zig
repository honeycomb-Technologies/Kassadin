const std = @import("std");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const chainsync = @import("chainsync.zig");

pub const Point = chainsync.Point;

/// Block-Fetch mini-protocol messages (protocol num 3).
pub const BlockFetchMsg = union(enum) {
    request_range: struct { from: Point, to: Point }, // [0, point, point]
    client_done: void, // [1]
    start_batch: void, // [2]
    no_blocks: void, // [3]
    block: []const u8, // [4, block_raw] — raw CBOR preserved
    batch_done: void, // [5]
};

pub fn encodeMsg(allocator: std.mem.Allocator, msg: BlockFetchMsg) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    switch (msg) {
        .request_range => |rr| {
            try enc.encodeArrayLen(3);
            try enc.encodeUint(0);
            try chainsync.encodePoint(&enc, rr.from);
            try chainsync.encodePoint(&enc, rr.to);
        },
        .client_done => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(1);
        },
        .start_batch => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(2);
        },
        .no_blocks => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(3);
        },
        .block => |raw| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(4);
            try enc.writeRaw(raw);
        },
        .batch_done => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(5);
        },
    }

    return enc.toOwnedSlice();
}

pub fn decodeMsg(data: []const u8) !BlockFetchMsg {
    var dec = Decoder.init(data);
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();

    return switch (tag) {
        0 => {
            const from = try chainsync.decodePoint(&dec) orelse return error.InvalidCbor;
            const to = try chainsync.decodePoint(&dec) orelse return error.InvalidCbor;
            return .{ .request_range = .{ .from = from, .to = to } };
        },
        1 => .client_done,
        2 => .start_batch,
        3 => .no_blocks,
        4 => .{ .block = dec.remaining() },
        5 => .batch_done,
        else => error.InvalidCbor,
    };
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "blockfetch: encode MsgClientDone" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .client_done);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x01 }, bytes);
}

test "blockfetch: encode MsgStartBatch" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .start_batch);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02 }, bytes);
}

test "blockfetch: encode MsgBatchDone" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .batch_done);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x05 }, bytes);
}

test "blockfetch: encode MsgRequestRange" {
    const allocator = std.testing.allocator;
    const from = Point{ .slot = 100, .hash = [_]u8{0xaa} ** 32 };
    const to = Point{ .slot = 200, .hash = [_]u8{0xbb} ** 32 };
    const bytes = try encodeMsg(allocator, .{ .request_range = .{ .from = from, .to = to } });
    defer allocator.free(bytes);

    // Verify structure: [0, [100, hash], [200, hash]]
    var dec = Decoder.init(bytes);
    const arr_len = try dec.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 3), arr_len);
    const t = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 0), t);
}

test "blockfetch: decode round-trip simple messages" {
    const allocator = std.testing.allocator;
    const simple_msgs = [_]BlockFetchMsg{ .client_done, .start_batch, .no_blocks, .batch_done };

    for (simple_msgs) |msg| {
        const bytes = try encodeMsg(allocator, msg);
        defer allocator.free(bytes);
        const decoded = try decodeMsg(bytes);
        switch (msg) {
            .client_done => try std.testing.expect(decoded == .client_done),
            .start_batch => try std.testing.expect(decoded == .start_batch),
            .no_blocks => try std.testing.expect(decoded == .no_blocks),
            .batch_done => try std.testing.expect(decoded == .batch_done),
            else => unreachable,
        }
    }
}

test "blockfetch: message tags match CDDL" {
    const allocator = std.testing.allocator;
    const bytes_done = try encodeMsg(allocator, .client_done);
    defer allocator.free(bytes_done);
    try std.testing.expectEqual(@as(u8, 1), bytes_done[1]); // tag 1

    const bytes_start = try encodeMsg(allocator, .start_batch);
    defer allocator.free(bytes_start);
    try std.testing.expectEqual(@as(u8, 2), bytes_start[1]); // tag 2

    const bytes_batch = try encodeMsg(allocator, .batch_done);
    defer allocator.free(bytes_batch);
    try std.testing.expectEqual(@as(u8, 5), bytes_batch[1]); // tag 5
}
