const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;
const block_mod = @import("../ledger/block.zig");
const ledger_apply = @import("../ledger/apply.zig");
const protocol_update = @import("../ledger/protocol_update.zig");
const rewards_mod = @import("../ledger/rewards.zig");
const rules = @import("../ledger/rules.zig");
const header_validation = @import("../consensus/header_validation.zig");
const praos = @import("../consensus/praos.zig");
const stake_mod = @import("../ledger/stake.zig");
const ImmutableDB = @import("immutable.zig").ImmutableDB;
const VolatileDB = @import("volatile.zig").VolatileDB;
const LedgerDB = @import("ledger.zig").LedgerDB;
const UtxoEntry = @import("ledger.zig").UtxoEntry;

pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;
pub const HeaderHash = types.HeaderHash;
pub const Point = types.Point;

/// Result of adding a block to the ChainDB.
pub const AddBlockResult = enum {
    added_to_current_chain,
    added_to_fork,
    already_known,
    invalid,
};

/// Unified interface combining ImmutableDB + VolatileDB + LedgerDB.
/// Manages the full block storage lifecycle: volatile → immutable promotion,
/// chain selection, and ledger state tracking.
pub const ChainDB = struct {
    const TipInfo = struct {
        point: Point,
        block_no: BlockNo,
    };

    const CurrentChainEntry = struct {
        point: Point,
        block_no: BlockNo,
        ledger_diffs_applied: u32,
        governance_snapshot: ?protocol_update.GovernanceSnapshot,
        ocert_counter_change: ?OCertCounterChange = null,
        praos_snapshot: ?praos.PraosState = null,
    };

    const OCertCounterChange = struct {
        issuer: types.KeyHash,
        previous: ?u64,
    };

    allocator: Allocator,
    immutable: ImmutableDB,
    @"volatile": VolatileDB,
    ledger: LedgerDB,
    current_chain: std.ArrayList(CurrentChainEntry),
    ocert_counters: std.AutoHashMap(types.KeyHash, u64),

    /// Current chain tip (from volatile or immutable).
    tip_slot: SlotNo,
    tip_hash: HeaderHash,
    tip_block_no: BlockNo,
    vrf_threshold_warnings: u64 = 0,
    base_tip: ?TipInfo,
    ledger_validation_enabled: bool,
    ledger_ready: bool,
    protocol_params: rules.ProtocolParams,
    slots_per_kes_period: u64,
    max_kes_evolutions: u32,
    praos_state: praos.PraosState,
    base_praos_state: ?praos.PraosState,
    praos_tracking_ready: bool,
    praos_epoch_length: u64,
    praos_era_start_slot: u64,
    praos_stability_window: u64,
    /// Conway+ nonce freeze window (4k/f). Set from GovernanceConfig.
    praos_randomness_stabilisation_window: u64,
    praos_initial_nonce: types.Nonce,
    praos_extra_entropy: types.Nonce,
    praos_active_slot_coeff: praos.ActiveSlotCoeff,
    shelley_governance_config: ?protocol_update.GovernanceConfig,
    governance_state: protocol_update.GovernanceState,

    /// Security parameter k — blocks deeper than this are finalized.
    security_param: u64,

    pub fn open(allocator: Allocator, db_path: []const u8, security_param: u64) !ChainDB {
        const imm_path = try std.fmt.allocPrint(allocator, "{s}/immutable", .{db_path});
        errdefer allocator.free(imm_path);

        const ledger_path = try std.fmt.allocPrint(allocator, "{s}/ledger", .{db_path});
        errdefer allocator.free(ledger_path);

        var immutable = try ImmutableDB.open(allocator, imm_path);
        errdefer immutable.close();

        var ledger = try LedgerDB.init(allocator, ledger_path);
        errdefer ledger.deinit();

        var db = ChainDB{
            .allocator = allocator,
            .immutable = immutable,
            .@"volatile" = VolatileDB.init(allocator),
            .ledger = ledger,
            .current_chain = .empty,
            .ocert_counters = std.AutoHashMap(types.KeyHash, u64).init(allocator),
            .tip_slot = 0,
            .tip_hash = [_]u8{0} ** 32,
            .tip_block_no = 0,
            .base_tip = null,
            .ledger_validation_enabled = false,
            .ledger_ready = false,
            .protocol_params = rules.ProtocolParams.compatibility_defaults,
            .slots_per_kes_period = types.mainnet.slots_per_kes_period,
            .max_kes_evolutions = types.mainnet.max_kes_evolutions,
            .praos_state = praos.PraosState.init(),
            .base_praos_state = null,
            .praos_tracking_ready = false,
            .praos_epoch_length = types.mainnet.slots_per_epoch,
            .praos_era_start_slot = 0,
            .praos_stability_window = 3 * security_param,
            .praos_randomness_stabilisation_window = 4 * security_param,
            .praos_initial_nonce = praos.initialNonce(),
            .praos_extra_entropy = .neutral,
            .praos_active_slot_coeff = .{
                .numerator = 1,
                .denominator = 20,
            },
            .shelley_governance_config = null,
            .governance_state = .{},
            .security_param = security_param,
        };

        if (db.immutable.getTip()) |tip| {
            db.tip_slot = tip.slot;
            db.tip_hash = tip.hash;
            db.tip_block_no = tip.block_no;
            db.base_tip = .{
                .point = .{ .slot = tip.slot, .hash = tip.hash },
                .block_no = tip.block_no,
            };
        }

        return db;
    }

    pub fn close(self: *ChainDB) void {
        for (self.current_chain.items) |*entry| {
            if (entry.governance_snapshot) |*snapshot| snapshot.deinit(self.allocator);
        }
        self.immutable.close();
        self.allocator.free(self.immutable.base_path);
        self.@"volatile".deinit();
        self.ledger.deinit();
        self.allocator.free(self.ledger.snapshot_path);
        self.current_chain.deinit(self.allocator);
        self.ocert_counters.deinit();
        self.governance_state.deinit(self.allocator);
        if (self.shelley_governance_config) |*config| {
            config.deinit(self.allocator);
        }
    }

    /// Enable ledger validation for an empty current chain.
    /// If `base_tip` is present, callers must have already hydrated the base ledger state.
    pub fn enableLedgerValidation(self: *ChainDB) !void {
        if (self.current_chain.items.len > 0) {
            return error.ChainNotEmpty;
        }
        if (self.base_tip == null and (self.tip_slot != 0 or self.tip_block_no != 0)) {
            return error.ChainNotEmpty;
        }

        self.ledger_validation_enabled = true;
        self.ledger_ready = true;
        self.ledger.setRewardBalancesTracked(true);
        self.ledger.setTipSlot(if (self.base_tip) |tip| tip.point.slot else null);
    }

    pub fn primeBaseUtxos(self: *ChainDB, entries: []const UtxoEntry) !u32 {
        return self.ledger.primeUtxos(entries);
    }

    pub fn isLedgerValidationEnabled(self: *const ChainDB) bool {
        return self.ledger_validation_enabled;
    }

    pub fn setProtocolParams(self: *ChainDB, pp: rules.ProtocolParams) void {
        self.protocol_params = pp;
    }

    pub fn getProtocolParams(self: *const ChainDB) rules.ProtocolParams {
        return self.protocol_params;
    }

    pub fn setConsensusParams(self: *ChainDB, slots_per_kes_period: u64, max_kes_evolutions: u32) void {
        self.slots_per_kes_period = slots_per_kes_period;
        self.max_kes_evolutions = max_kes_evolutions;
    }

    pub fn configureShelleyGovernanceTracking(
        self: *ChainDB,
        config: protocol_update.GovernanceConfig,
    ) !void {
        if (!self.ledger.hasGenesisDelegations()) {
            for (config.initial_genesis_delegations) |delegation| {
                try self.ledger.importGenesisDelegation(delegation.genesis, .{
                    .delegate = delegation.delegate,
                    .vrf = delegation.vrf,
                });
            }
        }
        if (self.shelley_governance_config) |*existing| {
            existing.deinit(self.allocator);
        }
        self.governance_state.deinit(self.allocator);
        self.governance_state = .{};
        self.governance_state.setCurrentEpoch(types.slotToEpoch(self.tip_slot, config.epoch_length));
        self.praos_epoch_length = config.epoch_length;
        self.praos_era_start_slot = config.era_start_slot;
        self.praos_stability_window = config.stability_window;
        self.praos_randomness_stabilisation_window = if (config.randomness_stabilisation_window > 0)
            config.randomness_stabilisation_window
        else
            config.stability_window;
        self.praos_initial_nonce = config.initial_nonce;
        self.praos_extra_entropy = config.extra_entropy;
        self.praos_active_slot_coeff = .{
            .numerator = config.reward_params.active_slot_coeff.numerator,
            .denominator = config.reward_params.active_slot_coeff.denominator,
        };
        self.shelley_governance_config = config;
    }

    /// Shelley-era epoch for a slot, accounting for the era start offset.
    fn praosSlotToEpoch(self: *const ChainDB, slot: types.SlotNo) types.EpochNo {
        if (slot < self.praos_era_start_slot) return 0;
        return (slot - self.praos_era_start_slot) / self.praos_epoch_length;
    }

    fn praosEpochFirstSlot(self: *const ChainDB, epoch: types.EpochNo) types.SlotNo {
        return self.praos_era_start_slot + epoch * self.praos_epoch_length;
    }

    pub fn attachPraosState(self: *ChainDB, state: praos.PraosState) void {
        self.praos_state = state;
        self.base_praos_state = state;
        self.praos_tracking_ready = true;
    }

    pub fn getPraosState(self: *const ChainDB) praos.PraosState {
        return self.praos_state;
    }

    pub fn isPraosTrackingReady(self: *const ChainDB) bool {
        return self.praos_tracking_ready;
    }

    pub fn getOcertCounters(self: *const ChainDB) *const std.AutoHashMap(types.KeyHash, u64) {
        return &self.ocert_counters;
    }

    pub fn attachOcertCounters(self: *ChainDB, counters: []const OcertCounterEntry) void {
        for (counters) |entry| {
            self.ocert_counters.put(entry.issuer, entry.counter) catch continue;
        }
    }

    pub const OcertCounterEntry = struct {
        issuer: types.KeyHash,
        counter: u64,
    };

    /// Seed the ChainDB tip from an external snapshot tip.
    /// This allows volatile blocks fetched after a Mithril snapshot to extend
    /// the known chain without pretending we already restored the ledger state.
    pub fn attachSnapshotTip(self: *ChainDB, point: Point, block_no: BlockNo) !void {
        if (self.current_chain.items.len > 0) return error.ChainNotEmpty;
        if (self.tip_block_no > 0 or self.base_tip != null) return error.ChainNotEmpty;

        self.base_tip = .{ .point = point, .block_no = block_no };
        self.tip_slot = point.slot;
        self.tip_hash = point.hash;
        self.tip_block_no = block_no;
        self.ledger_validation_enabled = false;
        self.ledger_ready = false;
        if (self.shelley_governance_config) |*config| {
            protocol_update.setCurrentEpochFromSlot(config, &self.governance_state, point.slot);
        }
    }

    fn validateConsensusPrereqs(
        self: *const ChainDB,
        block: *const block_mod.Block,
        praos_state: *const praos.PraosState,
    ) !void {
        if (block.era == .byron) return;

        const issuer = header_validation.poolKeyHash(block.header.issuer_vkey);
        const expected_vrf_key_hash = self.ledger.lookupIssuerVrfKeyHash(issuer) orelse {
            return error.VRFKeyUnknown;
        };
        const current_counter = self.ocert_counters.get(issuer) orelse 0;
        const next_counter = block.header.opcert_sequence_no orelse return error.OCertInvalidSignature;
        try header_validation.validateExpectedVRFKeyHash(&block.header, expected_vrf_key_hash);
        try header_validation.validateOperationalCertificateAndKes(
            &block.header,
            block.header.slot,
            self.slots_per_kes_period,
            self.max_kes_evolutions,
        );
        try header_validation.validateOperationalCertificateCounter(current_counter, next_counter);

        if (self.ledger.getStakeSnapshots().getActiveDistribution()) |distribution| {
            if (distribution.getPool(issuer)) |pool| {
                try header_validation.validateVrfProofsAndLeaderValue(
                    &block.header,
                    praos_state.epoch_nonce,
                    pool.active_stake,
                    pool.total_stake,
                    self.praos_active_slot_coeff,
                );
                return;
            }
        }

        if (self.ledger.isGenesisDelegateIssuer(issuer)) {
            try header_validation.validateVrfProofsOnly(
                &block.header,
                praos_state.epoch_nonce,
            );
        }
    }

    /// Add a block to the chain database.
    /// First validates it's not a duplicate, then stores in volatile DB.
    pub fn addBlock(self: *ChainDB, hash: HeaderHash, block_data: []const u8, slot: SlotNo, block_no: BlockNo, prev_hash: ?HeaderHash) !AddBlockResult {
        // Check if already known
        if (self.@"volatile".getBlock(hash) != null) return .already_known;
        if (self.immutable.getBlock(hash) catch null != null) return .already_known;

        var extends_current_chain = false;
        if (self.tip_block_no == 0 and self.base_tip == null and self.current_chain.items.len == 0) {
            extends_current_chain = true;
        } else if (prev_hash) |ph| {
            extends_current_chain = std.mem.eql(u8, &ph, &self.tip_hash) and block_no > self.tip_block_no;
        }

        if (!extends_current_chain) {
            try self.@"volatile".putBlock(hash, block_data, slot, block_no, prev_hash);
            return .added_to_fork;
        }

        const needs_block_parse = self.ledger_validation_enabled or self.shelley_governance_config != null;
        var parsed_block: ?block_mod.Block = null;
        if (needs_block_parse) {
            parsed_block = block_mod.parseBlock(block_data) catch |err| {
                if (!builtin.is_test) {
                    std.debug.print("ChainDB validation failed to parse block {}: {}\n", .{ block_no, err });
                }
                return .invalid;
            };
        }

        var governance_snapshot: ?protocol_update.GovernanceSnapshot = null;
        errdefer {
            if (governance_snapshot) |*snapshot| snapshot.deinit(self.allocator);
        }
        if (self.shelley_governance_config != null) {
            governance_snapshot = try self.governance_state.cloneSnapshot(self.allocator, self.protocol_params);
        }

        if (self.shelley_governance_config) |*config| {
            try protocol_update.advanceToSlot(
                self.allocator,
                config,
                &self.governance_state,
                &self.protocol_params,
                slot,
            );
        }

        var ledger_diffs_applied: u32 = 0;
        var ocert_counter_change: ?OCertCounterChange = null;
        var praos_snapshot: ?praos.PraosState = null;
        var pending_praos_state: ?praos.PraosState = null;
        var apply_result: ?ledger_apply.ApplyResult = null;
        defer {
            if (apply_result) |*result| result.deinit(self.allocator);
        }
        if (self.ledger_validation_enabled) {
            if (!self.ledger_ready) {
                if (!builtin.is_test) {
                    std.debug.print("ChainDB validation rejected block {} at slot {}: ledger not ready\n", .{ block_no, slot });
                }
                if (governance_snapshot) |*snapshot| {
                    try self.governance_state.restoreSnapshot(self.allocator, snapshot);
                    self.protocol_params = snapshot.active_params;
                }
                return .invalid;
            }

            if (parsed_block) |*block| {
                if (block.era == .conway) {
                    self.ledger.setPointerInstantStakeEnabled(false);
                }

                var next_praos_state = self.praos_state;
                var praos_ready_for_block = self.praos_tracking_ready;
                if (!praos_ready_for_block and self.shelley_governance_config != null) {
                    next_praos_state = praos.PraosState.initWithNonce(self.praos_initial_nonce);
                    praos_ready_for_block = true;
                }
                if (praos_ready_for_block and self.shelley_governance_config != null) {
                    const current_epoch = self.praosSlotToEpoch(self.tip_slot);
                    const block_epoch = self.praosSlotToEpoch(block.header.slot);
                    const is_new_epoch = block_epoch > current_epoch;
                    switch (block.era) {
                        .shelley, .allegra, .mary, .alonzo => next_praos_state.tickTpraos(is_new_epoch, self.praos_extra_entropy),
                        .babbage, .conway => next_praos_state.tickPraos(is_new_epoch),
                        else => {},
                    }
                }

                self.validateConsensusPrereqs(block, &next_praos_state) catch |err| {
                    // Treat VRFLeaderValueTooBig and VRFKeyUnknown as non-fatal:
                    // our Mithril snapshot pool registry is inherently stale — pools
                    // may have registered or rotated VRF keys since the snapshot.
                    // The block was already validated by the producing node.
                    if (err == error.VRFLeaderValueTooBig or err == error.VRFKeyUnknown) {
                        self.vrf_threshold_warnings += 1;
                    } else {
                        if (!builtin.is_test) {
                            std.debug.print("ChainDB consensus rejected block {}: {} era={s} leader_vrf_present={}\n", .{
                                block_no, err, @tagName(block.era),
                                block.header.leader_vrf_raw != null,
                            });
                        }
                        if (governance_snapshot) |*snapshot| {
                            try self.governance_state.restoreSnapshot(self.allocator, snapshot);
                            self.protocol_params = snapshot.active_params;
                        }
                        return .invalid;
                    }
                };

                if (praos_ready_for_block and self.shelley_governance_config != null and block.era != .byron) {
                    const nonce_output = header_validation.extractBlockNonceOutput(&block.header) catch |err| {
                        if (!builtin.is_test) {
                            std.debug.print("ChainDB nonce extraction failed for block {}: {}\n", .{ block_no, err });
                        }
                        if (governance_snapshot) |*snapshot| {
                            try self.governance_state.restoreSnapshot(self.allocator, snapshot);
                            self.protocol_params = snapshot.active_params;
                        }
                        return .invalid;
                    };
                    praos_snapshot = if (self.praos_tracking_ready) self.praos_state else null;
                    const block_nonce = switch (block.era) {
                        .babbage, .conway => praos.praosNonceFromVrfOutput(nonce_output),
                        else => praos.nonceFromVrfOutput(nonce_output),
                    };
                    // Babbage uses 3k/f (backwards compat), Conway+ uses 4k/f.
                    const nonce_window = switch (block.era) {
                        .conway => self.praos_randomness_stabilisation_window,
                        else => self.praos_stability_window,
                    };
                    next_praos_state.updateWithBlock(
                        block.header.slot,
                        block.header.prev_hash,
                        block_nonce,
                        self.praos_epoch_length,
                        nonce_window,
                        self.praos_era_start_slot,
                    );
                    pending_praos_state = next_praos_state;
                }
            }

            ledger_diffs_applied = try self.applyEpochBoundaryEffects(slot, hash);
            ledger_diffs_applied += try self.applyGenesisDelegationEffects(slot, hash);
            apply_result = ledger_apply.applyBlock(
                self.allocator,
                &self.ledger,
                &(parsed_block orelse unreachable),
                self.protocol_params,
                if (self.shelley_governance_config) |*config| config else null,
            ) catch |err| {
                if (!builtin.is_test) {
                    std.debug.print("ChainDB validation apply failed for block {}: {}\n", .{ block_no, err });
                }
                if (ledger_diffs_applied > 0) {
                    try self.ledger.rollback(ledger_diffs_applied);
                }
                if (governance_snapshot) |*snapshot| {
                    try self.governance_state.restoreSnapshot(self.allocator, snapshot);
                    self.protocol_params = snapshot.active_params;
                }
                return .invalid;
            };

            if (apply_result.?.txs_failed > 0) {
                if (!builtin.is_test) {
                    std.debug.print("ChainDB validation rejected block {}: {} txs failed, {} txs applied\n", .{
                        block_no,
                        apply_result.?.txs_failed,
                        apply_result.?.txs_applied,
                    });
                }
                ledger_diffs_applied += apply_result.?.txs_applied;
                if (ledger_diffs_applied > 0) {
                    try self.ledger.rollback(ledger_diffs_applied);
                }
                if (governance_snapshot) |*snapshot| {
                    try self.governance_state.restoreSnapshot(self.allocator, snapshot);
                    self.protocol_params = snapshot.active_params;
                }
                return .invalid;
            }
            // Parse-skipped txs are our limitation (unsupported CBOR features),
            // not invalid blocks. Log but don't reject.
            if (apply_result.?.txs_skipped > 0 and !builtin.is_test) {
                std.debug.print("ChainDB block {}: {} txs skipped (parse limitation), {} applied\n", .{
                    block_no,
                    apply_result.?.txs_skipped,
                    apply_result.?.txs_applied,
                });
            }

            ledger_diffs_applied += apply_result.?.txs_applied;
        }

        if (self.shelley_governance_config) |*config| {
            if (apply_result) |*result| {
                for (result.protocol_updates) |*update| {
                    protocol_update.stageTxUpdate(
                        self.allocator,
                        config,
                        &self.governance_state,
                        self.protocol_params,
                        slot,
                        update,
                    ) catch |err| {
                        if (!builtin.is_test) {
                            std.debug.print("ChainDB governance rejected block {}: {}\n", .{ block_no, err });
                        }
                        if (ledger_diffs_applied > 0) {
                            try self.ledger.rollback(ledger_diffs_applied);
                        }
                        if (governance_snapshot) |*snapshot| {
                            try self.governance_state.restoreSnapshot(self.allocator, snapshot);
                            self.protocol_params = snapshot.active_params;
                        }
                        return .invalid;
                    };
                }
            }
        }

        if (self.ledger_validation_enabled) {
            if (apply_result) |*result| {
                if (try self.ledger.buildFeePotDiff(self.allocator, slot, hash, result.total_fees)) |diff| {
                    try self.ledger.applyDiff(diff);
                    ledger_diffs_applied += 1;
                }
            }
            if (parsed_block) |*block| {
                if (block.era != .byron) {
                    const pool = header_validation.poolKeyHash(block.header.issuer_vkey);
                    if (try self.ledger.buildCurrentEpochBlocksMadeDiff(self.allocator, slot, hash, pool)) |diff| {
                        try self.ledger.applyDiff(diff);
                        ledger_diffs_applied += 1;
                    }
                }
            }
        }

        try self.@"volatile".putBlock(hash, block_data, slot, block_no, prev_hash);
        errdefer if (ocert_counter_change) |change| self.restoreOcertCounter(change);

        if (self.ledger_validation_enabled) {
            if (parsed_block) |*block| {
                if (block.era != .byron) {
                    const issuer = header_validation.poolKeyHash(block.header.issuer_vkey);
                    const sequence_no = block.header.opcert_sequence_no orelse unreachable;
                    const previous = self.ocert_counters.get(issuer);
                    try self.ocert_counters.put(issuer, sequence_no);
                    ocert_counter_change = .{
                        .issuer = issuer,
                        .previous = previous,
                    };
                }
            }
        }
        if (pending_praos_state) |next_state| {
            self.praos_state = next_state;
            self.praos_tracking_ready = true;
        }
        self.tip_slot = slot;
        self.tip_hash = hash;
        self.tip_block_no = block_no;
        try self.current_chain.append(self.allocator, .{
            .point = .{ .slot = slot, .hash = hash },
            .block_no = block_no,
            .ledger_diffs_applied = ledger_diffs_applied,
            .governance_snapshot = governance_snapshot,
            .ocert_counter_change = ocert_counter_change,
            .praos_snapshot = praos_snapshot,
        });
        governance_snapshot = null;

        return .added_to_current_chain;
    }

    /// Promote finalized blocks from volatile to immutable.
    /// Blocks deeper than k from the tip are considered final.
    pub fn promoteFinalized(self: *ChainDB) !u32 {
        const vol = &self.@"volatile";
        if (self.tip_block_no <= self.security_param or self.current_chain.items.len == 0) {
            return 0;
        }

        const finalized_block_no = self.tip_block_no - self.security_param;
        var promoted_len: usize = 0;
        while (promoted_len < self.current_chain.items.len and
            self.current_chain.items[promoted_len].block_no <= finalized_block_no)
        {
            promoted_len += 1;
        }
        if (promoted_len == 0) return 0;

        for (self.current_chain.items[0..promoted_len]) |entry| {
            const info = vol.getBlock(entry.point.hash) orelse return error.MissingVolatileBlock;
            try self.immutable.appendBlock(info.hash, info.data, info.slot, info.block_no);
        }

        const last_promoted = self.current_chain.items[promoted_len - 1];
        self.base_tip = .{
            .point = last_promoted.point,
            .block_no = last_promoted.block_no,
        };

        for (self.current_chain.items[0..promoted_len]) |*entry| {
            if (entry.governance_snapshot) |*snapshot| snapshot.deinit(self.allocator);
        }

        const remaining = self.current_chain.items.len - promoted_len;
        std.mem.copyForwards(
            CurrentChainEntry,
            self.current_chain.items[0..remaining],
            self.current_chain.items[promoted_len..],
        );
        self.current_chain.items.len = remaining;
        self.base_praos_state = if (remaining > 0)
            self.current_chain.items[0].praos_snapshot
        else if (self.praos_tracking_ready)
            self.praos_state
        else
            null;

        // GC promoted blocks from volatile.
        // Window must be in slot-space: stabilityWindow = 3k/f ≈ 129600 slots on preprod.
        // Keep 2x that to be safe (matches Haskell's conservative GC window).
        if (self.tip_block_no > self.security_param) {
            const min_slot = self.tip_slot -| (self.praos_stability_window * 2);
            try vol.garbageCollect(min_slot);
        }

        return @intCast(promoted_len);
    }

    /// Get current tip.
    pub fn getTip(self: *const ChainDB) struct { slot: SlotNo, hash: HeaderHash, block_no: BlockNo } {
        return .{
            .slot = self.tip_slot,
            .hash = self.tip_hash,
            .block_no = self.tip_block_no,
        };
    }

    pub fn rollbackToPoint(self: *ChainDB, point: ?Point) !u32 {
        var rolled_back: u32 = 0;

        while (self.current_chain.items.len > 0) {
            const last = self.current_chain.items[self.current_chain.items.len - 1];
            if (point) |target| {
                if (Point.eql(last.point, target)) break;
            }

            const removed = self.current_chain.pop().?;
            if (self.ledger_validation_enabled and removed.ledger_diffs_applied > 0) {
                try self.ledger.rollback(removed.ledger_diffs_applied);
            }
            var mutable_removed = removed;
            if (mutable_removed.praos_snapshot) |snapshot| {
                self.praos_state = snapshot;
                self.praos_tracking_ready = true;
            } else if (self.current_chain.items.len == 0) {
                self.praos_state = praos.PraosState.initWithNonce(self.praos_initial_nonce);
                self.praos_tracking_ready = false;
            }
            if (mutable_removed.ocert_counter_change) |change| {
                self.restoreOcertCounter(change);
            }
            if (mutable_removed.governance_snapshot) |*snapshot| {
                try self.governance_state.restoreSnapshot(self.allocator, snapshot);
                self.protocol_params = snapshot.active_params;
                snapshot.deinit(self.allocator);
            }
            rolled_back += 1;
        }

        if (self.current_chain.items.len > 0) {
            const last = self.current_chain.items[self.current_chain.items.len - 1];
            self.tip_slot = last.point.slot;
            self.tip_hash = last.point.hash;
            self.tip_block_no = last.block_no;
            self.ledger_ready = self.ledger_validation_enabled;
            return rolled_back;
        }

        // current_chain is empty after rollback. Decide where to set the tip.
        if (point) |target| {
            // The relay told us to roll back to a specific point. Trust it.
            // This handles the common case where the relay skips ahead past our
            // snapshot tip to a more recent point.
            self.tip_slot = target.slot;
            self.tip_hash = target.hash;
            // Estimate block_no from base_tip if available.
            self.tip_block_no = if (self.base_tip) |base| base.block_no else 0;
            if (self.base_praos_state) |snapshot| {
                self.praos_state = snapshot;
                self.praos_tracking_ready = true;
            } else {
                self.praos_state = praos.PraosState.initWithNonce(self.praos_initial_nonce);
                self.praos_tracking_ready = false;
            }
            self.ledger_ready = self.ledger_validation_enabled;
            return rolled_back;
        }

        // Rollback to genesis (point == null)
        self.tip_slot = 0;
        self.tip_hash = [_]u8{0} ** 32;
        self.tip_block_no = 0;
        self.base_tip = null;
        self.base_praos_state = null;
        self.ocert_counters.clearRetainingCapacity();
        self.praos_state = praos.PraosState.initWithNonce(self.praos_initial_nonce);
        self.praos_tracking_ready = false;
        self.ledger_ready = false;
        return rolled_back;
    }

    fn restoreOcertCounter(self: *ChainDB, change: OCertCounterChange) void {
        if (change.previous) |previous| {
            self.ocert_counters.put(change.issuer, previous) catch unreachable;
        } else {
            _ = self.ocert_counters.remove(change.issuer);
        }
    }

    /// Total blocks across volatile + immutable.
    pub fn totalBlocks(self: *const ChainDB) usize {
        return self.@"volatile".count() + self.immutable.blockCount();
    }

    fn applyEpochBoundaryEffects(
        self: *ChainDB,
        slot: SlotNo,
        block_hash: HeaderHash,
    ) !u32 {
        const config = self.shelley_governance_config orelse return 0;

        const current_epoch = types.slotToEpoch(self.tip_slot, config.epoch_length);
        const target_epoch = types.slotToEpoch(slot, config.epoch_length);
        if (target_epoch <= current_epoch) return 0;

        var applied: u32 = 0;
        var epoch = current_epoch + 1;
        while (epoch <= target_epoch) : (epoch += 1) {
            // 1. Distribute rewards from the "go" snapshot
            if (try self.ledger.buildEpochRewardDiff(
                self.allocator,
                slot,
                block_hash,
                config.reward_params,
                config.epoch_length,
            )) |diff| {
                try self.ledger.applyDiff(diff);
                applied += 1;
            }

            // 2. Realize or drop pending MIR updates before epoch state rotation.
            if (try self.ledger.buildEpochMirDiff(self.allocator, slot, block_hash)) |diff| {
                try self.ledger.applyDiff(diff);
                applied += 1;
            }

            // 3. Rotate stake snapshots: go ← set ← mark ← new
            self.ledger.rotateStakeSnapshots(epoch);

            if (try self.ledger.buildEpochBlocksMadeShiftDiff(self.allocator, slot, block_hash)) |diff| {
                try self.ledger.applyDiff(diff);
                applied += 1;
            }

            // 4. Roll the fee pot into the next snapshot epoch
            if (try self.ledger.buildEpochFeeRolloverDiff(self.allocator, slot, block_hash)) |diff| {
                try self.ledger.applyDiff(diff);
                applied += 1;
            }

            // 5. Reap retiring pools
            if (try self.ledger.buildPoolReapDiff(self.allocator, slot, block_hash, epoch)) |diff| {
                try self.ledger.applyDiff(diff);
                applied += 1;
            }
        }

        return applied;
    }

    fn applyGenesisDelegationEffects(
        self: *ChainDB,
        slot: SlotNo,
        block_hash: HeaderHash,
    ) !u32 {
        if (try self.ledger.buildGenesisDelegationAdoptionDiff(self.allocator, slot, block_hash)) |diff| {
            try self.ledger.applyDiff(diff);
            return 1;
        }
        return 0;
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "chaindb: open and close" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb", 2160);
    defer db.close();
    try std.testing.expectEqual(@as(usize, 0), db.totalBlocks());
}

test "chaindb: add blocks extends tip" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb2") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb2") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb2", 2160);
    defer db.close();

    // Add genesis-like block
    const hash0 = Blake2b256.hash("block0");
    const result1 = try db.addBlock(hash0, "block0", 0, 0, null);
    try std.testing.expect(result1 == .added_to_current_chain);

    // Add next block (extends chain)
    const hash1 = Blake2b256.hash("block1");
    const result2 = try db.addBlock(hash1, "block1", 10, 1, hash0);
    try std.testing.expect(result2 == .added_to_current_chain);

    try std.testing.expectEqual(@as(BlockNo, 1), db.getTip().block_no);
    try std.testing.expectEqual(@as(SlotNo, 10), db.getTip().slot);
}

test "chaindb: attach snapshot tip and extend from anchor" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-anchor") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-anchor") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb-anchor", 2160);
    defer db.close();

    const anchor_hash = Blake2b256.hash("snapshot-tip");
    try db.attachSnapshotTip(.{ .slot = 100, .hash = anchor_hash }, 50);

    const child_hash = Blake2b256.hash("child");
    const result = try db.addBlock(child_hash, "child", 110, 51, anchor_hash);
    try std.testing.expect(result == .added_to_current_chain);
    try std.testing.expectEqual(@as(BlockNo, 51), db.getTip().block_no);
    try std.testing.expectEqual(@as(SlotNo, 110), db.getTip().slot);
}

test "chaindb: rollback rewinds current chain tip" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-rollback") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-rollback") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb-rollback", 2160);
    defer db.close();

    const hash0 = Blake2b256.hash("block0");
    const hash1 = Blake2b256.hash("block1");
    const hash2 = Blake2b256.hash("block2");
    _ = try db.addBlock(hash0, "block0", 0, 0, null);
    _ = try db.addBlock(hash1, "block1", 10, 1, hash0);
    _ = try db.addBlock(hash2, "block2", 20, 2, hash1);

    const rolled_back = try db.rollbackToPoint(.{ .slot = 10, .hash = hash1 });
    try std.testing.expectEqual(@as(u32, 1), rolled_back);
    try std.testing.expectEqual(@as(BlockNo, 1), db.getTip().block_no);
    try std.testing.expectEqual(@as(SlotNo, 10), db.getTip().slot);
}

test "chaindb: promote finalized uses ordered current-chain prefix" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-test-chaindb-promote";
    const Encoder = @import("../cbor/encoder.zig").Encoder;

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    var tx_array_enc = Encoder.init(allocator);
    defer tx_array_enc.deinit();
    try tx_array_enc.encodeArrayLen(0);
    const tx_bodies_raw = try tx_array_enc.toOwnedSlice();
    defer allocator.free(tx_bodies_raw);

    const block0_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        0,
        0,
        null,
        [_]u8{0x31} ** 32,
        [_]u8{0x32} ** 32,
        [_]u8{0x33} ** 32,
        0,
        [_]u8{0x34} ** 32,
    );
    defer allocator.free(block0_data);
    const block0 = try block_mod.parseBlock(block0_data);
    const hash0 = block0.hash();

    const block1_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        1,
        10,
        hash0,
        [_]u8{0x41} ** 32,
        [_]u8{0x42} ** 32,
        [_]u8{0x43} ** 32,
        0,
        [_]u8{0x44} ** 32,
    );
    defer allocator.free(block1_data);
    const block1 = try block_mod.parseBlock(block1_data);
    const hash1 = block1.hash();

    const fork_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        1,
        11,
        hash0,
        [_]u8{0x51} ** 32,
        [_]u8{0x52} ** 32,
        [_]u8{0x53} ** 32,
        0,
        [_]u8{0x54} ** 32,
    );
    defer allocator.free(fork_data);
    const fork_block = try block_mod.parseBlock(fork_data);
    const fork_hash = fork_block.hash();

    const block2_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        2,
        20,
        hash1,
        [_]u8{0x61} ** 32,
        [_]u8{0x62} ** 32,
        [_]u8{0x63} ** 32,
        0,
        [_]u8{0x64} ** 32,
    );
    defer allocator.free(block2_data);
    const block2 = try block_mod.parseBlock(block2_data);
    const hash2 = block2.hash();

    {
        var db = try ChainDB.open(allocator, path, 1);
        defer db.close();

        try std.testing.expectEqual(AddBlockResult.added_to_current_chain, try db.addBlock(hash0, block0_data, block0.header.slot, block0.header.block_no, block0.header.prev_hash));
        try std.testing.expectEqual(AddBlockResult.added_to_current_chain, try db.addBlock(hash1, block1_data, block1.header.slot, block1.header.block_no, block1.header.prev_hash));
        try std.testing.expectEqual(AddBlockResult.added_to_fork, try db.addBlock(fork_hash, fork_data, fork_block.header.slot, fork_block.header.block_no, fork_block.header.prev_hash));
        try std.testing.expectEqual(AddBlockResult.added_to_current_chain, try db.addBlock(hash2, block2_data, block2.header.slot, block2.header.block_no, block2.header.prev_hash));

        const promoted = try db.promoteFinalized();
        try std.testing.expectEqual(@as(u32, 2), promoted);
        try std.testing.expectEqual(@as(usize, 1), db.current_chain.items.len);
        try std.testing.expectEqual(hash2, db.current_chain.items[0].point.hash);
        try std.testing.expectEqual(@as(BlockNo, 1), db.base_tip.?.block_no);
        try std.testing.expectEqual(hash1, db.base_tip.?.point.hash);
        try std.testing.expectEqual(@as(BlockNo, 2), db.getTip().block_no);
        try std.testing.expectEqual(@as(usize, 2), db.immutable.blockCount());
        const promoted0 = (try db.immutable.getBlock(hash0)).?;
        defer allocator.free(promoted0);
        const promoted1 = (try db.immutable.getBlock(hash1)).?;
        defer allocator.free(promoted1);
        try std.testing.expectEqualSlices(u8, block0_data, promoted0);
        try std.testing.expectEqualSlices(u8, block1_data, promoted1);
        try std.testing.expect((try db.immutable.getBlock(fork_hash)) == null);
    }

    var reopened = try ChainDB.open(allocator, path, 1);
    defer reopened.close();
    try std.testing.expectEqual(@as(BlockNo, 1), reopened.getTip().block_no);
    try std.testing.expectEqual(hash1, reopened.getTip().hash);
}

test "chaindb: ledger validation rejects invalid current-chain blocks" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-invalid") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-invalid") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb-invalid", 2160);
    defer db.close();

    try db.enableLedgerValidation();

    const hash = Blake2b256.hash("not a real block");
    const result = try db.addBlock(hash, "not a real block", 1, 1, null);
    try std.testing.expect(result == .invalid);
    try std.testing.expectEqual(@as(usize, 0), db.totalBlocks());
    try std.testing.expectEqual(@as(BlockNo, 0), db.getTip().block_no);
}

fn buildSignedShelleyTestBlock(
    allocator: Allocator,
    tx_bodies_raw: []const u8,
    block_no: BlockNo,
    slot: SlotNo,
    prev_hash: ?HeaderHash,
    issuer_seed: [32]u8,
    kes_seed: [32]u8,
    vrf_seed: [32]u8,
    opcert_sequence_no: u64,
    body_hash: [32]u8,
) ![]u8 {
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    const Ed25519 = @import("../crypto/ed25519.zig").Ed25519;
    const LiveKES = @import("../crypto/kes_sum.zig").KES;
    const VRF = @import("../crypto/vrf.zig").VRF;
    const opcert_mod = @import("../crypto/opcert.zig");
    const leader = @import("../consensus/leader.zig");

    const cold_kp = try Ed25519.keyFromSeed(issuer_seed);
    const kes_kp = try LiveKES.generate(kes_seed);
    const vrf_kp = try VRF.keyFromSeed(vrf_seed);
    const current_kes_period: u32 = @intCast(slot / types.mainnet.slots_per_kes_period);
    const vrf_result = try VRF.prove(&leader.makeSeed(leader.seedEta(), slot, .neutral), vrf_kp.sk);
    const opcert = try opcert_mod.OperationalCert.create(
        kes_kp.vk,
        opcert_sequence_no,
        current_kes_period,
        cold_kp.sk,
    );

    var header_body_enc = Encoder.init(allocator);
    defer header_body_enc.deinit();
    try header_body_enc.encodeArrayLen(10);
    try header_body_enc.encodeUint(block_no);
    try header_body_enc.encodeUint(slot);
    if (prev_hash) |hash| {
        try header_body_enc.encodeBytes(&hash);
    } else {
        try header_body_enc.encodeNull();
    }
    try header_body_enc.encodeBytes(&cold_kp.vk);
    try header_body_enc.encodeBytes(&vrf_kp.vk);
    try header_body_enc.encodeArrayLen(2);
    try header_body_enc.encodeBytes(&vrf_result.output);
    try header_body_enc.encodeBytes(&vrf_result.proof);
    try header_body_enc.encodeUint(tx_bodies_raw.len);
    try header_body_enc.encodeBytes(&body_hash);
    try header_body_enc.encodeArrayLen(4);
    try header_body_enc.encodeBytes(&opcert.hot_vkey);
    try header_body_enc.encodeUint(opcert.sequence_number);
    try header_body_enc.encodeUint(opcert.kes_period);
    try header_body_enc.encodeBytes(&opcert.cold_key_signature);
    try header_body_enc.encodeArrayLen(2);
    try header_body_enc.encodeUint(1);
    try header_body_enc.encodeUint(0);
    const header_body_raw = try header_body_enc.toOwnedSlice();
    defer allocator.free(header_body_raw);

    const kes_sig = try LiveKES.sign(current_kes_period, header_body_raw, &kes_kp.sk);

    var header_enc = Encoder.init(allocator);
    defer header_enc.deinit();
    try header_enc.encodeArrayLen(2);
    try header_enc.writeRaw(header_body_raw);
    try header_enc.encodeBytes(&kes_sig);
    const header_raw = try header_enc.toOwnedSlice();
    defer allocator.free(header_raw);

    var block_enc = Encoder.init(allocator);
    defer block_enc.deinit();
    try block_enc.encodeArrayLen(4);
    try block_enc.writeRaw(header_raw);
    try block_enc.writeRaw(tx_bodies_raw);
    try block_enc.encodeArrayLen(0); // witnesses
    try block_enc.encodeMapLen(0); // auxiliary data
    return block_enc.toOwnedSlice();
}

test "chaindb: ledger validation applies a real block" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;

    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-validated") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-validated") catch {};

    const input = types.TxIn{ .tx_id = [_]u8{0x11} ** 32, .tx_ix = 0 };

    var tx_enc = Encoder.init(allocator);
    defer tx_enc.deinit();
    try tx_enc.encodeMapLen(3);
    try tx_enc.encodeUint(0);
    try tx_enc.encodeArrayLen(1);
    try tx_enc.encodeArrayLen(2);
    try tx_enc.encodeBytes(&input.tx_id);
    try tx_enc.encodeUint(input.tx_ix);
    try tx_enc.encodeUint(1);
    try tx_enc.encodeArrayLen(1);
    try tx_enc.encodeArrayLen(2);
    try tx_enc.encodeBytes(&([_]u8{0x61} ++ [_]u8{0xaa} ** 28));
    try tx_enc.encodeUint(1_000_000);
    try tx_enc.encodeUint(2);
    try tx_enc.encodeUint(200_000);
    const tx_raw = try tx_enc.toOwnedSlice();
    defer allocator.free(tx_raw);

    var tx_array_enc = Encoder.init(allocator);
    defer tx_array_enc.deinit();
    try tx_array_enc.encodeArrayLen(1);
    try tx_array_enc.writeRaw(tx_raw);
    const tx_bodies_raw = try tx_array_enc.toOwnedSlice();
    defer allocator.free(tx_bodies_raw);

    const block_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        1,
        42,
        null,
        [_]u8{0x22} ** 32,
        [_]u8{0x23} ** 32,
        [_]u8{0x33} ** 32,
        0,
        [_]u8{0x44} ** 32,
    );
    defer allocator.free(block_data);

    const block = try block_mod.parseBlock(block_data);

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb-validated", 2160);
    defer db.close();

    const issuer_pool = header_validation.poolKeyHash(block.header.issuer_vkey);
    const vrf_hash = Blake2b256.hash(&block.header.vrf_vkey);

    const seed_produced = try allocator.alloc(UtxoEntry, 1);
    seed_produced[0] = .{
        .tx_in = input,
        .value = 1_200_000,
        .raw_cbor = try allocator.dupe(u8, "seed"),
    };
    try db.ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = seed_produced,
    });
    try db.ledger.importPoolConfig(issuer_pool, .{
        .vrf_keyhash = vrf_hash,
        .pledge = 0,
        .cost = 0,
        .margin = .{ .numerator = 0, .denominator = 1 },
    });

    try db.enableLedgerValidation();

    const result = try db.addBlock(
        block.hash(),
        block_data,
        block.header.slot,
        block.header.block_no,
        block.header.prev_hash,
    );

    try std.testing.expect(result == .added_to_current_chain);
    try std.testing.expectEqual(@as(BlockNo, 1), db.getTip().block_no);
    try std.testing.expectEqual(@as(SlotNo, 42), db.getTip().slot);
    try std.testing.expectEqual(@as(usize, 1), db.current_chain.items.len);
    try std.testing.expectEqual(@as(u32, 3), db.current_chain.items[0].ledger_diffs_applied);
    try std.testing.expectEqual(@as(types.Coin, 200_000), db.ledger.getFeesBalance());
}

test "chaindb: ocert counter rejects stale sequence numbers" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;

    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-ocert-stale") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-ocert-stale") catch {};

    var tx_array_enc = Encoder.init(allocator);
    defer tx_array_enc.deinit();
    try tx_array_enc.encodeArrayLen(0);
    const tx_bodies_raw = try tx_array_enc.toOwnedSlice();
    defer allocator.free(tx_bodies_raw);

    const issuer_seed = [_]u8{0x91} ** 32;
    const vrf_vkey = [_]u8{0x93} ** 32;

    const block1_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        1,
        42,
        null,
        issuer_seed,
        [_]u8{0x92} ** 32,
        vrf_vkey,
        1,
        [_]u8{0x94} ** 32,
    );
    defer allocator.free(block1_data);
    const block1 = try block_mod.parseBlock(block1_data);

    const block2_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        2,
        43,
        block1.hash(),
        issuer_seed,
        [_]u8{0x95} ** 32,
        vrf_vkey,
        0,
        [_]u8{0x96} ** 32,
    );
    defer allocator.free(block2_data);
    const block2 = try block_mod.parseBlock(block2_data);

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb-ocert-stale", 2160);
    defer db.close();

    const issuer_pool = header_validation.poolKeyHash(block1.header.issuer_vkey);
    const vrf_hash = Blake2b256.hash(&block1.header.vrf_vkey);
    try db.ledger.importPoolConfig(issuer_pool, .{
        .vrf_keyhash = vrf_hash,
        .pledge = 0,
        .cost = 0,
        .margin = .{ .numerator = 0, .denominator = 1 },
    });
    try db.enableLedgerValidation();

    try std.testing.expectEqual(
        AddBlockResult.added_to_current_chain,
        try db.addBlock(block1.hash(), block1_data, block1.header.slot, block1.header.block_no, block1.header.prev_hash),
    );
    try std.testing.expectEqual(
        AddBlockResult.invalid,
        try db.addBlock(block2.hash(), block2_data, block2.header.slot, block2.header.block_no, block2.header.prev_hash),
    );
    try std.testing.expectEqual(@as(BlockNo, 1), db.getTip().block_no);
    try std.testing.expectEqual(@as(usize, 1), db.current_chain.items.len);
}

test "chaindb: rollback restores ocert counter state" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;

    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-ocert-rollback") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-ocert-rollback") catch {};

    var tx_array_enc = Encoder.init(allocator);
    defer tx_array_enc.deinit();
    try tx_array_enc.encodeArrayLen(0);
    const tx_bodies_raw = try tx_array_enc.toOwnedSlice();
    defer allocator.free(tx_bodies_raw);

    const issuer_seed = [_]u8{0xa1} ** 32;
    const vrf_vkey = [_]u8{0xa2} ** 32;

    const block1_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        1,
        42,
        null,
        issuer_seed,
        [_]u8{0xa3} ** 32,
        vrf_vkey,
        1,
        [_]u8{0xa4} ** 32,
    );
    defer allocator.free(block1_data);
    const block1 = try block_mod.parseBlock(block1_data);
    const hash1 = block1.hash();

    const block2_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        2,
        43,
        hash1,
        issuer_seed,
        [_]u8{0xa5} ** 32,
        vrf_vkey,
        2,
        [_]u8{0xa6} ** 32,
    );
    defer allocator.free(block2_data);
    const block2 = try block_mod.parseBlock(block2_data);

    const block3_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        2,
        44,
        hash1,
        issuer_seed,
        [_]u8{0xa7} ** 32,
        vrf_vkey,
        1,
        [_]u8{0xa8} ** 32,
    );
    defer allocator.free(block3_data);
    const block3 = try block_mod.parseBlock(block3_data);

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb-ocert-rollback", 2160);
    defer db.close();

    const issuer_pool = header_validation.poolKeyHash(block1.header.issuer_vkey);
    const vrf_hash = Blake2b256.hash(&block1.header.vrf_vkey);
    try db.ledger.importPoolConfig(issuer_pool, .{
        .vrf_keyhash = vrf_hash,
        .pledge = 0,
        .cost = 0,
        .margin = .{ .numerator = 0, .denominator = 1 },
    });
    try db.enableLedgerValidation();

    try std.testing.expectEqual(
        AddBlockResult.added_to_current_chain,
        try db.addBlock(hash1, block1_data, block1.header.slot, block1.header.block_no, block1.header.prev_hash),
    );
    try std.testing.expectEqual(
        AddBlockResult.added_to_current_chain,
        try db.addBlock(block2.hash(), block2_data, block2.header.slot, block2.header.block_no, block2.header.prev_hash),
    );
    try std.testing.expectEqual(@as(u32, 1), try db.rollbackToPoint(.{ .slot = block1.header.slot, .hash = hash1 }));
    try std.testing.expectEqual(
        AddBlockResult.added_to_current_chain,
        try db.addBlock(block3.hash(), block3_data, block3.header.slot, block3.header.block_no, block3.header.prev_hash),
    );
    try std.testing.expectEqual(@as(BlockNo, 2), db.getTip().block_no);
}

test "chaindb: epoch boundary reaps retiring pool" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;

    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-pool-reap") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-pool-reap") catch {};

    var tx_array_enc = Encoder.init(allocator);
    defer tx_array_enc.deinit();
    try tx_array_enc.encodeArrayLen(0);
    const tx_bodies_raw = try tx_array_enc.toOwnedSlice();
    defer allocator.free(tx_bodies_raw);

    const block_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        1,
        100,
        null,
        [_]u8{0x72} ** 32,
        [_]u8{0x73} ** 32,
        [_]u8{0x74} ** 32,
        0,
        [_]u8{0x75} ** 32,
    );
    defer allocator.free(block_data);

    const block = try block_mod.parseBlock(block_data);

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb-pool-reap", 2160);
    defer db.close();

    const issuer_pool = header_validation.poolKeyHash(block.header.issuer_vkey);
    const vrf_hash = Blake2b256.hash(&block.header.vrf_vkey);

    const pool = [_]u8{0x75} ** 28;
    const delegated_cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0x76} ** 28,
    };
    const reward_account = types.RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0x77} ** 28,
        },
    };

    try db.ledger.importStakeDeposit(reward_account.credential, rules.ProtocolParams.mainnet_defaults.key_deposit);
    try db.ledger.importPoolDeposit(pool, rules.ProtocolParams.mainnet_defaults.pool_deposit);
    try db.ledger.importPoolRewardAccount(pool, reward_account);
    try db.ledger.importPoolRetirement(pool, 1);
    try db.ledger.importStakePoolDelegation(delegated_cred, pool);
    try db.ledger.importPoolConfig(issuer_pool, .{
        .vrf_keyhash = vrf_hash,
        .pledge = 0,
        .cost = 0,
        .margin = .{ .numerator = 0, .denominator = 1 },
    });

    try db.configureShelleyGovernanceTracking(.{
        .epoch_length = 100,
        .stability_window = 10,
        .update_quorum = 1,
        .initial_nonce = praos.initialNonce(),
        .extra_entropy = .neutral,
        .decentralization_param = .{ .numerator = 0, .denominator = 1 },
        .reward_params = rewards_mod.RewardParams.mainnet_defaults,
        .initial_genesis_delegations = try allocator.alloc(protocol_update.GenesisDelegation, 0),
    });
    try db.enableLedgerValidation();

    const result = try db.addBlock(
        block.hash(),
        block_data,
        block.header.slot,
        block.header.block_no,
        block.header.prev_hash,
    );

    try std.testing.expect(result == .added_to_current_chain);
    try std.testing.expect(db.ledger.lookupPoolDeposit(pool) == null);
    try std.testing.expect(db.ledger.lookupPoolRewardAccount(pool) == null);
    try std.testing.expect(db.ledger.lookupPoolRetirement(pool) == null);
    try std.testing.expect(db.ledger.lookupStakePoolDelegation(delegated_cred) == null);
    try std.testing.expectEqual(@as(?types.Coin, rules.ProtocolParams.mainnet_defaults.pool_deposit), db.ledger.lookupRewardBalance(reward_account));
    try std.testing.expectEqual(@as(u32, 2), db.current_chain.items[0].ledger_diffs_applied);
}

test "chaindb: epoch boundary sends unclaimed pool refunds to treasury" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;

    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-pool-reap-treasury") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb-pool-reap-treasury") catch {};

    var tx_array_enc = Encoder.init(allocator);
    defer tx_array_enc.deinit();
    try tx_array_enc.encodeArrayLen(0);
    const tx_bodies_raw = try tx_array_enc.toOwnedSlice();
    defer allocator.free(tx_bodies_raw);

    const block_data = try buildSignedShelleyTestBlock(
        allocator,
        tx_bodies_raw,
        1,
        100,
        null,
        [_]u8{0x81} ** 32,
        [_]u8{0x82} ** 32,
        [_]u8{0x83} ** 32,
        0,
        [_]u8{0x84} ** 32,
    );
    defer allocator.free(block_data);

    const block = try block_mod.parseBlock(block_data);

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb-pool-reap-treasury", 2160);
    defer db.close();

    const issuer_pool = header_validation.poolKeyHash(block.header.issuer_vkey);
    const vrf_hash = Blake2b256.hash(&block.header.vrf_vkey);

    const pool = [_]u8{0x84} ** 28;
    const reward_account = types.RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0x85} ** 28,
        },
    };

    db.ledger.importTreasuryBalance(7);
    try db.ledger.importPoolDeposit(pool, rules.ProtocolParams.mainnet_defaults.pool_deposit);
    try db.ledger.importPoolRewardAccount(pool, reward_account);
    try db.ledger.importPoolRetirement(pool, 1);
    try db.ledger.importPoolConfig(issuer_pool, .{
        .vrf_keyhash = vrf_hash,
        .pledge = 0,
        .cost = 0,
        .margin = .{ .numerator = 0, .denominator = 1 },
    });

    try db.configureShelleyGovernanceTracking(.{
        .epoch_length = 100,
        .stability_window = 10,
        .update_quorum = 1,
        .initial_nonce = praos.initialNonce(),
        .extra_entropy = .neutral,
        .decentralization_param = .{ .numerator = 0, .denominator = 1 },
        .reward_params = rewards_mod.RewardParams.mainnet_defaults,
        .initial_genesis_delegations = try allocator.alloc(protocol_update.GenesisDelegation, 0),
    });
    try db.enableLedgerValidation();

    const result = try db.addBlock(
        block.hash(),
        block_data,
        block.header.slot,
        block.header.block_no,
        block.header.prev_hash,
    );

    try std.testing.expect(result == .added_to_current_chain);
    try std.testing.expectEqual(
        @as(types.Coin, 7 + rules.ProtocolParams.mainnet_defaults.pool_deposit),
        db.ledger.getTreasuryBalance(),
    );
    try std.testing.expect(db.ledger.lookupRewardBalance(reward_account) == null);
}

test "chaindb: duplicate block returns already_known" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb3") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb3") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb3", 2160);
    defer db.close();

    const hash0 = Blake2b256.hash("block0");
    _ = try db.addBlock(hash0, "block0", 0, 0, null);
    const result = try db.addBlock(hash0, "block0", 0, 0, null);
    try std.testing.expect(result == .already_known);
}

test "chaindb: fork block returns added_to_fork" {
    const allocator = std.testing.allocator;
    std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb4") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-chaindb4") catch {};

    var db = try ChainDB.open(allocator, "/tmp/kassadin-test-chaindb4", 2160);
    defer db.close();

    const hash0 = Blake2b256.hash("block0");
    _ = try db.addBlock(hash0, "block0", 0, 0, null);
    _ = try db.addBlock(Blake2b256.hash("block1a"), "block1a", 10, 1, hash0);

    // Fork: different block at same height, same parent
    const result = try db.addBlock(Blake2b256.hash("block1b"), "block1b", 11, 1, hash0);
    try std.testing.expect(result == .added_to_fork);

    try std.testing.expectEqual(@as(usize, 3), db.totalBlocks());
}
