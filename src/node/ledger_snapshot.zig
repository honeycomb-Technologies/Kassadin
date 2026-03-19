const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const block_mod = @import("../ledger/block.zig");
const certificates = @import("../ledger/certificates.zig");
const ledger_apply = @import("../ledger/apply.zig");
const rewards_mod = @import("../ledger/rewards.zig");
const rules = @import("../ledger/rules.zig");
const header_validation = @import("../consensus/header_validation.zig");
const stake_mod = @import("../ledger/stake.zig");
const runtime_control = @import("runtime_control.zig");
const types = @import("../types.zig");
const LedgerDB = @import("../storage/ledger.zig").LedgerDB;

pub const SlotNo = types.SlotNo;
pub const TxIn = types.TxIn;
pub const Coin = types.Coin;
pub const DeltaCoin = types.DeltaCoin;
pub const Network = types.Network;
pub const Credential = types.Credential;
pub const CredentialType = types.CredentialType;
pub const RewardAccount = types.RewardAccount;
pub const DRep = certificates.DRep;
pub const MIRPot = certificates.MIRPot;

const zero_margin = types.UnitInterval{ .numerator = 0, .denominator = 1 };

pub const LocalLedgerSnapshot = struct {
    slot: SlotNo,
    path: []u8,

    pub fn deinit(self: *LocalLedgerSnapshot, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

pub const LoadSnapshotResult = struct {
    slot: SlotNo,
    utxos_loaded: u64,
    reward_accounts_loaded: u64,
    stake_deposits_loaded: u64,
    stake_snapshot_mark_pools_loaded: u64,
    stake_snapshot_set_pools_loaded: u64,
    stake_snapshot_go_pools_loaded: u64,
};

pub const ReplayResult = struct {
    blocks_replayed: u64,
    txs_applied: u64,
    txs_failed: u64,
    start_chunk: u32,
};

pub fn findLatestSnapshotAtOrBefore(
    allocator: Allocator,
    ledger_root: []const u8,
    max_slot: SlotNo,
) !?LocalLedgerSnapshot {
    var dir = std.fs.cwd().openDir(ledger_root, .{ .iterate = true }) catch return null;
    defer dir.close();

    var best_slot: ?SlotNo = null;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        const slot = std.fmt.parseInt(SlotNo, entry.name, 10) catch continue;
        if (slot > max_slot) continue;
        if (best_slot != null and slot <= best_slot.?) continue;

        const tvar_path = try std.fmt.allocPrint(allocator, "{s}/{s}/tables/tvar", .{ ledger_root, entry.name });
        defer allocator.free(tvar_path);
        const meta_path = try std.fmt.allocPrint(allocator, "{s}/{s}/meta", .{ ledger_root, entry.name });
        defer allocator.free(meta_path);

        if (!fileExists(tvar_path) or !fileExists(meta_path)) continue;
        best_slot = slot;
    }

    const slot = best_slot orelse return null;
    return .{
        .slot = slot,
        .path = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ ledger_root, slot }),
    };
}

pub fn loadSnapshotIntoLedger(
    allocator: Allocator,
    ledger: *LedgerDB,
    snapshot: LocalLedgerSnapshot,
    network: Network,
) !LoadSnapshotResult {
    ledger.setRewardAccountNetwork(network);

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/meta", .{snapshot.path});
    defer allocator.free(meta_path);
    try validateSnapshotMetadata(allocator, meta_path);

    const tvar_path = try std.fmt.allocPrint(allocator, "{s}/tables/tvar", .{snapshot.path});
    defer allocator.free(tvar_path);

    var file = try std.fs.cwd().openFile(tvar_path, .{});
    defer file.close();

    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(&file_buf);
    var reader = &file_reader.interface;

    const top_len = try readCborContainerLen(reader, 4);
    if (top_len == null or top_len.? != 1) return error.InvalidSnapshotTables;

    const map_len = try readCborContainerLen(reader, 5);

    var key_buf: [34]u8 = undefined;
    var value_buf: std.ArrayList(u8) = .empty;
    defer value_buf.deinit(allocator);

    var loaded: u64 = 0;
    var remaining = map_len;

    while (true) {
        if (runtime_control.stopRequested()) return error.Interrupted;

        if (remaining) |*count| {
            if (count.* == 0) break;
            count.* -= 1;
        } else {
            const next = try reader.takeByte();
            if (next == 0xff) break;
            const key_len = try readCborBytesLenFromFirst(reader, next);
            if (key_len != key_buf.len) return error.InvalidPackedTxIn;
            try readExactly(reader, key_buf[0..]);

            const value_len = try readCborBytesLen(reader);
            try value_buf.resize(allocator, value_len);
            try readExactly(reader, value_buf.items);

            const tx_in = try parsePackedTxIn(&key_buf);
            const output = try parsePackedTxOutInfo(value_buf.items);
            try ledger.importUtxo(tx_in, output.coin, output.stake_credential, output.stake_pointer);
            loaded += 1;

            if (!builtin.is_test and loaded % 100_000 == 0) {
                std.debug.print("  Loaded {} snapshot UTxOs...\n", .{loaded});
            }
            continue;
        }

        const key_len = try readCborBytesLen(reader);
        if (key_len != key_buf.len) return error.InvalidPackedTxIn;
        try readExactly(reader, key_buf[0..]);

        const value_len = try readCborBytesLen(reader);
        try value_buf.resize(allocator, value_len);
        try readExactly(reader, value_buf.items);

        const tx_in = try parsePackedTxIn(&key_buf);
        const output = try parsePackedTxOutInfo(value_buf.items);
        try ledger.importUtxo(tx_in, output.coin, output.stake_credential, output.stake_pointer);
        loaded += 1;

        if (!builtin.is_test and loaded % 100_000 == 0) {
            std.debug.print("  Loaded {} snapshot UTxOs...\n", .{loaded});
        }
    }

    var state_import = SnapshotAccountImport{
        .reward_accounts_loaded = 0,
        .stake_deposits_loaded = 0,
        .stake_snapshot_mark_pools_loaded = 0,
        .stake_snapshot_set_pools_loaded = 0,
        .stake_snapshot_go_pools_loaded = 0,
    };
    const state_path = try std.fmt.allocPrint(allocator, "{s}/state", .{snapshot.path});
    defer allocator.free(state_path);
    if (fileExists(state_path)) {
        state_import = try importSnapshotAccountState(allocator, ledger, state_path, network);
    }

    ledger.setTipSlot(snapshot.slot);
    return .{
        .slot = snapshot.slot,
        .utxos_loaded = loaded,
        .reward_accounts_loaded = state_import.reward_accounts_loaded,
        .stake_deposits_loaded = state_import.stake_deposits_loaded,
        .stake_snapshot_mark_pools_loaded = state_import.stake_snapshot_mark_pools_loaded,
        .stake_snapshot_set_pools_loaded = state_import.stake_snapshot_set_pools_loaded,
        .stake_snapshot_go_pools_loaded = state_import.stake_snapshot_go_pools_loaded,
    };
}

pub fn replayImmutableFromSlot(
    allocator: Allocator,
    ledger: *LedgerDB,
    immutable_path: []const u8,
    from_slot: SlotNo,
    pp: rules.ProtocolParams,
    epoch_length: ?u64,
    reward_params: rewards_mod.RewardParams,
) !ReplayResult {
    var result = ReplayResult{
        .blocks_replayed = 0,
        .txs_applied = 0,
        .txs_failed = 0,
        .start_chunk = 0,
    };

    const total_chunks = try countChunks(immutable_path);
    if (total_chunks == 0) return result;

    result.start_chunk = try findReplayStartChunk(allocator, immutable_path, total_chunks, from_slot);

    var last_slot = from_slot;
    var chunk_num = result.start_chunk;
    while (chunk_num < total_chunks) : (chunk_num += 1) {
        if (runtime_control.stopRequested()) return error.Interrupted;

        const chunk_data = try readChunkData(allocator, immutable_path, chunk_num);
        defer allocator.free(chunk_data);

        var pos: usize = 0;
        while (pos < chunk_data.len) {
            if (runtime_control.stopRequested()) return error.Interrupted;

            var dec = Decoder.init(chunk_data[pos..]);
            const block_slice = dec.sliceOfNextValue() catch break;
            const raw = chunk_data[pos .. pos + block_slice.len];
            pos += block_slice.len;

            const block = block_mod.parseBlock(raw) catch continue;
            if (block.era == .byron) continue;
            if (block.header.slot <= from_slot) continue;

            var ledger_diffs_applied: u32 = 0;
            if (epoch_length) |slots_per_epoch| {
                const current_epoch = types.slotToEpoch(last_slot, slots_per_epoch);
                const target_epoch = types.slotToEpoch(block.header.slot, slots_per_epoch);
                if (target_epoch > current_epoch) {
                    if (block.era == .conway) {
                        ledger.setPointerInstantStakeEnabled(false);
                    }
                    var epoch = current_epoch + 1;
                    while (epoch <= target_epoch) : (epoch += 1) {
                        ledger_diffs_applied += try applyReplayEpochBoundaryEffects(
                            allocator,
                            ledger,
                            block.header.slot,
                            block.hash(),
                            epoch,
                            reward_params,
                            slots_per_epoch,
                        );
                    }
                }
            }

            var apply_result = try ledger_apply.applyBlock(
                allocator,
                ledger,
                &block,
                pp,
                null,
            );
            defer apply_result.deinit(allocator);

            if (apply_result.txs_failed > 0) {
                ledger_diffs_applied += apply_result.txs_applied;
                if (ledger_diffs_applied > 0) {
                    try ledger.rollback(ledger_diffs_applied);
                }
                return error.InvalidImmutableReplay;
            }

            if (try ledger.buildFeePotDiff(
                allocator,
                block.header.slot,
                block.hash(),
                apply_result.total_fees,
            )) |diff| {
                try ledger.applyDiff(diff);
                ledger_diffs_applied += 1;
            }

            const pool = header_validation.poolKeyHash(block.header.issuer_vkey);
            if (try ledger.buildCurrentEpochBlocksMadeDiff(
                allocator,
                block.header.slot,
                block.hash(),
                pool,
            )) |diff| {
                try ledger.applyDiff(diff);
                ledger_diffs_applied += 1;
            }

            result.blocks_replayed += 1;
            result.txs_applied += apply_result.txs_applied;
            result.txs_failed += apply_result.txs_failed;
            ledger.setTipSlot(block.header.slot);
            last_slot = block.header.slot;
        }
    }

    return result;
}

fn applyReplayEpochBoundaryEffects(
    allocator: Allocator,
    ledger: *LedgerDB,
    slot: SlotNo,
    block_hash: types.HeaderHash,
    epoch: types.EpochNo,
    reward_params: rewards_mod.RewardParams,
    slots_per_epoch: u64,
) !u32 {
    var applied: u32 = 0;

    if (try ledger.buildEpochRewardDiff(
        allocator,
        slot,
        block_hash,
        reward_params,
        slots_per_epoch,
    )) |diff| {
        try ledger.applyDiff(diff);
        applied += 1;
    }

    if (try ledger.buildEpochMirDiff(allocator, slot, block_hash)) |diff| {
        try ledger.applyDiff(diff);
        applied += 1;
    }

    ledger.rotateStakeSnapshots(epoch);

    if (try ledger.buildEpochBlocksMadeShiftDiff(allocator, slot, block_hash)) |diff| {
        try ledger.applyDiff(diff);
        applied += 1;
    }

    if (try ledger.buildEpochFeeRolloverDiff(allocator, slot, block_hash)) |diff| {
        try ledger.applyDiff(diff);
        applied += 1;
    }

    if (try ledger.buildPoolReapDiff(allocator, slot, block_hash, epoch)) |diff| {
        try ledger.applyDiff(diff);
        applied += 1;
    }

    return applied;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn validateSnapshotMetadata(allocator: Allocator, path: []const u8) !void {
    const meta = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024);
    defer allocator.free(meta);

    if (std.mem.indexOf(u8, meta, "\"backend\":\"utxohd-mem\"") == null) {
        return error.UnsupportedSnapshotBackend;
    }
}

const SnapshotAccountImport = struct {
    reward_accounts_loaded: u64,
    stake_deposits_loaded: u64,
    stake_snapshot_mark_pools_loaded: u64,
    stake_snapshot_set_pools_loaded: u64,
    stake_snapshot_go_pools_loaded: u64,
};

fn importSnapshotAccountState(
    allocator: Allocator,
    ledger: *LedgerDB,
    state_path: []const u8,
    network: Network,
) !SnapshotAccountImport {
    const state_data = try std.fs.cwd().readFileAlloc(allocator, state_path, 128 * 1024 * 1024);
    defer allocator.free(state_data);

    var dec = Decoder.init(state_data);

    const top_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (top_len != 2) {
        std.debug.print("Snapshot state: unexpected top-level len {}\n", .{top_len});
        return error.InvalidSnapshotState;
    }
    const encoding_version = try dec.decodeUint();
    if (encoding_version != 1) {
        std.debug.print("Snapshot state: unsupported encoding version {}\n", .{encoding_version});
        return error.UnsupportedSnapshotEncodingVersion;
    }

    const ext_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (ext_len != 2) {
        std.debug.print("Snapshot state: unexpected extension len {}\n", .{ext_len});
        return error.InvalidSnapshotState;
    }

    const active_era = try parseCardanoLedgerState(allocator, ledger, network, &dec);
    ledger.setPointerInstantStakeEnabled(active_era < @intFromEnum(block_mod.Era.conway));
    try dec.skipValue(); // headerState

    ledger.setRewardBalancesTracked(true);
    return parse_import_result;
}

var parse_import_result: SnapshotAccountImport = .{
    .reward_accounts_loaded = 0,
    .stake_deposits_loaded = 0,
    .stake_snapshot_mark_pools_loaded = 0,
    .stake_snapshot_set_pools_loaded = 0,
    .stake_snapshot_go_pools_loaded = 0,
};

fn parseCardanoLedgerState(
    allocator: Allocator,
    ledger: *LedgerDB,
    network: Network,
    dec: *Decoder,
) !u8 {
    parse_import_result = .{
        .reward_accounts_loaded = 0,
        .stake_deposits_loaded = 0,
        .stake_snapshot_mark_pools_loaded = 0,
        .stake_snapshot_set_pools_loaded = 0,
        .stake_snapshot_go_pools_loaded = 0,
    };

    const telescope_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (telescope_len == 0 or telescope_len > 8) {
        std.debug.print("Snapshot state: unexpected telescope len {}\n", .{telescope_len});
        return error.InvalidSnapshotState;
    }

    var i: u64 = 1;
    while (i < telescope_len) : (i += 1) {
        try dec.skipValue();
    }

    const active_era: u8 = @intCast(telescope_len - 1);
    const current_era_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (current_era_len != 2) {
        std.debug.print("Snapshot state: unexpected current-era len {} for era {}\n", .{ current_era_len, active_era });
        return error.InvalidSnapshotState;
    }

    try dec.skipValue(); // current-era bound

    if (active_era == 0) {
        try dec.skipValue(); // Byron ledger state
        return active_era;
    }

    try parseVersionedShelleyLedgerState(allocator, ledger, network, active_era, dec);
    return active_era;
}

fn parseVersionedShelleyLedgerState(
    allocator: Allocator,
    ledger: *LedgerDB,
    network: Network,
    active_era: u8,
    dec: *Decoder,
) !void {
    const versioned_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (versioned_len != 2) {
        std.debug.print("Snapshot state: unexpected versioned ledger len {} for era {}\n", .{ versioned_len, active_era });
        return error.InvalidSnapshotState;
    }
    const ledger_version = try dec.decodeUint();
    if (ledger_version != 2) {
        std.debug.print("Snapshot state: unsupported ledger version {} for era {}\n", .{ ledger_version, active_era });
        return error.UnsupportedSnapshotLedgerVersion;
    }

    const shelley_state_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (shelley_state_len != 3 and shelley_state_len != 4) {
        std.debug.print("Snapshot state: unexpected Shelley state len {} for era {}\n", .{ shelley_state_len, active_era });
        return error.InvalidSnapshotState;
    }

    try dec.skipValue(); // tip
    try parseNewEpochState(allocator, ledger, network, active_era, dec);
    try dec.skipValue(); // shelleyTransition
    if (shelley_state_len == 4) {
        try dec.skipValue(); // latestPerasCertRound
    }
}

fn parseNewEpochState(
    allocator: Allocator,
    ledger: *LedgerDB,
    network: Network,
    active_era: u8,
    dec: *Decoder,
) !void {
    const new_epoch_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (new_epoch_len != 7) {
        std.debug.print("Snapshot state: unexpected NewEpochState len {} for era {}\n", .{ new_epoch_len, active_era });
        return error.InvalidSnapshotState;
    }

    try dec.skipValue(); // nesEL
    try parseBlocksMade(ledger, dec, .previous);
    try parseBlocksMade(ledger, dec, .current);
    try parseEpochState(allocator, ledger, network, active_era, dec);
    try dec.skipValue(); // nesRu
    try dec.skipValue(); // nesPd
    try dec.skipValue(); // stashedAVVMAddresses
}

const BlocksMadeTarget = enum {
    previous,
    current,
};

fn parseBlocksMade(
    ledger: *LedgerDB,
    dec: *Decoder,
    target: BlocksMadeTarget,
) !void {
    const map_len = try dec.decodeMapLen();

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            try importBlocksMadeEntry(ledger, dec, target);
        }
    } else {
        while (!dec.isBreak()) {
            try importBlocksMadeEntry(ledger, dec, target);
        }
        try dec.decodeBreak();
    }
}

fn importBlocksMadeEntry(
    ledger: *LedgerDB,
    dec: *Decoder,
    target: BlocksMadeTarget,
) !void {
    const pool_bytes = try dec.decodeBytes();
    if (pool_bytes.len != 28) {
        std.debug.print("Snapshot state: unexpected BlocksMade pool hash len {}\n", .{pool_bytes.len});
        return error.InvalidSnapshotState;
    }
    var pool: types.KeyHash = undefined;
    @memcpy(&pool, pool_bytes);
    const count = try dec.decodeUint();

    switch (target) {
        .previous => try ledger.importPreviousEpochBlocksMade(pool, count),
        .current => try ledger.importCurrentEpochBlocksMade(pool, count),
    }
}

fn parseEpochState(
    allocator: Allocator,
    ledger: *LedgerDB,
    network: Network,
    active_era: u8,
    dec: *Decoder,
) !void {
    const epoch_state_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (epoch_state_len != 4) {
        std.debug.print("Snapshot state: unexpected EpochState len {} for era {}\n", .{ epoch_state_len, active_era });
        return error.InvalidSnapshotState;
    }

    try parseChainAccountState(ledger, dec);
    try parseEraLedgerState(allocator, ledger, network, active_era, dec);
    try parseSnapShots(ledger, dec);
    try dec.skipValue(); // nonMyopic
}

fn parseEraLedgerState(
    allocator: Allocator,
    ledger: *LedgerDB,
    network: Network,
    active_era: u8,
    dec: *Decoder,
) !void {
    const ledger_state_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (ledger_state_len != 2) {
        std.debug.print("Snapshot state: unexpected LedgerState len {} for era {}\n", .{ ledger_state_len, active_era });
        return error.InvalidSnapshotState;
    }

    try parseCertState(allocator, ledger, network, active_era, dec);
    try parseUtxoState(ledger, active_era, dec);
}

fn parseChainAccountState(
    ledger: *LedgerDB,
    dec: *Decoder,
) !void {
    const account_state_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (account_state_len != 2) {
        std.debug.print("Snapshot state: unexpected ChainAccountState len {}\n", .{account_state_len});
        return error.InvalidSnapshotState;
    }

    ledger.importTreasuryBalance(try dec.decodeUint());
    ledger.importReservesBalance(try dec.decodeUint());
}

fn parseUtxoState(
    ledger: *LedgerDB,
    active_era: u8,
    dec: *Decoder,
) !void {
    const utxo_state_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (utxo_state_len != 6) {
        std.debug.print("Snapshot state: unexpected UTxOState len {} for era {}\n", .{ utxo_state_len, active_era });
        return error.InvalidSnapshotState;
    }

    try dec.skipValue(); // utxosUtxo
    try dec.skipValue(); // utxosDeposited
    ledger.importFeesBalance(try dec.decodeUint());

    var i: u64 = 3;
    while (i < 6) : (i += 1) {
        try dec.skipValue();
    }
}

fn parseSnapShots(
    ledger: *LedgerDB,
    dec: *Decoder,
) !void {
    const snapshots_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (snapshots_len != 4) {
        std.debug.print("Snapshot state: unexpected SnapShots len {}\n", .{snapshots_len});
        return error.InvalidSnapshotState;
    }

    var snapshots = stake_mod.StakeSnapshots.init(ledger.allocator);
    errdefer snapshots.deinit();

    snapshots.mark = try parseStakeSnapshot(ledger.allocator, dec, 0);
    snapshots.set = try parseStakeSnapshot(ledger.allocator, dec, 0);
    snapshots.go = try parseStakeSnapshot(ledger.allocator, dec, 0);
    ledger.importSnapshotFees(try dec.decodeUint());
    ledger.replaceStakeSnapshots(snapshots);

    parse_import_result.stake_snapshot_mark_pools_loaded = if (ledger.getStakeSnapshots().mark) |dist| dist.poolCount() else 0;
    parse_import_result.stake_snapshot_set_pools_loaded = if (ledger.getStakeSnapshots().set) |dist| dist.poolCount() else 0;
    parse_import_result.stake_snapshot_go_pools_loaded = if (ledger.getStakeSnapshots().go) |dist| dist.poolCount() else 0;
}

fn parseStakeSnapshot(
    allocator: Allocator,
    dec: *Decoder,
    epoch: types.EpochNo,
) !?stake_mod.StakeDistribution {
    const snapshot_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (snapshot_len != 2 and snapshot_len != 3) {
        std.debug.print("Snapshot state: unexpected SnapShot len {}\n", .{snapshot_len});
        return error.InvalidSnapshotState;
    }

    var distribution = stake_mod.StakeDistribution.init(allocator, epoch);
    errdefer distribution.deinit();

    var active_stake_by_pool = std.AutoHashMap(types.KeyHash, Coin).init(allocator);
    defer active_stake_by_pool.deinit();

    if (snapshot_len == 2) {
        try parseActiveStakeByPool(&distribution, &active_stake_by_pool, dec);
    } else {
        try parseLegacyActiveStakeByPool(allocator, &distribution, &active_stake_by_pool, dec);
    }

    try parseStakePoolSnapshotMap(&distribution, &active_stake_by_pool, dec);
    distribution.finalize();
    return distribution;
}

fn parseStakePoolSnapshotMap(
    distribution: *stake_mod.StakeDistribution,
    active_stake_by_pool: *const std.AutoHashMap(types.KeyHash, Coin),
    dec: *Decoder,
) !void {
    const map_len = try dec.decodeMapLen();

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importStakePoolSnapshotEntry(distribution, active_stake_by_pool, dec);
        }
    } else {
        while (!dec.isBreak()) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importStakePoolSnapshotEntry(distribution, active_stake_by_pool, dec);
        }
        try dec.decodeBreak();
    }
}

fn importStakePoolSnapshotEntry(
    distribution: *stake_mod.StakeDistribution,
    active_stake_by_pool: *const std.AutoHashMap(types.KeyHash, Coin),
    dec: *Decoder,
) !void {
    const pool_bytes = try dec.decodeBytes();
    if (pool_bytes.len != 28) {
        std.debug.print("Snapshot state: unexpected stake-snapshot pool hash len {}\n", .{pool_bytes.len});
        return error.InvalidSnapshotState;
    }
    var pool: types.KeyHash = undefined;
    @memcpy(&pool, pool_bytes);

    const pool_snapshot_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;

    var active_stake: Coin = 0;
    var self_delegated_owner_stake: Coin = 0;
    var pledge: Coin = 0;
    var cost: Coin = 0;
    var margin = zero_margin;
    var reward_account = RewardAccount{
        .network = .testnet,
        .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0} ** 28 },
    };
    var self_delegated_owners: []const types.KeyHash = try distribution.allocator.alloc(types.KeyHash, 0);
    defer if (self_delegated_owners.len > 0) distribution.allocator.free(self_delegated_owners);

    if (pool_snapshot_len == 9) {
        // Legacy StakePoolParams-shaped snapshot entries:
        // [poolId, vrf, pledge, cost, margin, rewardAcct, owners, relays, metadata]
        try dec.skipValue(); // poolId (redundant with map key)
        try dec.skipValue(); // vrf
        pledge = try dec.decodeUint();
        cost = try dec.decodeUint();
        margin = try parseUnitInterval(dec);
        const reward_bytes = try dec.decodeBytes();
        if (reward_bytes.len != 29) return error.InvalidSnapshotState;
        var reward_raw: [29]u8 = undefined;
        @memcpy(&reward_raw, reward_bytes);
        reward_account = try RewardAccount.fromBytes(reward_raw);
        try dec.skipValue(); // owners
        try dec.skipValue(); // relays
        try dec.skipValue(); // metadata
        active_stake = active_stake_by_pool.get(pool) orelse 0;
    } else if (pool_snapshot_len == 10) {
        // New StakePoolSnapShot format:
        // [stake, stakeRatio, selfDelegOwners, selfDelegOwnerStake, vrf, pledge, cost, margin, numDelegators, accountId]
        active_stake = try dec.decodeUint(); // spssStake
        try dec.skipValue(); // spssStakeRatio
        distribution.allocator.free(self_delegated_owners);
        self_delegated_owners = try parseKeyHashSet(distribution.allocator, dec);
        self_delegated_owner_stake = try dec.decodeUint(); // spssSelfDelegatedOwnersStake
        try dec.skipValue(); // spssVrf
        pledge = try dec.decodeUint(); // spssPledge
        cost = try dec.decodeUint(); // spssCost
        margin = try parseUnitInterval(dec); // spssMargin
        try dec.skipValue(); // spssNumDelegators
        const reward_bytes = try dec.decodeBytes(); // spssAccountId
        if (reward_bytes.len != 29) return error.InvalidSnapshotState;
        var reward_raw: [29]u8 = undefined;
        @memcpy(&reward_raw, reward_bytes);
        reward_account = try RewardAccount.fromBytes(reward_raw);
    } else {
        std.debug.print("Snapshot state: unexpected StakePoolSnapShot len {}\n", .{pool_snapshot_len});
        return error.InvalidSnapshotState;
    }

    try distribution.setPoolStake(
        pool,
        active_stake,
        self_delegated_owner_stake,
        pledge,
        cost,
        margin,
        reward_account,
    );
    for (self_delegated_owners) |owner| {
        try distribution.setPoolOwnerMembership(pool, owner);
    }
}

fn parseKeyHashSet(
    allocator: Allocator,
    dec: *Decoder,
) ![]const types.KeyHash {
    var item_count: u64 = 0;
    const major = try dec.peekMajorType();
    if (major == 6) {
        const tag = try dec.decodeTag();
        if (tag != 258) return error.InvalidSnapshotState;
        item_count = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    } else {
        item_count = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    }

    const items = try allocator.alloc(types.KeyHash, item_count);
    errdefer allocator.free(items);

    var i: u64 = 0;
    while (i < item_count) : (i += 1) {
        const item_bytes = try dec.decodeBytes();
        if (item_bytes.len != 28) return error.InvalidSnapshotState;
        @memcpy(&items[i], item_bytes);
    }

    return items;
}

fn parseUnitInterval(dec: *Decoder) !types.UnitInterval {
    const raw = try dec.sliceOfNextValue();
    var inner = Decoder.init(raw);

    if (raw.len > 0 and (raw[0] & 0xe0) == 0xc0) {
        const tag = try inner.decodeTag();
        if (tag != 30) return error.InvalidSnapshotState;
    }

    const len = (try inner.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (len != 2) return error.InvalidSnapshotState;

    const numerator = try inner.decodeUint();
    const denominator = try inner.decodeUint();
    const interval = types.UnitInterval{
        .numerator = numerator,
        .denominator = denominator,
    };
    if (!interval.isValid()) return error.InvalidSnapshotState;
    return interval;
}

fn parseActiveStakeByPool(
    distribution: *stake_mod.StakeDistribution,
    active_stake_by_pool: *std.AutoHashMap(types.KeyHash, Coin),
    dec: *Decoder,
) !void {
    const map_len = try dec.decodeMapLen();

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            const credential = try parseCredential(dec);
            try importActiveStakeEntry(distribution, active_stake_by_pool, credential, dec);
        }
    } else {
        while (!dec.isBreak()) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            const credential = try parseCredential(dec);
            try importActiveStakeEntry(distribution, active_stake_by_pool, credential, dec);
        }
        try dec.decodeBreak();
    }
}

fn importActiveStakeEntry(
    distribution: *stake_mod.StakeDistribution,
    active_stake_by_pool: *std.AutoHashMap(types.KeyHash, Coin),
    credential: Credential,
    dec: *Decoder,
) !void {
    const swd_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (swd_len != 2) {
        std.debug.print("Snapshot state: unexpected StakeWithDelegation len {}\n", .{swd_len});
        return error.InvalidSnapshotState;
    }

    const stake = try dec.decodeUint();
    const pool_bytes = try dec.decodeBytes();
    if (pool_bytes.len != 28) {
        std.debug.print("Snapshot state: unexpected active-stake pool hash len {}\n", .{pool_bytes.len});
        return error.InvalidSnapshotState;
    }
    var pool: types.KeyHash = undefined;
    @memcpy(&pool, pool_bytes);

    try distribution.setDelegatedStake(credential, pool, stake);
    try appendPoolStake(active_stake_by_pool, pool, stake);
}

fn parseLegacyActiveStakeByPool(
    allocator: Allocator,
    distribution: *stake_mod.StakeDistribution,
    active_stake_by_pool: *std.AutoHashMap(types.KeyHash, Coin),
    dec: *Decoder,
) !void {
    var legacy_stake = std.AutoHashMap(Credential, Coin).init(allocator);
    defer legacy_stake.deinit();

    try parseLegacyStakeMap(&legacy_stake, dec);
    try parseLegacyDelegations(&legacy_stake, distribution, active_stake_by_pool, dec);
}

fn parseLegacyStakeMap(
    legacy_stake: *std.AutoHashMap(Credential, Coin),
    dec: *Decoder,
) !void {
    const map_len = try dec.decodeMapLen();

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            const credential = try parseCredential(dec);
            const stake = try dec.decodeUint();
            try legacy_stake.put(credential, stake);
        }
    } else {
        while (!dec.isBreak()) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            const credential = try parseCredential(dec);
            const stake = try dec.decodeUint();
            try legacy_stake.put(credential, stake);
        }
        try dec.decodeBreak();
    }
}

fn parseLegacyDelegations(
    legacy_stake: *const std.AutoHashMap(Credential, Coin),
    distribution: *stake_mod.StakeDistribution,
    active_stake_by_pool: *std.AutoHashMap(types.KeyHash, Coin),
    dec: *Decoder,
) !void {
    const map_len = try dec.decodeMapLen();

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importLegacyDelegationEntry(legacy_stake, distribution, active_stake_by_pool, dec);
        }
    } else {
        while (!dec.isBreak()) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importLegacyDelegationEntry(legacy_stake, distribution, active_stake_by_pool, dec);
        }
        try dec.decodeBreak();
    }
}

fn importLegacyDelegationEntry(
    legacy_stake: *const std.AutoHashMap(Credential, Coin),
    distribution: *stake_mod.StakeDistribution,
    active_stake_by_pool: *std.AutoHashMap(types.KeyHash, Coin),
    dec: *Decoder,
) !void {
    const credential = try parseCredential(dec);
    const pool_bytes = try dec.decodeBytes();
    if (pool_bytes.len != 28) {
        std.debug.print("Snapshot state: unexpected legacy delegation pool hash len {}\n", .{pool_bytes.len});
        return error.InvalidSnapshotState;
    }
    var pool: types.KeyHash = undefined;
    @memcpy(&pool, pool_bytes);

    const stake = legacy_stake.get(credential) orelse return;
    try distribution.setDelegatedStake(credential, pool, stake);
    try appendPoolStake(active_stake_by_pool, pool, stake);
}

fn appendPoolStake(
    active_stake_by_pool: *std.AutoHashMap(types.KeyHash, Coin),
    pool: types.KeyHash,
    added: Coin,
) !void {
    const gop = try active_stake_by_pool.getOrPut(pool);
    if (!gop.found_existing) {
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += added;
}

fn parseCertState(
    allocator: Allocator,
    ledger: *LedgerDB,
    network: Network,
    active_era: u8,
    dec: *Decoder,
) !void {
    const cert_state_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (active_era >= 6) {
        if (cert_state_len != 3) {
            std.debug.print("Snapshot state: unexpected Conway CertState len {}\n", .{cert_state_len});
            return error.InvalidSnapshotState;
        }
        try dec.skipValue(); // vstate
        try parsePState(allocator, ledger, dec);
        try parseDState(allocator, ledger, network, active_era, dec);
    } else {
        if (cert_state_len != 2) {
            std.debug.print("Snapshot state: unexpected Shelley CertState len {} for era {}\n", .{ cert_state_len, active_era });
            return error.InvalidSnapshotState;
        }
        try parsePState(allocator, ledger, dec);
        try parseDState(allocator, ledger, network, active_era, dec);
    }
}

fn parsePState(
    allocator: Allocator,
    ledger: *LedgerDB,
    dec: *Decoder,
) !void {
    const pstate_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (pstate_len != 4) {
        std.debug.print("Snapshot state: unexpected PState len {}\n", .{pstate_len});
        return error.InvalidSnapshotState;
    }

    try dec.skipValue(); // psVRFKeyHashes
    try parseStakePools(allocator, ledger, dec);
    try parseFutureStakePoolParams(allocator, ledger, dec);
    try parsePoolRetirements(allocator, ledger, dec);
}

fn parseStakePools(
    allocator: Allocator,
    ledger: *LedgerDB,
    dec: *Decoder,
) !void {
    const map_len = try dec.decodeMapLen();
    var imported_pools: u64 = 0;

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importStakePoolEntry(ledger, dec);
            imported_pools += 1;
            if (!builtin.is_test and imported_pools % 10_000 == 0) {
                std.debug.print("  Loaded {} snapshot stake pools...\n", .{imported_pools});
            }
        }
    } else {
        while (!dec.isBreak()) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importStakePoolEntry(ledger, dec);
            imported_pools += 1;
            if (!builtin.is_test and imported_pools % 10_000 == 0) {
                std.debug.print("  Loaded {} snapshot stake pools...\n", .{imported_pools});
            }
        }
        try dec.decodeBreak();
    }

    _ = allocator;
}

fn parseFutureStakePoolParams(
    allocator: Allocator,
    ledger: *LedgerDB,
    dec: *Decoder,
) !void {
    const map_len = try dec.decodeMapLen();

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importFutureStakePoolParamEntry(ledger, dec);
        }
    } else {
        while (!dec.isBreak()) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importFutureStakePoolParamEntry(ledger, dec);
        }
        try dec.decodeBreak();
    }

    _ = allocator;
}

fn importStakePoolEntry(ledger: *LedgerDB, dec: *Decoder) !void {
    const pool_bytes = try dec.decodeBytes();
    if (pool_bytes.len != 28) {
        std.debug.print("Snapshot state: unexpected pool hash len {}\n", .{pool_bytes.len});
        return error.InvalidSnapshotState;
    }
    var pool: types.KeyHash = undefined;
    @memcpy(&pool, pool_bytes);

    const state_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (state_len != 9 and state_len != 10) {
        std.debug.print("Snapshot state: unexpected stake-pool state len {}\n", .{state_len});
        return error.InvalidSnapshotState;
    }

    try dec.skipValue(); // vrf
    const pledge = try dec.decodeUint();
    const cost = try dec.decodeUint();
    const margin = try parseUnitInterval(dec);

    const reward_bytes = try dec.decodeBytes();
    if (reward_bytes.len != 29) {
        std.debug.print("Snapshot state: unexpected pool reward-account len {}\n", .{reward_bytes.len});
        return error.InvalidSnapshotState;
    }
    var reward_raw: [29]u8 = undefined;
    @memcpy(&reward_raw, reward_bytes);
    const reward_account = try RewardAccount.fromBytes(reward_raw);

    const owners = try parseKeyHashSet(ledger.allocator, dec);
    defer if (owners.len > 0) ledger.allocator.free(owners);
    try dec.skipValue(); // relays
    try dec.skipValue(); // metadata

    const deposit = try dec.decodeUint();

    if (state_len == 10) {
        try dec.skipValue(); // delegators
    }

    try ledger.importPoolRewardAccount(pool, reward_account);
    try ledger.importPoolDeposit(pool, deposit);
    try ledger.importPoolConfig(pool, .{
        .pledge = pledge,
        .cost = cost,
        .margin = margin,
    });
    for (owners) |owner| {
        try ledger.importPoolOwnerMembership(pool, owner);
    }
}

fn importFutureStakePoolParamEntry(ledger: *LedgerDB, dec: *Decoder) !void {
    const pool_bytes = try dec.decodeBytes();
    if (pool_bytes.len != 28) {
        std.debug.print("Snapshot state: unexpected future pool hash len {}\n", .{pool_bytes.len});
        return error.InvalidSnapshotState;
    }
    var pool: types.KeyHash = undefined;
    @memcpy(&pool, pool_bytes);

    const params_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (params_len < 8 or params_len > 10) {
        std.debug.print("Snapshot state: unexpected future pool params len {}\n", .{params_len});
        return error.InvalidSnapshotState;
    }

    var remaining = params_len;
    var probe = dec.*;
    const first_value = try probe.sliceOfNextValue();
    var first_dec = Decoder.init(first_value);
    const has_embedded_pool_id = blk: {
        if (first_dec.peekMajorType() catch null != 2) break :blk false;
        const embedded = first_dec.decodeBytes() catch break :blk false;
        break :blk embedded.len == 28 and std.mem.eql(u8, embedded, &pool);
    };
    if (has_embedded_pool_id) {
        try dec.skipValue();
        remaining -= 1;
    }

    if (remaining < 5) return error.InvalidSnapshotState;

    try dec.skipValue(); // vrf
    remaining -= 1;
    const pledge = try dec.decodeUint();
    remaining -= 1;
    const cost = try dec.decodeUint();
    remaining -= 1;
    const margin = try parseUnitInterval(dec);
    remaining -= 1;
    const reward_bytes = try dec.decodeBytes();
    remaining -= 1;
    if (reward_bytes.len != 29) {
        std.debug.print("Snapshot state: unexpected future pool reward-account len {}\n", .{reward_bytes.len});
        return error.InvalidSnapshotState;
    }
    var reward_raw: [29]u8 = undefined;
    @memcpy(&reward_raw, reward_bytes);
    const reward_account = try RewardAccount.fromBytes(reward_raw);

    var owners: []const types.KeyHash = try ledger.allocator.alloc(types.KeyHash, 0);
    defer if (owners.len > 0) ledger.allocator.free(owners);
    if (remaining > 0) {
        ledger.allocator.free(owners);
        owners = try parseKeyHashSet(ledger.allocator, dec);
        remaining -= 1;
    }

    while (remaining > 0) : (remaining -= 1) {
        try dec.skipValue();
    }

    try ledger.importFuturePoolParams(pool, .{
        .config = .{
            .pledge = pledge,
            .cost = cost,
            .margin = margin,
        },
        .reward_account = reward_account,
    });
    for (owners) |owner| {
        try ledger.importFuturePoolOwnerMembership(pool, owner);
    }
}

fn parsePoolRetirements(
    allocator: Allocator,
    ledger: *LedgerDB,
    dec: *Decoder,
) !void {
    const map_len = try dec.decodeMapLen();

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importPoolRetirementEntry(ledger, dec);
        }
    } else {
        while (!dec.isBreak()) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importPoolRetirementEntry(ledger, dec);
        }
        try dec.decodeBreak();
    }

    _ = allocator;
}

fn importPoolRetirementEntry(ledger: *LedgerDB, dec: *Decoder) !void {
    const pool_bytes = try dec.decodeBytes();
    if (pool_bytes.len != 28) {
        std.debug.print("Snapshot state: unexpected retiring pool hash len {}\n", .{pool_bytes.len});
        return error.InvalidSnapshotState;
    }
    var pool: types.KeyHash = undefined;
    @memcpy(&pool, pool_bytes);

    const epoch = try dec.decodeUint();
    try ledger.importPoolRetirement(pool, epoch);
}

fn parseDState(
    allocator: Allocator,
    ledger: *LedgerDB,
    network: Network,
    active_era: u8,
    dec: *Decoder,
) !void {
    const dstate_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (dstate_len != 4) {
        std.debug.print("Snapshot state: unexpected DState len {} for era {}\n", .{ dstate_len, active_era });
        return error.InvalidSnapshotState;
    }

    try parseAccounts(allocator, ledger, network, active_era, dec);
    try dec.skipValue(); // futureGenDelegs
    try dec.skipValue(); // genDelegs
    try parseInstantaneousRewards(allocator, ledger, dec);
}

fn parseInstantaneousRewards(
    allocator: Allocator,
    ledger: *LedgerDB,
    dec: *Decoder,
) !void {
    const rewards_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (rewards_len != 4) {
        std.debug.print("Snapshot state: unexpected InstantaneousRewards len {}\n", .{rewards_len});
        return error.InvalidSnapshotState;
    }

    try parseInstantaneousRewardMap(allocator, ledger, .reserves, dec);
    try parseInstantaneousRewardMap(allocator, ledger, .treasury, dec);
    ledger.importMirDeltaReserves(try parseDeltaCoin(dec));
    ledger.importMirDeltaTreasury(try parseDeltaCoin(dec));
}

fn parseInstantaneousRewardMap(
    allocator: Allocator,
    ledger: *LedgerDB,
    pot: MIRPot,
    dec: *Decoder,
) !void {
    const map_len = try dec.decodeMapLen();

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            const credential = try parseCredential(dec);
            const amount = try dec.decodeUint();
            try ledger.importMirReward(pot, credential, amount);
        }
    } else {
        while (!dec.isBreak()) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            const credential = try parseCredential(dec);
            const amount = try dec.decodeUint();
            try ledger.importMirReward(pot, credential, amount);
        }
        try dec.decodeBreak();
    }

    _ = allocator;
}

fn parseDeltaCoin(dec: *Decoder) !DeltaCoin {
    const value = try dec.decodeInt();
    return std.math.cast(DeltaCoin, value) orelse error.InvalidSnapshotState;
}

fn parseAccounts(
    allocator: Allocator,
    ledger: *LedgerDB,
    network: Network,
    active_era: u8,
    dec: *Decoder,
) !void {
    if (active_era >= 6) {
        try parseAccountMap(allocator, ledger, network, active_era, dec);
        return;
    }

    const major = try dec.peekMajorType();
    if (major == 5) {
        try parseAccountMap(allocator, ledger, network, active_era, dec);
        return;
    }

    const accounts_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (accounts_len != 2) {
        std.debug.print("Snapshot state: unexpected legacy Accounts len {} for era {}\n", .{ accounts_len, active_era });
        return error.InvalidSnapshotState;
    }
    try parseAccountMap(allocator, ledger, network, active_era, dec);
    try dec.skipValue(); // ptr map
}

fn parseAccountMap(
    allocator: Allocator,
    ledger: *LedgerDB,
    network: Network,
    active_era: u8,
    dec: *Decoder,
) !void {
    const map_len = try dec.decodeMapLen();
    var imported_accounts: u64 = 0;

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importAccountEntry(ledger, network, active_era, dec);
            imported_accounts += 1;
            if (!builtin.is_test and imported_accounts % 100_000 == 0) {
                std.debug.print("  Loaded {} snapshot accounts...\n", .{imported_accounts});
            }
        }
    } else {
        while (!dec.isBreak()) {
            if (runtime_control.stopRequested()) return error.Interrupted;
            try importAccountEntry(ledger, network, active_era, dec);
            imported_accounts += 1;
            if (!builtin.is_test and imported_accounts % 100_000 == 0) {
                std.debug.print("  Loaded {} snapshot accounts...\n", .{imported_accounts});
            }
        }
        try dec.decodeBreak();
    }

    _ = allocator;
}

fn importAccountEntry(
    ledger: *LedgerDB,
    network: Network,
    active_era: u8,
    dec: *Decoder,
) !void {
    const credential = try parseCredential(dec);
    const account = try parseAccountState(dec, active_era);
    try ledger.importStakeAccount(.{
        .network = network,
        .credential = credential,
    }, .{
        .registered = true,
        .reward_balance = account.balance,
        .deposit = account.deposit,
        .stake_pool_delegation = account.stake_pool,
        .drep_delegation = account.drep,
        .pointer = account.pointer,
    });

    if (account.balance > 0) {
        parse_import_result.reward_accounts_loaded += 1;
    }

    if (account.deposit > 0) {
        parse_import_result.stake_deposits_loaded += 1;
    }
}

const ParsedAccountState = struct {
    balance: Coin,
    deposit: Coin,
    stake_pool: ?types.KeyHash,
    drep: ?DRep,
    pointer: ?types.Pointer,
};

fn parseAccountState(dec: *Decoder, active_era: u8) !ParsedAccountState {
    const account_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (account_len != 4) {
        std.debug.print("Snapshot state: unexpected account-state len {} for era {}\n", .{ account_len, active_era });
        return error.InvalidSnapshotState;
    }

    if (active_era >= 6) {
        const balance = try dec.decodeUint();
        const deposit = try dec.decodeUint();
        const stake_pool = try parseMaybeKeyHash(dec);
        const drep = try parseMaybeDRep(dec);
        return .{
            .balance = balance,
            .deposit = deposit,
            .stake_pool = stake_pool,
            .drep = drep,
            .pointer = null,
        };
    }

    const pointer = try parseMaybePointer(dec);
    const balance = try dec.decodeUint();
    const deposit = try dec.decodeUint();
    const stake_pool = try parseMaybeKeyHash(dec);
    return .{
        .balance = balance,
        .deposit = deposit,
        .stake_pool = stake_pool,
        .drep = null,
        .pointer = pointer,
    };
}

fn parseMaybePointer(dec: *Decoder) !?types.Pointer {
    const major = try dec.peekMajorType();
    if (major == 7) {
        try dec.decodeNull();
        return null;
    }

    const pointer_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (pointer_len != 3) {
        std.debug.print("Snapshot state: unexpected pointer len {}\n", .{pointer_len});
        return error.InvalidSnapshotState;
    }

    return .{
        .slot = try dec.decodeUint(),
        .tx_ix = try dec.decodeUint(),
        .cert_ix = try dec.decodeUint(),
    };
}

fn parseMaybeKeyHash(dec: *Decoder) !?types.KeyHash {
    const major = try dec.peekMajorType();
    if (major == 7) {
        try dec.decodeNull();
        return null;
    }

    const key_bytes = try dec.decodeBytes();
    if (key_bytes.len != 28) {
        std.debug.print("Snapshot state: unexpected stake-pool hash len {}\n", .{key_bytes.len});
        return error.InvalidSnapshotState;
    }
    var key_hash: types.KeyHash = undefined;
    @memcpy(&key_hash, key_bytes);
    return key_hash;
}

fn parseMaybeDRep(dec: *Decoder) !?DRep {
    const major = try dec.peekMajorType();
    if (major == 7) {
        try dec.decodeNull();
        return null;
    }

    const drep_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (drep_len == 0 or drep_len > 2) {
        std.debug.print("Snapshot state: unexpected DRep len {}\n", .{drep_len});
        return error.InvalidSnapshotState;
    }

    const tag = try dec.decodeUint();
    return switch (tag) {
        0 => blk: {
            const hash_bytes = try dec.decodeBytes();
            if (hash_bytes.len != 28) return error.InvalidSnapshotState;
            var hash: types.Hash28 = undefined;
            @memcpy(&hash, hash_bytes);
            break :blk DRep{ .key_hash = hash };
        },
        1 => blk: {
            const hash_bytes = try dec.decodeBytes();
            if (hash_bytes.len != 28) return error.InvalidSnapshotState;
            var hash: types.Hash28 = undefined;
            @memcpy(&hash, hash_bytes);
            break :blk DRep{ .script_hash = hash };
        },
        2 => DRep{ .always_abstain = {} },
        3 => DRep{ .always_no_confidence = {} },
        else => {
            std.debug.print("Snapshot state: unexpected DRep tag {}\n", .{tag});
            return error.InvalidSnapshotState;
        },
    };
}

fn parseCredential(dec: *Decoder) !Credential {
    const cred_len = (try dec.decodeArrayLen()) orelse return error.InvalidSnapshotState;
    if (cred_len != 2) {
        std.debug.print("Snapshot state: unexpected credential len {}\n", .{cred_len});
        return error.InvalidSnapshotState;
    }

    const tag = try dec.decodeUint();
    if (tag > 1) {
        std.debug.print("Snapshot state: unexpected credential tag {}\n", .{tag});
        return error.InvalidSnapshotState;
    }

    const hash_bytes = try dec.decodeBytes();
    if (hash_bytes.len != 28) {
        std.debug.print("Snapshot state: unexpected credential hash len {}\n", .{hash_bytes.len});
        return error.InvalidSnapshotState;
    }

    var hash: [28]u8 = undefined;
    @memcpy(&hash, hash_bytes);
    return .{
        .cred_type = if (tag == 0) CredentialType.key_hash else CredentialType.script_hash,
        .hash = hash,
    };
}

fn countChunks(immutable_path: []const u8) !u32 {
    var dir = try std.fs.cwd().openDir(immutable_path, .{ .iterate = true });
    defer dir.close();

    var max_chunk: ?u32 = null;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".chunk")) continue;

        const num = std.fmt.parseInt(u32, entry.name[0 .. entry.name.len - 6], 10) catch continue;
        max_chunk = if (max_chunk) |current| @max(current, num) else num;
    }

    return if (max_chunk) |num| num + 1 else 0;
}

fn findReplayStartChunk(
    allocator: Allocator,
    immutable_path: []const u8,
    total_chunks: u32,
    from_slot: SlotNo,
) !u32 {
    var chunk_num = total_chunks;
    while (chunk_num > 0) {
        chunk_num -= 1;

        const range = try readChunkSlotRange(allocator, immutable_path, chunk_num);
        if (range == null) continue;

        if (range.?.first_slot <= from_slot and from_slot <= range.?.last_slot) {
            return chunk_num;
        }
        if (range.?.last_slot < from_slot) {
            return @min(chunk_num + 1, total_chunks - 1);
        }
    }

    return 0;
}

fn readChunkSlotRange(
    allocator: Allocator,
    immutable_path: []const u8,
    chunk_num: u32,
) !?struct { first_slot: SlotNo, last_slot: SlotNo } {
    const data = try readChunkData(allocator, immutable_path, chunk_num);
    defer allocator.free(data);

    var pos: usize = 0;
    var first_slot: ?SlotNo = null;
    var last_slot: ?SlotNo = null;

    while (pos < data.len) {
        var dec = Decoder.init(data[pos..]);
        const block_slice = dec.sliceOfNextValue() catch break;
        const raw = data[pos .. pos + block_slice.len];
        pos += block_slice.len;

        const block = block_mod.parseBlock(raw) catch continue;
        if (block.era == .byron) continue;
        if (first_slot == null) first_slot = block.header.slot;
        last_slot = block.header.slot;
    }

    if (first_slot == null or last_slot == null) return null;
    return .{ .first_slot = first_slot.?, .last_slot = last_slot.? };
}

fn readChunkData(allocator: Allocator, immutable_path: []const u8, chunk_num: u32) ![]u8 {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{ immutable_path, chunk_num });
    return std.fs.cwd().readFileAlloc(allocator, path, 512 * 1024 * 1024);
}

fn readCborContainerLen(reader: anytype, expected_major: u3) !?u64 {
    const first = try reader.takeByte();
    const major = @as(u3, @intCast(first >> 5));
    if (major != expected_major) return error.InvalidCbor;

    const ai = first & 0x1f;
    if (ai == 31) return null;
    return try readCborArg(reader, ai);
}

fn readExactly(reader: anytype, dest: []u8) !void {
    var offset: usize = 0;
    while (offset < dest.len) {
        const step = @min(dest.len - offset, 32 * 1024);
        const chunk = try reader.take(step);
        @memcpy(dest[offset .. offset + step], chunk);
        offset += step;
    }
}

fn readCborBytesLen(reader: anytype) !usize {
    const first = try reader.takeByte();
    return readCborBytesLenFromFirst(reader, first);
}

fn readCborBytesLenFromFirst(reader: anytype, first: u8) !usize {
    const major = @as(u3, @intCast(first >> 5));
    if (major != 2) return error.InvalidCbor;
    const ai = first & 0x1f;
    return @intCast(try readCborArg(reader, ai));
}

fn readCborArg(reader: anytype, ai: u8) !u64 {
    return switch (ai) {
        0...23 => ai,
        24 => try reader.takeByte(),
        25 => blk: {
            break :blk @as(u64, try reader.takeInt(u16, .big));
        },
        26 => blk: {
            break :blk @as(u64, try reader.takeInt(u32, .big));
        },
        27 => blk: {
            break :blk try reader.takeInt(u64, .big);
        },
        else => error.InvalidCbor,
    };
}

fn parsePackedTxIn(bytes: *const [34]u8) !TxIn {
    var tx_id: [32]u8 = undefined;
    @memcpy(&tx_id, bytes[0..32]);
    const tx_ix = std.mem.readInt(u16, bytes[32..34], .little);
    return .{
        .tx_id = tx_id,
        .tx_ix = tx_ix,
    };
}

fn parsePackedTxOutCoin(bytes: []const u8) !Coin {
    return (try parsePackedTxOutInfo(bytes)).coin;
}

const PackedTxOutInfo = struct {
    coin: Coin,
    stake_credential: ?Credential,
    stake_pointer: ?types.Pointer,
};

fn parsePackedTxOutInfo(bytes: []const u8) !PackedTxOutInfo {
    var pos: usize = 0;
    const tag = try readPackedByte(bytes, &pos);

    switch (tag) {
        0, 1, 4, 5 => {
            const address_raw = try readPackedShortBytes(bytes, &pos);
            const stake_info = types.stakeAddressInfoFromBytes(address_raw) catch types.StakeAddressInfo{};
            return .{
                .coin = try readPackedCompactValueCoin(bytes, &pos),
                .stake_credential = stake_info.credential,
                .stake_pointer = stake_info.pointer,
            };
        },
        2, 3 => {
            const stake_credential = try readPackedCredential(bytes, &pos);
            try skipPackedFixed(bytes, &pos, 32); // Addr28Extra
            return .{
                .coin = try readPackedCompactCoin(bytes, &pos),
                .stake_credential = stake_credential,
                .stake_pointer = null,
            };
        },
        else => return error.UnsupportedPackedTxOut,
    }
}

fn readPackedCompactValueCoin(bytes: []const u8, pos: *usize) !Coin {
    const tag = try readPackedByte(bytes, pos);
    return switch (tag) {
        0 => try readPackedVarLen(bytes, pos),
        1 => try readPackedVarLen(bytes, pos),
        else => error.UnsupportedCompactValue,
    };
}

fn readPackedCompactCoin(bytes: []const u8, pos: *usize) !Coin {
    const tag = try readPackedByte(bytes, pos);
    if (tag != 0) return error.UnsupportedCompactCoin;
    return readPackedVarLen(bytes, pos);
}

fn readPackedShortBytes(bytes: []const u8, pos: *usize) ![]const u8 {
    const len = try readPackedVarLen(bytes, pos);
    const start = pos.*;
    try skipPackedFixed(bytes, pos, @intCast(len));
    return bytes[start..pos.*];
}

fn readPackedCredential(bytes: []const u8, pos: *usize) !Credential {
    const tag = try readPackedByte(bytes, pos);
    const cred_type: types.CredentialType = switch (tag) {
        0 => .script_hash,
        1 => .key_hash,
        else => return error.InvalidPackedTxOut,
    };
    const start = pos.*;
    try skipPackedFixed(bytes, pos, 28);
    return .{
        .cred_type = cred_type,
        .hash = bytes[start..pos.*][0..28].*,
    };
}

fn skipPackedFixed(bytes: []const u8, pos: *usize, len: usize) !void {
    if (pos.* + len > bytes.len) return error.InvalidPackedTxOut;
    pos.* += len;
}

fn readPackedByte(bytes: []const u8, pos: *usize) !u8 {
    if (pos.* >= bytes.len) return error.InvalidPackedTxOut;
    const byte = bytes[pos.*];
    pos.* += 1;
    return byte;
}

fn readPackedVarLen(bytes: []const u8, pos: *usize) !u64 {
    var value: u64 = 0;

    while (true) {
        const byte = try readPackedByte(bytes, pos);
        if (value > (std.math.maxInt(u64) >> 7)) return error.InvalidPackedVarLen;
        value = (value << 7) | @as(u64, byte & 0x7f);
        if ((byte & 0x80) == 0) return value;
    }
}

test "ledger_snapshot: parse packed txin and txout coin from real ancillary sample" {
    const key = [_]u8{
        0x00, 0x00, 0x0c, 0x0c, 0xf6, 0xfe, 0x63, 0x89,
        0x49, 0x2d, 0xd7, 0xfe, 0x7c, 0x8f, 0xf3, 0x04,
        0x0d, 0x70, 0xd1, 0x1b, 0x33, 0x56, 0x09, 0x3c,
        0xf6, 0x51, 0xac, 0x87, 0x6c, 0x6f, 0x66, 0xd9,
        0x00, 0x00,
    };
    const tx_in = try parsePackedTxIn(&key);
    try std.testing.expectEqual(@as(u16, 0), tx_in.tx_ix);

    const value = [_]u8{
        0x00, 0x39, 0x00, 0x6d, 0x5b, 0x57, 0x5d, 0x9d, 0xff, 0xc1, 0xe4, 0xf1,
        0x2b, 0x49, 0x9b, 0x99, 0xbf, 0xe1, 0xd3, 0xe1, 0x75, 0xe5, 0xed, 0x32,
        0x56, 0xcd, 0x28, 0x57, 0x91, 0xaf, 0xb1, 0xd1, 0x98, 0x34, 0xbc, 0x0a,
        0x0d, 0x4f, 0xa1, 0xfd, 0x45, 0xf9, 0xd4, 0x5d, 0x91, 0xed, 0x04, 0xfe,
        0x0f, 0xdf, 0xed, 0x74, 0x8c, 0x44, 0xf5, 0x81, 0xfc, 0xbd, 0xbb, 0x01,
        0xe8, 0xaf, 0x30, 0x0a, 0x81, 0x50, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    const coin = try parsePackedTxOutCoin(&value);
    try std.testing.expectEqual(@as(Coin, 1_710_000), coin);
}

test "ledger_snapshot: import local preprod snapshot account state" {
    const allocator = std.testing.allocator;

    const ledger_root = "db/preprod/ledger";
    const maybe_snapshot = findLatestSnapshotAtOrBefore(allocator, ledger_root, std.math.maxInt(SlotNo)) catch return;
    if (maybe_snapshot == null) return;

    var snapshot = maybe_snapshot.?;
    defer snapshot.deinit(allocator);

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state", .{snapshot.path});
    defer allocator.free(state_path);
    if (!fileExists(state_path)) return;

    std.fs.cwd().deleteTree("/tmp/kassadin-test-ledger-snapshot-state") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-ledger-snapshot-state") catch {};

    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-snapshot-state");
    defer ledger.deinit();

    const result = try importSnapshotAccountState(allocator, &ledger, state_path, .testnet);
    try std.testing.expect(result.reward_accounts_loaded > 0 or result.stake_deposits_loaded > 0);
    try std.testing.expect(
        result.stake_snapshot_mark_pools_loaded > 0 or
            result.stake_snapshot_set_pools_loaded > 0 or
            result.stake_snapshot_go_pools_loaded > 0,
    );
    try std.testing.expect(ledger.getStakeSnapshots().mark != null);
    try std.testing.expect(ledger.getStakeSnapshots().set != null);
    try std.testing.expect(ledger.getStakeSnapshots().go != null);
    try std.testing.expect(
        ledger.getStakeSnapshots().mark.?.total_stake > 0 or
            ledger.getStakeSnapshots().set.?.total_stake > 0 or
            ledger.getStakeSnapshots().go.?.total_stake > 0,
    );
    try std.testing.expect(
        ledger.getStakeSnapshots().mark.?.delegatorCount() > 0 or
            ledger.getStakeSnapshots().set.?.delegatorCount() > 0 or
            ledger.getStakeSnapshots().go.?.delegatorCount() > 0,
    );
}

test "ledger_snapshot: parse packed txin uses little-endian tx index in ancillary tables" {
    const key = [_]u8{
        0x22, 0x91, 0x0c, 0x04, 0x02, 0x8d, 0x88, 0xf9,
        0x0d, 0xf7, 0x1e, 0xc0, 0x24, 0x4f, 0x11, 0x1f,
        0xc1, 0xa8, 0xa0, 0xdb, 0x7e, 0x32, 0xc9, 0x5e,
        0x85, 0x60, 0xf8, 0x02, 0x2e, 0xb8, 0x6b, 0xdb,
        0x01, 0x00,
    };
    const tx_in = try parsePackedTxIn(&key);
    try std.testing.expectEqual(@as(u16, 1), tx_in.tx_ix);
}

test "ledger_snapshot: packed varlen matches snapshot output value encoding" {
    const bytes = [_]u8{ 0x81, 0xab, 0xbb, 0xc9, 0x4c };
    var pos: usize = 0;
    const value = try readPackedVarLen(&bytes, &pos);
    try std.testing.expectEqual(@as(u64, 359_589_068), value);
    try std.testing.expectEqual(bytes.len, pos);
}

test "ledger_snapshot: parse packed tag-2 txout coin from real ancillary sample" {
    const value = [_]u8{
        0x02, 0x01, 0xf7, 0x2d, 0x0e, 0x90, 0x15, 0x27, 0xe8, 0xbf, 0x83, 0x8d,
        0x79, 0x88, 0x0f, 0x96, 0x88, 0x23, 0xe7, 0xaa, 0x71, 0x91, 0x96, 0x3f,
        0xf6, 0xa5, 0xf8, 0x01, 0x3f, 0xab, 0x4f, 0x7b, 0xb5, 0x86, 0xa5, 0xf0,
        0x76, 0x1d, 0x85, 0xdd, 0x66, 0x4d, 0x69, 0xf7, 0x08, 0x5e, 0xe6, 0xcb,
        0xf2, 0x1b, 0x74, 0xb6, 0x12, 0xef, 0x01, 0x00, 0x00, 0x00, 0x5b, 0xc2,
        0x2e, 0x4c, 0x00, 0x81, 0x8a, 0x83, 0x17,
    };
    const output = try parsePackedTxOutInfo(&value);
    try std.testing.expectEqual(@as(Coin, 2_261_399), output.coin);
    const credential = output.stake_credential.?;
    try std.testing.expectEqual(types.CredentialType.key_hash, credential.cred_type);
}
