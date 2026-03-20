const std = @import("std");
const types = @import("../types.zig");
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

pub fn hashHeaderToNonce(hash: HeaderHash) Nonce {
    return .{ .hash = hash };
}

pub fn prevHashToNonce(prev_hash: ?HeaderHash) Nonce {
    if (prev_hash) |hash| {
        return hashHeaderToNonce(hash);
    }
    return .neutral;
}

/// TPraos (Shelley-Alonzo) nonce derivation: Blake2b256(vrfOutput)
pub fn nonceFromVrfOutput(output: [64]u8) Nonce {
    return .{ .hash = Blake2b256.hash(&output) };
}

/// Praos (Babbage+) nonce derivation: Blake2b256(Blake2b256("N" || vrfOutput))
/// Double hash per Haskell VRF.hs vrfNonceValue: range extension then nonce derivation.
pub fn praosNonceFromVrfOutput(output: [64]u8) Nonce {
    var buf: [1 + 64]u8 = undefined;
    buf[0] = 'N';
    @memcpy(buf[1..65], &output);
    const first_hash = Blake2b256.hash(&buf);
    return .{ .hash = Blake2b256.hash(&first_hash) };
}

pub fn initialNonce() Nonce {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, 0, .big);
    return .{ .hash = Blake2b256.hash(&buf) };
}

pub const Flavor = enum(u8) {
    tpraos = 0,
    praos = 1,
};

/// Haskell-shaped follower-side chain-dep state.
pub const PraosState = struct {
    flavor: Flavor,
    evolving_nonce: Nonce,
    candidate_nonce: Nonce,
    epoch_nonce: Nonce,
    previous_epoch_nonce: Nonce,
    last_epoch_block_nonce: Nonce,
    lab_nonce: Nonce,

    pub fn init() PraosState {
        return initWithNonce(initialNonce());
    }

    pub fn initWithNonce(init_nonce: Nonce) PraosState {
        return .{
            .flavor = .tpraos,
            .evolving_nonce = init_nonce,
            .candidate_nonce = init_nonce,
            .epoch_nonce = init_nonce,
            .previous_epoch_nonce = init_nonce,
            .last_epoch_block_nonce = .neutral,
            .lab_nonce = .neutral,
        };
    }

    pub fn transitionToPraos(self: *PraosState) void {
        if (self.flavor == .praos) return;
        self.flavor = .praos;
        self.previous_epoch_nonce = self.epoch_nonce;
    }

    /// Tick chain-dep state across an epoch boundary before validating the first block
    /// in a Shelley-Alonzo epoch.
    pub fn tickTpraos(self: *PraosState, is_new_epoch: bool, extra_entropy: Nonce) void {
        if (!is_new_epoch) return;
        self.epoch_nonce = Nonce.xorOp(
            self.candidate_nonce,
            Nonce.xorOp(self.last_epoch_block_nonce, extra_entropy),
        );
        self.last_epoch_block_nonce = self.lab_nonce;
    }

    /// Tick chain-dep state across an epoch boundary before validating the first block
    /// in a Babbage+ epoch.
    pub fn tickPraos(self: *PraosState, is_new_epoch: bool) void {
        self.transitionToPraos();
        if (!is_new_epoch) return;
        const old_epoch_nonce = self.epoch_nonce;
        self.epoch_nonce = Nonce.xorOp(
            self.candidate_nonce,
            self.last_epoch_block_nonce,
        );
        self.previous_epoch_nonce = old_epoch_nonce;
        self.last_epoch_block_nonce = self.lab_nonce;
    }

    /// Update chain-dep state after a block has been accepted.
    pub fn updateWithBlock(
        self: *PraosState,
        slot: SlotNo,
        prev_hash: ?HeaderHash,
        block_nonce: Nonce,
        epoch_length: u64,
        stability_window: u64,
        era_start_slot: u64,
    ) void {
        self.evolving_nonce = Nonce.xorOp(self.evolving_nonce, block_nonce);

        const relative_slot = if (slot >= era_start_slot) slot - era_start_slot else slot;
        const current_epoch = relative_slot / epoch_length;
        const first_slot_next_epoch = era_start_slot + (current_epoch + 1) * epoch_length;
        if (slot + stability_window < first_slot_next_epoch) {
            self.candidate_nonce = self.evolving_nonce;
        }

        self.lab_nonce = prevHashToNonce(prev_hash);
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

test "praos: state init uses Haskell initial nonce" {
    const state = PraosState.init();
    try std.testing.expectEqual(Flavor.tpraos, state.flavor);
    try std.testing.expect(Nonce.eql(state.evolving_nonce, initialNonce()));
    try std.testing.expect(Nonce.eql(state.candidate_nonce, initialNonce()));
    try std.testing.expect(Nonce.eql(state.epoch_nonce, initialNonce()));
    try std.testing.expect(Nonce.eql(state.previous_epoch_nonce, initialNonce()));
}

test "praos: init with nonce matches Haskell initial chain dep state" {
    const init_nonce = Nonce{ .hash = [_]u8{0x77} ** 32 };
    const state = PraosState.initWithNonce(init_nonce);
    try std.testing.expectEqual(Flavor.tpraos, state.flavor);
    try std.testing.expect(Nonce.eql(state.evolving_nonce, init_nonce));
    try std.testing.expect(Nonce.eql(state.candidate_nonce, init_nonce));
    try std.testing.expect(Nonce.eql(state.epoch_nonce, init_nonce));
    try std.testing.expect(Nonce.eql(state.previous_epoch_nonce, init_nonce));
    try std.testing.expect(Nonce.eql(state.last_epoch_block_nonce, .neutral));
    try std.testing.expect(Nonce.eql(state.lab_nonce, .neutral));
}

test "praos: updateWithBlock tracks evolving and candidate nonces" {
    var state = PraosState.initWithNonce(.neutral);
    state.updateWithBlock(
        100,
        [_]u8{0x01} ** 32,
        nonceFromVrfOutput([_]u8{0xab} ** 64),
        slots_per_epoch,
        randomness_stabilization_window,
        0,
    );

    try std.testing.expect(!Nonce.eql(state.evolving_nonce, .neutral));
    try std.testing.expect(Nonce.eql(state.candidate_nonce, state.evolving_nonce));
    try std.testing.expect(!Nonce.eql(state.lab_nonce, .neutral));
}

test "praos: TPraos tick updates epoch nonce from candidate, previous hash, and entropy" {
    var state = PraosState.initWithNonce(.neutral);
    state.candidate_nonce = .{ .hash = [_]u8{0x22} ** 32 };
    state.last_epoch_block_nonce = .{ .hash = [_]u8{0x33} ** 32 };
    state.lab_nonce = .{ .hash = [_]u8{0x44} ** 32 };

    state.tickTpraos(true, .{ .hash = [_]u8{0x55} ** 32 });

    try std.testing.expect(!Nonce.eql(state.epoch_nonce, .neutral));
    try std.testing.expect(Nonce.eql(state.last_epoch_block_nonce, .{ .hash = [_]u8{0x44} ** 32 }));
}

test "praos: Praos tick updates epoch nonce and previous epoch nonce" {
    var state = PraosState.initWithNonce(.neutral);
    state.transitionToPraos();
    state.candidate_nonce = .{ .hash = [_]u8{0x22} ** 32 };
    state.epoch_nonce = .{ .hash = [_]u8{0x11} ** 32 };
    state.last_epoch_block_nonce = .{ .hash = [_]u8{0x33} ** 32 };
    state.lab_nonce = .{ .hash = [_]u8{0x44} ** 32 };

    state.tickPraos(true);

    try std.testing.expectEqual(Flavor.praos, state.flavor);
    try std.testing.expect(Nonce.eql(state.previous_epoch_nonce, .{ .hash = [_]u8{0x11} ** 32 }));
    try std.testing.expect(Nonce.eql(state.last_epoch_block_nonce, .{ .hash = [_]u8{0x44} ** 32 }));
}

test "praos: prevHashToNonce uses neutral for genesis" {
    try std.testing.expect(Nonce.eql(prevHashToNonce(null), .neutral));
    try std.testing.expect(Nonce.eql(prevHashToNonce([_]u8{0x11} ** 32), .{ .hash = [_]u8{0x11} ** 32 }));
}

test "praos: constants match mainnet" {
    try std.testing.expectEqual(@as(u64, 2160), security_param_k);
    try std.testing.expectEqual(@as(u64, 432_000), slots_per_epoch);
    try std.testing.expectEqual(@as(u64, 129_600), slots_per_kes_period);
    try std.testing.expectEqual(@as(u64, 1), ActiveSlotCoeff.mainnet.numerator);
    try std.testing.expectEqual(@as(u64, 20), ActiveSlotCoeff.mainnet.denominator);
}
