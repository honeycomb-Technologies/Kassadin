//! RIPEMD-160 cryptographic hash function.
//! Reference: https://homes.esat.kuleuven.be/~bosMDsel/ripemd160.html

const std = @import("std");
const mem = std.mem;

/// RIPEMD-160 hash function producing a 20-byte (160-bit) digest.
pub const Ripemd160 = struct {
    state: [5]u32 = .{
        0x67452301,
        0xEFCDAB89,
        0x98BADCFE,
        0x10325476,
        0xC3D2E1F0,
    },
    buf: [64]u8 = undefined,
    buf_len: u8 = 0,
    total_len: u64 = 0,

    pub const digest_length = 20;
    pub const block_length = 64;

    pub fn hash(msg: []const u8, out: *[digest_length]u8, _: struct {}) void {
        var h: Ripemd160 = .{};
        h.update(msg);
        h.final(out);
    }

    pub fn update(self: *Ripemd160, data: []const u8) void {
        var d = data;
        self.total_len += d.len;

        // Fill partial buffer
        if (self.buf_len > 0) {
            const space = 64 - self.buf_len;
            if (d.len >= space) {
                @memcpy(self.buf[self.buf_len..64], d[0..space]);
                self.processBlock(&self.buf);
                d = d[space..];
                self.buf_len = 0;
            } else {
                @memcpy(self.buf[self.buf_len..][0..d.len], d);
                self.buf_len += @intCast(d.len);
                return;
            }
        }

        // Process full blocks
        while (d.len >= 64) {
            self.processBlock(d[0..64]);
            d = d[64..];
        }

        // Store remainder
        if (d.len > 0) {
            @memcpy(self.buf[0..d.len], d);
            self.buf_len = @intCast(d.len);
        }
    }

    pub fn final(self: *Ripemd160, out: *[digest_length]u8) void {
        const total_bits = self.total_len * 8;
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;

        if (self.buf_len > 56) {
            @memset(self.buf[self.buf_len..64], 0);
            self.processBlock(&self.buf);
            self.buf_len = 0;
        }

        @memset(self.buf[self.buf_len..56], 0);
        mem.writeInt(u64, self.buf[56..64], total_bits, .little);
        self.processBlock(&self.buf);

        inline for (0..5) |i| {
            mem.writeInt(u32, out[i * 4 ..][0..4], self.state[i], .little);
        }
    }

    // Boolean functions
    fn f0(b: u32, c: u32, d: u32) u32 {
        return b ^ c ^ d;
    }
    fn f1(b: u32, c: u32, d: u32) u32 {
        return (b & c) | (~b & d);
    }
    fn f2(b: u32, c: u32, d: u32) u32 {
        return (b | ~c) ^ d;
    }
    fn f3(b: u32, c: u32, d: u32) u32 {
        return (b & d) | (c & ~d);
    }
    fn f4(b: u32, c: u32, d: u32) u32 {
        return b ^ (c | ~d);
    }

    fn leftF(comptime j: usize) *const fn (u32, u32, u32) u32 {
        return switch (j / 16) {
            0 => &f0,
            1 => &f1,
            2 => &f2,
            3 => &f3,
            4 => &f4,
            else => unreachable,
        };
    }
    fn rightF(comptime j: usize) *const fn (u32, u32, u32) u32 {
        return switch (j / 16) {
            0 => &f4,
            1 => &f3,
            2 => &f2,
            3 => &f1,
            4 => &f0,
            else => unreachable,
        };
    }

    const left_k = [5]u32{ 0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E };
    const right_k = [5]u32{ 0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000 };

    fn processBlock(self: *Ripemd160, block: *const [64]u8) void {
        var x: [16]u32 = undefined;
        inline for (0..16) |i| {
            x[i] = mem.readInt(u32, block[i * 4 ..][0..4], .little);
        }

        var al = self.state[0];
        var bl = self.state[1];
        var cl = self.state[2];
        var dl = self.state[3];
        var el = self.state[4];

        var ar = self.state[0];
        var br = self.state[1];
        var cr = self.state[2];
        var dr = self.state[3];
        var er = self.state[4];

        // Left rounds
        inline for (0..80) |j| {
            const fl = comptime leftF(j);
            const kl = comptime left_k[j / 16];
            const rl = comptime left_r[j];
            const sl = comptime left_s[j];

            const t = rotl(al +% fl(bl, cl, dl) +% x[rl] +% kl, sl) +% el;
            al = el;
            el = dl;
            dl = rotl(cl, 10);
            cl = bl;
            bl = t;
        }

        // Right rounds
        inline for (0..80) |j| {
            const fr = comptime rightF(j);
            const kr = comptime right_k[j / 16];
            const rr = comptime right_r[j];
            const sr = comptime right_s[j];

            const t = rotl(ar +% fr(br, cr, dr) +% x[rr] +% kr, sr) +% er;
            ar = er;
            er = dr;
            dr = rotl(cr, 10);
            cr = br;
            br = t;
        }

        const t = self.state[1] +% cl +% dr;
        self.state[1] = self.state[2] +% dl +% er;
        self.state[2] = self.state[3] +% el +% ar;
        self.state[3] = self.state[4] +% al +% br;
        self.state[4] = self.state[0] +% bl +% cr;
        self.state[0] = t;
    }

    fn rotl(x: u32, comptime n: u5) u32 {
        return std.math.rotl(u32, x, n);
    }

    // Message word selection for left rounds
    const left_r = [80]u4{
        0, 1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
        7, 4,  13, 1,  10, 6,  15, 3,  12, 0, 9,  5,  2,  14, 11, 8,
        3, 10, 14, 4,  9,  15, 8,  1,  2,  7, 0,  6,  13, 11, 5,  12,
        1, 9,  11, 10, 0,  8,  12, 4,  13, 3, 7,  15, 14, 5,  6,  2,
        4, 0,  5,  9,  7,  12, 2,  10, 14, 1, 3,  8,  11, 6,  15, 13,
    };

    // Rotation amounts for left rounds
    const left_s = [80]u5{
        11, 14, 15, 12, 5,  8,  7,  9,  11, 13, 14, 15, 6,  7,  9,  8,
        7,  6,  8,  13, 11, 9,  7,  15, 7,  12, 15, 9,  11, 7,  13, 12,
        11, 13, 6,  7,  14, 9,  13, 15, 14, 8,  13, 6,  5,  12, 7,  5,
        11, 12, 14, 15, 14, 15, 9,  8,  9,  14, 5,  6,  8,  6,  5,  12,
        9,  15, 5,  11, 6,  8,  13, 12, 5,  12, 13, 14, 11, 8,  5,  6,
    };

    // Message word selection for right rounds
    const right_r = [80]u4{
        5,  14, 7,  0, 9, 2,  11, 4,  13, 6,  15, 8,  1,  10, 3,  12,
        6,  11, 3,  7, 0, 13, 5,  10, 14, 15, 8,  12, 4,  9,  1,  2,
        15, 5,  1,  3, 7, 14, 6,  9,  11, 8,  12, 2,  10, 0,  4,  13,
        8,  6,  4,  1, 3, 11, 15, 0,  5,  12, 2,  13, 9,  7,  10, 14,
        12, 15, 10, 4, 1, 5,  8,  7,  6,  2,  13, 14, 0,  3,  9,  11,
    };

    // Rotation amounts for right rounds
    const right_s = [80]u5{
        8,  9,  9,  11, 13, 15, 15, 5,  7,  7,  8,  11, 14, 14, 12, 6,
        9,  13, 15, 7,  12, 8,  9,  11, 7,  7,  12, 7,  6,  15, 13, 11,
        9,  7,  15, 11, 8,  6,  6,  14, 12, 13, 5,  14, 13, 13, 7,  5,
        15, 5,  8,  11, 14, 14, 6,  14, 6,  9,  12, 9,  12, 5,  15, 8,
        8,  5,  12, 9,  12, 5,  14, 6,  8,  13, 6,  5,  15, 13, 11, 11,
    };
};

test "RIPEMD-160 empty string" {
    var out: [20]u8 = undefined;
    Ripemd160.hash("", &out, .{});
    const expected = [_]u8{
        0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54, 0x61, 0x28,
        0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31,
    };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "RIPEMD-160 'a'" {
    var out: [20]u8 = undefined;
    Ripemd160.hash("a", &out, .{});
    const expected = [_]u8{
        0x0b, 0xdc, 0x9d, 0x2d, 0x25, 0x6b, 0x3e, 0xe9, 0xda, 0xae,
        0x34, 0x7b, 0xe6, 0xf4, 0xdc, 0x83, 0x5a, 0x46, 0x7f, 0xfe,
    };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "RIPEMD-160 'abc'" {
    var out: [20]u8 = undefined;
    Ripemd160.hash("abc", &out, .{});
    const expected = [_]u8{
        0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04,
        0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x0b, 0xfc,
    };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "RIPEMD-160 'message digest'" {
    var out: [20]u8 = undefined;
    Ripemd160.hash("message digest", &out, .{});
    const expected = [_]u8{
        0x5d, 0x06, 0x89, 0xef, 0x49, 0xd2, 0xfa, 0xe5, 0x72, 0xb8,
        0x81, 0xb1, 0x23, 0xa8, 0x5f, 0xfa, 0x21, 0x59, 0x5f, 0x36,
    };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}
