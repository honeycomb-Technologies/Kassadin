const std = @import("std");
const blake2 = std.crypto.hash.blake2;

/// Blake2b-256: 32-byte hash used for block hashes, transaction hashes, script hashes.
pub const Blake2b256 = struct {
    pub const digest_length: usize = 32;
    pub const Digest = [digest_length]u8;

    pub fn hash(data: []const u8) Digest {
        var out: Digest = undefined;
        var state = blake2.Blake2b256.init(.{});
        state.update(data);
        state.final(&out);
        return out;
    }

    /// Incremental hashing state.
    pub const State = struct {
        inner: blake2.Blake2b256,

        pub fn init() State {
            return .{ .inner = blake2.Blake2b256.init(.{}) };
        }

        pub fn update(self: *State, data: []const u8) void {
            self.inner.update(data);
        }

        pub fn final(self: *State) Digest {
            var out: Digest = undefined;
            self.inner.final(&out);
            return out;
        }
    };
};

/// Blake2b-224: 28-byte hash used for verification key hashes (credentials, addresses).
pub const Blake2b224 = struct {
    pub const digest_length: usize = 28;
    pub const Digest = [digest_length]u8;

    pub fn hash(data: []const u8) Digest {
        var out: Digest = undefined;
        var state = blake2.Blake2b(224).init(.{});
        state.update(data);
        state.final(&out);
        return out;
    }

    pub const State = struct {
        inner: blake2.Blake2b(224),

        pub fn init() State {
            return .{ .inner = blake2.Blake2b(224).init(.{}) };
        }

        pub fn update(self: *State, data: []const u8) void {
            self.inner.update(data);
        }

        pub fn final(self: *State) Digest {
            var out: Digest = undefined;
            self.inner.final(&out);
            return out;
        }
    };
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "blake2b-256: empty input" {
    const d = Blake2b256.hash("");
    const expected = [_]u8{
        0x0e, 0x57, 0x51, 0xc0, 0x26, 0xe5, 0x43, 0xb2,
        0xe8, 0xab, 0x2e, 0xb0, 0x60, 0x99, 0xda, 0xa1,
        0xd1, 0xe5, 0xdf, 0x47, 0x77, 0x8f, 0x77, 0x87,
        0xfa, 0xab, 0x45, 0xcd, 0xf1, 0x2f, 0xe3, 0xa8,
    };
    try std.testing.expectEqualSlices(u8, &expected, &d);
}

test "blake2b-256: abc" {
    const d = Blake2b256.hash("abc");
    // Known blake2b-256("abc") value
    const expected = [_]u8{
        0xbd, 0xdd, 0x81, 0x3c, 0x63, 0x42, 0x39, 0x72,
        0x31, 0x71, 0xef, 0x3f, 0xee, 0x98, 0x57, 0x9b,
        0x94, 0x96, 0x4e, 0x3b, 0xb1, 0xcb, 0x3e, 0x42,
        0x72, 0x62, 0xc8, 0xc0, 0x68, 0xd5, 0x23, 0x19,
    };
    try std.testing.expectEqualSlices(u8, &expected, &d);
}

test "blake2b-256: incremental matches one-shot" {
    const msg = "The quick brown fox jumps over the lazy dog";
    const one_shot = Blake2b256.hash(msg);

    var state = Blake2b256.State.init();
    state.update(msg[0..10]);
    state.update(msg[10..]);
    const incremental = state.final();

    try std.testing.expectEqualSlices(u8, &one_shot, &incremental);
}

test "blake2b-224: output length" {
    const d = Blake2b224.hash("test");
    try std.testing.expectEqual(@as(usize, 28), d.len);
}

test "blake2b-224: incremental matches one-shot" {
    const msg = "hello world";
    const one_shot = Blake2b224.hash(msg);

    var state = Blake2b224.State.init();
    state.update("hello ");
    state.update("world");
    const incremental = state.final();

    try std.testing.expectEqualSlices(u8, &one_shot, &incremental);
}
