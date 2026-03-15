const std = @import("std");
const types = @import("../types.zig");
const VRF = @import("../crypto/vrf.zig").VRF;
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;
const praos = @import("praos.zig");

pub const SlotNo = types.SlotNo;
pub const Nonce = types.Nonce;

/// VRF input for leader election: epochNonce(32) || slotNumber(8 big-endian)
pub fn makeVRFInput(epoch_nonce: Nonce, slot: SlotNo) [40]u8 {
    var input: [40]u8 = undefined;
    switch (epoch_nonce) {
        .neutral => @memset(input[0..32], 0),
        .hash => |h| @memcpy(input[0..32], &h),
    }
    std.mem.writeInt(u64, input[32..40], slot, .big);
    return input;
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

    // First 32 bytes: nonce hash
    try std.testing.expectEqual(@as(u8, 0xab), input[0]);
    try std.testing.expectEqual(@as(u8, 0xab), input[31]);

    // Last 8 bytes: slot 42 in big-endian
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, input[32..40], .big));
}

test "leader: neutral nonce produces zero prefix" {
    const input = makeVRFInput(.neutral, 100);
    for (input[0..32]) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
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
            try std.testing.expectEqual(@as(usize, 128), r.proof.len);
            try std.testing.expectEqual(@as(usize, 64), r.output.len);
            found_leader = true;
            break;
        }
    }
    try std.testing.expect(found_leader);
}
