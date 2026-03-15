const std = @import("std");
const types = @import("../types.zig");
const VRF = @import("../crypto/vrf.zig").VRF;
const KES = @import("../crypto/kes.zig").KES;
const Ed25519 = @import("../crypto/ed25519.zig").Ed25519;
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

pub const SlotNo = types.SlotNo;
pub const EpochNo = types.EpochNo;
pub const BlockNo = types.BlockNo;
pub const HeaderHash = types.HeaderHash;
pub const Nonce = types.Nonce;

/// Active slot coefficient: probability of a slot having a block producer.
/// On mainnet: f = 1/20 = 0.05 (approximately 5% of slots produce blocks).
pub const ActiveSlotCoeff = struct {
    numerator: u64,
    denominator: u64,

    pub const mainnet: ActiveSlotCoeff = .{ .numerator = 1, .denominator = 20 };
};

/// Security parameter k — maximum rollback depth.
pub const security_param_k: u64 = 2160;

/// Slots per epoch on mainnet.
pub const slots_per_epoch: u64 = 432_000;

/// Slots per KES period on mainnet.
pub const slots_per_kes_period: u64 = 129_600;

/// Randomness stabilization window: 3 * k * (1/f) slots from epoch start.
pub const randomness_stabilization_window: u64 = 3 * security_param_k; // = 6480 slots

/// Protocol state tracking nonces and operational certificate counters.
pub const PraosState = struct {
    last_slot: ?SlotNo,
    evolving_nonce: Nonce,
    candidate_nonce: Nonce,
    epoch_nonce: Nonce,
    previous_epoch_nonce: Nonce,
    lab_nonce: Nonce, // Last Applied Block nonce
    last_epoch_block_nonce: Nonce,

    pub fn init() PraosState {
        return .{
            .last_slot = null,
            .evolving_nonce = .neutral,
            .candidate_nonce = .neutral,
            .epoch_nonce = .neutral,
            .previous_epoch_nonce = .neutral,
            .lab_nonce = .neutral,
            .last_epoch_block_nonce = .neutral,
        };
    }

    /// Update state when a new block is received.
    pub fn onBlock(self: *PraosState, slot: SlotNo, prev_hash: ?HeaderHash, vrf_output: ?[64]u8) void {
        self.last_slot = slot;

        // Update LAB nonce from previous block hash
        if (prev_hash) |ph| {
            self.lab_nonce = .{ .hash = Blake2b256.hash(&ph) };
        }

        // Update evolving nonce with VRF output
        if (vrf_output) |vrf_out| {
            const vrf_nonce = Nonce{ .hash = Blake2b256.hash(&vrf_out) };
            self.evolving_nonce = Nonce.xorOp(self.evolving_nonce, vrf_nonce);
        }

        // Snapshot candidate nonce at randomness stabilization window
        const slot_in_epoch = slot % slots_per_epoch;
        if (slot_in_epoch == randomness_stabilization_window) {
            self.candidate_nonce = self.evolving_nonce;
        }
    }

    /// Update state at epoch boundary.
    pub fn onEpochBoundary(self: *PraosState) void {
        self.previous_epoch_nonce = self.epoch_nonce;
        self.epoch_nonce = Nonce.xorOp(self.candidate_nonce, self.last_epoch_block_nonce);
        self.evolving_nonce = .neutral;
        self.last_epoch_block_nonce = self.lab_nonce;
    }
};

/// Chain selection: compare two chain tips.
/// Returns true if candidate is preferred over current.
pub fn preferCandidate(current_block_no: BlockNo, candidate_block_no: BlockNo) bool {
    return candidate_block_no > current_block_no;
}

/// Slot to epoch conversion.
pub fn slotToEpoch(slot: SlotNo) EpochNo {
    return slot / slots_per_epoch;
}

/// First slot of an epoch.
pub fn epochFirstSlot(epoch: EpochNo) SlotNo {
    return epoch * slots_per_epoch;
}

/// Current KES period for a given slot.
pub fn currentKesPeriod(slot: SlotNo) u32 {
    return @intCast(slot / slots_per_kes_period);
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "praos: slot/epoch conversion" {
    try std.testing.expectEqual(@as(EpochNo, 0), slotToEpoch(0));
    try std.testing.expectEqual(@as(EpochNo, 0), slotToEpoch(431_999));
    try std.testing.expectEqual(@as(EpochNo, 1), slotToEpoch(432_000));
    try std.testing.expectEqual(@as(EpochNo, 10), slotToEpoch(4_320_000));

    try std.testing.expectEqual(@as(SlotNo, 0), epochFirstSlot(0));
    try std.testing.expectEqual(@as(SlotNo, 432_000), epochFirstSlot(1));
}

test "praos: KES period calculation" {
    try std.testing.expectEqual(@as(u32, 0), currentKesPeriod(0));
    try std.testing.expectEqual(@as(u32, 0), currentKesPeriod(129_599));
    try std.testing.expectEqual(@as(u32, 1), currentKesPeriod(129_600));
    try std.testing.expectEqual(@as(u32, 3), currentKesPeriod(3 * 129_600 + 50));
}

test "praos: chain selection prefers longer chain" {
    try std.testing.expect(preferCandidate(100, 101));
    try std.testing.expect(!preferCandidate(100, 100));
    try std.testing.expect(!preferCandidate(100, 99));
}

test "praos: state init" {
    const state = PraosState.init();
    try std.testing.expect(state.last_slot == null);
    try std.testing.expect(Nonce.eql(state.epoch_nonce, .neutral));
}

test "praos: nonce evolution on block" {
    var state = PraosState.init();

    // Apply a block
    const fake_vrf_output = [_]u8{0xab} ** 64;
    state.onBlock(100, [_]u8{0x01} ** 32, fake_vrf_output);

    try std.testing.expectEqual(@as(?SlotNo, 100), state.last_slot);
    try std.testing.expect(!Nonce.eql(state.evolving_nonce, .neutral));
    try std.testing.expect(!Nonce.eql(state.lab_nonce, .neutral));
}

test "praos: epoch boundary updates nonces" {
    var state = PraosState.init();
    state.epoch_nonce = .{ .hash = [_]u8{0x11} ** 32 };
    state.candidate_nonce = .{ .hash = [_]u8{0x22} ** 32 };
    state.lab_nonce = .{ .hash = [_]u8{0x33} ** 32 };

    state.onEpochBoundary();

    // previous_epoch_nonce should be the old epoch_nonce
    try std.testing.expect(Nonce.eql(state.previous_epoch_nonce, .{ .hash = [_]u8{0x11} ** 32 }));
    // epoch_nonce = candidate XOR last_epoch_block_nonce
    try std.testing.expect(!Nonce.eql(state.epoch_nonce, .neutral));
    // evolving_nonce reset to neutral
    try std.testing.expect(Nonce.eql(state.evolving_nonce, .neutral));
}

test "praos: constants match mainnet" {
    try std.testing.expectEqual(@as(u64, 2160), security_param_k);
    try std.testing.expectEqual(@as(u64, 432_000), slots_per_epoch);
    try std.testing.expectEqual(@as(u64, 129_600), slots_per_kes_period);
    try std.testing.expectEqual(@as(u64, 1), ActiveSlotCoeff.mainnet.numerator);
    try std.testing.expectEqual(@as(u64, 20), ActiveSlotCoeff.mainnet.denominator);
}
