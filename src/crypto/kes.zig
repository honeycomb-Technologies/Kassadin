const std = @import("std");
const Blake2b256 = @import("hash.zig").Blake2b256;
const Ed25519 = @import("ed25519.zig").Ed25519;

/// CompactSumKES — Key Evolving Signature scheme.
/// Implements a forward-secure signature scheme using a binary tree composition.
/// At depth D, supports 2^D time periods. Cardano mainnet uses depth 6 (64 periods).
///
/// Based on the Haskell reference implementation in cardano-crypto-class:
///   CompactSingleKES (base case) + CompactSumKES (recursive case)
pub fn CompactSumKES(comptime depth: u4) type {
    return struct {
        const Self = @This();
        pub const total_periods: u32 = 1 << depth; // 2^depth

        pub const vk_length: usize = 32;
        pub const VerKey = [vk_length]u8;

        // Signature: at base (depth 0), it's ed25519_sig(64) + ed25519_vk(32) = 96 bytes.
        // Each recursive level adds one vk_length (32 bytes) for vk_other.
        pub const sig_length: usize = 96 + @as(usize, depth) * 32;
        pub const Signature = [sig_length]u8;

        // Sign key sizes computed recursively:
        // Base (depth 0): ed25519_seed = 32 bytes
        // Recursive (depth d): sk_inner + seed(32) + vk_left(32) + vk_right(32)
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

        fn computeSkSize(comptime d: u4) usize {
            if (d == 0) return 32; // Ed25519 seed
            return computeSkSize(d - 1) + 32 + 32 + 32; // sk_inner + seed + vk_left + vk_right
        }

        // ── Seed Expansion ──
        // Split a 32-byte seed into two using Blake2b-256 with counter prefix.
        // Matches Haskell: expandHashWith with counter bytes 1 and 2.

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

        // ── Hash a pair of verification keys ──
        // VK = Blake2b-256(vk_left ++ vk_right)

        fn hashVkPair(vk_left: []const u8, vk_right: []const u8) [32]u8 {
            var state = Blake2b256.State.init();
            state.update(vk_left);
            state.update(vk_right);
            return state.final();
        }

        // ── Recursive operations parameterized by depth ──

        fn genAtDepth(comptime d: u4, seed: Seed, sk_out: []u8, vk_out: *[32]u8) Error!void {
            if (d == 0) {
                // Base case: Ed25519 keypair from seed
                const kp = Ed25519.keyFromSeed(seed) catch return error.KeyGenFailed;
                @memcpy(sk_out[0..32], &seed);
                @memcpy(vk_out, &kp.vk);
                return;
            }

            // Recursive: expand seed, generate left and right subtrees
            const seeds = expandSeed(seed);
            const inner_sk_size = computeSkSize(d - 1);

            // Generate left subtree
            var vk_left: [32]u8 = undefined;
            try genAtDepth(d - 1, seeds.left, sk_out[0..inner_sk_size], &vk_left);

            // Store right seed (for lazy generation), vk_left, and vk_right
            // We need vk_right, so generate temporarily
            var temp_sk: [computeSkSize(d - 1)]u8 = undefined;
            var vk_right: [32]u8 = undefined;
            try genAtDepth(d - 1, seeds.right, &temp_sk, &vk_right);
            // Zero out temp (forward security)
            @memset(&temp_sk, 0);

            // Layout: [inner_sk | right_seed | vk_left | vk_right]
            @memcpy(sk_out[inner_sk_size .. inner_sk_size + 32], &seeds.right);
            @memcpy(sk_out[inner_sk_size + 32 .. inner_sk_size + 64], &vk_left);
            @memcpy(sk_out[inner_sk_size + 64 .. inner_sk_size + 96], &vk_right);

            // VK = hash(vk_left ++ vk_right)
            vk_out.* = hashVkPair(&vk_left, &vk_right);
        }

        fn signAtDepth(comptime d: u4, period: u32, msg: []const u8, sk: []const u8, sig_out: []u8) Error!void {
            if (d == 0) {
                // Base case: Ed25519 sign, output = ed25519_sig(64) ++ ed25519_vk(32)
                const seed: Ed25519.Seed = sk[0..32].*;
                const kp = Ed25519.keyFromSeed(seed) catch return error.SignFailed;
                const ed_sig = Ed25519.sign(msg, kp.sk) catch return error.SignFailed;
                @memcpy(sig_out[0..64], &ed_sig);
                @memcpy(sig_out[64..96], &kp.vk);
                return;
            }

            const inner_sk_size = computeSkSize(d - 1);
            const inner_sig_size = 96 + @as(usize, d - 1) * 32;
            const half: u32 = 1 << (d - 1);

            const inner_sk = sk[0..inner_sk_size];
            const vk_left = sk[inner_sk_size + 32 .. inner_sk_size + 64];
            const vk_right = sk[inner_sk_size + 64 .. inner_sk_size + 96];

            if (period < half) {
                // Sign with left subtree, attach right vk
                try signAtDepth(d - 1, period, msg, inner_sk, sig_out[0..inner_sig_size]);
                @memcpy(sig_out[inner_sig_size .. inner_sig_size + 32], vk_right);
            } else {
                // Sign with right subtree (which is now in inner_sk position after evolution), attach left vk
                try signAtDepth(d - 1, period - half, msg, inner_sk, sig_out[0..inner_sig_size]);
                @memcpy(sig_out[inner_sig_size .. inner_sig_size + 32], vk_left);
            }
        }

        /// Extract the embedded verification key from a signature at a given period.
        fn vkFromSigAtDepth(comptime d: u4, period: u32, sig: []const u8) [32]u8 {
            if (d == 0) {
                // Base case: vk is embedded in sig at bytes 64..96
                return sig[64..96].*;
            }

            const inner_sig_size = 96 + @as(usize, d - 1) * 32;
            const half: u32 = 1 << (d - 1);
            const vk_other = sig[inner_sig_size .. inner_sig_size + 32];

            if (period < half) {
                const inner_vk = vkFromSigAtDepth(d - 1, period, sig[0..inner_sig_size]);
                return hashVkPair(&inner_vk, vk_other);
            } else {
                const inner_vk = vkFromSigAtDepth(d - 1, period - half, sig[0..inner_sig_size]);
                return hashVkPair(vk_other, &inner_vk);
            }
        }

        fn verifySigAtDepth(comptime d: u4, period: u32, msg: []const u8, sig: []const u8) bool {
            if (d == 0) {
                // Base case: verify Ed25519 sig against embedded vk
                const ed_sig: Ed25519.Signature = sig[0..64].*;
                const ed_vk: Ed25519.VerKey = sig[64..96].*;
                return Ed25519.verify(msg, ed_sig, ed_vk);
            }

            const inner_sig_size = 96 + @as(usize, d - 1) * 32;
            const half: u32 = 1 << (d - 1);

            if (period < half) {
                return verifySigAtDepth(d - 1, period, msg, sig[0..inner_sig_size]);
            } else {
                return verifySigAtDepth(d - 1, period - half, msg, sig[0..inner_sig_size]);
            }
        }

        fn evolveAtDepth(comptime d: u4, sk: []u8, period: u32) Error!bool {
            if (d == 0) {
                // Base case: single period, cannot evolve
                return false;
            }

            const inner_sk_size = computeSkSize(d - 1);
            const half: u32 = 1 << (d - 1);
            const next = period + 1;

            if (next >= (1 << d)) {
                // At max period
                return false;
            }

            if (next < half) {
                // Still in left subtree, evolve inner key
                return evolveAtDepth(d - 1, sk[0..inner_sk_size], period);
            } else if (next == half) {
                // Transition: regenerate right subtree from stored seed, swap it in
                var right_seed: Seed = undefined;
                @memcpy(&right_seed, sk[inner_sk_size .. inner_sk_size + 32]);

                // Generate right subtree key
                var vk_right: [32]u8 = undefined;
                try genAtDepth(d - 1, right_seed, sk[0..inner_sk_size], &vk_right);

                // Zero out the right seed (forward security!)
                @memset(sk[inner_sk_size .. inner_sk_size + 32], 0);

                return true;
            } else {
                // In right subtree, evolve inner key
                return evolveAtDepth(d - 1, sk[0..inner_sk_size], period - half);
            }
        }

        // ── Public API ──

        /// Generate a KES keypair from a 32-byte seed. Deterministic.
        pub fn generate(seed: Seed) Error!struct { sk: SignKey, vk: VerKey } {
            var sk: SignKey = undefined;
            var vk: VerKey = undefined;
            try genAtDepth(depth, seed, &sk, &vk);
            return .{ .sk = sk, .vk = vk };
        }

        /// Sign a message at a given KES period.
        pub fn sign(period: u32, msg: []const u8, sk: *const SignKey) Error!Signature {
            if (period >= total_periods) return error.InvalidPeriod;
            var sig: Signature = undefined;
            try signAtDepth(depth, period, msg, sk, &sig);
            return sig;
        }

        /// Verify a KES signature for a given period and verification key.
        pub fn verify(vk: VerKey, period: u32, msg: []const u8, sig: Signature) bool {
            if (period >= total_periods) return false;

            // Step 1: verify the inner Ed25519 signature
            if (!verifySigAtDepth(depth, period, msg, &sig)) return false;

            // Step 2: reconstruct VK from signature and compare
            const reconstructed = vkFromSigAtDepth(depth, period, &sig);
            return std.mem.eql(u8, &reconstructed, &vk);
        }

        /// Evolve the signing key to the next period. Returns true on success,
        /// false if already at max period.
        pub fn evolve(sk: *SignKey, current_period: u32) Error!bool {
            return evolveAtDepth(depth, sk, current_period);
        }

        /// Derive the verification key from a signing key.
        pub fn deriveVerKey(sk: *const SignKey) VerKey {
            return deriveVkAtDepth(depth, sk);
        }

        fn deriveVkAtDepth(comptime d: u4, sk: []const u8) [32]u8 {
            if (d == 0) {
                const seed: Ed25519.Seed = sk[0..32].*;
                const kp = Ed25519.keyFromSeed(seed) catch unreachable;
                return kp.vk;
            }
            const inner_sk_size = computeSkSize(d - 1);
            const vk_left = sk[inner_sk_size + 32 .. inner_sk_size + 64];
            const vk_right = sk[inner_sk_size + 64 .. inner_sk_size + 96];
            return hashVkPair(vk_left, vk_right);
        }
    };
}

/// Cardano mainnet KES: CompactSumKES depth 6 (64 periods).
pub const KES = CompactSumKES(6);

// ──────────────────────────────────── Tests ────────────────────────────────────

// Test with small depths first for sanity, then full depth 6.

test "kes depth 0: single period sign/verify" {
    const KES0 = CompactSumKES(0);
    const seed = [_]u8{0x42} ** 32;
    const kp = try KES0.generate(seed);

    const msg = "hello kes";
    const sig = try KES0.sign(0, msg, &kp.sk);
    try std.testing.expect(KES0.verify(kp.vk, 0, msg, sig));
}

test "kes depth 0: cannot evolve" {
    const KES0 = CompactSumKES(0);
    const seed = [_]u8{0x42} ** 32;
    var kp = try KES0.generate(seed);
    const can_evolve = try KES0.evolve(&kp.sk, 0);
    try std.testing.expect(!can_evolve);
}

test "kes depth 1: two periods" {
    const KES1 = CompactSumKES(1);
    const seed = [_]u8{0xaa} ** 32;
    var kp = try KES1.generate(seed);
    const msg = "depth 1 test";

    // Period 0
    const sig0 = try KES1.sign(0, msg, &kp.sk);
    try std.testing.expect(KES1.verify(kp.vk, 0, msg, sig0));

    // Evolve to period 1
    const evolved = try KES1.evolve(&kp.sk, 0);
    try std.testing.expect(evolved);

    // Period 1
    const sig1 = try KES1.sign(1, msg, &kp.sk);
    try std.testing.expect(KES1.verify(kp.vk, 1, msg, sig1));

    // Cannot evolve further
    const evolved2 = try KES1.evolve(&kp.sk, 1);
    try std.testing.expect(!evolved2);
}

test "kes depth 1: wrong period fails" {
    const KES1 = CompactSumKES(1);
    const seed = [_]u8{0xbb} ** 32;
    const kp = try KES1.generate(seed);
    const msg = "wrong period";

    const sig0 = try KES1.sign(0, msg, &kp.sk);
    // Verify at period 1 with period 0's signature should fail
    try std.testing.expect(!KES1.verify(kp.vk, 1, msg, sig0));
}

test "kes depth 2: four periods" {
    const KES2 = CompactSumKES(2);
    const seed = [_]u8{0xcc} ** 32;
    var kp = try KES2.generate(seed);
    const original_vk = kp.vk;
    const msg = "four periods";

    var period: u32 = 0;
    while (period < 4) : (period += 1) {
        // Sign at current period
        const sig = try KES2.sign(period, msg, &kp.sk);
        try std.testing.expect(KES2.verify(kp.vk, period, msg, sig));

        // VK should remain constant
        const derived_vk = KES2.deriveVerKey(&kp.sk);
        try std.testing.expectEqualSlices(u8, &original_vk, &derived_vk);

        // Evolve (except at last period)
        if (period < 3) {
            const evolved = try KES2.evolve(&kp.sk, period);
            try std.testing.expect(evolved);
        }
    }
}

test "kes depth 6: generate and sign at period 0" {
    const seed = [_]u8{0xdd} ** 32;
    const kp = try KES.generate(seed);

    try std.testing.expectEqual(@as(u32, 64), KES.total_periods);
    try std.testing.expectEqual(@as(usize, 288), KES.sig_length);

    const msg = "kassadin mainnet kes";
    const sig = try KES.sign(0, msg, &kp.sk);
    try std.testing.expect(KES.verify(kp.vk, 0, msg, sig));
}

test "kes depth 6: wrong message fails" {
    const seed = [_]u8{0xee} ** 32;
    const kp = try KES.generate(seed);

    const sig = try KES.sign(0, "correct", &kp.sk);
    try std.testing.expect(!KES.verify(kp.vk, 0, "wrong", sig));
}

test "kes depth 6: evolve first 4 periods" {
    const seed = [_]u8{0xff} ** 32;
    var kp = try KES.generate(seed);
    const original_vk = kp.vk;
    const msg = "evolve test";

    var period: u32 = 0;
    while (period < 4) : (period += 1) {
        const sig = try KES.sign(period, msg, &kp.sk);
        try std.testing.expect(KES.verify(kp.vk, period, msg, sig));

        // VK constant
        try std.testing.expectEqualSlices(u8, &original_vk, &KES.deriveVerKey(&kp.sk));

        if (period < 3) {
            _ = try KES.evolve(&kp.sk, period);
        }
    }
}

test "kes depth 6: forward security" {
    const KES3 = CompactSumKES(3); // depth 3 = 8 periods, faster to test
    const seed = [_]u8{0x11} ** 32;
    var kp = try KES3.generate(seed);
    const msg = "forward secure";

    // Sign at period 0
    const sig0 = try KES3.sign(0, msg, &kp.sk);
    try std.testing.expect(KES3.verify(kp.vk, 0, msg, sig0));

    // Evolve to period 1
    _ = try KES3.evolve(&kp.sk, 0);

    // Old signature at period 0 should still verify (it's the signature that's forward-secure,
    // not that old sigs become invalid — forward security means you can't CREATE new period-0
    // sigs with the evolved key)
    try std.testing.expect(KES3.verify(kp.vk, 0, msg, sig0));

    // Sign at period 1 works
    const sig1 = try KES3.sign(1, msg, &kp.sk);
    try std.testing.expect(KES3.verify(kp.vk, 1, msg, sig1));
}

test "kes: deterministic generation" {
    const seed = [_]u8{0x99} ** 32;
    const kp1 = try KES.generate(seed);
    const kp2 = try KES.generate(seed);
    try std.testing.expectEqualSlices(u8, &kp1.vk, &kp2.vk);
    try std.testing.expectEqualSlices(u8, &kp1.sk, &kp2.sk);
}

test "kes: type sizes" {
    try std.testing.expectEqual(@as(u32, 64), KES.total_periods);
    try std.testing.expectEqual(@as(usize, 32), KES.vk_length);
    try std.testing.expectEqual(@as(usize, 288), KES.sig_length);
    // SK: base=32, each level adds 96, so 32 + 6*96 = 608
    try std.testing.expectEqual(@as(usize, 608), KES.sk_length);
}

// ── Golden test vectors from input-output-hk/kes (Rust) and cardano-base (Haskell) ──
// Seed: "test string of 32 byte of lenght" (deliberate misspelling)
// Message: "test message"
// These vectors are byte-identical between the Haskell and Rust KES implementations.

fn hexToBytes(comptime len: usize, hex: *const [len * 2]u8) [len]u8 {
    var result: [len]u8 = undefined;
    for (0..len) |i| {
        result[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return result;
}

test "kes golden: depth 6 SK layout matches Rust compactkey6.bin" {
    // Seed = "test string of 32 byte of lenght" (deliberate misspelling, matches Rust/Haskell test)
    const seed: [32]u8 = "test string of 32 byte of lenght".*;
    const kp = try KES.generate(seed);

    // Verify the full SK layout from compactkey6.bin (608 bytes):
    // Layout: [depth5_inner_sk(512) | right_seed(32) | vk_left(32) | vk_right(32)]

    // First 32 bytes: deepest-left Ed25519 seed (6 levels of left seed expansion)
    try std.testing.expectEqualSlices(u8,
        &hexToBytes(32, "3b6ba22c41839fc27fdf4e42ae9c75c0bb7f2f41ef69003692b3203b6b678598"),
        kp.sk[0..32]);

    // Depth-1 level: vk_left = Ed25519 VK of the deepest-left leaf
    try std.testing.expectEqualSlices(u8,
        &hexToBytes(32, "1bf4bacb1be6ac5ff6a2ba1f9a3a8332425e09c2018b9da013c9b46ae1a4b690"),
        kp.sk[64..96]);

    // Bytes 512-543: top-level right seed
    try std.testing.expectEqualSlices(u8,
        &hexToBytes(32, "e78d6e26974a438f1376e3339d92f4e7e54944fa9e6e4f3f8c9b7ed1b46bbed1"),
        kp.sk[512..544]);

    // Bytes 544-575: top-level vk_left (= VK of entire depth-5 left subtree)
    try std.testing.expectEqualSlices(u8,
        &hexToBytes(32, "0b318353c6c6ffc2b27907bb5118f52d9b6031e4f6e69d62d208553e35c099a9"),
        kp.sk[544..576]);

    // Bytes 576-607: top-level vk_right (= VK of entire depth-5 right subtree)
    try std.testing.expectEqualSlices(u8,
        &hexToBytes(32, "4c1665a7ebaccd3378175bc5490d9d5b414d66f1565909492ed415cbf6d7a35e"),
        kp.sk[576..608]);

    // VK = Blake2b-256(vk_left || vk_right) — this is what gets published
    const expected_vk = Blake2b256.hash(kp.sk[544..576] ++ kp.sk[576..608]);
    try std.testing.expectEqualSlices(u8, &expected_vk, &kp.vk);
}

test "kes golden: depth 6 full SK byte-exact match with Rust compactkey6.bin" {
    // Complete 608-byte SK from compactkey6.bin — byte-exact comparison
    const expected_sk = hexToBytes(608,
        "3b6ba22c41839fc27fdf4e42ae9c75c0bb7f2f41ef69003692b3203b6b678598" ++
        "ba07fad4876a7094e1f081051040da432fd22cababd3ebf77332fb25b624f973" ++
        "1bf4bacb1be6ac5ff6a2ba1f9a3a8332425e09c2018b9da013c9b46ae1a4b690" ++
        "f9324acf6b44db26de96dd82e258a0b19f812a1813284955e63fdbb4c8ecf971" ++
        "8af95e8b0da95d172e749ead8dc4828fc5607723f3e7611762d46f8723555920" ++
        "a0448a6a090bbf65c1052e3995b5ee749626ab5a2484f7d767e75e2da828af97" ++
        "e326e7889f40372c9bf7c422ce4f039de181e5354d26abbd82c8cae63e66ed43" ++
        "473c46e066829bb6c19c956d83c4ef1a1d83949b39d16e28523030eb1b1adfcf" ++
        "68c6febced18af77a204d79b570bc425f9f3b1f68c369f8270a9ce97ab124e6e" ++
        "1ce29b709e4e4512a9db6bb7f8517c7c4c9b3aa0cbb516a128213b53c237172c" ++
        "0abc61518b7113d686520c4c3216a273f6f2a1b0bb653cc96478e74db520a058" ++
        "ef212dd8e22cfa42d3a6048250603c7f743d15886fb60ff22407a37b1a66311c" ++
        "97480108d12e8c8c278afcb368e61a57df16e94594246f9f3edbc4c4461ac662" ++
        "095ed01b1c3bdcf5b17055e8939283aad504f63ec0b6c29b4e7c5864df47815a" ++
        "dfce87cddaeda4f313f5b91fe4e8dc13fb889d42bf04ca64cbeca3e5e71ab683" ++
        "41f2ea1e2f71a5bffd9756aefc230f1aad4381072bac475611ff3d64f9a6cfb5" ++
        "e78d6e26974a438f1376e3339d92f4e7e54944fa9e6e4f3f8c9b7ed1b46bbed1" ++
        "0b318353c6c6ffc2b27907bb5118f52d9b6031e4f6e69d62d208553e35c099a9" ++
        "4c1665a7ebaccd3378175bc5490d9d5b414d66f1565909492ed415cbf6d7a35e",
    );

    const seed: [32]u8 = "test string of 32 byte of lenght".*;
    const kp = try KES.generate(seed);
    try std.testing.expectEqualSlices(u8, &expected_sk, &kp.sk);
}

test "kes golden: depth 6 signature at period 0 matches Rust golden file" {
    // compactkey6Sig.bin — signature of "test message" at period 0
    const expected_sig = hexToBytes(288,
        "bfc5aacd9410f03b877630578c1779db6388fa1441553408f2bc7347ffdd9885" ++
        "f512e10b92a735935dd9fc631f2a598009770eab72a6926aea089ab6e8a11d07" ++
        "1bf4bacb1be6ac5ff6a2ba1f9a3a8332425e09c2018b9da013c9b46ae1a4b690" ++
        "f9324acf6b44db26de96dd82e258a0b19f812a1813284955e63fdbb4c8ecf971" ++
        "e326e7889f40372c9bf7c422ce4f039de181e5354d26abbd82c8cae63e66ed43" ++
        "1ce29b709e4e4512a9db6bb7f8517c7c4c9b3aa0cbb516a128213b53c237172c" ++
        "97480108d12e8c8c278afcb368e61a57df16e94594246f9f3edbc4c4461ac662" ++
        "41f2ea1e2f71a5bffd9756aefc230f1aad4381072bac475611ff3d64f9a6cfb5" ++
        "4c1665a7ebaccd3378175bc5490d9d5b414d66f1565909492ed415cbf6d7a35e",
    );

    const seed: [32]u8 = "test string of 32 byte of lenght".*;
    const kp = try KES.generate(seed);
    const sig = try KES.sign(0, "test message", &kp.sk);
    try std.testing.expectEqualSlices(u8, &expected_sig, &sig);

    // Also verify it
    try std.testing.expect(KES.verify(kp.vk, 0, "test message", sig));
}

test "kes golden: depth 6 signature at period 5 matches Rust golden file" {
    // compactkey6Sig5.bin — signature of "test message" at period 5
    const expected_sig = hexToBytes(288,
        "b639087e56dbdfcae8ebda18dabd7775987439b96e694282656d95ccd9c31211" ++
        "d6eccbcba0124ee6989c92ba4f42b527b3b30926db49fdfdbc9a740058b9b703" ++
        "2f02a20af2b53a534eb90a6c939d22be18f72190100d8cad89d1959cef516e71" ++
        "a883cc98300eedfe34f2ba1fb4469cd17a583148d88966c912c3688664c4763d" ++
        "ea3d8ad90313fa5749b566f8787552b970bbe9d98d4870839fbe681b68fd1d9c" ++
        "68c6febced18af77a204d79b570bc425f9f3b1f68c369f8270a9ce97ab124e6e" ++
        "97480108d12e8c8c278afcb368e61a57df16e94594246f9f3edbc4c4461ac662" ++
        "41f2ea1e2f71a5bffd9756aefc230f1aad4381072bac475611ff3d64f9a6cfb5" ++
        "4c1665a7ebaccd3378175bc5490d9d5b414d66f1565909492ed415cbf6d7a35e",
    );

    const seed: [32]u8 = "test string of 32 byte of lenght".*;
    var kp = try KES.generate(seed);

    // Evolve from period 0 to period 5
    var period: u32 = 0;
    while (period < 5) : (period += 1) {
        _ = try KES.evolve(&kp.sk, period);
    }

    const sig = try KES.sign(5, "test message", &kp.sk);
    try std.testing.expectEqualSlices(u8, &expected_sig, &sig);
    try std.testing.expect(KES.verify(kp.vk, 5, "test message", sig));
}

test "kes golden: depth 6 SK after 1 evolution matches Rust golden file" {
    // compactkey6update1.bin — SK at period 1 (after one evolution)
    // Key difference: second 32 bytes should be zeroed (right seed consumed)
    const seed: [32]u8 = "test string of 32 byte of lenght".*;
    var kp = try KES.generate(seed);
    _ = try KES.evolve(&kp.sk, 0);

    // After evolving, the second 32 bytes of SK (the innermost right seed) should be zeroed
    const expected_sk_32_64 = hexToBytes(32, "0000000000000000000000000000000000000000000000000000000000000000");
    try std.testing.expectEqualSlices(u8, &expected_sk_32_64, kp.sk[32..64]);

    // First 32 bytes should be the right-side leaf seed
    const expected_sk_0_32 = hexToBytes(32, "ba07fad4876a7094e1f081051040da432fd22cababd3ebf77332fb25b624f973");
    try std.testing.expectEqualSlices(u8, &expected_sk_0_32, kp.sk[0..32]);
}
