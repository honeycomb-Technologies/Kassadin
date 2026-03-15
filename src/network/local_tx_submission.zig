const std = @import("std");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;

/// Local Tx-Submission mini-protocol (N2C, protocol num 6).
/// Push-based: client submits, server accepts or rejects.
pub const LocalTxSubmissionMsg = union(enum) {
    submit_tx: []const u8, // [0, tx_raw]
    accept_tx: void, // [1]
    reject_tx: []const u8, // [2, reason_raw]
    done: void, // [3]
};

pub fn encodeMsg(allocator: std.mem.Allocator, msg: LocalTxSubmissionMsg) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    switch (msg) {
        .submit_tx => |tx| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(0);
            try enc.writeRaw(tx);
        },
        .accept_tx => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(1);
        },
        .reject_tx => |reason| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(2);
            try enc.writeRaw(reason);
        },
        .done => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(3);
        },
    }

    return enc.toOwnedSlice();
}

pub fn decodeMsg(data: []const u8) !LocalTxSubmissionMsg {
    var dec = Decoder.init(data);
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();

    return switch (tag) {
        0 => .{ .submit_tx = dec.remaining() },
        1 => .accept_tx,
        2 => .{ .reject_tx = dec.remaining() },
        3 => .done,
        else => error.InvalidCbor,
    };
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "local_tx_submission: encode MsgAcceptTx" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .accept_tx);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x01 }, bytes);
}

test "local_tx_submission: encode MsgDone" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .done);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x03 }, bytes);
}

test "local_tx_submission: decode round-trip" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .accept_tx);
    defer allocator.free(bytes);
    const decoded = try decodeMsg(bytes);
    try std.testing.expect(decoded == .accept_tx);
}
