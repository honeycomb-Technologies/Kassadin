const std = @import("std");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;

/// Keep-Alive mini-protocol messages (protocol num 8).
/// Simple ping/pong with a cookie for request-response matching.
pub const KeepAliveMsg = union(enum) {
    keep_alive: u16, // [0, cookie]
    keep_alive_response: u16, // [1, cookie]
    done: void, // [2]
};

/// Encode a KeepAlive message to CBOR bytes.
pub fn encodeMsg(allocator: std.mem.Allocator, msg: KeepAliveMsg) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    switch (msg) {
        .keep_alive => |cookie| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(0);
            try enc.encodeUint(cookie);
        },
        .keep_alive_response => |cookie| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(1);
            try enc.encodeUint(cookie);
        },
        .done => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(2);
        },
    }

    return enc.toOwnedSlice();
}

/// Decode a KeepAlive message from CBOR bytes.
pub fn decodeMsg(data: []const u8) !KeepAliveMsg {
    var dec = Decoder.init(data);
    _ = try dec.decodeArrayLen(); // array length (1 or 2)
    const tag = try dec.decodeUint();

    return switch (tag) {
        0 => .{ .keep_alive = @intCast(try dec.decodeUint()) },
        1 => .{ .keep_alive_response = @intCast(try dec.decodeUint()) },
        2 => .done,
        else => error.InvalidCbor,
    };
}

// ──────────────────────────────────── Tests ────────────────────────────────────
// CBOR encodings verified against keep-alive.cddl from ouroboros-network

test "keepalive: encode MsgKeepAlive" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .keep_alive = 42 });
    defer allocator.free(bytes);
    // [0, 42] = array(2), uint 0, uint 42
    // 42 in CBOR = 0x18 0x2a (one-byte length prefix)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x00, 0x18, 0x2a }, bytes);
}

test "keepalive: encode MsgKeepAliveResponse" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .keep_alive_response = 42 });
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x01, 0x18, 0x2a }, bytes);
}

test "keepalive: encode MsgDone" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .done);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02 }, bytes);
}

test "keepalive: decode round-trip" {
    const allocator = std.testing.allocator;

    const msgs = [_]KeepAliveMsg{
        .{ .keep_alive = 0 },
        .{ .keep_alive = 12345 },
        .{ .keep_alive = 65535 },
        .{ .keep_alive_response = 42 },
        .done,
    };

    for (msgs) |msg| {
        const bytes = try encodeMsg(allocator, msg);
        defer allocator.free(bytes);
        const decoded = try decodeMsg(bytes);

        switch (msg) {
            .keep_alive => |c| try std.testing.expectEqual(c, decoded.keep_alive),
            .keep_alive_response => |c| try std.testing.expectEqual(c, decoded.keep_alive_response),
            .done => try std.testing.expect(decoded == .done),
        }
    }
}

test "keepalive: cookie 0 encodes as single byte" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .keep_alive = 0 });
    defer allocator.free(bytes);
    // [0, 0] = array(2), uint 0, uint 0
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x00, 0x00 }, bytes);
}
