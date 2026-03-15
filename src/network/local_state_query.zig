const std = @import("std");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");
const chainsync = @import("chainsync.zig");

/// Local State Query mini-protocol (N2C, protocol num 7).
/// Query the node's ledger state at a specific chain point.
pub const LocalStateQueryMsg = union(enum) {
    acquire_point: ?chainsync.Point, // [0, point] or [8] (immutable tip) or [10] (volatile tip)
    acquired: void, // [1]
    failure: AcquireFailure, // [2, reason]
    query: []const u8, // [3, query_raw]
    result: []const u8, // [4, result_raw]
    release: void, // [5]
    reacquire: ?chainsync.Point, // [6, point] or [9] or [11]
    done: void, // [7]
};

pub const AcquireFailure = enum(u8) {
    point_too_old = 0,
    point_not_on_chain = 1,
};

pub fn encodeMsg(allocator: std.mem.Allocator, msg: LocalStateQueryMsg) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    switch (msg) {
        .acquire_point => |point| {
            if (point) |p| {
                try enc.encodeArrayLen(2);
                try enc.encodeUint(0);
                try chainsync.encodePoint(&enc, p);
            } else {
                try enc.encodeArrayLen(1);
                try enc.encodeUint(8); // immutable tip
            }
        },
        .acquired => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(1);
        },
        .failure => |reason| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(2);
            try enc.encodeUint(@intFromEnum(reason));
        },
        .query => |q| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(3);
            try enc.writeRaw(q);
        },
        .result => |r| {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(4);
            try enc.writeRaw(r);
        },
        .release => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(5);
        },
        .reacquire => |point| {
            if (point) |p| {
                try enc.encodeArrayLen(2);
                try enc.encodeUint(6);
                try chainsync.encodePoint(&enc, p);
            } else {
                try enc.encodeArrayLen(1);
                try enc.encodeUint(9); // immutable tip
            }
        },
        .done => {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(7);
        },
    }

    return enc.toOwnedSlice();
}

pub fn decodeMsg(data: []const u8) !LocalStateQueryMsg {
    var dec = Decoder.init(data);
    _ = try dec.decodeArrayLen();
    const tag = try dec.decodeUint();

    return switch (tag) {
        0 => {
            const point = try chainsync.decodePoint(&dec);
            return .{ .acquire_point = point };
        },
        1 => .acquired,
        2 => .{ .failure = @enumFromInt(@as(u8, @intCast(try dec.decodeUint()))) },
        3 => .{ .query = dec.remaining() },
        4 => .{ .result = dec.remaining() },
        5 => .release,
        6 => {
            const point = try chainsync.decodePoint(&dec);
            return .{ .reacquire = point };
        },
        7 => .done,
        8 => .{ .acquire_point = null }, // immutable tip
        9 => .{ .reacquire = null }, // immutable tip
        10 => .{ .acquire_point = null }, // volatile tip
        11 => .{ .reacquire = null }, // volatile tip
        else => error.InvalidCbor,
    };
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "local_state_query: encode MsgAcquire immutable tip" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .acquire_point = null });
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x08 }, bytes);
}

test "local_state_query: encode MsgAcquired" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .acquired);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x01 }, bytes);
}

test "local_state_query: encode MsgRelease" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .release);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x05 }, bytes);
}

test "local_state_query: encode MsgDone" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .done);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x07 }, bytes);
}

test "local_state_query: encode MsgFailure" {
    const allocator = std.testing.allocator;
    const bytes = try encodeMsg(allocator, .{ .failure = .point_too_old });
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x02, 0x00 }, bytes);
}

test "local_state_query: decode round-trip" {
    const allocator = std.testing.allocator;
    const msgs = [_]LocalStateQueryMsg{
        .acquired,
        .{ .failure = .point_not_on_chain },
        .release,
        .done,
    };
    for (msgs) |msg| {
        const bytes = try encodeMsg(allocator, msg);
        defer allocator.free(bytes);
        _ = try decodeMsg(bytes);
    }
}
