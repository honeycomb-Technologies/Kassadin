const std = @import("std");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const protocol = @import("protocol.zig");
const mux = @import("mux.zig");

/// N2C version numbers have bit 15 set to distinguish from N2N.
/// E.g., N2C v16 encodes as 16 | (1 << 15) = 32784
pub const N2CVersion = enum(u64) {
    v16 = 32784, // 16 | 0x8000
    v17 = 32785,
    v18 = 32786,
    v19 = 32787,
    v20 = 32788,
    v21 = 32789,
};

/// N2C version data: just [networkMagic, query]
pub const N2CVersionData = struct {
    network_magic: u32,
    query: bool,
};

pub const N2CHandshakeResult = union(enum) {
    accepted: struct {
        version: u64,
        version_data: N2CVersionData,
    },
    refused: []const u8,
};

/// Encode MsgProposeVersions for N2C.
pub fn encodeProposeVersions(allocator: std.mem.Allocator, magic: u32) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    try enc.encodeArrayLen(2);
    try enc.encodeUint(0); // MsgProposeVersions

    // Map of supported versions (keys ascending)
    try enc.encodeMapLen(6); // v16-v21
    inline for (.{ 32784, 32785, 32786, 32787, 32788, 32789 }) |ver| {
        try enc.encodeUint(ver);
        try enc.encodeArrayLen(2);
        try enc.encodeUint(magic);
        try enc.encodeBool(false); // query = false
    }

    return enc.toOwnedSlice();
}

/// Decode N2C handshake response.
pub fn decodeResponse(data: []const u8) !N2CHandshakeResult {
    var dec = Decoder.init(data);
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();

    switch (tag) {
        1 => {
            // MsgAcceptVersion
            const version = try dec.decodeUint();
            _ = try dec.decodeArrayLen();
            const magic = @as(u32, @intCast(try dec.decodeUint()));
            const query = try dec.decodeBool();
            return .{ .accepted = .{
                .version = version,
                .version_data = .{ .network_magic = magic, .query = query },
            } };
        },
        2 => {
            // MsgRefuse
            return .{ .refused = "version refused" };
        },
        else => return error.InvalidCbor,
    }
}

/// Perform N2C handshake over a bearer.
pub fn performHandshake(allocator: std.mem.Allocator, bearer: *mux.Bearer, magic: u32) !N2CHandshakeResult {
    const propose = try encodeProposeVersions(allocator, magic);
    defer allocator.free(propose);

    try bearer.writeSDU(0, .initiator, propose);

    const response = try bearer.readProtocolMessage(0, allocator);
    defer allocator.free(response);

    return decodeResponse(response);
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "n2c_handshake: encode propose versions structure" {
    const allocator = std.testing.allocator;
    const bytes = try encodeProposeVersions(allocator, 2);
    defer allocator.free(bytes);

    var dec = Decoder.init(bytes);
    const arr = try dec.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 2), arr);
    try std.testing.expectEqual(@as(u64, 0), try dec.decodeUint()); // tag
    const map_len = try dec.decodeMapLen();
    try std.testing.expectEqual(@as(?u64, 6), map_len); // 6 versions

    // First key should be v16 = 32784
    const first_key = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 32784), first_key);
}

test "n2c_handshake: decode accept response" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    try enc.encodeArrayLen(3);
    try enc.encodeUint(1); // MsgAcceptVersion
    try enc.encodeUint(32789); // v21
    try enc.encodeArrayLen(2);
    try enc.encodeUint(2); // magic
    try enc.encodeBool(false);

    const result = try decodeResponse(enc.getWritten());
    switch (result) {
        .accepted => |a| {
            try std.testing.expectEqual(@as(u64, 32789), a.version);
            try std.testing.expectEqual(@as(u32, 2), a.version_data.network_magic);
        },
        .refused => unreachable,
    }
}

test "n2c_handshake: version numbers have bit 15 set" {
    try std.testing.expectEqual(@as(u64, 32784), @intFromEnum(N2CVersion.v16));
    try std.testing.expectEqual(@as(u64, 32789), @intFromEnum(N2CVersion.v21));
    // Verify bit 15 is set
    try std.testing.expect((@intFromEnum(N2CVersion.v16) & 0x8000) != 0);
}
