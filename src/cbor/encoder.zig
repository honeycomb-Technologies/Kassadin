const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Encoder = struct {
    data: std.ArrayList(u8) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Encoder {
        return .{ .data = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Encoder) void {
        self.data.deinit(self.allocator);
    }

    // ── Major type 0: Unsigned integer ──

    pub fn encodeUint(self: *Encoder, value: u64) !void {
        try self.writeTypedArgument(0, value);
    }

    // ── Major type 1: Negative integer (encodes -1 - value) ──

    pub fn encodeNint(self: *Encoder, value: u64) !void {
        try self.writeTypedArgument(1, value);
    }

    /// Encode a signed integer, selecting uint or nint automatically.
    pub fn encodeInt(self: *Encoder, value: i64) !void {
        if (value >= 0) {
            try self.encodeUint(@intCast(value));
        } else {
            // CBOR negative: -1 - value stored, so for value=-1, store 0
            try self.encodeNint(@intCast(-1 - value));
        }
    }

    // ── Major type 2: Byte string ──

    pub fn encodeBytes(self: *Encoder, bytes: []const u8) !void {
        try self.writeTypedArgument(2, bytes.len);
        try self.data.appendSlice(self.allocator, bytes);
    }

    // ── Major type 3: Text string ──

    pub fn encodeText(self: *Encoder, text: []const u8) !void {
        try self.writeTypedArgument(3, text.len);
        try self.data.appendSlice(self.allocator, text);
    }

    // ── Major type 4: Array ──

    pub fn encodeArrayLen(self: *Encoder, len: usize) !void {
        try self.writeTypedArgument(4, len);
    }

    pub fn encodeArrayIndef(self: *Encoder) !void {
        try self.data.append(self.allocator, 0x9f);
    }

    // ── Major type 5: Map ──

    pub fn encodeMapLen(self: *Encoder, len: usize) !void {
        try self.writeTypedArgument(5, len);
    }

    pub fn encodeMapIndef(self: *Encoder) !void {
        try self.data.append(self.allocator, 0xbf);
    }

    // ── Major type 6: Tag ──

    pub fn encodeTag(self: *Encoder, tag_number: u64) !void {
        try self.writeTypedArgument(6, tag_number);
    }

    // ── Major type 7: Simple values and floats ──

    pub fn encodeBool(self: *Encoder, value: bool) !void {
        try self.data.append(self.allocator, if (value) 0xf5 else 0xf4);
    }

    pub fn encodeNull(self: *Encoder) !void {
        try self.data.append(self.allocator, 0xf6);
    }

    pub fn encodeUndefined(self: *Encoder) !void {
        try self.data.append(self.allocator, 0xf7);
    }

    pub fn encodeBreak(self: *Encoder) !void {
        try self.data.append(self.allocator, 0xff);
    }

    pub fn encodeSimple(self: *Encoder, value: u8) !void {
        if (value <= 23) {
            try self.data.append(self.allocator, 0xe0 | value);
        } else {
            try self.data.append(self.allocator, 0xf8);
            try self.data.append(self.allocator, value);
        }
    }

    // ── Raw byte injection ──

    pub fn writeRaw(self: *Encoder, raw: []const u8) !void {
        try self.data.appendSlice(self.allocator, raw);
    }

    // ── Output ──

    pub fn getWritten(self: *const Encoder) []const u8 {
        return self.data.items;
    }

    pub fn toOwnedSlice(self: *Encoder) ![]u8 {
        return self.data.toOwnedSlice(self.allocator);
    }

    // ── Internal: Write major type + argument ──

    fn writeTypedArgument(self: *Encoder, major: u3, value: u64) !void {
        const high: u8 = @as(u8, major) << 5;
        if (value <= 23) {
            try self.data.append(self.allocator, high | @as(u8, @intCast(value)));
        } else if (value <= 0xff) {
            try self.data.append(self.allocator, high | 24);
            try self.data.append(self.allocator, @intCast(value));
        } else if (value <= 0xffff) {
            try self.data.append(self.allocator, high | 25);
            try self.data.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeTo(u16, @intCast(value), .big)));
        } else if (value <= 0xffff_ffff) {
            try self.data.append(self.allocator, high | 26);
            try self.data.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeTo(u32, @intCast(value), .big)));
        } else {
            try self.data.append(self.allocator, high | 27);
            try self.data.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeTo(u64, value, .big)));
        }
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "cbor encode: uint small values" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();

    try enc.encodeUint(0);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, enc.getWritten());
}

test "cbor encode: uint 23" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeUint(23);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x17}, enc.getWritten());
}

test "cbor encode: uint 24" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeUint(24);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x18, 0x18 }, enc.getWritten());
}

test "cbor encode: uint 1000000" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeUint(1000000);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x1a, 0x00, 0x0f, 0x42, 0x40 }, enc.getWritten());
}

test "cbor encode: nint -1" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeInt(-1);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x20}, enc.getWritten());
}

test "cbor encode: nint -100" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeInt(-100);
    // -100: stored as 99 (one-byte), major type 1
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x38, 0x63 }, enc.getWritten());
}

test "cbor encode: bytes" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeBytes("hello");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x45, 0x68, 0x65, 0x6c, 0x6c, 0x6f }, enc.getWritten());
}

test "cbor encode: text" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeText("hello");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x65, 0x68, 0x65, 0x6c, 0x6c, 0x6f }, enc.getWritten());
}

test "cbor encode: array of uint" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeArrayLen(3);
    try enc.encodeUint(1);
    try enc.encodeUint(2);
    try enc.encodeUint(3);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x01, 0x02, 0x03 }, enc.getWritten());
}

test "cbor encode: bool" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeBool(true);
    try enc.encodeBool(false);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xf5, 0xf4 }, enc.getWritten());
}

test "cbor encode: null" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeNull();
    try std.testing.expectEqualSlices(u8, &[_]u8{0xf6}, enc.getWritten());
}

test "cbor encode: tag" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeTag(24);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xd8, 0x18 }, enc.getWritten());
}

test "cbor encode: indefinite array with break" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeArrayIndef();
    try enc.encodeUint(1);
    try enc.encodeUint(2);
    try enc.encodeBreak();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x9f, 0x01, 0x02, 0xff }, enc.getWritten());
}

test "cbor encode: empty map" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeMapLen(0);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xa0}, enc.getWritten());
}

test "cbor encode: map with one entry" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encodeMapLen(1);
    try enc.encodeUint(1); // key
    try enc.encodeText("a"); // value
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa1, 0x01, 0x61, 0x61 }, enc.getWritten());
}
