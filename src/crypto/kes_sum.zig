const std = @import("std");
const Blake2b256 = @import("hash.zig").Blake2b256;
const Ed25519 = @import("ed25519.zig").Ed25519;

/// Haskell-aligned SumKES implementation.
/// Cardano StandardCrypto uses Sum6KES Ed25519DSIGN Blake2b_256, not CompactSumKES.
pub fn SumKES(comptime depth: u4) type {
    return struct {
        const Self = @This();
        pub const total_periods: u32 = 1 << depth;

        pub const vk_length: usize = 32;
        pub const VerKey = [vk_length]u8;
        pub const sig_length: usize = computeSigSize(depth);
        pub const Signature = [sig_length]u8;
        pub const sk_length: usize = computeSkSize(depth);
        pub const SignKey = [sk_length]u8;
        pub const seed_length: usize = 32;
        pub const Seed = [seed_length]u8;

        pub const Error = error{
            PeriodExpired,
            InvalidPeriod,
            InvalidSignature,
            KeyGenFailed,
            SignFailed,
        };

        fn computeSigSize(comptime d: u4) usize {
            if (d == 0) return Ed25519.sig_length;
            return computeSigSize(d - 1) + (vk_length * 2);
        }

        fn computeSkSize(comptime d: u4) usize {
            if (d == 0) return Ed25519.sk_length;
            return computeSkSize(d - 1) + seed_length + vk_length + vk_length;
        }

        fn expandSeed(seed: Seed) struct { left: Seed, right: Seed } {
            var buf_left: [33]u8 = undefined;
            buf_left[0] = 1;
            @memcpy(buf_left[1..33], &seed);
            const left = Blake2b256.hash(&buf_left);

            var buf_right: [33]u8 = undefined;
            buf_right[0] = 2;
            @memcpy(buf_right[1..33], &seed);
            const right = Blake2b256.hash(&buf_right);

            return .{ .left = left, .right = right };
        }

        fn hashVkPair(vk_left: []const u8, vk_right: []const u8) [32]u8 {
            var state = Blake2b256.State.init();
            state.update(vk_left);
            state.update(vk_right);
            return state.final();
        }

        fn genAtDepth(comptime d: u4, seed: Seed, sk_out: []u8, vk_out: *[32]u8) Error!void {
            if (d == 0) {
                const kp = Ed25519.keyFromSeed(seed) catch return error.KeyGenFailed;
                @memcpy(sk_out[0..Ed25519.sk_length], &kp.sk);
                @memcpy(vk_out, &kp.vk);
                return;
            }

            const seeds = expandSeed(seed);
            const inner_sk_size = computeSkSize(d - 1);

            var vk_left: [32]u8 = undefined;
            try genAtDepth(d - 1, seeds.left, sk_out[0..inner_sk_size], &vk_left);

            var temp_sk: [computeSkSize(d - 1)]u8 = undefined;
            var vk_right: [32]u8 = undefined;
            try genAtDepth(d - 1, seeds.right, &temp_sk, &vk_right);
            @memset(&temp_sk, 0);

            @memcpy(sk_out[inner_sk_size .. inner_sk_size + 32], &seeds.right);
            @memcpy(sk_out[inner_sk_size + 32 .. inner_sk_size + 64], &vk_left);
            @memcpy(sk_out[inner_sk_size + 64 .. inner_sk_size + 96], &vk_right);

            vk_out.* = hashVkPair(&vk_left, &vk_right);
        }

        fn signAtDepth(comptime d: u4, period: u32, msg: []const u8, sk: []const u8, sig_out: []u8) Error!void {
            if (d == 0) {
                const ed_sk: Ed25519.SignKey = sk[0..Ed25519.sk_length].*;
                const sig = Ed25519.sign(msg, ed_sk) catch return error.SignFailed;
                @memcpy(sig_out[0..Ed25519.sig_length], &sig);
                return;
            }

            const inner_sk_size = computeSkSize(d - 1);
            const inner_sig_size = computeSigSize(d - 1);
            const half: u32 = 1 << (d - 1);

            const inner_sk = sk[0..inner_sk_size];
            const vk_left = sk[inner_sk_size + 32 .. inner_sk_size + 64];
            const vk_right = sk[inner_sk_size + 64 .. inner_sk_size + 96];

            if (period < half) {
                try signAtDepth(d - 1, period, msg, inner_sk, sig_out[0..inner_sig_size]);
            } else {
                try signAtDepth(d - 1, period - half, msg, inner_sk, sig_out[0..inner_sig_size]);
            }
            @memcpy(sig_out[inner_sig_size .. inner_sig_size + 32], vk_left);
            @memcpy(sig_out[inner_sig_size + 32 .. inner_sig_size + 64], vk_right);
        }

        fn verifyAtDepth(comptime d: u4, vk: VerKey, period: u32, msg: []const u8, sig: []const u8) bool {
            if (d == 0) {
                const ed_sig: Ed25519.Signature = sig[0..Ed25519.sig_length].*;
                return Ed25519.verify(msg, ed_sig, vk);
            }

            const inner_sig_size = computeSigSize(d - 1);
            const half: u32 = 1 << (d - 1);
            const vk_left: VerKey = sig[inner_sig_size..][0..32].*;
            const vk_right: VerKey = sig[inner_sig_size + 32 ..][0..32].*;
            const expected_vk = hashVkPair(&vk_left, &vk_right);
            if (!std.mem.eql(u8, &expected_vk, &vk)) return false;

            if (period < half) {
                return verifyAtDepth(d - 1, vk_left, period, msg, sig[0..inner_sig_size]);
            }
            return verifyAtDepth(d - 1, vk_right, period - half, msg, sig[0..inner_sig_size]);
        }

        fn evolveAtDepth(comptime d: u4, sk: []u8, period: u32) Error!bool {
            if (d == 0) return false;

            const inner_sk_size = computeSkSize(d - 1);
            const half: u32 = 1 << (d - 1);
            const next = period + 1;

            if (next >= (1 << d)) return false;

            if (next < half) {
                return evolveAtDepth(d - 1, sk[0..inner_sk_size], period);
            } else if (next == half) {
                var right_seed: Seed = undefined;
                @memcpy(&right_seed, sk[inner_sk_size .. inner_sk_size + 32]);

                var vk_right: [32]u8 = undefined;
                try genAtDepth(d - 1, right_seed, sk[0..inner_sk_size], &vk_right);
                @memset(sk[inner_sk_size .. inner_sk_size + 32], 0);
                return true;
            } else {
                return evolveAtDepth(d - 1, sk[0..inner_sk_size], period - half);
            }
        }

        fn deriveVkAtDepth(comptime d: u4, sk: []const u8) [32]u8 {
            if (d == 0) {
                const ed_sk: Ed25519.SignKey = sk[0..Ed25519.sk_length].*;
                return Ed25519.vkFromSk(ed_sk);
            }

            const inner_sk_size = computeSkSize(d - 1);
            const vk_left = sk[inner_sk_size + 32 .. inner_sk_size + 64];
            const vk_right = sk[inner_sk_size + 64 .. inner_sk_size + 96];
            return hashVkPair(vk_left, vk_right);
        }

        pub fn generate(seed: Seed) Error!struct { sk: SignKey, vk: VerKey } {
            var sk: SignKey = undefined;
            var vk: VerKey = undefined;
            try genAtDepth(depth, seed, &sk, &vk);
            return .{ .sk = sk, .vk = vk };
        }

        pub fn sign(period: u32, msg: []const u8, sk: *const SignKey) Error!Signature {
            if (period >= total_periods) return error.InvalidPeriod;
            var sig: Signature = undefined;
            try signAtDepth(depth, period, msg, sk, &sig);
            return sig;
        }

        pub fn verify(vk: VerKey, period: u32, msg: []const u8, sig: Signature) bool {
            if (period >= total_periods) return false;
            return verifyAtDepth(depth, vk, period, msg, &sig);
        }

        pub fn evolve(sk: *SignKey, current_period: u32) Error!bool {
            return evolveAtDepth(depth, sk, current_period);
        }

        pub fn deriveVerKey(sk: *const SignKey) VerKey {
            return deriveVkAtDepth(depth, sk);
        }
    };
}

/// Cardano StandardCrypto KES: Sum6KES Ed25519DSIGN Blake2b_256.
pub const KES = SumKES(6);

test "sum kes depth 0: single period sign/verify" {
    const KES0 = SumKES(0);
    const seed = [_]u8{0xaa} ** 32;
    const kp = try KES0.generate(seed);
    const msg = "single";
    const sig = try KES0.sign(0, msg, &kp.sk);
    try std.testing.expect(KES0.verify(kp.vk, 0, msg, sig));
}

test "sum kes depth 1: two periods" {
    const KES1 = SumKES(1);
    const seed = [_]u8{0xbb} ** 32;
    var kp = try KES1.generate(seed);
    const msg = "two periods";

    const sig0 = try KES1.sign(0, msg, &kp.sk);
    try std.testing.expect(KES1.verify(kp.vk, 0, msg, sig0));

    const evolved = try KES1.evolve(&kp.sk, 0);
    try std.testing.expect(evolved);

    const sig1 = try KES1.sign(1, msg, &kp.sk);
    try std.testing.expect(KES1.verify(kp.vk, 1, msg, sig1));
}

test "sum kes depth 2: wrong period fails" {
    const KES2 = SumKES(2);
    const seed = [_]u8{0xcc} ** 32;
    const kp = try KES2.generate(seed);
    const sig = try KES2.sign(0, "period", &kp.sk);
    try std.testing.expect(!KES2.verify(kp.vk, 1, "period", sig));
}

test "sum kes depth 6: sizes match StandardCrypto" {
    try std.testing.expectEqual(@as(u32, 64), KES.total_periods);
    try std.testing.expectEqual(@as(usize, 32), KES.vk_length);
    try std.testing.expectEqual(@as(usize, 448), KES.sig_length);
    try std.testing.expectEqual(@as(usize, 640), KES.sk_length);
}
