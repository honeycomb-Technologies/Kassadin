const std = @import("std");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;

pub const PeerAddress = union(enum) {
    ipv4: struct { addr: u32, port: u16 },
    ipv6: struct { addr: [4]u32, port: u16 },
};

/// Peer-Sharing mini-protocol messages (protocol num 10).
pub const PeerSharingMsg = union(enum) {
    share_request: u8, // [0, amount]
    share_peers: []const PeerAddress, // [1, [*peer_addr]]
    done: void, // [2]
};

pub fn encodeMsg(allocator: std.mem.Allocator, msg: PeerSharingMsg) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    switch (msg) {
        .share_request => |amount| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(0);
            try enc.encodeUint(amount);
        },
        .share_peers => |peers| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(1);
            try enc.encodeArrayLen(peers.len);
            for (peers) |peer| {
                try encodePeerAddress(&enc, peer);
            }
        },
        .done => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(2);
        },
    }

    return enc.toOwnedSlice();
}

fn encodePeerAddress(enc: *Encoder, addr: PeerAddress) !void {
    switch (addr) {
        .ipv4 => |v4| {
            try enc.encodeArrayLen(3);
            try enc.encodeUint(0); // IPv4 tag
            try enc.encodeUint(v4.addr);
            try enc.encodeUint(v4.port);
        },
        .ipv6 => |v6| {
            try enc.encodeArrayLen(6);
            try enc.encodeUint(1); // IPv6 tag
            for (v6.addr) |word| {
                try enc.encodeUint(word);
            }
            try enc.encodeUint(v6.port);
        },
    }
}

pub fn decodeMsg(allocator: std.mem.Allocator, data: []const u8) !PeerSharingMsg {
    var dec = Decoder.init(data);
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();

    return switch (tag) {
        0 => .{ .share_request = @intCast(try dec.decodeUint()) },
        1 => {
            const len = try dec.decodeArrayLen() orelse return error.InvalidCbor;
            if (len == 0) return .{ .share_peers = &[_]PeerAddress{} };
            const peers = try allocator.alloc(PeerAddress, @intCast(len));
            for (peers) |*peer| {
                peer.* = try decodePeerAddress(&dec);
            }
            return .{ .share_peers = peers };
        },
        2 => .done,
        else => error.InvalidCbor,
    };
}

fn decodePeerAddress(dec: *Decoder) !PeerAddress {
    const arr_len = try dec.decodeArrayLen() orelse return error.InvalidCbor;
    const addr_tag = try dec.decodeUint();
    switch (addr_tag) {
        0 => {
            if (arr_len != 3) return error.InvalidCbor;
            const addr = @as(u32, @intCast(try dec.decodeUint()));
            const port = @as(u16, @intCast(try dec.decodeUint()));
            return .{ .ipv4 = .{ .addr = addr, .port = port } };
        },
        1 => {
            if (arr_len != 6) return error.InvalidCbor;
            var addr: [4]u32 = undefined;
            for (&addr) |*word| {
                word.* = @intCast(try dec.decodeUint());
            }
            const port = @as(u16, @intCast(try dec.decodeUint()));
            return .{ .ipv6 = .{ .addr = addr, .port = port } };
        },
        else => return error.InvalidCbor,
    }
}

/// Convert PeerAddress to a human-readable string.
pub fn formatAddress(addr: PeerAddress, buf: []u8) ![]u8 {
    switch (addr) {
        .ipv4 => |v4| {
            return std.fmt.bufPrint(buf, "{}.{}.{}.{}:{}", .{
                (v4.addr >> 24) & 0xff,
                (v4.addr >> 16) & 0xff,
                (v4.addr >> 8) & 0xff,
                v4.addr & 0xff,
                v4.port,
            });
        },
        .ipv6 => |v6| {
            return std.fmt.bufPrint(buf, "[{x}:{x}:{x}:{x}]:{}", .{
                v6.addr[0], v6.addr[1], v6.addr[2], v6.addr[3], v6.port,
            });
        },
    }
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "peersharing: encode MsgShareRequest" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .share_request = 5 });
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x00, 0x05 }, bytes);
}

test "peersharing: encode MsgDone" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .done);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02 }, bytes);
}

test "peersharing: encode empty SharePeers" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .share_peers = &[_]PeerAddress{} });
    defer allocator.free(bytes);
    // [1, []] = array(2), uint 1, array(0)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x01, 0x80 }, bytes);
}

test "peersharing: IPv4 address round-trip" {
    const allocator = std.testing.allocator;
    const addr = PeerAddress{ .ipv4 = .{ .addr = 0x7f000001, .port = 3001 } }; // 127.0.0.1:3001
    const peers = [_]PeerAddress{addr};

    const bytes = try encodeMsg(allocator, .{ .share_peers = &peers });
    defer allocator.free(bytes);

    const msg = try decodeMsg(allocator, bytes);
    defer allocator.free(msg.share_peers);

    try std.testing.expectEqual(@as(usize, 1), msg.share_peers.len);
    try std.testing.expectEqual(@as(u32, 0x7f000001), msg.share_peers[0].ipv4.addr);
    try std.testing.expectEqual(@as(u16, 3001), msg.share_peers[0].ipv4.port);
}

test "peersharing: IPv6 address round-trip" {
    const allocator = std.testing.allocator;
    const addr = PeerAddress{ .ipv6 = .{
        .addr = [4]u32{ 0x20010db8, 0x00000000, 0x00000000, 0x00000001 },
        .port = 3001,
    } };
    const peers = [_]PeerAddress{addr};

    const bytes = try encodeMsg(allocator, .{ .share_peers = &peers });
    defer allocator.free(bytes);

    const msg = try decodeMsg(allocator, bytes);
    defer allocator.free(msg.share_peers);

    try std.testing.expectEqual(@as(usize, 1), msg.share_peers.len);
    switch (msg.share_peers[0]) {
        .ipv6 => |v6| {
            try std.testing.expectEqual(@as(u32, 0x20010db8), v6.addr[0]);
            try std.testing.expectEqual(@as(u16, 3001), v6.port);
        },
        else => unreachable,
    }
}

test "peersharing: format IPv4 address" {
    var buf: [64]u8 = undefined;
    const addr = PeerAddress{ .ipv4 = .{ .addr = 0x7f000001, .port = 3001 } };
    const str = try formatAddress(addr, &buf);
    try std.testing.expectEqualSlices(u8, "127.0.0.1:3001", str);
}
