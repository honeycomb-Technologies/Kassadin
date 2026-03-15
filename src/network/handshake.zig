const std = @import("std");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const protocol = @import("protocol.zig");
const mux = @import("mux.zig");

pub const N2NVersion = protocol.N2NVersion;
pub const N2NVersionData = protocol.N2NVersionData;
pub const PeerSharing = protocol.PeerSharing;

/// Result of a handshake attempt.
pub const HandshakeResult = union(enum) {
    accepted: struct {
        version: u64,
        version_data: N2NVersionData,
    },
    refused: RefuseReason,
};

pub const RefuseReason = union(enum) {
    version_mismatch: void,
    decode_error: []const u8,
    refused: []const u8,
};

/// Encode MsgProposeVersions for N2N handshake.
/// CBOR: [0, {14 => [magic, initiator_only, peer_sharing, query], 15 => [...]}]
/// Map keys MUST be in ascending order.
pub fn encodeProposeVersions(allocator: std.mem.Allocator, magic: u32, initiator_only: bool, peer_sharing: PeerSharing, query: bool) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    // Outer array of 2
    try enc.encodeArrayLen(2);
    try enc.encodeUint(0); // MsgProposeVersions tag

    // Map of 2 entries (v14, v15) — keys in ascending order
    try enc.encodeMapLen(2);

    // Version 14
    try enc.encodeUint(14);
    try encodeVersionData(&enc, magic, initiator_only, peer_sharing, query);

    // Version 15
    try enc.encodeUint(15);
    try encodeVersionData(&enc, magic, initiator_only, peer_sharing, query);

    return enc.toOwnedSlice();
}

fn encodeVersionData(enc: *Encoder, magic: u32, initiator_only: bool, peer_sharing: PeerSharing, query: bool) !void {
    try enc.encodeArrayLen(4);
    try enc.encodeUint(magic);
    try enc.encodeBool(initiator_only);
    try enc.encodeUint(@intFromEnum(peer_sharing));
    try enc.encodeBool(query);
}

/// Decode a handshake response (MsgAcceptVersion or MsgRefuse).
pub fn decodeHandshakeResponse(allocator: std.mem.Allocator, data: []const u8) !HandshakeResult {
    _ = allocator;
    var dec = Decoder.init(data);
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();

    switch (tag) {
        1 => {
            // MsgAcceptVersion = [1, version, version_data]
            const version = try dec.decodeUint();
            _ = try dec.decodeArrayLen(); // version data array
            const magic = @as(u32, @intCast(try dec.decodeUint()));
            const initiator_only = try dec.decodeBool();
            const peer_sharing_val = try dec.decodeUint();
            const query = try dec.decodeBool();

            return .{ .accepted = .{
                .version = version,
                .version_data = .{
                    .network_magic = magic,
                    .initiator_only = initiator_only,
                    .peer_sharing = @enumFromInt(@as(u8, @intCast(peer_sharing_val))),
                    .query = query,
                },
            } };
        },
        2 => {
            // MsgRefuse = [2, reason]
            _ = try dec.decodeArrayLen(); // reason array
            const reason_tag = try dec.decodeUint();
            switch (reason_tag) {
                0 => return .{ .refused = .version_mismatch },
                1, 2 => {
                    _ = try dec.decodeUint(); // version
                    const msg = try dec.decodeText();
                    if (reason_tag == 1) {
                        return .{ .refused = .{ .decode_error = msg } };
                    } else {
                        return .{ .refused = .{ .refused = msg } };
                    }
                },
                else => return error.InvalidCbor,
            }
        },
        else => return error.InvalidCbor,
    }
}

/// Perform a complete N2N handshake over a bearer.
/// Sends MsgProposeVersions and reads MsgAcceptVersion/MsgRefuse.
pub fn performHandshake(allocator: std.mem.Allocator, bearer: *mux.Bearer, magic: u32) !HandshakeResult {
    // Encode and send MsgProposeVersions
    const propose_bytes = try encodeProposeVersions(
        allocator,
        magic,
        false, // initiator and responder mode (duplex)
        .disabled,
        false,
    );
    defer allocator.free(propose_bytes);

    try bearer.writeSDU(
        @intFromEnum(protocol.MiniProtocolNum.handshake),
        .initiator,
        propose_bytes,
    );

    // Read response
    const response_bytes = try bearer.readProtocolMessage(
        @intFromEnum(protocol.MiniProtocolNum.handshake),
        allocator,
    );
    defer allocator.free(response_bytes);

    return decodeHandshakeResponse(allocator, response_bytes);
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "handshake: encode MsgProposeVersions structure" {
    const allocator = std.testing.allocator;
    const bytes = try encodeProposeVersions(allocator, 2, false, .disabled, false);
    defer allocator.free(bytes);

    // Decode and verify structure
    var dec = Decoder.init(bytes);

    // Outer: array(2)
    const outer_len = try dec.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 2), outer_len);

    // Tag: 0 (MsgProposeVersions)
    const tag = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 0), tag);

    // Map of 2 entries
    const map_len = try dec.decodeMapLen();
    try std.testing.expectEqual(@as(?u64, 2), map_len);

    // Entry 1: key = 14
    const key1 = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 14), key1);

    // Version data array(4)
    const vd1_len = try dec.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 4), vd1_len);

    // magic = 2 (preview)
    const magic1 = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 2), magic1);

    // initiator_only = false
    const init_only1 = try dec.decodeBool();
    try std.testing.expectEqual(false, init_only1);

    // peer_sharing = 0 (disabled)
    const ps1 = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 0), ps1);

    // query = false
    const q1 = try dec.decodeBool();
    try std.testing.expectEqual(false, q1);

    // Entry 2: key = 15
    const key2 = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 15), key2);

    // Skip version data for v15
    try dec.skipValue();

    // Should be fully consumed
    try std.testing.expect(dec.isComplete());
}

test "handshake: MsgProposeVersions CBOR starts correctly" {
    const allocator = std.testing.allocator;
    const bytes = try encodeProposeVersions(allocator, 764824073, false, .disabled, false);
    defer allocator.free(bytes);

    // First bytes: 82 (array 2), 00 (uint 0 = MsgProposeVersions tag), a2 (map 2)
    try std.testing.expectEqual(@as(u8, 0x82), bytes[0]); // array(2)
    try std.testing.expectEqual(@as(u8, 0x00), bytes[1]); // uint 0
    try std.testing.expectEqual(@as(u8, 0xa2), bytes[2]); // map(2)
}

test "handshake: decode MsgAcceptVersion" {
    const allocator = std.testing.allocator;

    // Manually construct a MsgAcceptVersion: [1, 14, [2, false, 0, false]]
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.encodeArrayLen(3);
    try enc.encodeUint(1); // MsgAcceptVersion tag
    try enc.encodeUint(14); // version
    try enc.encodeArrayLen(4);
    try enc.encodeUint(2); // magic = preview
    try enc.encodeBool(false); // initiator_only
    try enc.encodeUint(0); // peer_sharing disabled
    try enc.encodeBool(false); // query

    const response = try decodeHandshakeResponse(allocator, enc.getWritten());
    switch (response) {
        .accepted => |a| {
            try std.testing.expectEqual(@as(u64, 14), a.version);
            try std.testing.expectEqual(@as(u32, 2), a.version_data.network_magic);
            try std.testing.expectEqual(false, a.version_data.initiator_only);
        },
        .refused => unreachable,
    }
}

test "handshake: decode MsgRefuse version mismatch" {
    const allocator = std.testing.allocator;

    // [2, [0, [14, 15]]]
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.encodeArrayLen(2);
    try enc.encodeUint(2); // MsgRefuse tag
    try enc.encodeArrayLen(1);
    try enc.encodeUint(0); // VersionMismatch reason

    const response = try decodeHandshakeResponse(allocator, enc.getWritten());
    switch (response) {
        .refused => |r| {
            try std.testing.expect(r == .version_mismatch);
        },
        .accepted => unreachable,
    }
}

test "handshake: map keys ascending (14 before 15)" {
    const allocator = std.testing.allocator;
    const bytes = try encodeProposeVersions(allocator, 2, false, .disabled, false);
    defer allocator.free(bytes);

    // Find the map and verify key order
    var dec = Decoder.init(bytes);
    _ = try dec.decodeArrayLen(); // outer array
    _ = try dec.decodeUint(); // tag
    _ = try dec.decodeMapLen(); // map

    const key1 = try dec.decodeUint();
    try dec.skipValue(); // skip v14 data
    const key2 = try dec.decodeUint();

    try std.testing.expect(key1 < key2); // 14 < 15
}
