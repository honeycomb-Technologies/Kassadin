const std = @import("std");
const types = @import("../types.zig");
const block_mod = @import("../ledger/block.zig");
const VRF = @import("../crypto/vrf.zig").VRF;
const KES = @import("../crypto/kes.zig").KES;
const Ed25519 = @import("../crypto/ed25519.zig").Ed25519;
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;
const Blake2b224 = @import("../crypto/hash.zig").Blake2b224;

pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;
pub const HeaderHash = types.HeaderHash;

/// Errors during header validation.
pub const ValidationError = error{
    SlotNotIncreasing,
    BlockNumberNotIncreasing,
    PrevHashMismatch,
    VRFKeyUnknown,
    VRFKeyMismatch,
    VRFBadProof,
    VRFLeaderValueTooBig,
    KESBeforeStart,
    KESAfterEnd,
    KESInvalidSignature,
    OCertCounterTooSmall,
    OCertCounterOverIncremented,
    OCertInvalidSignature,
    BodyHashMismatch,
    InvalidProtocolVersion,
};

/// Information about a pool needed for header validation.
pub const PoolInfo = struct {
    vrf_key_hash: [32]u8, // VRF verification key hash (Blake2b-256)
    relative_stake_num: u64,
    relative_stake_den: u64,
};

/// Validate a block header's structural properties.
/// Does NOT verify VRF proof or KES signature (those need pool lookup).
pub fn validateHeaderStructure(
    header: *const block_mod.BlockHeader,
    expected_prev_hash: ?HeaderHash,
    last_slot: ?SlotNo,
    last_block_no: ?BlockNo,
) ValidationError!void {
    // 1. Slot must be strictly increasing
    if (last_slot) |ls| {
        if (header.slot <= ls) return error.SlotNotIncreasing;
    }

    // 2. Block number must be increasing
    if (last_block_no) |lbn| {
        if (header.block_no <= lbn) return error.BlockNumberNotIncreasing;
    }

    // 3. Previous hash must match
    if (expected_prev_hash) |expected| {
        if (header.prev_hash) |actual| {
            if (!std.mem.eql(u8, &actual, &expected)) return error.PrevHashMismatch;
        } else {
            return error.PrevHashMismatch;
        }
    }
}

/// Validate the VRF key in the header matches the registered pool VRF key.
pub fn validateVRFKey(
    header: *const block_mod.BlockHeader,
    pool_info: *const PoolInfo,
) ValidationError!void {
    // The VRF key in the header must hash to the registered VRF key hash
    const vrf_key_hash = Blake2b256.hash(&header.vrf_vkey);
    if (!std.mem.eql(u8, &vrf_key_hash, &pool_info.vrf_key_hash)) {
        return error.VRFKeyMismatch;
    }
}

/// Compute the pool key hash (Blake2b-224 of the issuer VKey).
/// This is used to look up the pool in the stake distribution.
pub fn poolKeyHash(issuer_vkey: [32]u8) [28]u8 {
    return Blake2b224.hash(&issuer_vkey);
}

/// Validate that the block body hash in the header matches the actual body.
pub fn validateBodyHash(
    header: *const block_mod.BlockHeader,
    actual_body_hash: [32]u8,
) ValidationError!void {
    if (!std.mem.eql(u8, &header.block_body_hash, &actual_body_hash)) {
        return error.BodyHashMismatch;
    }
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "header_validation: slot must increase" {
    const header = block_mod.BlockHeader{
        .block_no = 10,
        .slot = 100,
        .prev_hash = [_]u8{0} ** 32,
        .issuer_vkey = [_]u8{0} ** 32,
        .vrf_vkey = [_]u8{0} ** 32,
        .block_body_size = 0,
        .block_body_hash = [_]u8{0} ** 32,
        .protocol_version_major = 0,
        .protocol_version_minor = 0,
        .header_body_raw = "",
        .kes_signature_raw = "",
    };

    // Slot 100 after slot 50 — should pass
    try validateHeaderStructure(&header, null, 50, null);

    // Slot 100 after slot 100 — should fail
    try std.testing.expectError(error.SlotNotIncreasing, validateHeaderStructure(&header, null, 100, null));

    // Slot 100 after slot 200 — should fail
    try std.testing.expectError(error.SlotNotIncreasing, validateHeaderStructure(&header, null, 200, null));
}

test "header_validation: block number must increase" {
    const header = block_mod.BlockHeader{
        .block_no = 10,
        .slot = 100,
        .prev_hash = null,
        .issuer_vkey = [_]u8{0} ** 32,
        .vrf_vkey = [_]u8{0} ** 32,
        .block_body_size = 0,
        .block_body_hash = [_]u8{0} ** 32,
        .protocol_version_major = 0,
        .protocol_version_minor = 0,
        .header_body_raw = "",
        .kes_signature_raw = "",
    };

    try validateHeaderStructure(&header, null, null, 9);
    try std.testing.expectError(error.BlockNumberNotIncreasing, validateHeaderStructure(&header, null, null, 10));
}

test "header_validation: prev hash must match" {
    const expected = [_]u8{0xaa} ** 32;
    const header = block_mod.BlockHeader{
        .block_no = 10,
        .slot = 100,
        .prev_hash = expected,
        .issuer_vkey = [_]u8{0} ** 32,
        .vrf_vkey = [_]u8{0} ** 32,
        .block_body_size = 0,
        .block_body_hash = [_]u8{0} ** 32,
        .protocol_version_major = 0,
        .protocol_version_minor = 0,
        .header_body_raw = "",
        .kes_signature_raw = "",
    };

    // Correct prev hash — pass
    try validateHeaderStructure(&header, expected, null, null);

    // Wrong prev hash — fail
    try std.testing.expectError(error.PrevHashMismatch, validateHeaderStructure(&header, [_]u8{0xbb} ** 32, null, null));
}

test "header_validation: pool key hash" {
    const vkey = [_]u8{0x42} ** 32;
    const pkh = poolKeyHash(vkey);
    try std.testing.expectEqual(@as(usize, 28), pkh.len);
    // Deterministic
    try std.testing.expectEqualSlices(u8, &pkh, &poolKeyHash(vkey));
}

test "header_validation: golden block header structure" {
    const allocator = std.testing.allocator;
    const data = std.fs.cwd().readFileAlloc(allocator, "tests/vectors/alonzo_block.cbor", 10 * 1024 * 1024) catch return;
    defer allocator.free(data);

    const block = try block_mod.parseBlock(data);

    // Block 3, slot 9 — structural validation should pass
    try validateHeaderStructure(&block.header, null, 0, 0);

    // Should fail if last_slot is >= 9
    try std.testing.expectError(error.SlotNotIncreasing, validateHeaderStructure(&block.header, null, 9, null));
}
