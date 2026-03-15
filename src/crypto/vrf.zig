const std = @import("std");

/// VRF (Verifiable Random Function) using ECVRF-ED25519-SHA512-Elligator2.
///
/// Requires the IOHK fork of libsodium which includes crypto_vrf_ietfdraft03_*.
/// If the fork is not available, all operations return error.VrfNotAvailable.
pub const VRF = struct {
    pub const seed_length = 32;
    pub const vk_length = 32;
    pub const sk_length = 64;
    pub const proof_length = 80;
    pub const output_length = 64;

    pub const Seed = [seed_length]u8;
    pub const VerKey = [vk_length]u8;
    pub const SignKey = [sk_length]u8;
    pub const Proof = [proof_length]u8;
    pub const Output = [output_length]u8;

    pub const Error = error{
        VrfNotAvailable,
        VrfKeypairFailed,
        VrfProveFailed,
        VrfVerifyFailed,
        VrfHashFailed,
    };

    // C FFI declarations — these symbols only exist in the IOHK libsodium fork.
    // If linking against vanilla libsodium, they will be undefined.
    const c = struct {
        extern "c" fn crypto_vrf_ietfdraft03_keypair_from_seed(
            pk: *[vk_length]u8,
            sk: *[sk_length]u8,
            seed: *const [seed_length]u8,
        ) c_int;

        extern "c" fn crypto_vrf_ietfdraft03_prove(
            proof: *[proof_length]u8,
            sk: *const [sk_length]u8,
            msg: [*]const u8,
            msg_len: c_ulonglong,
        ) c_int;

        extern "c" fn crypto_vrf_ietfdraft03_verify(
            output: *[output_length]u8,
            pk: *const [vk_length]u8,
            proof: *const [proof_length]u8,
            msg: [*]const u8,
            msg_len: c_ulonglong,
        ) c_int;

        extern "c" fn crypto_vrf_ietfdraft03_proof_to_hash(
            hash: *[output_length]u8,
            proof: *const [proof_length]u8,
        ) c_int;

        extern "c" fn crypto_vrf_ietfdraft03_sk_to_pk(
            pk: *[vk_length]u8,
            sk: *const [sk_length]u8,
        ) c_int;
    };

    /// Whether VRF is available (IOHK libsodium fork is linked).
    /// Detected at runtime by attempting a no-op call.
    pub fn isAvailable() bool {
        // If the symbols are resolved, we can use VRF.
        // This is a compile-time check via weak linkage fallback.
        // For now, we try to detect at comptime whether the extern is resolvable.
        // In practice, if the IOHK fork is not linked, calling any function
        // will cause a linker error at build time. So we use a build flag approach.
        return vrf_enabled;
    }

    // Build-time feature flag. Set to true when IOHK libsodium is available.
    const vrf_enabled = false;

    /// Generate keypair from seed.
    pub fn keyFromSeed(seed: Seed) Error!struct { sk: SignKey, vk: VerKey } {
        if (!vrf_enabled) return error.VrfNotAvailable;
        var pk: VerKey = undefined;
        var sk: SignKey = undefined;
        if (c.crypto_vrf_ietfdraft03_keypair_from_seed(&pk, &sk, &seed) != 0) {
            return error.VrfKeypairFailed;
        }
        return .{ .sk = sk, .vk = pk };
    }

    /// Create a VRF proof and output for a message.
    pub fn prove(msg: []const u8, sk: SignKey) Error!struct { proof: Proof, output: Output } {
        if (!vrf_enabled) return error.VrfNotAvailable;
        var proof: Proof = undefined;
        if (c.crypto_vrf_ietfdraft03_prove(&proof, &sk, msg.ptr, @intCast(msg.len)) != 0) {
            return error.VrfProveFailed;
        }
        const output = try proofToHash(proof);
        return .{ .proof = proof, .output = output };
    }

    /// Verify a VRF proof. Returns output on success, null on failure.
    pub fn verifyProof(msg: []const u8, vk: VerKey, proof: Proof) ?Output {
        if (!vrf_enabled) return null;
        var output: Output = undefined;
        if (c.crypto_vrf_ietfdraft03_verify(&output, &vk, &proof, msg.ptr, @intCast(msg.len)) != 0) {
            return null;
        }
        return output;
    }

    /// Convert a proof directly to its hash output.
    pub fn proofToHash(proof: Proof) Error!Output {
        if (!vrf_enabled) return error.VrfNotAvailable;
        var output: Output = undefined;
        if (c.crypto_vrf_ietfdraft03_proof_to_hash(&output, &proof) != 0) {
            return error.VrfHashFailed;
        }
        return output;
    }

    /// Extract verification key from signing key.
    pub fn vkFromSk(sk: SignKey) Error!VerKey {
        if (!vrf_enabled) return error.VrfNotAvailable;
        var pk: VerKey = undefined;
        if (c.crypto_vrf_ietfdraft03_sk_to_pk(&pk, &sk) != 0) {
            return error.VrfKeypairFailed;
        }
        return pk;
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "vrf: availability check" {
    // VRF is currently disabled until IOHK libsodium fork is linked.
    // This test verifies the stub returns the expected error.
    if (!VRF.isAvailable()) {
        const result = VRF.keyFromSeed([_]u8{0} ** 32);
        try std.testing.expectError(error.VrfNotAvailable, result);
    }
}

test "vrf: type sizes" {
    try std.testing.expectEqual(@as(usize, 32), VRF.seed_length);
    try std.testing.expectEqual(@as(usize, 32), VRF.vk_length);
    try std.testing.expectEqual(@as(usize, 64), VRF.sk_length);
    try std.testing.expectEqual(@as(usize, 80), VRF.proof_length);
    try std.testing.expectEqual(@as(usize, 64), VRF.output_length);
}
