const std = @import("std");

/// VRF (Verifiable Random Function) using ECVRF-ED25519-SHA512-Elligator2.
///
/// Uses the exact C implementation from cardano-crypto-praos/cbits — the same
/// code the Haskell node uses. This is PraosBatchCompatVRF (IETF draft-13),
/// which is the VRF variant used on Cardano mainnet.
///
/// The C code includes the Cardano-specific Elligator2 sign bit handling that
/// makes it incompatible with naive IETF VRF implementations.
///
/// All test vectors sourced from cardano-crypto-praos/test_vectors/vrf_ver13_*
pub const VRF = struct {
    pub const seed_length = 32;
    pub const vk_length = 32;
    pub const sk_length = 64; // seed(32) + pk(32)
    pub const proof_length = 128; // PraosBatchCompatVRF (draft-13) uses 128-byte proofs
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
    // We call the batchcompat variants directly — same as the Haskell node's
    // PraosBatchCompatVRF bindings.
    const c = struct {
        extern "c" fn crypto_vrf_seed_keypair(
            pk: *[vk_length]u8,
            skpk: *[sk_length]u8,
            seed: *const [seed_length]u8,
        ) c_int;

        // PraosBatchCompatVRF uses the _batchcompat prove/verify/hash functions
        extern "c" fn crypto_vrf_ietfdraft13_prove_batchcompat(
            proof: *[proof_length]u8,
            skpk: *const [sk_length]u8,
            msg: [*]const u8,
            msg_len: c_ulonglong,
        ) c_int;

        extern "c" fn crypto_vrf_ietfdraft13_verify_batchcompat(
            output: *[output_length]u8,
            pk: *const [vk_length]u8,
            proof: *const [proof_length]u8,
            msg: [*]const u8,
            msg_len: c_ulonglong,
        ) c_int;

        extern "c" fn crypto_vrf_ietfdraft13_proof_to_hash_batchcompat(
            hash: *[output_length]u8,
            proof: *const [proof_length]u8,
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
        if (c.crypto_vrf_seed_keypair(&pk, &sk, &seed) != 0) {
            return error.VrfKeypairFailed;
        }
        return .{ .sk = sk, .vk = pk };
    }

    /// Create a VRF proof for a message.
    pub fn prove(msg: []const u8, sk: SignKey) Error!struct { proof: Proof, output: Output } {
        var proof: Proof = undefined;
        const msg_ptr: [*]const u8 = if (msg.len > 0) msg.ptr else @as([*]const u8, &[_]u8{0});
        if (c.crypto_vrf_ietfdraft13_prove_batchcompat(&proof, &sk, msg_ptr, @intCast(msg.len)) != 0) {
            return error.VrfProveFailed;
        }
        const output = try proofToHash(proof);
        return .{ .proof = proof, .output = output };
    }

    /// Verify a VRF proof. Returns output on success, null on failure.
    pub fn verifyProof(msg: []const u8, vk: VerKey, proof: Proof) ?Output {
        var output: Output = undefined;
        const msg_ptr: [*]const u8 = if (msg.len > 0) msg.ptr else @as([*]const u8, &[_]u8{0});
        if (c.crypto_vrf_ietfdraft13_verify_batchcompat(&output, &vk, &proof, msg_ptr, @intCast(msg.len)) != 0) {
            return null;
        }
        return output;
    }

    /// Convert a proof directly to its hash output (without verification).
    pub fn proofToHash(proof: Proof) Error!Output {
        var output: Output = undefined;
        if (c.crypto_vrf_ietfdraft13_proof_to_hash_batchcompat(&output, &proof) != 0) {
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
// All test vectors from cardano-crypto-praos/test_vectors/vrf_ver13_*
// These are PraosBatchCompatVRF (ietfdraft13) — the variant used on Cardano mainnet.
// Each test validates: key derivation, proof generation, output, and verification.

test "vrf: type sizes" {
    try std.testing.expectEqual(@as(usize, 32), VRF.seed_length);
    try std.testing.expectEqual(@as(usize, 32), VRF.vk_length);
    try std.testing.expectEqual(@as(usize, 64), VRF.sk_length);
    try std.testing.expectEqual(@as(usize, 128), VRF.proof_length);
    try std.testing.expectEqual(@as(usize, 64), VRF.output_length);
}

// vrf_ver13_standard_10: empty message
test "vrf: draft-13 standard vector 10 — empty message" {
    const seed = hexToBytes(32, "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const expected_pk = hexToBytes(32, "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    const expected_proof = hexToBytes(128, "7d9c633ffeee27349264cf5c667579fc583b4bda63ab71d001f89c10003ab46f762f5c178b68f0cddcc1157918edf45ec334ac8e8286601a3256c3bbf858edd94652eba1c4612e6fce762977a59420b451e12964adbe4fbecd58a7aeff5860afcafa73589b023d14311c331a9ad15ff2fb37831e00f0acaa6d73bc9997b06501");
    const expected_beta = hexToBytes(64, "9d574bf9b8302ec0fc1e21c3ec5368269527b87b462ce36dab2d14ccf80c53cccf6758f058c5b1c856b116388152bbe509ee3b9ecfe63d93c3b4346c1fbc6c54");

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

// vrf_ver13_standard_11: message = 0x72
test "vrf: draft-13 standard vector 11 — single byte" {
    const seed = hexToBytes(32, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
    const expected_pk = hexToBytes(32, "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
    const expected_proof = hexToBytes(128, "47b327393ff2dd81336f8a2ef10339112401253b3c714eeda879f12c509072ef8ec26e77b8cb3114dd2265fe1564a4efb40d109aa3312536d93dfe3d8d80a061fe799eb5770b4e3a5a27d22518bb631db183c8316bb552155f442c62a47d1c8bd60e93908f93df1623ad78a86a028d6bc064dbfc75a6a57379ef855dc6733801");
    const expected_beta = hexToBytes(64, "38561d6b77b71d30eb97a062168ae12b667ce5c28caccdf76bc88e093e4635987cd96814ce55b4689b3dd2947f80e59aac7b7675f8083865b46c89b2ce9cc735");

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

// vrf_ver13_standard_12: message = 0xaf82
test "vrf: draft-13 standard vector 12 — two bytes" {
    const seed = hexToBytes(32, "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7");
    const expected_pk = hexToBytes(32, "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025");
    const expected_proof = hexToBytes(128, "926e895d308f5e328e7aa159c06eddbe56d06846abf5d98c2512235eaa57fdcea012f35433df219a88ab0f9481f4e0065d00422c3285f3d34a8b0202f20bac60fb613986d171b3e98319c7ca4dc44c5dd8314a6e5616c1a4f16ce72bd7a0c25a374e7ef73027e14760d42e77341fe05467bb286cc2c9d7fde29120a0b2320d04");
    const expected_beta = hexToBytes(64, "121b7f9b9aaaa29099fc04a94ba52784d44eac976dd1a3cca458733be5cd090a7b5fbd148444f17f8daf1fb55cb04b1ae85a626e30a54b4b0f8abf4a43314a58");

    const kp = try VRF.keyFromSeed(seed);
    try std.testing.expectEqualSlices(u8, &expected_pk, &kp.vk);

    const msg = [_]u8{ 0xaf, 0x82 };
    const result = try VRF.prove(&msg, kp.sk);
    try std.testing.expectEqualSlices(u8, &expected_proof, &result.proof);
    try std.testing.expectEqualSlices(u8, &expected_beta, &result.output);
}

// vrf_ver13_generated_1: zero seed, message = 0x00
test "vrf: draft-13 generated vector 1 — zero seed" {
    const seed = [_]u8{0} ** 32;
    const expected_pk = hexToBytes(32, "3b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da29");
    const expected_proof = hexToBytes(128, "93d70c5ed59ccb21ca9991be561756939ff9753bf85764d2a7b937d6fbf9183443cd118bee8a0f61e8bdc5403c03d6c94ead31956e98bfd6a5e02d3be5900d17a540852d586f0891caed3e3b0e0871d6a741fb0edcdb586f7f10252f79c35176474ece4936e0190b5167832c10712884ad12acdfff2e434aacb165e1f789660f");
    const expected_beta = hexToBytes(64, "9a4d34f87003412e413ca42feba3b6158bdf11db41c2bbde98961c5865400cfdee07149b928b376db365c5d68459378b0981f1cb0510f1e0c194c4a17603d44d");

    const kp = try VRF.keyFromSeed(seed);
    try std.testing.expectEqualSlices(u8, &expected_pk, &kp.vk);

    const msg = [_]u8{0x00};
    const result = try VRF.prove(&msg, kp.sk);
    try std.testing.expectEqualSlices(u8, &expected_proof, &result.proof);
    try std.testing.expectEqualSlices(u8, &expected_beta, &result.output);
}

// vrf_ver13_generated_3: different key, message = 0x00
test "vrf: draft-13 generated vector 3 — different key" {
    const seed = hexToBytes(32, "a70b8f607568df8ae26cf438b1057d8d0a94b7f3ac44cd984577fc43c2da55b7");
    const expected_pk = hexToBytes(32, "f1eb347d5c59e24f9f5f33c80cfd866e79fd72e0c370da3c011b1c9f045e23f1");
    const expected_proof = hexToBytes(128, "fe7fe305611dbd8402bf580ceaa4775b573a3be110bc30901880cfd81903852b306d432fc2d197b79a690ba8af62d166134ad57ec546b4675554207465e5d92d5570ba7336636f78afdf4ed2362c220572c2735752b975773ec3289c803689cbfa9b8d841d2e603e3d9376c9c884a156c70cfd0a4293cc4edcd8902da8972f04");
    const expected_beta = hexToBytes(64, "05cff584ea083ae01537fc43a2456f70cbd0d1abc60b8f62170b83b647a0022840c27f747134e16641428d6cc6f66675b13fff7f975a5c6891172360417ac62d");

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
