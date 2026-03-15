const std = @import("std");
const Std = std.crypto.sign.Ed25519;

pub const Ed25519 = struct {
    pub const seed_length = 32;
    pub const vk_length = 32;
    pub const sk_length = 64; // seed[32] || pk[32] (libsodium layout)
    pub const sig_length = 64;

    pub const Seed = [seed_length]u8;
    pub const VerKey = [vk_length]u8;
    pub const SignKey = [sk_length]u8;
    pub const Signature = [sig_length]u8;

    pub const Error = error{
        KeyGenFailed,
        SignFailed,
    };

    /// Generate a keypair from a 32-byte seed. Deterministic.
    pub fn keyFromSeed(seed: Seed) Error!struct { sk: SignKey, vk: VerKey } {
        const kp = Std.KeyPair.generateDeterministic(seed) catch return error.KeyGenFailed;
        var sk: SignKey = undefined;
        @memcpy(sk[0..32], &seed);
        @memcpy(sk[32..64], &kp.public_key.bytes);
        return .{ .sk = sk, .vk = kp.public_key.bytes };
    }

    /// Sign a message. Deterministic (RFC 8032).
    pub fn sign(msg: []const u8, sk: SignKey) Error!Signature {
        const seed: Seed = sk[0..32].*;
        const kp = Std.KeyPair.generateDeterministic(seed) catch return error.SignFailed;
        const sig = kp.sign(msg, null) catch return error.SignFailed;
        return sig.toBytes();
    }

    /// Verify a signature. Returns true if valid.
    pub fn verify(msg: []const u8, sig: Signature, vk: VerKey) bool {
        const sig_obj = Std.Signature.fromBytes(sig);
        const pk = Std.PublicKey.fromBytes(vk) catch return false;
        sig_obj.verify(msg, pk) catch return false;
        return true;
    }

    /// Extract verification key from signing key.
    pub fn vkFromSk(sk: SignKey) VerKey {
        return sk[32..64].*;
    }

    /// Extract seed from signing key.
    pub fn seedFromSk(sk: SignKey) Seed {
        return sk[0..32].*;
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "ed25519: round-trip sign/verify" {
    const seed = [_]u8{0x42} ** 32;
    const kp = try Ed25519.keyFromSeed(seed);
    const msg = "Kassadin Cardano Node";
    const sig = try Ed25519.sign(msg, kp.sk);
    try std.testing.expect(Ed25519.verify(msg, sig, kp.vk));
}

test "ed25519: wrong key fails verification" {
    const seed_a = [_]u8{0x01} ** 32;
    const seed_b = [_]u8{0x02} ** 32;
    const kp_a = try Ed25519.keyFromSeed(seed_a);
    const kp_b = try Ed25519.keyFromSeed(seed_b);
    const sig = try Ed25519.sign("test", kp_a.sk);
    try std.testing.expect(!Ed25519.verify("test", sig, kp_b.vk));
}

test "ed25519: wrong message fails verification" {
    const seed = [_]u8{0xaa} ** 32;
    const kp = try Ed25519.keyFromSeed(seed);
    const sig = try Ed25519.sign("hello", kp.sk);
    try std.testing.expect(!Ed25519.verify("world", sig, kp.vk));
}

test "ed25519: seed recovery round-trip" {
    const seed = [_]u8{0x55} ** 32;
    const kp = try Ed25519.keyFromSeed(seed);
    const recovered = Ed25519.seedFromSk(kp.sk);
    try std.testing.expectEqualSlices(u8, &seed, &recovered);
}

test "ed25519: vk from sk matches keypair vk" {
    const seed = [_]u8{0x77} ** 32;
    const kp = try Ed25519.keyFromSeed(seed);
    const vk = Ed25519.vkFromSk(kp.sk);
    try std.testing.expectEqualSlices(u8, &kp.vk, &vk);
}

test "ed25519: deterministic signing" {
    const seed = [_]u8{0x33} ** 32;
    const kp = try Ed25519.keyFromSeed(seed);
    const sig1 = try Ed25519.sign("deterministic", kp.sk);
    const sig2 = try Ed25519.sign("deterministic", kp.sk);
    try std.testing.expectEqualSlices(u8, &sig1, &sig2);
}
