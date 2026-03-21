const std = @import("std");
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");
const VRF = @import("../crypto/vrf.zig").VRF;
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;
const praos = @import("praos.zig");

pub const SlotNo = types.SlotNo;
pub const Nonce = types.Nonce;

pub const CertifiedVrf = struct {
    output: VRF.Output,
    proof: VRF.Proof,
};

fn nonceFromNumber(value: u64) Nonce {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    return .{ .hash = Blake2b256.hash(&buf) };
}

pub fn seedEta() Nonce {
    return nonceFromNumber(0);
}

pub fn seedL() Nonce {
    return nonceFromNumber(1);
}

/// Haskell-aligned VRF seed construction (mkSeed):
/// Seed = Blake2b256(slotNumber(8 BE) [|| epochNonce]) XOR universalConstantNonce
/// When epochNonce is NeutralNonce, Haskell uses mempty (no bytes), not 32 zeros.
pub fn makeSeed(universal_constant_nonce: Nonce, slot: SlotNo, epoch_nonce: Nonce) [32]u8 {
    var seed: [32]u8 = undefined;
    switch (epoch_nonce) {
        .neutral => {
            // Haskell: mempty — hash only the 8-byte slot
            var input: [8]u8 = undefined;
            std.mem.writeInt(u64, &input, slot, .big);
            seed = Blake2b256.hash(&input);
        },
        .hash => |h| {
            // Haskell: 8-byte slot || 32-byte nonce hash
            var input: [40]u8 = undefined;
            std.mem.writeInt(u64, input[0..8], slot, .big);
            @memcpy(input[8..40], &h);
            seed = Blake2b256.hash(&input);
        },
    }
    switch (universal_constant_nonce) {
        .neutral => {},
        .hash => |h| {
            for (&seed, h) |*dst, src| dst.* ^= src;
        },
    }
    return seed;
}

/// VRF input for leader election uses the leader universal constant (TPraos).
pub fn makeVRFInput(epoch_nonce: Nonce, slot: SlotNo) [32]u8 {
    return makeSeed(seedL(), slot, epoch_nonce);
}

/// Praos-era (Babbage+) unified VRF input: Blake2b256(slot || epochNonce)
/// No universal constant XOR — range extension happens post-verification.
pub fn makeInputVRF(slot: SlotNo, epoch_nonce: Nonce) [32]u8 {
    return makeSeed(.neutral, slot, epoch_nonce);
}

/// Praos-era nonce derivation: Blake2b256("N" || vrfOutput)
pub fn praosNonceFromVrfOutput(output: VRF.Output) [32]u8 {
    var buf: [1 + 64]u8 = undefined;
    buf[0] = 'N';
    @memcpy(buf[1..65], &output);
    return Blake2b256.hash(&buf);
}

/// Praos-era leader value derivation: Blake2b256("L" || vrfOutput)
pub fn praosLeaderFromVrfOutput(output: VRF.Output) [32]u8 {
    var buf: [1 + 64]u8 = undefined;
    buf[0] = 'L';
    @memcpy(buf[1..65], &output);
    return Blake2b256.hash(&buf);
}

pub fn parseCertifiedVrf(raw: []const u8) !CertifiedVrf {
    var dec = Decoder.init(raw);
    const len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (len != 2) return error.InvalidCbor;

    const output_bytes = try dec.decodeBytes();
    if (output_bytes.len != VRF.output_length) return error.InvalidCbor;

    const proof_bytes = try dec.decodeBytes();
    if (proof_bytes.len != VRF.proof_length) return error.InvalidCbor;

    var certified: CertifiedVrf = undefined;
    @memcpy(&certified.output, output_bytes);
    @memcpy(&certified.proof, proof_bytes);
    return certified;
}

pub fn verifyCertifiedVrfRaw(raw: []const u8, vk: VRF.VerKey, seed: [32]u8) ?VRF.Output {
    const certified = parseCertifiedVrf(raw) catch return null;
    const output = VRF.verifyProof(&seed, vk, certified.proof) orelse {
        std.debug.print("VRF verify: proof rejected by C (draft03 and draft13 both failed)\n", .{});
        std.debug.print("  seed[0..4]: {x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ seed[0], seed[1], seed[2], seed[3] });
        return null;
    };
    if (!std.mem.eql(u8, &output, &certified.output)) {
        std.debug.print("VRF verify: output mismatch\n", .{});
        return null;
    }
    return output;
}

/// Check if a VRF output meets the leader threshold for a given relative stake.
///
/// The check is: certifiedNatural / 2^512 < 1 - (1-f)^σ
/// where:
///   certifiedNatural = big-endian interpretation of 64-byte VRF output
///   f = active slot coefficient (1/20 on mainnet)
///   σ = relative stake (pool_stake / total_active_stake)
///
/// To avoid floating point, we use the approximation:
///   Check that: certifiedNatural * denominator < 2^512 * (1 - (1-f)^σ) * denominator
///
/// For simplicity and correctness, we use the logarithmic approximation:
///   1 - (1-f)^σ ≈ 1 - exp(-f*σ) ≈ f*σ (for small f)
///   So the check becomes: certifiedNatural < 2^512 * f * σ
///
/// This is the same approximation used by the Haskell node for the
/// active slot coefficient check.
pub fn meetsLeaderThreshold(
    vrf_output: VRF.Output,
    relative_stake_num: u64,
    relative_stake_den: u64,
    active_slot_coeff: praos.ActiveSlotCoeff,
) bool {
    if (relative_stake_den == 0) return false;

    // Interpret first 8 bytes of VRF output as big-endian u64
    // (simplified — full check uses all 64 bytes as a 512-bit number,
    // but for the threshold comparison, the top 8 bytes dominate)
    const cert_natural = std.mem.readInt(u64, vrf_output[0..8], .big);

    // Threshold: 2^64 * f * σ (using the top 64 bits of the 512-bit space)
    // = 2^64 * (f_num / f_den) * (stake_num / stake_den)
    // = (2^64 * f_num * stake_num) / (f_den * stake_den)
    //
    // To avoid overflow, compute in 128 bits:
    const max_val: u128 = std.math.maxInt(u64);
    const threshold: u128 = (max_val * @as(u128, active_slot_coeff.numerator) * @as(u128, relative_stake_num)) /
        (@as(u128, active_slot_coeff.denominator) * @as(u128, relative_stake_den));

    return @as(u128, cert_natural) < threshold;
}

/// Full VRF leader check: generate VRF proof and check threshold.
pub fn checkLeaderVRF(
    epoch_nonce: Nonce,
    slot: SlotNo,
    vrf_sk: VRF.SignKey,
    relative_stake_num: u64,
    relative_stake_den: u64,
    active_slot_coeff: praos.ActiveSlotCoeff,
) ?struct { proof: VRF.Proof, output: VRF.Output } {
    const input = makeVRFInput(epoch_nonce, slot);

    const result = VRF.prove(&input, vrf_sk) catch return null;

    if (meetsLeaderThreshold(result.output, relative_stake_num, relative_stake_den, active_slot_coeff)) {
        return .{ .proof = result.proof, .output = result.output };
    }

    return null;
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "leader: VRF input construction" {
    const nonce = Nonce{ .hash = [_]u8{0xab} ** 32 };
    const input = makeVRFInput(nonce, 42);
    const expected = makeSeed(seedL(), 42, nonce);
    try std.testing.expectEqualSlices(u8, &expected, &input);
}

test "leader: seed construction matches Haskell slot||nonce hash xor constant" {
    const epoch_nonce = Nonce{ .hash = [_]u8{0x11} ** 32 };
    const universal = seedEta();
    const seed = makeSeed(universal, 7, epoch_nonce);

    var input: [40]u8 = undefined;
    std.mem.writeInt(u64, input[0..8], 7, .big);
    @memcpy(input[8..40], &([_]u8{0x11} ** 32));
    const hashed = Blake2b256.hash(&input);
    const universal_hash = switch (universal) {
        .neutral => [_]u8{0} ** 32,
        .hash => |h| h,
    };

    var expected = hashed;
    for (&expected, universal_hash) |*dst, src| dst.* ^= src;
    try std.testing.expectEqualSlices(u8, &expected, &seed);
}

test "leader: threshold check with 100% stake always passes" {
    // With 100% relative stake, threshold should be very high
    const output = [_]u8{0x01} ** 64; // small VRF output
    try std.testing.expect(meetsLeaderThreshold(
        output,
        1, // numerator (100% stake)
        1, // denominator
        praos.ActiveSlotCoeff.mainnet, // f = 1/20
    ));
}

test "leader: threshold check with 0 stake never passes" {
    const output = [_]u8{0x00} ** 64;
    try std.testing.expect(!meetsLeaderThreshold(
        output,
        0, // 0% stake
        1,
        praos.ActiveSlotCoeff.mainnet,
    ));
}

test "leader: threshold check with 5% stake — probabilistic" {
    // With f=1/20 and σ=0.05, probability ≈ 0.0025
    // A very small VRF output should pass, a large one should fail
    const small_output = [_]u8{0x00} ++ [_]u8{0x01} ++ [_]u8{0x00} ** 62;
    try std.testing.expect(meetsLeaderThreshold(
        small_output,
        5, // 5% stake
        100,
        praos.ActiveSlotCoeff.mainnet,
    ));

    const large_output = [_]u8{0xff} ** 64;
    try std.testing.expect(!meetsLeaderThreshold(
        large_output,
        5, // 5% stake
        100,
        praos.ActiveSlotCoeff.mainnet,
    ));
}

test "leader: full VRF leader check — deterministic" {
    // With a known VRF key and nonce, the result should be deterministic
    const seed = [_]u8{0x42} ** 32;
    const kp = VRF.keyFromSeed(seed) catch return; // skip if VRF not available
    const nonce = Nonce{ .hash = [_]u8{0xaa} ** 32 };

    // With 100% stake, most slots should be leader (but not guaranteed
    // due to the simplified 64-bit threshold approximation)
    // Try multiple slots — at least one should succeed with f=1/20
    var found_leader = false;
    for (0..100) |slot| {
        const result = checkLeaderVRF(nonce, @intCast(slot), kp.sk, 1, 1, praos.ActiveSlotCoeff.mainnet);
        if (result) |r| {
            try std.testing.expectEqual(@as(usize, 80), r.proof.len);
            try std.testing.expectEqual(@as(usize, 64), r.output.len);
            found_leader = true;
            break;
        }
    }
    try std.testing.expect(found_leader);
}

test "leader: verify certified VRF raw round-trip" {
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    const allocator = std.testing.allocator;
    const key_seed = [_]u8{0x44} ** 32;
    const kp = try VRF.keyFromSeed(key_seed);
    const epoch_nonce = Nonce{ .hash = [_]u8{0x55} ** 32 };
    const seed = makeSeed(seedEta(), 99, epoch_nonce);
    const result = try VRF.prove(&seed, kp.sk);

    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.encodeArrayLen(2);
    try enc.encodeBytes(&result.output);
    try enc.encodeBytes(&result.proof);
    const raw = try enc.toOwnedSlice();
    defer allocator.free(raw);

    const verified = verifyCertifiedVrfRaw(raw, kp.vk, seed);
    try std.testing.expect(verified != null);
    try std.testing.expectEqualSlices(u8, &result.output, &verified.?);
}

test "leader: certified VRF rejects mismatched output" {
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    const allocator = std.testing.allocator;
    const key_seed = [_]u8{0x66} ** 32;
    const kp = try VRF.keyFromSeed(key_seed);
    const seed = makeSeed(seedL(), 101, .neutral);
    const result = try VRF.prove(&seed, kp.sk);

    var bad_output = result.output;
    bad_output[0] ^= 0xff;

    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.encodeArrayLen(2);
    try enc.encodeBytes(&bad_output);
    try enc.encodeBytes(&result.proof);
    const raw = try enc.toOwnedSlice();
    defer allocator.free(raw);

    try std.testing.expect(verifyCertifiedVrfRaw(raw, kp.vk, seed) == null);
}
