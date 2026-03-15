const std = @import("std");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");

pub const Point = types.Point;
pub const HeaderHash = types.HeaderHash;
pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;

/// Tip of a peer's chain.
pub const Tip = struct {
    slot: SlotNo,
    hash: HeaderHash,
    block_no: BlockNo,
    is_genesis: bool,
};

/// Chain-Sync mini-protocol messages (protocol num 2 for N2N, 5 for N2C).
pub const ChainSyncMsg = union(enum) {
    request_next: void, // [0]
    await_reply: void, // [1]
    roll_forward: struct { // [2, header, tip]
        header_raw: []const u8, // Raw CBOR of header (byte-preserving)
        tip: Tip,
    },
    roll_backward: struct { // [3, point, tip]
        point: ?Point, // null = genesis
        tip: Tip,
    },
    find_intersect: struct { // [4, [*point]]
        points: []const Point,
    },
    intersect_found: struct { // [5, point, tip]
        point: Point,
        tip: Tip,
    },
    intersect_not_found: struct { // [6, tip]
        tip: Tip,
    },
    done: void, // [7]
};

/// Encode a Point as CBOR.
/// Genesis = [] (empty array), Specific = [slot_u64, hash_bytes32]
pub fn encodePoint(enc: *Encoder, point: ?Point) !void {
    if (point) |p| {
        try enc.encodeArrayLen(2);
        try enc.encodeUint(p.slot);
        try enc.encodeBytes(&p.hash);
    } else {
        try enc.encodeArrayLen(0); // Genesis = empty array
    }
}

/// Decode a Point from CBOR.
/// Returns null for genesis (empty array).
pub fn decodePoint(dec: *Decoder) !?Point {
    const len = try dec.decodeArrayLen();
    if (len) |l| {
        if (l == 0) return null; // Genesis
        if (l != 2) return error.InvalidCbor;
        const slot = try dec.decodeUint();
        const hash_bytes = try dec.decodeBytes();
        if (hash_bytes.len != 32) return error.InvalidCbor;
        var hash: HeaderHash = undefined;
        @memcpy(&hash, hash_bytes);
        return Point{ .slot = slot, .hash = hash };
    }
    return error.InvalidCbor;
}

/// Decode a Tip from CBOR.
/// Tip = [point, block_no]
pub fn decodeTip(dec: *Decoder) !Tip {
    _ = try dec.decodeArrayLen(); // array(2)
    const point = try decodePoint(dec);
    const block_no = try dec.decodeUint();

    if (point) |p| {
        return Tip{
            .slot = p.slot,
            .hash = p.hash,
            .block_no = block_no,
            .is_genesis = false,
        };
    } else {
        return Tip{
            .slot = 0,
            .hash = [_]u8{0} ** 32,
            .block_no = block_no,
            .is_genesis = true,
        };
    }
}

/// Encode a ChainSync message to CBOR.
pub fn encodeMsg(allocator: std.mem.Allocator, msg: ChainSyncMsg) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    switch (msg) {
        .request_next => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(0);
        },
        .await_reply => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(1);
        },
        .roll_forward => |rf| {
            try enc.encodeArrayLen(3);
            try enc.encodeUint(2);
            try enc.writeRaw(rf.header_raw);
            try encodeTip(&enc, rf.tip);
        },
        .roll_backward => |rb| {
            try enc.encodeArrayLen(3);
            try enc.encodeUint(3);
            try encodePoint(&enc, rb.point);
            try encodeTip(&enc, rb.tip);
        },
        .find_intersect => |fi| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(4);
            try enc.encodeArrayLen(fi.points.len);
            for (fi.points) |p| {
                try encodePoint(&enc, p);
            }
        },
        .intersect_found => |isf| {
            try enc.encodeArrayLen(3);
            try enc.encodeUint(5);
            try encodePoint(&enc, isf.point);
            try encodeTip(&enc, isf.tip);
        },
        .intersect_not_found => |inf| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(6);
            try encodeTip(&enc, inf.tip);
        },
        .done => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(7);
        },
    }

    return enc.toOwnedSlice();
}

fn encodeTip(enc: *Encoder, tip: Tip) !void {
    try enc.encodeArrayLen(2);
    if (tip.is_genesis) {
        try encodePoint(enc, null);
    } else {
        try encodePoint(enc, Point{ .slot = tip.slot, .hash = tip.hash });
    }
    try enc.encodeUint(tip.block_no);
}

/// Decode a ChainSync message from CBOR.
pub fn decodeMsg(data: []const u8) !ChainSyncMsg {
    var dec = Decoder.init(data);
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();

    return switch (tag) {
        0 => .request_next,
        1 => .await_reply,
        2 => {
            // RollForward: [2, header, tip]
            const header_raw = try dec.sliceOfNextValue();
            const tip = try decodeTip(&dec);
            return .{ .roll_forward = .{ .header_raw = header_raw, .tip = tip } };
        },
        3 => {
            // RollBackward: [3, point, tip]
            const point = try decodePoint(&dec);
            const tip = try decodeTip(&dec);
            return .{ .roll_backward = .{ .point = point, .tip = tip } };
        },
        4 => {
            // FindIntersect: [4, [*point]]
            const points_len = try dec.decodeArrayLen();
            if (points_len) |len| {
                // We don't allocate here — for encoding only we accept empty points
                if (len == 0) return .{ .find_intersect = .{ .points = &[_]Point{} } };
                // For decoding received messages, we'd need allocator.
                // Skip for now — we only SEND FindIntersect, never receive it (we're the client)
                var i: u64 = 0;
                while (i < len) : (i += 1) {
                    try dec.skipValue();
                }
                return .{ .find_intersect = .{ .points = &[_]Point{} } };
            }
            return error.InvalidCbor;
        },
        5 => {
            const point = try decodePoint(&dec);
            const tip = try decodeTip(&dec);
            // Genesis (null point) is a valid intersect — use slot 0 with zero hash
            return .{ .intersect_found = .{
                .point = point orelse Point{ .slot = 0, .hash = [_]u8{0} ** 32 },
                .tip = tip,
            } };
        },
        6 => {
            const tip = try decodeTip(&dec);
            return .{ .intersect_not_found = .{ .tip = tip } };
        },
        7 => .done,
        else => error.InvalidCbor,
    };
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "chainsync: encode MsgRequestNext" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .request_next);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x00 }, bytes);
}

test "chainsync: encode MsgAwaitReply" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .await_reply);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x01 }, bytes);
}

test "chainsync: encode MsgDone" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .done);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x07 }, bytes);
}

test "chainsync: encode genesis point" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try encodePoint(&enc, null);
    // Genesis = empty array = 0x80
    try std.testing.expectEqualSlices(u8, &[_]u8{0x80}, enc.getWritten());
}

test "chainsync: encode specific point" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    const point = Point{ .slot = 100, .hash = [_]u8{0xab} ** 32 };
    try encodePoint(&enc, point);
    // array(2), uint 100, bytes(32)
    const written = enc.getWritten();
    try std.testing.expectEqual(@as(u8, 0x82), written[0]); // array(2)
    try std.testing.expectEqual(@as(u8, 0x18), written[1]); // uint one-byte follows
    try std.testing.expectEqual(@as(u8, 100), written[2]); // slot = 100
    try std.testing.expectEqual(@as(u8, 0x58), written[3]); // bytes, one-byte length
    try std.testing.expectEqual(@as(u8, 32), written[4]); // 32 bytes
}

test "chainsync: point round-trip" {
    const allocator = std.testing.allocator;

    // Genesis point
    var enc1 = Encoder.init(allocator);
    defer enc1.deinit();
    try encodePoint(&enc1, null);
    var dec1 = Decoder.init(enc1.getWritten());
    const decoded_genesis = try decodePoint(&dec1);
    try std.testing.expect(decoded_genesis == null);

    // Specific point
    var enc2 = Encoder.init(allocator);
    defer enc2.deinit();
    const original = Point{ .slot = 42, .hash = [_]u8{0xcd} ** 32 };
    try encodePoint(&enc2, original);
    var dec2 = Decoder.init(enc2.getWritten());
    const decoded = try decodePoint(&dec2);
    try std.testing.expect(decoded != null);
    try std.testing.expectEqual(@as(u64, 42), decoded.?.slot);
    try std.testing.expectEqualSlices(u8, &original.hash, &decoded.?.hash);
}

test "chainsync: encode MsgFindIntersect with empty points" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .find_intersect = .{ .points = &[_]Point{} } });
    defer allocator.free(bytes);
    // [4, []] = array(2), uint 4, array(0)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x04, 0x80 }, bytes);
}

test "chainsync: decode MsgIntersectNotFound" {
    const allocator = std.testing.allocator;

    // Construct: [6, [[42, hash], 100]]
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.encodeArrayLen(2);
    try enc.encodeUint(6); // IntersectNotFound tag
    // Tip
    try enc.encodeArrayLen(2);
    // Point (slot=42, hash)
    try enc.encodeArrayLen(2);
    try enc.encodeUint(42);
    try enc.encodeBytes(&([_]u8{0xaa} ** 32));
    try enc.encodeUint(100); // block_no

    const msg = try decodeMsg(enc.getWritten());
    switch (msg) {
        .intersect_not_found => |inf| {
            try std.testing.expectEqual(@as(u64, 42), inf.tip.slot);
            try std.testing.expectEqual(@as(u64, 100), inf.tip.block_no);
            try std.testing.expect(!inf.tip.is_genesis);
        },
        else => return error.InvalidCbor,
    }
}

test "chainsync: message tags match CDDL" {
    const allocator = std.testing.allocator;

    const test_cases = [_]struct { msg: ChainSyncMsg, expected_tag: u8 }{
        .{ .msg = .request_next, .expected_tag = 0 },
        .{ .msg = .await_reply, .expected_tag = 1 },
        .{ .msg = .done, .expected_tag = 7 },
    };

    for (test_cases) |tc| {
        const bytes = try encodeMsg(allocator, tc.msg);
        defer allocator.free(bytes);
        // Tag is second byte (after array length byte)
        try std.testing.expectEqual(tc.expected_tag, bytes[1]);
    }
}
