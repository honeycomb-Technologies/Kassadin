const std = @import("std");

/// VRF (Verifiable Random Function) using ECVRF-ED25519-SHA512-Elligator2.
///
/// This follows the Haskell node's non-batchcompat Praos verification path.
/// Current chain headers serialize 80-byte proofs, not the legacy 128-byte
/// batchcompat form. For follower-side verification we accept either 80-byte
/// standard proof variant (`ietfdraft03` or `ietfdraft13`) if it verifies
/// cleanly, which keeps early/live chain interop tolerant while still rejecting
/// invalid proofs.
///
/// The C code includes Cardano's Elligator2 handling, so the proofs are not
/// compatible with naive off-the-shelf IETF implementations.
///
/// Test vectors are sourced from cardano-crypto-praos/test_vectors/vrf_ver03_*.
pub const VRF = struct {
    pub const seed_length = 32;
    pub const vk_length = 32;
    pub const sk_length = 64; // seed(32) + pk(32)
    pub const proof_length = 80;
    pub const output_length = 64;

    pub const Seed = [seed_length]u8;
    pub const VerKey = [vk_length]u8;
    pub const SignKey = [sk_length]u8;
    pub const Proof = [proof_length]u8;
    pub const Output = [output_length]u8;

    pub const Error = error{
        VrfKeypairFailed,
        VrfProveFailed,
        VrfVerifyFailed,
        VrfHashFailed,
    };

    // C FFI to the vendored cardano-crypto-praos cbits.
    // This matches the Haskell node's `Cardano.Crypto.VRF.Praos` bindings.
    const c = struct {
        extern "c" fn crypto_vrf_ietfdraft03_keypair_from_seed(
            pk: *[vk_length]u8,
            skpk: *[sk_length]u8,
            seed: *const [seed_length]u8,
        ) c_int;

        extern "c" fn crypto_vrf_ietfdraft03_prove(
            proof: *[proof_length]u8,
            skpk: *const [sk_length]u8,
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

        extern "c" fn crypto_vrf_ietfdraft13_verify(
            output: *[output_length]u8,
            pk: *const [vk_length]u8,
            proof: *const [proof_length]u8,
            msg: [*]const u8,
            msg_len: c_ulonglong,
        ) c_int;

        extern "c" fn crypto_vrf_sk_to_pk(
            pk: *[vk_length]u8,
            skpk: *const [sk_length]u8,
        ) void;

        extern "c" fn crypto_vrf_sk_to_seed(
            seed: *[seed_length]u8,
            skpk: *const [sk_length]u8,
        ) void;
    };

    /// Generate keypair from a 32-byte seed. Deterministic.
    pub fn keyFromSeed(seed: Seed) Error!struct { sk: SignKey, vk: VerKey } {
        var pk: VerKey = undefined;
        var sk: SignKey = undefined;
        if (c.crypto_vrf_ietfdraft03_keypair_from_seed(&pk, &sk, &seed) != 0) {
            return error.VrfKeypairFailed;
        }
        return .{ .sk = sk, .vk = pk };
    }

    /// Create a VRF proof for a message.
    pub fn prove(msg: []const u8, sk: SignKey) Error!struct { proof: Proof, output: Output } {
        var proof: Proof = undefined;
        const msg_ptr: [*]const u8 = if (msg.len > 0) msg.ptr else @as([*]const u8, &[_]u8{0});
        if (c.crypto_vrf_ietfdraft03_prove(&proof, &sk, msg_ptr, @intCast(msg.len)) != 0) {
            return error.VrfProveFailed;
        }
        const output = try proofToHash(proof);
        return .{ .proof = proof, .output = output };
    }

    pub fn verifyProofDraft03(msg: []const u8, vk: VerKey, proof: Proof) ?Output {
        var output: Output = undefined;
        const msg_ptr: [*]const u8 = if (msg.len > 0) msg.ptr else @as([*]const u8, &[_]u8{0});
        if (c.crypto_vrf_ietfdraft03_verify(&output, &vk, &proof, msg_ptr, @intCast(msg.len)) != 0) {
            return null;
        }
        return output;
    }

    pub fn verifyProofDraft13(msg: []const u8, vk: VerKey, proof: Proof) ?Output {
        var output: Output = undefined;
        const msg_ptr: [*]const u8 = if (msg.len > 0) msg.ptr else @as([*]const u8, &[_]u8{0});
        if (c.crypto_vrf_ietfdraft13_verify(&output, &vk, &proof, msg_ptr, @intCast(msg.len)) != 0) {
            return null;
        }
        return output;
    }

    /// Verify a VRF proof. Returns output on success, null on failure.
    pub fn verifyProof(msg: []const u8, vk: VerKey, proof: Proof) ?Output {
        return verifyProofDraft03(msg, vk, proof) orelse verifyProofDraft13(msg, vk, proof);
    }

    /// Convert a proof directly to its hash output (without verification).
    pub fn proofToHash(proof: Proof) Error!Output {
        var output: Output = undefined;
        if (c.crypto_vrf_ietfdraft03_proof_to_hash(&output, &proof) != 0) {
            return error.VrfHashFailed;
        }
        return output;
    }

    /// Extract verification key from signing key.
    pub fn vkFromSk(sk: SignKey) VerKey {
        var pk: VerKey = undefined;
        c.crypto_vrf_sk_to_pk(&pk, &sk);
        return pk;
    }

    /// Extract seed from signing key.
    pub fn seedFromSk(sk: SignKey) Seed {
        var seed: Seed = undefined;
        c.crypto_vrf_sk_to_seed(&seed, &sk);
        return seed;
    }
};

// ── Hex parsing helper ──

fn hexToBytes(comptime len: usize, hex: *const [len * 2]u8) [len]u8 {
    var result: [len]u8 = undefined;
    for (0..len) |i| {
        result[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return result;
}

// ──────────────────────────────────── Tests ────────────────────────────────────
// All test vectors from cardano-crypto-praos/test_vectors/vrf_ver03_*
// These are PraosVRF (ietfdraft03) — the variant used by StandardCrypto.
// Each test validates: key derivation, proof generation, output, and verification.

test "vrf: type sizes" {
    try std.testing.expectEqual(@as(usize, 32), VRF.seed_length);
    try std.testing.expectEqual(@as(usize, 32), VRF.vk_length);
    try std.testing.expectEqual(@as(usize, 64), VRF.sk_length);
    try std.testing.expectEqual(@as(usize, 80), VRF.proof_length);
    try std.testing.expectEqual(@as(usize, 64), VRF.output_length);
}

// vrf_ver03_standard_10: empty message
test "vrf: draft-03 standard vector 10 — empty message" {
    const seed = hexToBytes(32, "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const expected_pk = hexToBytes(32, "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    const expected_proof = hexToBytes(80, "b6b4699f87d56126c9117a7da55bd0085246f4c56dbc95d20172612e9d38e8d7ca65e573a126ed88d4e30a46f80a666854d675cf3ba81de0de043c3774f061560f55edc256a787afe701677c0f602900");
    const expected_beta = hexToBytes(64, "5b49b554d05c0cd5a5325376b3387de59d924fd1e13ded44648ab33c21349a603f25b84ec5ed887995b33da5e3bfcb87cd2f64521c4c62cf825cffabbe5d31cc");

    const kp = try VRF.keyFromSeed(seed);
    try std.testing.expectEqualSlices(u8, &expected_pk, &kp.vk);

    const result = try VRF.prove(&[_]u8{}, kp.sk);
    try std.testing.expectEqualSlices(u8, &expected_proof, &result.proof);
    try std.testing.expectEqualSlices(u8, &expected_beta, &result.output);

    const verified = VRF.verifyProof(&[_]u8{}, kp.vk, result.proof);
    try std.testing.expect(verified != null);
    try std.testing.expectEqualSlices(u8, &expected_beta, &verified.?);

    const hash = try VRF.proofToHash(result.proof);
    try std.testing.expectEqualSlices(u8, &expected_beta, &hash);
}

// vrf_ver03_standard_11: message = 0x72
test "vrf: draft-03 standard vector 11 — single byte" {
    const seed = hexToBytes(32, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
    const expected_pk = hexToBytes(32, "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
    const expected_proof = hexToBytes(80, "ae5b66bdf04b4c010bfe32b2fc126ead2107b697634f6f7337b9bff8785ee111200095ece87dde4dbe87343f6df3b107d91798c8a7eb1245d3bb9c5aafb093358c13e6ae1111a55717e895fd15f99f07");
    const expected_beta = hexToBytes(64, "94f4487e1b2fec954309ef1289ecb2e15043a2461ecc7b2ae7d4470607ef82eb1cfa97d84991fe4a7bfdfd715606bc27e2967a6c557cfb5875879b671740b7d8");

    const kp = try VRF.keyFromSeed(seed);
    try std.testing.expectEqualSlices(u8, &expected_pk, &kp.vk);

    const msg = [_]u8{0x72};
    const result = try VRF.prove(&msg, kp.sk);
    try std.testing.expectEqualSlices(u8, &expected_proof, &result.proof);
    try std.testing.expectEqualSlices(u8, &expected_beta, &result.output);

    const verified = VRF.verifyProof(&msg, kp.vk, result.proof);
    try std.testing.expect(verified != null);
    try std.testing.expectEqualSlices(u8, &expected_beta, &verified.?);
}

// vrf_ver03_standard_12: message = 0xaf82
test "vrf: draft-03 standard vector 12 — two bytes" {
    const seed = hexToBytes(32, "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7");
    const expected_pk = hexToBytes(32, "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025");
    const expected_proof = hexToBytes(80, "dfa2cba34b611cc8c833a6ea83b8eb1bb5e2ef2dd1b0c481bc42ff36ae7847f6ab52b976cfd5def172fa412defde270c8b8bdfbaae1c7ece17d9833b1bcf31064fff78ef493f820055b561ece45e1009");
    const expected_beta = hexToBytes(64, "2031837f582cd17a9af9e0c7ef5a6540e3453ed894b62c293686ca3c1e319dde9d0aa489a4b59a9594fc2328bc3deff3c8a0929a369a72b1180a596e016b5ded");

    const kp = try VRF.keyFromSeed(seed);
    try std.testing.expectEqualSlices(u8, &expected_pk, &kp.vk);

    const msg = [_]u8{ 0xaf, 0x82 };
    const result = try VRF.prove(&msg, kp.sk);
    try std.testing.expectEqualSlices(u8, &expected_proof, &result.proof);
    try std.testing.expectEqualSlices(u8, &expected_beta, &result.output);
}

// vrf_ver03_generated_1: zero seed, message = 0x00
test "vrf: draft-03 generated vector 1 — zero seed" {
    const seed = [_]u8{0} ** 32;
    const expected_pk = hexToBytes(32, "3b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da29");
    const expected_proof = hexToBytes(80, "000f006e64c91f84212919fe0899970cd341206fc081fe599339c8492e2cea3299ae9de4b6ce21cda0a975f65f45b70f82b3952ba6d0dbe11a06716e67aca233c0d78f115a655aa1952ada9f3d692a0a");
    const expected_beta = hexToBytes(64, "9930b5dddc0938f01cf6f9746eded569ee676bd6ff3b4f19233d74b903ec53a45c5728116088b7c622b6d6c354f7125c7d09870b56ec6f1e4bf4970f607e04b2");

    const kp = try VRF.keyFromSeed(seed);
    try std.testing.expectEqualSlices(u8, &expected_pk, &kp.vk);

    const msg = [_]u8{0x00};
    const result = try VRF.prove(&msg, kp.sk);
    try std.testing.expectEqualSlices(u8, &expected_proof, &result.proof);
    try std.testing.expectEqualSlices(u8, &expected_beta, &result.output);
}

// vrf_ver03_generated_3: different key, message = 0x00
test "vrf: draft-03 generated vector 3 — different key" {
    const seed = hexToBytes(32, "a70b8f607568df8ae26cf438b1057d8d0a94b7f3ac44cd984577fc43c2da55b7");
    const expected_pk = hexToBytes(32, "f1eb347d5c59e24f9f5f33c80cfd866e79fd72e0c370da3c011b1c9f045e23f1");
    const expected_proof = hexToBytes(80, "aa349327d919c8c96de316855de6fe5fa841ef25af913cfb9b33d6b663c425bd024456ca193f10da319a2205c67222e8a62da87101904f453de0beb79568902cedeea891f3db8202690f51c8e7d3210b");
    const expected_beta = hexToBytes(64, "d4b4deef941fc3ece4e86f837c784951b4a0cbc4accd79cdcbc882123befeb17c63b329730c59bbe9253294496f730428d588b9221832cb336bfd9d67754030f");

    const kp = try VRF.keyFromSeed(seed);
    try std.testing.expectEqualSlices(u8, &expected_pk, &kp.vk);

    const msg = [_]u8{0x00};
    const result = try VRF.prove(&msg, kp.sk);
    try std.testing.expectEqualSlices(u8, &expected_proof, &result.proof);
    try std.testing.expectEqualSlices(u8, &expected_beta, &result.output);
}

// Negative test: wrong VK fails verification
test "vrf: wrong vk fails verification" {
    const seed = hexToBytes(32, "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const kp = try VRF.keyFromSeed(seed);
    const result = try VRF.prove(&[_]u8{}, kp.sk);

    var wrong_vk = kp.vk;
    wrong_vk[0] ^= 0xff;
    const verified = VRF.verifyProof(&[_]u8{}, wrong_vk, result.proof);
    try std.testing.expect(verified == null);
}

// Round-trip: seed recovery
test "vrf: seed recovery round-trip" {
    const seed = hexToBytes(32, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
    const kp = try VRF.keyFromSeed(seed);
    const recovered = VRF.seedFromSk(kp.sk);
    try std.testing.expectEqualSlices(u8, &seed, &recovered);
}

// Round-trip: vk derivation
test "vrf: vk from sk matches keypair" {
    const seed = hexToBytes(32, "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7");
    const kp = try VRF.keyFromSeed(seed);
    const derived_vk = VRF.vkFromSk(kp.sk);
    try std.testing.expectEqualSlices(u8, &kp.vk, &derived_vk);
}
