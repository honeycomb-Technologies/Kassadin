const std = @import("std");

pub const DecodeError = error{
    EndOfInput,
    InvalidCbor,
    UnexpectedMajorType,
    Overflow,
    OutOfMemory,
};

pub const Decoder = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Decoder {
        return .{ .data = data, .pos = 0 };
    }

    /// Peek at the major type of the next value without consuming it.
    pub fn peekMajorType(self: *const Decoder) DecodeError!u3 {
        if (self.pos >= self.data.len) return error.EndOfInput;
        return @intCast(self.data[self.pos] >> 5);
    }

    /// Peek at the next byte without consuming it.
    pub fn peekByte(self: *const Decoder) DecodeError!u8 {
        if (self.pos >= self.data.len) return error.EndOfInput;
        return self.data[self.pos];
    }

    // ── Major type 0: Unsigned integer ──

    pub fn decodeUint(self: *Decoder) DecodeError!u64 {
        const initial = try self.readByte();
        const major: u3 = @intCast(initial >> 5);
        if (major != 0) return error.UnexpectedMajorType;
        return self.readArgument(@intCast(initial & 0x1f));
    }

    // ── Major type 1: Negative integer ──
    // Returns the stored value; actual = -1 - returned

    pub fn decodeNint(self: *Decoder) DecodeError!u64 {
        const initial = try self.readByte();
        const major: u3 = @intCast(initial >> 5);
        if (major != 1) return error.UnexpectedMajorType;
        return self.readArgument(@intCast(initial & 0x1f));
    }

    /// Decode any integer (major 0 or 1) as i128.
    pub fn decodeInt(self: *Decoder) DecodeError!i128 {
        const initial = try self.peekByte();
        const major: u3 = @intCast(initial >> 5);
        if (major == 0) {
            return @intCast(try self.decodeUint());
        } else if (major == 1) {
            const raw = try self.decodeNint();
            return -1 - @as(i128, @intCast(raw));
        }
        return error.UnexpectedMajorType;
    }

    // ── Major type 2: Byte string ──

    pub fn decodeBytes(self: *Decoder) DecodeError![]const u8 {
        const initial = try self.readByte();
        const major: u3 = @intCast(initial >> 5);
        if (major != 2) return error.UnexpectedMajorType;
        const len = try self.readArgument(@intCast(initial & 0x1f));
        return self.readSlice(@intCast(len));
    }

    // ── Major type 3: Text string ──

    pub fn decodeText(self: *Decoder) DecodeError![]const u8 {
        const initial = try self.readByte();
        const major: u3 = @intCast(initial >> 5);
        if (major != 3) return error.UnexpectedMajorType;
        const len = try self.readArgument(@intCast(initial & 0x1f));
        return self.readSlice(@intCast(len));
    }

    // ── Major type 4: Array ──

    /// Returns length, or null for indefinite-length.
    pub fn decodeArrayLen(self: *Decoder) DecodeError!?u64 {
        const initial = try self.readByte();
        const major: u3 = @intCast(initial >> 5);
        if (major != 4) return error.UnexpectedMajorType;
        const additional: u5 = @intCast(initial & 0x1f);
        if (additional == 31) return null; // indefinite
        return @as(?u64, try self.readArgument(additional));
    }

    // ── Major type 5: Map ──

    /// Returns number of key-value pairs, or null for indefinite-length.
    pub fn decodeMapLen(self: *Decoder) DecodeError!?u64 {
        const initial = try self.readByte();
        const major: u3 = @intCast(initial >> 5);
        if (major != 5) return error.UnexpectedMajorType;
        const additional: u5 = @intCast(initial & 0x1f);
        if (additional == 31) return null; // indefinite
        return @as(?u64, try self.readArgument(additional));
    }

    // ── Major type 6: Tag ──

    pub fn decodeTag(self: *Decoder) DecodeError!u64 {
        const initial = try self.readByte();
        const major: u3 = @intCast(initial >> 5);
        if (major != 6) return error.UnexpectedMajorType;
        return self.readArgument(@intCast(initial & 0x1f));
    }

    // ── Major type 7: Simple / Bool / Null ──

    pub fn decodeBool(self: *Decoder) DecodeError!bool {
        const b = try self.readByte();
        if (b == 0xf5) return true;
        if (b == 0xf4) return false;
        return error.InvalidCbor;
    }

    pub fn decodeNull(self: *Decoder) DecodeError!void {
        const b = try self.readByte();
        if (b != 0xf6) return error.InvalidCbor;
    }

    /// Check if the next byte is a break code (0xff).
    pub fn isBreak(self: *const Decoder) bool {
        if (self.pos >= self.data.len) return false;
        return self.data[self.pos] == 0xff;
    }

    /// Consume the break code.
    pub fn decodeBreak(self: *Decoder) DecodeError!void {
        const b = try self.readByte();
        if (b != 0xff) return error.InvalidCbor;
    }

    // ── Navigation ──

    /// Skip one complete CBOR value (including nested structures).
    pub fn skipValue(self: *Decoder) DecodeError!void {
        const initial = try self.readByte();
        const major: u3 = @intCast(initial >> 5);
        const additional: u5 = @intCast(initial & 0x1f);

        switch (major) {
            0, 1 => {
                // Integer: just skip the argument bytes
                _ = try self.readArgument(additional);
            },
            2, 3 => {
                // Byte/text string: skip argument + payload
                if (additional == 31) {
                    // Indefinite-length: skip chunks until break
                    while (!self.isBreak()) {
                        try self.skipValue();
                    }
                    try self.decodeBreak();
                } else {
                    const len = try self.readArgument(additional);
                    self.pos += @intCast(len);
                    if (self.pos > self.data.len) return error.EndOfInput;
                }
            },
            4 => {
                // Array
                if (additional == 31) {
                    while (!self.isBreak()) {
                        try self.skipValue();
                    }
                    try self.decodeBreak();
                } else {
                    const count = try self.readArgument(additional);
                    var i: u64 = 0;
                    while (i < count) : (i += 1) {
                        try self.skipValue();
                    }
                }
            },
            5 => {
                // Map
                if (additional == 31) {
                    while (!self.isBreak()) {
                        try self.skipValue(); // key
                        try self.skipValue(); // value
                    }
                    try self.decodeBreak();
                } else {
                    const count = try self.readArgument(additional);
                    var i: u64 = 0;
                    while (i < count) : (i += 1) {
                        try self.skipValue(); // key
                        try self.skipValue(); // value
                    }
                }
            },
            6 => {
                // Tag: skip argument + tagged value
                _ = try self.readArgument(additional);
                try self.skipValue();
            },
            7 => {
                // Simple / float / break
                switch (additional) {
                    0...23 => {}, // simple value, no extra bytes
                    24 => self.pos += 1, // 1-byte simple
                    25 => self.pos += 2, // float16
                    26 => self.pos += 4, // float32
                    27 => self.pos += 8, // float64
                    31 => {}, // break (shouldn't reach here normally)
                    else => return error.InvalidCbor,
                }
                if (self.pos > self.data.len) return error.EndOfInput;
            },
        }
    }

    /// Return the raw bytes of the next complete CBOR value WITHOUT consuming.
    pub fn sliceOfNextValue(self: *Decoder) DecodeError![]const u8 {
        const start = self.pos;
        try self.skipValue();
        return self.data[start..self.pos];
    }

    /// Check if all data has been consumed.
    pub fn isComplete(self: *const Decoder) bool {
        return self.pos >= self.data.len;
    }

    /// Return remaining unconsumed bytes.
    pub fn remaining(self: *const Decoder) []const u8 {
        return self.data[self.pos..];
    }

    // ── Internal helpers ──

    fn readByte(self: *Decoder) DecodeError!u8 {
        if (self.pos >= self.data.len) return error.EndOfInput;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readSlice(self: *Decoder, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.data.len) return error.EndOfInput;
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn readArgument(self: *Decoder, additional: u5) DecodeError!u64 {
        if (additional <= 23) return @intCast(additional);
        switch (additional) {
            24 => {
                const b = try self.readByte();
                return @intCast(b);
            },
            25 => {
                const bytes = try self.readSlice(2);
                return @intCast(std.mem.readInt(u16, bytes[0..2], .big));
            },
            26 => {
                const bytes = try self.readSlice(4);
                return @intCast(std.mem.readInt(u32, bytes[0..4], .big));
            },
            27 => {
                const bytes = try self.readSlice(8);
                return std.mem.readInt(u64, bytes[0..8], .big);
            },
            else => return error.InvalidCbor,
        }
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "cbor decode: uint 0" {
    var dec = Decoder.init(&[_]u8{0x00});
    const val = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 0), val);
    try std.testing.expect(dec.isComplete());
}

test "cbor decode: uint 23" {
    var dec = Decoder.init(&[_]u8{0x17});
    const val = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 23), val);
}

test "cbor decode: uint 24" {
    var dec = Decoder.init(&[_]u8{ 0x18, 0x18 });
    const val = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 24), val);
}

test "cbor decode: uint 1000000" {
    var dec = Decoder.init(&[_]u8{ 0x1a, 0x00, 0x0f, 0x42, 0x40 });
    const val = try dec.decodeUint();
    try std.testing.expectEqual(@as(u64, 1000000), val);
}

test "cbor decode: nint -1" {
    var dec = Decoder.init(&[_]u8{0x20});
    const val = try dec.decodeInt();
    try std.testing.expectEqual(@as(i128, -1), val);
}

test "cbor decode: nint -100" {
    var dec = Decoder.init(&[_]u8{ 0x38, 0x63 });
    const val = try dec.decodeInt();
    try std.testing.expectEqual(@as(i128, -100), val);
}

test "cbor decode: bytes" {
    var dec = Decoder.init(&[_]u8{ 0x45, 0x68, 0x65, 0x6c, 0x6c, 0x6f });
    const val = try dec.decodeBytes();
    try std.testing.expectEqualSlices(u8, "hello", val);
}

test "cbor decode: text" {
    var dec = Decoder.init(&[_]u8{ 0x65, 0x68, 0x65, 0x6c, 0x6c, 0x6f });
    const val = try dec.decodeText();
    try std.testing.expectEqualSlices(u8, "hello", val);
}

test "cbor decode: array of 3 uints" {
    var dec = Decoder.init(&[_]u8{ 0x83, 0x01, 0x02, 0x03 });
    const len = try dec.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 3), len);
    try std.testing.expectEqual(@as(u64, 1), try dec.decodeUint());
    try std.testing.expectEqual(@as(u64, 2), try dec.decodeUint());
    try std.testing.expectEqual(@as(u64, 3), try dec.decodeUint());
}

test "cbor decode: indefinite array" {
    var dec = Decoder.init(&[_]u8{ 0x9f, 0x01, 0x02, 0xff });
    const len = try dec.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, null), len);
    try std.testing.expectEqual(@as(u64, 1), try dec.decodeUint());
    try std.testing.expectEqual(@as(u64, 2), try dec.decodeUint());
    try std.testing.expect(dec.isBreak());
    try dec.decodeBreak();
}

test "cbor decode: bool" {
    var dec = Decoder.init(&[_]u8{ 0xf5, 0xf4 });
    try std.testing.expectEqual(true, try dec.decodeBool());
    try std.testing.expectEqual(false, try dec.decodeBool());
}

test "cbor decode: null" {
    var dec = Decoder.init(&[_]u8{0xf6});
    try dec.decodeNull();
    try std.testing.expect(dec.isComplete());
}

test "cbor decode: tag" {
    var dec = Decoder.init(&[_]u8{ 0xd8, 0x18 });
    const tag = try dec.decodeTag();
    try std.testing.expectEqual(@as(u64, 24), tag);
}

test "cbor decode: empty array" {
    var dec = Decoder.init(&[_]u8{0x80});
    const len = try dec.decodeArrayLen();
    try std.testing.expectEqual(@as(?u64, 0), len);
}

test "cbor decode: empty map" {
    var dec = Decoder.init(&[_]u8{0xa0});
    const len = try dec.decodeMapLen();
    try std.testing.expectEqual(@as(?u64, 0), len);
}

test "cbor decode: skip nested structure" {
    // Array of [1, [2, 3], "hi"]
    var dec = Decoder.init(&[_]u8{ 0x83, 0x01, 0x82, 0x02, 0x03, 0x62, 0x68, 0x69 });
    const raw = try dec.sliceOfNextValue();
    try std.testing.expectEqual(@as(usize, 8), raw.len);
    // Position should be back at end after sliceOfNextValue consumed
    try std.testing.expect(dec.isComplete());
}

test "cbor decode: map with entry" {
    // {1: "a"}
    var dec = Decoder.init(&[_]u8{ 0xa1, 0x01, 0x61, 0x61 });
    const len = try dec.decodeMapLen();
    try std.testing.expectEqual(@as(?u64, 1), len);
    try std.testing.expectEqual(@as(u64, 1), try dec.decodeUint());
    const val = try dec.decodeText();
    try std.testing.expectEqualSlices(u8, "a", val);
}

test "cbor decode: peek major type" {
    var dec = Decoder.init(&[_]u8{0x83});
    const major = try dec.peekMajorType();
    try std.testing.expectEqual(@as(u3, 4), major); // array
    // Position unchanged
    try std.testing.expectEqual(@as(usize, 0), dec.pos);
}
