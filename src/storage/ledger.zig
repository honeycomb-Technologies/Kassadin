const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const certificates = @import("../ledger/certificates.zig");
const rewards_mod = @import("../ledger/rewards.zig");
const stake_mod = @import("../ledger/stake.zig");

pub const SlotNo = types.SlotNo;
pub const TxIn = types.TxIn;
pub const Coin = types.Coin;
pub const DeltaCoin = types.DeltaCoin;
pub const HeaderHash = types.HeaderHash;
pub const EpochNo = types.EpochNo;
pub const Credential = types.Credential;
pub const KeyHash = types.KeyHash;
pub const RewardAccount = types.RewardAccount;
pub const UnitInterval = types.UnitInterval;
pub const PoolOwnerMembership = types.PoolOwnerMembership;
pub const DRep = certificates.DRep;
pub const MIRPot = certificates.MIRPot;
pub const StakeSnapshots = stake_mod.StakeSnapshots;
pub const StakeDistribution = stake_mod.StakeDistribution;

/// A simplified UTxO entry (full TxOut support comes in Phase 3).
pub const UtxoEntry = struct {
    tx_in: TxIn,
    value: Coin,
    raw_cbor: []const u8, // original CBOR bytes for byte-preserving hashing
};

/// A ledger state diff produced by applying one block.
pub const LedgerDiff = struct {
    slot: SlotNo,
    block_hash: HeaderHash,
    consumed: []const UtxoEntry, // UTxOs consumed (full entries for rollback)
    produced: []const UtxoEntry, // UTxOs produced (outputs)
    treasury_balance_change: ?CoinStateChange = null,
    reserves_balance_change: ?CoinStateChange = null,
    fees_balance_change: ?CoinStateChange = null,
    snapshot_fees_change: ?CoinStateChange = null,
    mir_delta_reserves_change: ?DeltaCoinStateChange = null,
    mir_delta_treasury_change: ?DeltaCoinStateChange = null,
    reward_balance_changes: []const RewardBalanceChange = &.{},
    mir_reserves_changes: []const MIRRewardChange = &.{},
    mir_treasury_changes: []const MIRRewardChange = &.{},
    stake_deposit_changes: []const StakeDepositChange = &.{},
    pool_deposit_changes: []const PoolDepositChange = &.{},
    pool_config_changes: []const PoolConfigChange = &.{},
    future_pool_param_changes: []const FuturePoolParamsChange = &.{},
    pool_reward_account_changes: []const PoolRewardAccountChange = &.{},
    pool_owner_changes: []const PoolOwnerMembershipChange = &.{},
    future_pool_owner_changes: []const PoolOwnerMembershipChange = &.{},
    pool_retirement_changes: []const PoolRetirementChange = &.{},
    drep_deposit_changes: []const DRepDepositChange = &.{},
    stake_pool_delegation_changes: []const StakePoolDelegationChange = &.{},
    drep_delegation_changes: []const DRepDelegationChange = &.{},
    previous_epoch_blocks_made_changes: []const BlocksMadeChange = &.{},
    current_epoch_blocks_made_changes: []const BlocksMadeChange = &.{},
};

pub const RewardBalanceChange = struct {
    account: RewardAccount,
    previous: ?Coin,
    next: ?Coin,
};

pub const CoinStateChange = struct {
    previous: Coin,
    next: Coin,
};

pub const StakeDepositChange = struct {
    credential: Credential,
    previous: ?Coin,
    next: ?Coin,
};

pub const PoolDepositChange = struct {
    pool: KeyHash,
    previous: ?Coin,
    next: ?Coin,
};

pub const PoolConfig = struct {
    pledge: Coin,
    cost: Coin,
    margin: UnitInterval,
};

pub const PoolConfigChange = struct {
    pool: KeyHash,
    previous: ?PoolConfig,
    next: ?PoolConfig,
};

pub const FuturePoolParams = struct {
    config: PoolConfig,
    reward_account: RewardAccount,
};

pub const FuturePoolParamsChange = struct {
    pool: KeyHash,
    previous: ?FuturePoolParams,
    next: ?FuturePoolParams,
};

pub const PoolRewardAccountChange = struct {
    pool: KeyHash,
    previous: ?RewardAccount,
    next: ?RewardAccount,
};

pub const PoolOwnerMembershipChange = struct {
    membership: PoolOwnerMembership,
    previous: bool,
    next: bool,
};

pub const PoolRetirementChange = struct {
    pool: KeyHash,
    previous: ?EpochNo,
    next: ?EpochNo,
};

pub const DRepDepositChange = struct {
    credential: Credential,
    previous: ?Coin,
    next: ?Coin,
};

pub const StakePoolDelegationChange = struct {
    credential: Credential,
    previous: ?KeyHash,
    next: ?KeyHash,
};

pub const DRepDelegationChange = struct {
    credential: Credential,
    previous: ?DRep,
    next: ?DRep,
};

pub const BlocksMadeChange = struct {
    pool: KeyHash,
    previous: ?u64,
    next: ?u64,
};

pub const DeltaCoinStateChange = struct {
    previous: DeltaCoin,
    next: DeltaCoin,
};

pub const MIRRewardChange = struct {
    credential: Credential,
    previous: ?Coin,
    next: ?Coin,
};

/// Manages the ledger state: UTxO set, stake distribution, protocol parameters.
/// For Phase 2, this is a simplified in-memory UTxO set with diff-based rollback.
/// Full LMDB-backed storage comes when we need mainnet-scale UTxO sets.
pub const LedgerDB = struct {
    allocator: Allocator,

    /// Current UTxO set (in-memory for now — LMDB for production).
    utxo_set: std.AutoHashMap(TxIn, UtxoEntry),
    reward_balances: std.AutoHashMap(RewardAccount, Coin),
    reward_balances_tracked: bool,
    reward_account_network: types.Network,
    treasury_balance: Coin,
    reserves_balance: Coin,
    fees_balance: Coin,
    snapshot_fees: Coin,
    mir_reserves: std.AutoHashMap(Credential, Coin),
    mir_treasury: std.AutoHashMap(Credential, Coin),
    mir_delta_reserves: DeltaCoin,
    mir_delta_treasury: DeltaCoin,
    stake_snapshots: StakeSnapshots,
    stake_deposits: std.AutoHashMap(Credential, Coin),
    pool_deposits: std.AutoHashMap(KeyHash, Coin),
    pool_configs: std.AutoHashMap(KeyHash, PoolConfig),
    future_pool_params: std.AutoHashMap(KeyHash, FuturePoolParams),
    pool_reward_accounts: std.AutoHashMap(KeyHash, RewardAccount),
    pool_owners: std.AutoHashMap(PoolOwnerMembership, void),
    future_pool_owners: std.AutoHashMap(PoolOwnerMembership, void),
    pool_retirements: std.AutoHashMap(KeyHash, EpochNo),
    drep_deposits: std.AutoHashMap(Credential, Coin),
    stake_pool_delegations: std.AutoHashMap(Credential, KeyHash),
    drep_delegations: std.AutoHashMap(Credential, DRep),
    blocks_made_previous_epoch: std.AutoHashMap(KeyHash, u64),
    blocks_made_current_epoch: std.AutoHashMap(KeyHash, u64),

    /// Ring buffer of recent diffs for rollback support.
    /// Keeps the last k=2160 diffs.
    diffs: std.ArrayList(LedgerDiff),

    /// Current tip slot.
    tip_slot: ?SlotNo,

    /// Snapshot directory.
    snapshot_path: []const u8,

    pub fn init(allocator: Allocator, snapshot_path: []const u8) !LedgerDB {
        std.fs.cwd().makePath(snapshot_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return .{
            .allocator = allocator,
            .utxo_set = std.AutoHashMap(TxIn, UtxoEntry).init(allocator),
            .reward_balances = std.AutoHashMap(RewardAccount, Coin).init(allocator),
            .reward_balances_tracked = false,
            .reward_account_network = .testnet,
            .treasury_balance = 0,
            .reserves_balance = 0,
            .fees_balance = 0,
            .snapshot_fees = 0,
            .mir_reserves = std.AutoHashMap(Credential, Coin).init(allocator),
            .mir_treasury = std.AutoHashMap(Credential, Coin).init(allocator),
            .mir_delta_reserves = 0,
            .mir_delta_treasury = 0,
            .stake_snapshots = StakeSnapshots.init(allocator),
            .stake_deposits = std.AutoHashMap(Credential, Coin).init(allocator),
            .pool_deposits = std.AutoHashMap(KeyHash, Coin).init(allocator),
            .pool_configs = std.AutoHashMap(KeyHash, PoolConfig).init(allocator),
            .future_pool_params = std.AutoHashMap(KeyHash, FuturePoolParams).init(allocator),
            .pool_reward_accounts = std.AutoHashMap(KeyHash, RewardAccount).init(allocator),
            .pool_owners = std.AutoHashMap(PoolOwnerMembership, void).init(allocator),
            .future_pool_owners = std.AutoHashMap(PoolOwnerMembership, void).init(allocator),
            .pool_retirements = std.AutoHashMap(KeyHash, EpochNo).init(allocator),
            .drep_deposits = std.AutoHashMap(Credential, Coin).init(allocator),
            .stake_pool_delegations = std.AutoHashMap(Credential, KeyHash).init(allocator),
            .drep_delegations = std.AutoHashMap(Credential, DRep).init(allocator),
            .blocks_made_previous_epoch = std.AutoHashMap(KeyHash, u64).init(allocator),
            .blocks_made_current_epoch = std.AutoHashMap(KeyHash, u64).init(allocator),
            .diffs = .empty,
            .tip_slot = null,
            .snapshot_path = snapshot_path,
        };
    }

    pub fn deinit(self: *LedgerDB) void {
        // Free UTxO entries (these own their raw_cbor)
        var it = self.utxo_set.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.raw_cbor);
        }
        self.utxo_set.deinit();
        self.reward_balances.deinit();
        self.mir_reserves.deinit();
        self.mir_treasury.deinit();
        self.stake_snapshots.deinit();
        self.stake_deposits.deinit();
        self.pool_deposits.deinit();
        self.pool_configs.deinit();
        self.future_pool_params.deinit();
        self.pool_reward_accounts.deinit();
        self.pool_owners.deinit();
        self.future_pool_owners.deinit();
        self.pool_retirements.deinit();
        self.drep_deposits.deinit();
        self.stake_pool_delegations.deinit();
        self.drep_delegations.deinit();
        self.blocks_made_previous_epoch.deinit();
        self.blocks_made_current_epoch.deinit();

        // Diffs own their consumed/produced slices
        for (self.diffs.items) |diff| {
            freeEntries(self.allocator, diff.consumed);
            freeEntries(self.allocator, diff.produced);
            freeRewardChanges(self.allocator, diff.reward_balance_changes);
            freeMIRRewardChanges(self.allocator, diff.mir_reserves_changes);
            freeMIRRewardChanges(self.allocator, diff.mir_treasury_changes);
            freeStakeChanges(self.allocator, diff.stake_deposit_changes);
            freePoolChanges(self.allocator, diff.pool_deposit_changes);
            freePoolConfigChanges(self.allocator, diff.pool_config_changes);
            freeFuturePoolParamChanges(self.allocator, diff.future_pool_param_changes);
            freePoolRewardAccountChanges(self.allocator, diff.pool_reward_account_changes);
            freePoolOwnerMembershipChanges(self.allocator, diff.pool_owner_changes);
            freePoolOwnerMembershipChanges(self.allocator, diff.future_pool_owner_changes);
            freePoolRetirementChanges(self.allocator, diff.pool_retirement_changes);
            freeDRepChanges(self.allocator, diff.drep_deposit_changes);
            freeStakePoolDelegationChanges(self.allocator, diff.stake_pool_delegation_changes);
            freeDRepDelegationChanges(self.allocator, diff.drep_delegation_changes);
            freeBlocksMadeChanges(self.allocator, diff.previous_epoch_blocks_made_changes);
            freeBlocksMadeChanges(self.allocator, diff.current_epoch_blocks_made_changes);
        }
        self.diffs.deinit(self.allocator);
    }

    /// Apply a ledger diff (from a validated block).
    /// Takes ownership of the diff's consumed and produced slices.
    pub fn applyDiff(self: *LedgerDB, diff: LedgerDiff) !void {
        // Remove consumed UTxOs
        for (diff.consumed) |entry| {
            if (self.utxo_set.fetchRemove(entry.tx_in)) |removed| {
                self.allocator.free(removed.value.raw_cbor);
            }
        }

        // Add produced UTxOs
        for (diff.produced) |entry| {
            const owned_cbor = try self.allocator.dupe(u8, entry.raw_cbor);
            try self.utxo_set.put(entry.tx_in, .{
                .tx_in = entry.tx_in,
                .value = entry.value,
                .raw_cbor = owned_cbor,
            });
        }

        applyCoinStateChange(&self.treasury_balance, diff.treasury_balance_change);
        applyCoinStateChange(&self.reserves_balance, diff.reserves_balance_change);
        applyCoinStateChange(&self.fees_balance, diff.fees_balance_change);
        applyCoinStateChange(&self.snapshot_fees, diff.snapshot_fees_change);
        applyDeltaCoinStateChange(&self.mir_delta_reserves, diff.mir_delta_reserves_change);
        applyDeltaCoinStateChange(&self.mir_delta_treasury, diff.mir_delta_treasury_change);
        applyRewardBalanceChanges(&self.reward_balances, diff.reward_balance_changes);
        applyMIRRewardChanges(&self.mir_reserves, diff.mir_reserves_changes);
        applyMIRRewardChanges(&self.mir_treasury, diff.mir_treasury_changes);
        applyStakeDepositChanges(&self.stake_deposits, diff.stake_deposit_changes);
        applyPoolDepositChanges(&self.pool_deposits, diff.pool_deposit_changes);
        applyPoolConfigChanges(&self.pool_configs, diff.pool_config_changes);
        applyFuturePoolParamChanges(&self.future_pool_params, diff.future_pool_param_changes);
        applyPoolRewardAccountChanges(&self.pool_reward_accounts, diff.pool_reward_account_changes);
        applyPoolOwnerMembershipChanges(&self.pool_owners, diff.pool_owner_changes);
        applyPoolOwnerMembershipChanges(&self.future_pool_owners, diff.future_pool_owner_changes);
        applyPoolRetirementChanges(&self.pool_retirements, diff.pool_retirement_changes);
        applyDRepDepositChanges(&self.drep_deposits, diff.drep_deposit_changes);
        applyStakePoolDelegationChanges(&self.stake_pool_delegations, diff.stake_pool_delegation_changes);
        applyDRepDelegationChanges(&self.drep_delegations, diff.drep_delegation_changes);
        applyBlocksMadeChanges(&self.blocks_made_previous_epoch, diff.previous_epoch_blocks_made_changes);
        applyBlocksMadeChanges(&self.blocks_made_current_epoch, diff.current_epoch_blocks_made_changes);

        // Store diff for rollback (we take ownership of consumed/produced slices)
        try self.diffs.append(self.allocator, diff);

        // Trim diffs to k=2160
        const max_diffs = 2160;
        while (self.diffs.items.len > max_diffs) {
            const old = self.diffs.orderedRemove(0);
            freeEntries(self.allocator, old.consumed);
            freeEntries(self.allocator, old.produced);
            freeRewardChanges(self.allocator, old.reward_balance_changes);
            freeMIRRewardChanges(self.allocator, old.mir_reserves_changes);
            freeMIRRewardChanges(self.allocator, old.mir_treasury_changes);
            freeStakeChanges(self.allocator, old.stake_deposit_changes);
            freePoolChanges(self.allocator, old.pool_deposit_changes);
            freePoolConfigChanges(self.allocator, old.pool_config_changes);
            freeFuturePoolParamChanges(self.allocator, old.future_pool_param_changes);
            freePoolRewardAccountChanges(self.allocator, old.pool_reward_account_changes);
            freePoolOwnerMembershipChanges(self.allocator, old.pool_owner_changes);
            freePoolOwnerMembershipChanges(self.allocator, old.future_pool_owner_changes);
            freePoolRetirementChanges(self.allocator, old.pool_retirement_changes);
            freeDRepChanges(self.allocator, old.drep_deposit_changes);
            freeStakePoolDelegationChanges(self.allocator, old.stake_pool_delegation_changes);
            freeDRepDelegationChanges(self.allocator, old.drep_delegation_changes);
            freeBlocksMadeChanges(self.allocator, old.previous_epoch_blocks_made_changes);
            freeBlocksMadeChanges(self.allocator, old.current_epoch_blocks_made_changes);
        }

        self.tip_slot = diff.slot;
    }

    /// Rollback the last n diffs.
    pub fn rollback(self: *LedgerDB, n: usize) !void {
        var i: usize = 0;
        while (i < n and self.diffs.items.len > 0) : (i += 1) {
            const diff = self.diffs.pop().?;

            // Undo: remove produced UTxOs
            for (diff.produced) |entry| {
                if (self.utxo_set.fetchRemove(entry.tx_in)) |removed| {
                    self.allocator.free(removed.value.raw_cbor);
                }
            }

            // Undo: re-add consumed UTxOs with their original values.
            for (diff.consumed) |entry| {
                const owned_cbor = try self.allocator.dupe(u8, entry.raw_cbor);
                try self.utxo_set.put(entry.tx_in, .{
                    .tx_in = entry.tx_in,
                    .value = entry.value,
                    .raw_cbor = owned_cbor,
                });
            }

            // Free diff-owned slices
            freeEntries(self.allocator, diff.consumed);
            freeEntries(self.allocator, diff.produced);
            rollbackCoinStateChange(&self.treasury_balance, diff.treasury_balance_change);
            rollbackCoinStateChange(&self.reserves_balance, diff.reserves_balance_change);
            rollbackCoinStateChange(&self.fees_balance, diff.fees_balance_change);
            rollbackCoinStateChange(&self.snapshot_fees, diff.snapshot_fees_change);
            rollbackDeltaCoinStateChange(&self.mir_delta_reserves, diff.mir_delta_reserves_change);
            rollbackDeltaCoinStateChange(&self.mir_delta_treasury, diff.mir_delta_treasury_change);
            rollbackRewardBalanceChanges(&self.reward_balances, diff.reward_balance_changes);
            rollbackMIRRewardChanges(&self.mir_reserves, diff.mir_reserves_changes);
            rollbackMIRRewardChanges(&self.mir_treasury, diff.mir_treasury_changes);
            freeRewardChanges(self.allocator, diff.reward_balance_changes);
            freeMIRRewardChanges(self.allocator, diff.mir_reserves_changes);
            freeMIRRewardChanges(self.allocator, diff.mir_treasury_changes);
            rollbackStakeDepositChanges(&self.stake_deposits, diff.stake_deposit_changes);
            rollbackPoolDepositChanges(&self.pool_deposits, diff.pool_deposit_changes);
            rollbackPoolConfigChanges(&self.pool_configs, diff.pool_config_changes);
            rollbackFuturePoolParamChanges(&self.future_pool_params, diff.future_pool_param_changes);
            rollbackPoolRewardAccountChanges(&self.pool_reward_accounts, diff.pool_reward_account_changes);
            rollbackPoolOwnerMembershipChanges(&self.pool_owners, diff.pool_owner_changes);
            rollbackPoolOwnerMembershipChanges(&self.future_pool_owners, diff.future_pool_owner_changes);
            rollbackPoolRetirementChanges(&self.pool_retirements, diff.pool_retirement_changes);
            rollbackDRepDepositChanges(&self.drep_deposits, diff.drep_deposit_changes);
            rollbackStakePoolDelegationChanges(&self.stake_pool_delegations, diff.stake_pool_delegation_changes);
            rollbackDRepDelegationChanges(&self.drep_delegations, diff.drep_delegation_changes);
            rollbackBlocksMadeChanges(&self.blocks_made_previous_epoch, diff.previous_epoch_blocks_made_changes);
            rollbackBlocksMadeChanges(&self.blocks_made_current_epoch, diff.current_epoch_blocks_made_changes);
            freeStakeChanges(self.allocator, diff.stake_deposit_changes);
            freePoolChanges(self.allocator, diff.pool_deposit_changes);
            freePoolConfigChanges(self.allocator, diff.pool_config_changes);
            freeFuturePoolParamChanges(self.allocator, diff.future_pool_param_changes);
            freePoolRewardAccountChanges(self.allocator, diff.pool_reward_account_changes);
            freePoolOwnerMembershipChanges(self.allocator, diff.pool_owner_changes);
            freePoolOwnerMembershipChanges(self.allocator, diff.future_pool_owner_changes);
            freePoolRetirementChanges(self.allocator, diff.pool_retirement_changes);
            freeDRepChanges(self.allocator, diff.drep_deposit_changes);
            freeStakePoolDelegationChanges(self.allocator, diff.stake_pool_delegation_changes);
            freeDRepDelegationChanges(self.allocator, diff.drep_delegation_changes);
            freeBlocksMadeChanges(self.allocator, diff.previous_epoch_blocks_made_changes);
            freeBlocksMadeChanges(self.allocator, diff.current_epoch_blocks_made_changes);
        }

        // Update tip
        if (self.diffs.items.len > 0) {
            self.tip_slot = self.diffs.items[self.diffs.items.len - 1].slot;
        } else {
            self.tip_slot = null;
        }
    }

    /// Seed base UTxOs without recording a diff.
    /// Used when hydrating state from an external snapshot/query source.
    pub fn primeUtxos(self: *LedgerDB, entries: []const UtxoEntry) !u32 {
        var inserted: u32 = 0;

        for (entries) |entry| {
            if (self.utxo_set.contains(entry.tx_in)) continue;

            const owned_cbor = try self.allocator.dupe(u8, entry.raw_cbor);
            try self.utxo_set.put(entry.tx_in, .{
                .tx_in = entry.tx_in,
                .value = entry.value,
                .raw_cbor = owned_cbor,
            });
            inserted += 1;
        }

        return inserted;
    }

    /// Insert a UTxO entry loaded from an external snapshot.
    /// Snapshot imports use empty raw bytes to keep memory usage down.
    pub fn importUtxo(self: *LedgerDB, tx_in: TxIn, value: Coin) !void {
        if (self.utxo_set.contains(tx_in)) return;

        try self.utxo_set.put(tx_in, .{
            .tx_in = tx_in,
            .value = value,
            .raw_cbor = try self.allocator.alloc(u8, 0),
        });
    }

    pub fn importStakeDeposit(self: *LedgerDB, credential: Credential, deposit: Coin) !void {
        if (deposit == 0) return;
        try self.stake_deposits.put(credential, deposit);
    }

    pub fn importPoolDeposit(self: *LedgerDB, pool: KeyHash, deposit: Coin) !void {
        if (deposit == 0) return;
        try self.pool_deposits.put(pool, deposit);
    }

    pub fn importRewardBalance(self: *LedgerDB, account: RewardAccount, amount: Coin) !void {
        if (amount == 0) return;
        try self.reward_balances.put(account, amount);
    }

    pub fn importTreasuryBalance(self: *LedgerDB, amount: Coin) void {
        self.treasury_balance = amount;
    }

    pub fn importReservesBalance(self: *LedgerDB, amount: Coin) void {
        self.reserves_balance = amount;
    }

    pub fn importFeesBalance(self: *LedgerDB, amount: Coin) void {
        self.fees_balance = amount;
    }

    pub fn importSnapshotFees(self: *LedgerDB, amount: Coin) void {
        self.snapshot_fees = amount;
    }

    pub fn importMirReward(self: *LedgerDB, pot: MIRPot, credential: Credential, amount: Coin) !void {
        if (amount == 0) return;

        const map = switch (pot) {
            .reserves => &self.mir_reserves,
            .treasury => &self.mir_treasury,
        };
        try map.put(credential, amount);
    }

    pub fn importMirDeltaReserves(self: *LedgerDB, amount: DeltaCoin) void {
        self.mir_delta_reserves = amount;
    }

    pub fn importMirDeltaTreasury(self: *LedgerDB, amount: DeltaCoin) void {
        self.mir_delta_treasury = amount;
    }

    pub fn replaceStakeSnapshots(self: *LedgerDB, snapshots: StakeSnapshots) void {
        self.stake_snapshots.deinit();
        self.stake_snapshots = snapshots;
    }

    pub fn importPoolRewardAccount(self: *LedgerDB, pool: KeyHash, account: RewardAccount) !void {
        try self.pool_reward_accounts.put(pool, account);
    }

    pub fn importPoolOwnerMembership(self: *LedgerDB, pool: KeyHash, owner: KeyHash) !void {
        try self.pool_owners.put(.{
            .pool = pool,
            .owner = owner,
        }, {});
    }

    pub fn importFuturePoolOwnerMembership(self: *LedgerDB, pool: KeyHash, owner: KeyHash) !void {
        try self.future_pool_owners.put(.{
            .pool = pool,
            .owner = owner,
        }, {});
    }

    pub fn importPoolConfig(self: *LedgerDB, pool: KeyHash, config: PoolConfig) !void {
        try self.pool_configs.put(pool, config);
    }

    pub fn importFuturePoolParams(self: *LedgerDB, pool: KeyHash, params: FuturePoolParams) !void {
        try self.future_pool_params.put(pool, params);
    }

    pub fn importPoolRetirement(self: *LedgerDB, pool: KeyHash, epoch: EpochNo) !void {
        try self.pool_retirements.put(pool, epoch);
    }

    pub fn importStakePoolDelegation(self: *LedgerDB, credential: Credential, pool: KeyHash) !void {
        try self.stake_pool_delegations.put(credential, pool);
    }

    pub fn importDRepDelegation(self: *LedgerDB, credential: Credential, drep: DRep) !void {
        try self.drep_delegations.put(credential, drep);
    }

    pub fn importPreviousEpochBlocksMade(self: *LedgerDB, pool: KeyHash, count: u64) !void {
        if (count == 0) return;
        try self.blocks_made_previous_epoch.put(pool, count);
    }

    pub fn importCurrentEpochBlocksMade(self: *LedgerDB, pool: KeyHash, count: u64) !void {
        if (count == 0) return;
        try self.blocks_made_current_epoch.put(pool, count);
    }

    pub fn setTipSlot(self: *LedgerDB, slot: ?SlotNo) void {
        self.tip_slot = slot;
    }

    /// Lookup a UTxO by TxIn.
    pub fn lookupUtxo(self: *const LedgerDB, txin: TxIn) ?*const UtxoEntry {
        return self.utxo_set.getPtr(txin);
    }

    pub fn lookupStakeDeposit(self: *const LedgerDB, credential: Credential) ?Coin {
        return self.stake_deposits.get(credential);
    }

    pub fn lookupRewardBalance(self: *const LedgerDB, account: RewardAccount) ?Coin {
        return self.reward_balances.get(account);
    }

    pub fn lookupMirReward(
        self: *const LedgerDB,
        pot: MIRPot,
        credential: Credential,
    ) ?Coin {
        return switch (pot) {
            .reserves => self.mir_reserves.get(credential),
            .treasury => self.mir_treasury.get(credential),
        };
    }

    pub fn getTreasuryBalance(self: *const LedgerDB) Coin {
        return self.treasury_balance;
    }

    pub fn getReservesBalance(self: *const LedgerDB) Coin {
        return self.reserves_balance;
    }

    pub fn getFeesBalance(self: *const LedgerDB) Coin {
        return self.fees_balance;
    }

    pub fn getSnapshotFees(self: *const LedgerDB) Coin {
        return self.snapshot_fees;
    }

    pub fn getMirDeltaReserves(self: *const LedgerDB) DeltaCoin {
        return self.mir_delta_reserves;
    }

    pub fn getMirDeltaTreasury(self: *const LedgerDB) DeltaCoin {
        return self.mir_delta_treasury;
    }

    pub fn getStakeSnapshots(self: *const LedgerDB) *const StakeSnapshots {
        return &self.stake_snapshots;
    }

    pub fn lookupPoolDeposit(self: *const LedgerDB, pool: KeyHash) ?Coin {
        return self.pool_deposits.get(pool);
    }

    pub fn lookupPoolConfig(self: *const LedgerDB, pool: KeyHash) ?PoolConfig {
        return self.pool_configs.get(pool);
    }

    pub fn lookupFuturePoolParams(self: *const LedgerDB, pool: KeyHash) ?FuturePoolParams {
        return self.future_pool_params.get(pool);
    }

    pub fn lookupPoolRewardAccount(self: *const LedgerDB, pool: KeyHash) ?RewardAccount {
        return self.pool_reward_accounts.get(pool);
    }

    pub fn isPoolOwner(self: *const LedgerDB, pool: KeyHash, owner: KeyHash) bool {
        return self.pool_owners.contains(.{
            .pool = pool,
            .owner = owner,
        });
    }

    pub fn isFuturePoolOwner(self: *const LedgerDB, pool: KeyHash, owner: KeyHash) bool {
        return self.future_pool_owners.contains(.{
            .pool = pool,
            .owner = owner,
        });
    }

    pub fn listPoolOwners(
        self: *const LedgerDB,
        allocator: Allocator,
        pool: KeyHash,
        future: bool,
    ) ![]KeyHash {
        var owners: std.ArrayList(KeyHash) = .empty;
        defer owners.deinit(allocator);

        var it = if (future) self.future_pool_owners.iterator() else self.pool_owners.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, &entry.key_ptr.pool, &pool)) continue;
            try owners.append(allocator, entry.key_ptr.owner);
        }

        return owners.toOwnedSlice(allocator);
    }

    pub fn lookupPoolRetirement(self: *const LedgerDB, pool: KeyHash) ?EpochNo {
        return self.pool_retirements.get(pool);
    }

    pub fn lookupDRepDeposit(self: *const LedgerDB, credential: Credential) ?Coin {
        return self.drep_deposits.get(credential);
    }

    pub fn lookupStakePoolDelegation(self: *const LedgerDB, credential: Credential) ?KeyHash {
        return self.stake_pool_delegations.get(credential);
    }

    pub fn lookupDRepDelegation(self: *const LedgerDB, credential: Credential) ?DRep {
        return self.drep_delegations.get(credential);
    }

    pub fn lookupPreviousEpochBlocksMade(self: *const LedgerDB, pool: KeyHash) ?u64 {
        return self.blocks_made_previous_epoch.get(pool);
    }

    pub fn lookupCurrentEpochBlocksMade(self: *const LedgerDB, pool: KeyHash) ?u64 {
        return self.blocks_made_current_epoch.get(pool);
    }

    pub fn setRewardBalancesTracked(self: *LedgerDB, tracked: bool) void {
        self.reward_balances_tracked = tracked;
    }

    pub fn areRewardBalancesTracked(self: *const LedgerDB) bool {
        return self.reward_balances_tracked;
    }

    pub fn setRewardAccountNetwork(self: *LedgerDB, network: types.Network) void {
        self.reward_account_network = network;
    }

    pub fn setRewardBalance(self: *LedgerDB, account: RewardAccount, amount: Coin) !void {
        try self.reward_balances.put(account, amount);
    }

    pub fn buildFeePotDiff(
        self: *const LedgerDB,
        allocator: Allocator,
        slot: SlotNo,
        block_hash: HeaderHash,
        added_fees: Coin,
    ) !?LedgerDiff {
        if (added_fees == 0) return null;

        return .{
            .slot = slot,
            .block_hash = block_hash,
            .consumed = try allocator.alloc(UtxoEntry, 0),
            .produced = try allocator.alloc(UtxoEntry, 0),
            .fees_balance_change = .{
                .previous = self.fees_balance,
                .next = self.fees_balance + added_fees,
            },
        };
    }

    pub fn buildEpochFeeRolloverDiff(
        self: *const LedgerDB,
        allocator: Allocator,
        slot: SlotNo,
        block_hash: HeaderHash,
    ) !?LedgerDiff {
        if (self.fees_balance == 0) return null;

        return .{
            .slot = slot,
            .block_hash = block_hash,
            .consumed = try allocator.alloc(UtxoEntry, 0),
            .produced = try allocator.alloc(UtxoEntry, 0),
            .fees_balance_change = .{
                .previous = self.fees_balance,
                .next = 0,
            },
            .snapshot_fees_change = .{
                .previous = self.snapshot_fees,
                .next = self.snapshot_fees + self.fees_balance,
            },
        };
    }

    pub fn buildCurrentEpochBlocksMadeDiff(
        self: *const LedgerDB,
        allocator: Allocator,
        slot: SlotNo,
        block_hash: HeaderHash,
        pool: KeyHash,
    ) !?LedgerDiff {
        const previous = self.lookupCurrentEpochBlocksMade(pool) orelse 0;
        const next = previous + 1;
        const changes = try allocator.alloc(BlocksMadeChange, 1);
        changes[0] = .{
            .pool = pool,
            .previous = if (previous == 0) null else previous,
            .next = next,
        };

        return .{
            .slot = slot,
            .block_hash = block_hash,
            .consumed = try allocator.alloc(UtxoEntry, 0),
            .produced = try allocator.alloc(UtxoEntry, 0),
            .current_epoch_blocks_made_changes = changes,
        };
    }

    pub fn buildEpochBlocksMadeShiftDiff(
        self: *const LedgerDB,
        allocator: Allocator,
        slot: SlotNo,
        block_hash: HeaderHash,
    ) !?LedgerDiff {
        if (self.blocks_made_previous_epoch.count() == 0 and self.blocks_made_current_epoch.count() == 0) {
            return null;
        }

        var previous_changes: std.ArrayList(BlocksMadeChange) = .empty;
        defer previous_changes.deinit(allocator);
        var current_changes: std.ArrayList(BlocksMadeChange) = .empty;
        defer current_changes.deinit(allocator);

        var current_it = self.blocks_made_current_epoch.iterator();
        while (current_it.next()) |entry| {
            try previous_changes.append(allocator, .{
                .pool = entry.key_ptr.*,
                .previous = self.lookupPreviousEpochBlocksMade(entry.key_ptr.*),
                .next = entry.value_ptr.*,
            });
            try current_changes.append(allocator, .{
                .pool = entry.key_ptr.*,
                .previous = entry.value_ptr.*,
                .next = null,
            });
        }

        var previous_it = self.blocks_made_previous_epoch.iterator();
        while (previous_it.next()) |entry| {
            if (self.blocks_made_current_epoch.contains(entry.key_ptr.*)) continue;
            try previous_changes.append(allocator, .{
                .pool = entry.key_ptr.*,
                .previous = entry.value_ptr.*,
                .next = null,
            });
        }

        return .{
            .slot = slot,
            .block_hash = block_hash,
            .consumed = try allocator.alloc(UtxoEntry, 0),
            .produced = try allocator.alloc(UtxoEntry, 0),
            .previous_epoch_blocks_made_changes = try previous_changes.toOwnedSlice(allocator),
            .current_epoch_blocks_made_changes = try current_changes.toOwnedSlice(allocator),
        };
    }

    pub fn buildPoolReapDiff(
        self: *const LedgerDB,
        allocator: Allocator,
        slot: SlotNo,
        block_hash: HeaderHash,
        epoch: EpochNo,
    ) !?LedgerDiff {
        var retired_pools: std.ArrayList(KeyHash) = .empty;
        defer retired_pools.deinit(allocator);

        var retirements = self.pool_retirements.iterator();
        while (retirements.next()) |entry| {
            if (entry.value_ptr.* == epoch) {
                try retired_pools.append(allocator, entry.key_ptr.*);
            }
        }

        var reward_changes: std.ArrayList(RewardBalanceChange) = .empty;
        defer reward_changes.deinit(allocator);
        var pool_changes: std.ArrayList(PoolDepositChange) = .empty;
        defer pool_changes.deinit(allocator);
        var pool_config_changes: std.ArrayList(PoolConfigChange) = .empty;
        defer pool_config_changes.deinit(allocator);
        var future_pool_param_changes: std.ArrayList(FuturePoolParamsChange) = .empty;
        defer future_pool_param_changes.deinit(allocator);
        var pool_reward_account_changes: std.ArrayList(PoolRewardAccountChange) = .empty;
        defer pool_reward_account_changes.deinit(allocator);
        var pool_owner_changes: std.ArrayList(PoolOwnerMembershipChange) = .empty;
        defer pool_owner_changes.deinit(allocator);
        var future_pool_owner_changes: std.ArrayList(PoolOwnerMembershipChange) = .empty;
        defer future_pool_owner_changes.deinit(allocator);
        var pool_retirement_changes: std.ArrayList(PoolRetirementChange) = .empty;
        defer pool_retirement_changes.deinit(allocator);
        var stake_pool_delegation_changes: std.ArrayList(StakePoolDelegationChange) = .empty;
        defer stake_pool_delegation_changes.deinit(allocator);
        var treasury_delta: Coin = 0;

        var future_params = self.future_pool_params.iterator();
        while (future_params.next()) |entry| {
            try pool_config_changes.append(allocator, .{
                .pool = entry.key_ptr.*,
                .previous = self.lookupPoolConfig(entry.key_ptr.*),
                .next = entry.value_ptr.config,
            });
            try pool_reward_account_changes.append(allocator, .{
                .pool = entry.key_ptr.*,
                .previous = self.lookupPoolRewardAccount(entry.key_ptr.*),
                .next = entry.value_ptr.reward_account,
            });
            try future_pool_param_changes.append(allocator, .{
                .pool = entry.key_ptr.*,
                .previous = entry.value_ptr.*,
                .next = null,
            });

            var existing_owner_it = self.pool_owners.iterator();
            while (existing_owner_it.next()) |owner_entry| {
                if (!std.mem.eql(u8, &owner_entry.key_ptr.pool, entry.key_ptr)) continue;
                if (!self.future_pool_owners.contains(owner_entry.key_ptr.*)) {
                    try pool_owner_changes.append(allocator, .{
                        .membership = owner_entry.key_ptr.*,
                        .previous = true,
                        .next = false,
                    });
                }
            }

            var staged_owner_it = self.future_pool_owners.iterator();
            while (staged_owner_it.next()) |owner_entry| {
                if (!std.mem.eql(u8, &owner_entry.key_ptr.pool, entry.key_ptr)) continue;
                try future_pool_owner_changes.append(allocator, .{
                    .membership = owner_entry.key_ptr.*,
                    .previous = true,
                    .next = false,
                });
                if (!self.pool_owners.contains(owner_entry.key_ptr.*)) {
                    try pool_owner_changes.append(allocator, .{
                        .membership = owner_entry.key_ptr.*,
                        .previous = false,
                        .next = true,
                    });
                }
            }
        }

        if (retired_pools.items.len == 0 and future_pool_param_changes.items.len == 0) return null;

        for (retired_pools.items) |pool| {
            if (self.lookupPoolDeposit(pool)) |deposit| {
                try pool_changes.append(allocator, .{
                    .pool = pool,
                    .previous = deposit,
                    .next = null,
                });

                if (self.lookupPoolRewardAccount(pool)) |reward_account| {
                    if (self.lookupRewardBalance(reward_account) != null or self.lookupStakeDeposit(reward_account.credential) != null) {
                        try appendPoolReapRewardChange(
                            allocator,
                            &reward_changes,
                            self,
                            reward_account,
                            deposit,
                        );
                    } else {
                        treasury_delta += deposit;
                    }

                    try pool_reward_account_changes.append(allocator, .{
                        .pool = pool,
                        .previous = reward_account,
                        .next = null,
                    });
                }
            }

            if (self.lookupPoolConfig(pool)) |config| {
                try pool_config_changes.append(allocator, .{
                    .pool = pool,
                    .previous = config,
                    .next = null,
                });
            }

            var owner_it = self.pool_owners.iterator();
            while (owner_it.next()) |owner_entry| {
                if (!std.mem.eql(u8, &owner_entry.key_ptr.pool, &pool)) continue;
                try pool_owner_changes.append(allocator, .{
                    .membership = owner_entry.key_ptr.*,
                    .previous = true,
                    .next = false,
                });
            }

            var future_owner_it = self.future_pool_owners.iterator();
            while (future_owner_it.next()) |owner_entry| {
                if (!std.mem.eql(u8, &owner_entry.key_ptr.pool, &pool)) continue;
                try future_pool_owner_changes.append(allocator, .{
                    .membership = owner_entry.key_ptr.*,
                    .previous = true,
                    .next = false,
                });
            }

            try pool_retirement_changes.append(allocator, .{
                .pool = pool,
                .previous = epoch,
                .next = null,
            });

            var delegations = self.stake_pool_delegations.iterator();
            while (delegations.next()) |entry| {
                if (std.mem.eql(u8, &entry.value_ptr.*, &pool)) {
                    try stake_pool_delegation_changes.append(allocator, .{
                        .credential = entry.key_ptr.*,
                        .previous = pool,
                        .next = null,
                    });
                }
            }
        }

        return .{
            .slot = slot,
            .block_hash = block_hash,
            .consumed = try allocator.alloc(UtxoEntry, 0),
            .produced = try allocator.alloc(UtxoEntry, 0),
            .treasury_balance_change = if (treasury_delta > 0) .{
                .previous = self.treasury_balance,
                .next = self.treasury_balance + treasury_delta,
            } else null,
            .reward_balance_changes = try reward_changes.toOwnedSlice(allocator),
            .pool_deposit_changes = try pool_changes.toOwnedSlice(allocator),
            .pool_config_changes = try pool_config_changes.toOwnedSlice(allocator),
            .future_pool_param_changes = try future_pool_param_changes.toOwnedSlice(allocator),
            .pool_reward_account_changes = try pool_reward_account_changes.toOwnedSlice(allocator),
            .pool_owner_changes = try pool_owner_changes.toOwnedSlice(allocator),
            .future_pool_owner_changes = try future_pool_owner_changes.toOwnedSlice(allocator),
            .pool_retirement_changes = try pool_retirement_changes.toOwnedSlice(allocator),
            .stake_pool_delegation_changes = try stake_pool_delegation_changes.toOwnedSlice(allocator),
        };
    }

    /// Rotate stake snapshots at an epoch boundary and build the new mark
    /// distribution from currently tracked delegations and reward balances.
    pub fn rotateStakeSnapshots(self: *LedgerDB, new_epoch: EpochNo) void {
        self.stake_snapshots.onEpochBoundary(new_epoch);

        // Populate the new mark snapshot from current delegations.
        if (self.stake_snapshots.mark) |*mark| {
            var it = self.stake_pool_delegations.iterator();
            while (it.next()) |entry| {
                const cred = entry.key_ptr.*;
                const pool = entry.value_ptr.*;
                const acct = RewardAccount{ .network = self.reward_account_network, .credential = cred };
                const balance = self.reward_balances.get(acct) orelse 0;
                const deposit = self.stake_deposits.get(cred) orelse 0;
                const delegated = balance + deposit;
                if (delegated == 0) continue;

                const is_owner = cred.cred_type == .key_hash and self.isPoolOwner(pool, cred.hash);
                mark.setDelegatedStake(cred, pool, delegated) catch {};
                if (mark.pools.getPtr(pool)) |existing| {
                    existing.active_stake += delegated;
                    if (is_owner) {
                        existing.self_delegated_owner_stake += delegated;
                        mark.setPoolOwnerMembership(pool, cred.hash) catch {};
                    }
                } else {
                    const current_config = self.lookupPoolConfig(pool);
                    const current_reward_account = self.lookupPoolRewardAccount(pool);
                    const pool_template = self.lookupSnapshotPoolStake(pool);
                    const pledge = if (current_config) |config| config.pledge else if (pool_template) |template| template.pledge else 0;
                    const cost = if (current_config) |config| config.cost else if (pool_template) |template| template.cost else 0;
                    const margin = if (current_config) |config| config.margin else if (pool_template) |template| template.margin else types.UnitInterval{ .numerator = 0, .denominator = 1 };
                    const reward_account = if (current_reward_account) |account| account else if (pool_template) |template| template.reward_account else continue;
                    mark.setPoolStake(
                        pool,
                        delegated,
                        if (is_owner) delegated else 0,
                        pledge,
                        cost,
                        margin,
                        reward_account,
                    ) catch {};
                    if (is_owner) {
                        mark.setPoolOwnerMembership(pool, cred.hash) catch {};
                    }
                }
            }
            mark.finalize();
        }
    }

    /// Build a reward distribution diff for an epoch boundary.
    /// Uses the "go" snapshot (2 epochs prior) to distribute rewards.
    pub fn buildEpochRewardDiff(
        self: *const LedgerDB,
        allocator: Allocator,
        slot: SlotNo,
        block_hash: HeaderHash,
        params: rewards_mod.RewardParams,
        slots_per_epoch: u64,
    ) !?LedgerDiff {
        const go_dist = self.stake_snapshots.go orelse return null;
        if (go_dist.total_stake == 0) return null;

        const epoch_rewards = rewards_mod.calculateEpochRewards(
            self.reserves_balance,
            self.snapshot_fees,
            params,
        );
        if (epoch_rewards.pool_rewards == 0) return null;

        var reward_changes: std.ArrayList(RewardBalanceChange) = .empty;
        defer reward_changes.deinit(allocator);

        const total_stake = params.total_lovelace -| self.reserves_balance;
        const blocks_total = rewards_mod.calculateExpectedBlocks(slots_per_epoch, params.active_slot_coeff);

        var total_distributed: Coin = 0;
        var pool_it = go_dist.pools.iterator();
        while (pool_it.next()) |entry| {
            const pool_stake = entry.value_ptr;
            if (pool_stake.active_stake == 0) continue;
            if (pool_stake.self_delegated_owner_stake < pool_stake.pledge) continue;
            const blocks_made = self.lookupPreviousEpochBlocksMade(entry.key_ptr.*) orelse 0;
            if (blocks_made == 0) continue;

            const pool_reward = rewards_mod.calculatePoolReward(
                pool_stake.active_stake,
                total_stake,
                go_dist.total_stake,
                epoch_rewards.pool_rewards,
                pool_stake.pledge,
                params,
                blocks_made,
                blocks_total,
            );
            if (pool_reward == 0) continue;

            const leader_reward = rewards_mod.calculatePoolLeaderReward(
                pool_reward,
                pool_stake.cost,
                pool_stake.margin,
                pool_stake.self_delegated_owner_stake,
                pool_stake.active_stake,
            );

            if (leader_reward > 0) {
                try appendPoolReapRewardChange(
                    allocator,
                    &reward_changes,
                    self,
                    pool_stake.reward_account,
                    leader_reward,
                );
                total_distributed += leader_reward;
            }

            var member_distributed: Coin = 0;
            var deleg_it = go_dist.delegators.iterator();
            while (deleg_it.next()) |deleg_entry| {
                const delegated = deleg_entry.value_ptr.*;
                if (!std.mem.eql(u8, &delegated.pool_id, entry.key_ptr)) continue;
                if (delegated.active_stake == 0) continue;
                if (delegated.credential.cred_type == .key_hash and go_dist.isPoolOwner(entry.key_ptr.*, delegated.credential.hash)) {
                    continue;
                }

                const reward = rewards_mod.calculatePoolMemberReward(
                    pool_reward,
                    pool_stake.cost,
                    pool_stake.margin,
                    delegated.active_stake,
                    pool_stake.active_stake,
                );
                if (reward == 0) continue;

                try appendPoolReapRewardChange(
                    allocator,
                    &reward_changes,
                    self,
                    .{ .network = self.reward_account_network, .credential = delegated.credential },
                    reward,
                );
                member_distributed += reward;
            }
            total_distributed += member_distributed;
        }

        if (total_distributed == 0) return null;

        return .{
            .slot = slot,
            .block_hash = block_hash,
            .consumed = try allocator.alloc(UtxoEntry, 0),
            .produced = try allocator.alloc(UtxoEntry, 0),
            .treasury_balance_change = .{
                .previous = self.treasury_balance,
                .next = self.treasury_balance + epoch_rewards.treasury_cut,
            },
            .reserves_balance_change = .{
                .previous = self.reserves_balance,
                .next = self.reserves_balance -| (total_distributed + epoch_rewards.treasury_cut),
            },
            .snapshot_fees_change = .{
                .previous = self.snapshot_fees,
                .next = 0,
            },
            .reward_balance_changes = try reward_changes.toOwnedSlice(allocator),
        };
    }

    pub fn buildEpochMirDiff(
        self: *const LedgerDB,
        allocator: Allocator,
        slot: SlotNo,
        block_hash: HeaderHash,
    ) !?LedgerDiff {
        if (self.mir_reserves.count() == 0 and
            self.mir_treasury.count() == 0 and
            self.mir_delta_reserves == 0 and
            self.mir_delta_treasury == 0)
        {
            return null;
        }

        var reward_changes: std.ArrayList(RewardBalanceChange) = .empty;
        defer reward_changes.deinit(allocator);
        var mir_reserves_changes: std.ArrayList(MIRRewardChange) = .empty;
        defer mir_reserves_changes.deinit(allocator);
        var mir_treasury_changes: std.ArrayList(MIRRewardChange) = .empty;
        defer mir_treasury_changes.deinit(allocator);

        var total_reserves_payout: Coin = 0;
        var reserve_it = self.mir_reserves.iterator();
        while (reserve_it.next()) |entry| {
            try mir_reserves_changes.append(allocator, .{
                .credential = entry.key_ptr.*,
                .previous = entry.value_ptr.*,
                .next = null,
            });
            if (!self.isRegisteredRewardCredential(entry.key_ptr.*)) continue;
            total_reserves_payout += entry.value_ptr.*;
            try appendPoolReapRewardChange(
                allocator,
                &reward_changes,
                self,
                .{ .network = self.reward_account_network, .credential = entry.key_ptr.* },
                entry.value_ptr.*,
            );
        }

        var total_treasury_payout: Coin = 0;
        var treasury_it = self.mir_treasury.iterator();
        while (treasury_it.next()) |entry| {
            try mir_treasury_changes.append(allocator, .{
                .credential = entry.key_ptr.*,
                .previous = entry.value_ptr.*,
                .next = null,
            });
            if (!self.isRegisteredRewardCredential(entry.key_ptr.*)) continue;
            total_treasury_payout += entry.value_ptr.*;
            try appendPoolReapRewardChange(
                allocator,
                &reward_changes,
                self,
                .{ .network = self.reward_account_network, .credential = entry.key_ptr.* },
                entry.value_ptr.*,
            );
        }

        const available_reserves = addDeltaCoinChecked(self.reserves_balance, self.mir_delta_reserves);
        const available_treasury = addDeltaCoinChecked(self.treasury_balance, self.mir_delta_treasury);
        const success = if (available_reserves) |reserves_after_delta|
            if (available_treasury) |treasury_after_delta|
                total_reserves_payout <= reserves_after_delta and total_treasury_payout <= treasury_after_delta
            else
                false
        else
            false;

        return .{
            .slot = slot,
            .block_hash = block_hash,
            .consumed = try allocator.alloc(UtxoEntry, 0),
            .produced = try allocator.alloc(UtxoEntry, 0),
            .treasury_balance_change = if (success) .{
                .previous = self.treasury_balance,
                .next = available_treasury.? - total_treasury_payout,
            } else null,
            .reserves_balance_change = if (success) .{
                .previous = self.reserves_balance,
                .next = available_reserves.? - total_reserves_payout,
            } else null,
            .mir_delta_reserves_change = .{
                .previous = self.mir_delta_reserves,
                .next = 0,
            },
            .mir_delta_treasury_change = .{
                .previous = self.mir_delta_treasury,
                .next = 0,
            },
            .reward_balance_changes = if (success)
                try reward_changes.toOwnedSlice(allocator)
            else
                try allocator.alloc(RewardBalanceChange, 0),
            .mir_reserves_changes = try mir_reserves_changes.toOwnedSlice(allocator),
            .mir_treasury_changes = try mir_treasury_changes.toOwnedSlice(allocator),
        };
    }

    fn lookupSnapshotPoolStake(self: *const LedgerDB, pool: KeyHash) ?stake_mod.PoolStake {
        if (self.stake_snapshots.mark) |*mark| {
            if (mark.getPool(pool)) |entry| return entry.*;
        }
        if (self.stake_snapshots.set) |*set| {
            if (set.getPool(pool)) |entry| return entry.*;
        }
        if (self.stake_snapshots.go) |*go| {
            if (go.getPool(pool)) |entry| return entry.*;
        }
        return null;
    }

    /// Save ledger state to a binary checkpoint file.
    pub fn saveCheckpoint(self: *const LedgerDB, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        // Helper to write big-endian integers
        var buf: [8]u8 = undefined;

        // Header: magic + version + tip_slot
        try file.writeAll("KLED");
        std.mem.writeInt(u32, buf[0..4], 6, .big);
        try file.writeAll(buf[0..4]);
        std.mem.writeInt(u64, &buf, self.tip_slot orelse 0, .big);
        try file.writeAll(&buf);
        try file.writeAll(&[_]u8{if (self.tip_slot != null) 1 else 0});

        // Section 1: Scalar state
        std.mem.writeInt(u64, &buf, self.treasury_balance, .big);
        try file.writeAll(&buf);
        std.mem.writeInt(u64, &buf, self.reserves_balance, .big);
        try file.writeAll(&buf);
        std.mem.writeInt(u64, &buf, self.fees_balance, .big);
        try file.writeAll(&buf);
        std.mem.writeInt(u64, &buf, self.snapshot_fees, .big);
        try file.writeAll(&buf);
        try file.writeAll(&[_]u8{if (self.reward_balances_tracked) 1 else 0});

        // Section 2: UTxO count (we skip UTxOs — loaded from Mithril snapshot)
        std.mem.writeInt(u64, &buf, 0, .big);
        try file.writeAll(&buf);

        // Section 3: Reward balances
        std.mem.writeInt(u64, &buf, @intCast(self.reward_balances.count()), .big);
        try file.writeAll(&buf);
        var reward_it = self.reward_balances.iterator();
        while (reward_it.next()) |entry| {
            try file.writeAll(&[_]u8{@intFromEnum(entry.key_ptr.network)});
            try file.writeAll(&[_]u8{@intFromEnum(entry.key_ptr.credential.cred_type)});
            try file.writeAll(&entry.key_ptr.credential.hash);
            std.mem.writeInt(u64, &buf, entry.value_ptr.*, .big);
            try file.writeAll(&buf);
        }

        // Section 4: Stake deposits
        std.mem.writeInt(u64, &buf, @intCast(self.stake_deposits.count()), .big);
        try file.writeAll(&buf);
        var stake_it = self.stake_deposits.iterator();
        while (stake_it.next()) |entry| {
            try file.writeAll(&[_]u8{@intFromEnum(entry.key_ptr.cred_type)});
            try file.writeAll(&entry.key_ptr.hash);
            std.mem.writeInt(u64, &buf, entry.value_ptr.*, .big);
            try file.writeAll(&buf);
        }

        // Section 5: Pool deposits
        std.mem.writeInt(u64, &buf, @intCast(self.pool_deposits.count()), .big);
        try file.writeAll(&buf);
        var pool_dep_it = self.pool_deposits.iterator();
        while (pool_dep_it.next()) |entry| {
            try file.writeAll(entry.key_ptr);
            std.mem.writeInt(u64, &buf, entry.value_ptr.*, .big);
            try file.writeAll(&buf);
        }

        // Section 6: Pool reward accounts
        std.mem.writeInt(u64, &buf, @intCast(self.pool_reward_accounts.count()), .big);
        try file.writeAll(&buf);
        var pool_acct_it = self.pool_reward_accounts.iterator();
        while (pool_acct_it.next()) |entry| {
            try file.writeAll(entry.key_ptr);
            try file.writeAll(&[_]u8{@intFromEnum(entry.value_ptr.network)});
            try file.writeAll(&[_]u8{@intFromEnum(entry.value_ptr.credential.cred_type)});
            try file.writeAll(&entry.value_ptr.credential.hash);
        }

        // Section 7: Pool retirements
        std.mem.writeInt(u64, &buf, @intCast(self.pool_retirements.count()), .big);
        try file.writeAll(&buf);
        var pool_ret_it = self.pool_retirements.iterator();
        while (pool_ret_it.next()) |entry| {
            try file.writeAll(entry.key_ptr);
            std.mem.writeInt(u64, &buf, entry.value_ptr.*, .big);
            try file.writeAll(&buf);
        }

        // Section 8: Stake pool delegations
        std.mem.writeInt(u64, &buf, @intCast(self.stake_pool_delegations.count()), .big);
        try file.writeAll(&buf);
        var deleg_it = self.stake_pool_delegations.iterator();
        while (deleg_it.next()) |entry| {
            try file.writeAll(&[_]u8{@intFromEnum(entry.key_ptr.cred_type)});
            try file.writeAll(&entry.key_ptr.hash);
            try file.writeAll(entry.value_ptr);
        }

        // Section 9: DRep deposits
        std.mem.writeInt(u64, &buf, @intCast(self.drep_deposits.count()), .big);
        try file.writeAll(&buf);
        var drep_dep_it = self.drep_deposits.iterator();
        while (drep_dep_it.next()) |entry| {
            try file.writeAll(&[_]u8{@intFromEnum(entry.key_ptr.cred_type)});
            try file.writeAll(&entry.key_ptr.hash);
            std.mem.writeInt(u64, &buf, entry.value_ptr.*, .big);
            try file.writeAll(&buf);
        }

        // Section 10: DRep delegations
        std.mem.writeInt(u64, &buf, @intCast(self.drep_delegations.count()), .big);
        try file.writeAll(&buf);
        var drep_deleg_it = self.drep_delegations.iterator();
        while (drep_deleg_it.next()) |entry| {
            try file.writeAll(&[_]u8{@intFromEnum(entry.key_ptr.cred_type)});
            try file.writeAll(&entry.key_ptr.hash);
            try writeDRepToFile(file, entry.value_ptr.*);
        }

        // Section 11: Pool configs
        std.mem.writeInt(u64, &buf, @intCast(self.pool_configs.count()), .big);
        try file.writeAll(&buf);
        var pool_cfg_it = self.pool_configs.iterator();
        while (pool_cfg_it.next()) |entry| {
            try file.writeAll(entry.key_ptr);
            std.mem.writeInt(u64, &buf, entry.value_ptr.pledge, .big);
            try file.writeAll(&buf);
            std.mem.writeInt(u64, &buf, entry.value_ptr.cost, .big);
            try file.writeAll(&buf);
            try writeUnitIntervalToFile(file, entry.value_ptr.margin);
        }

        // Section 12: Future pool params
        std.mem.writeInt(u64, &buf, @intCast(self.future_pool_params.count()), .big);
        try file.writeAll(&buf);
        var future_pool_it = self.future_pool_params.iterator();
        while (future_pool_it.next()) |entry| {
            try file.writeAll(entry.key_ptr);
            std.mem.writeInt(u64, &buf, entry.value_ptr.config.pledge, .big);
            try file.writeAll(&buf);
            std.mem.writeInt(u64, &buf, entry.value_ptr.config.cost, .big);
            try file.writeAll(&buf);
            try writeUnitIntervalToFile(file, entry.value_ptr.config.margin);
            try file.writeAll(&[_]u8{@intFromEnum(entry.value_ptr.reward_account.network)});
            try file.writeAll(&[_]u8{@intFromEnum(entry.value_ptr.reward_account.credential.cred_type)});
            try file.writeAll(&entry.value_ptr.reward_account.credential.hash);
        }

        // Section 13: Current pool owners
        std.mem.writeInt(u64, &buf, @intCast(self.pool_owners.count()), .big);
        try file.writeAll(&buf);
        var pool_owner_it = self.pool_owners.iterator();
        while (pool_owner_it.next()) |entry| {
            try file.writeAll(&entry.key_ptr.pool);
            try file.writeAll(&entry.key_ptr.owner);
        }

        // Section 14: Future pool owners
        std.mem.writeInt(u64, &buf, @intCast(self.future_pool_owners.count()), .big);
        try file.writeAll(&buf);
        var future_owner_it = self.future_pool_owners.iterator();
        while (future_owner_it.next()) |entry| {
            try file.writeAll(&entry.key_ptr.pool);
            try file.writeAll(&entry.key_ptr.owner);
        }

        // Section 15: Previous-epoch blocks made
        std.mem.writeInt(u64, &buf, @intCast(self.blocks_made_previous_epoch.count()), .big);
        try file.writeAll(&buf);
        var prev_blocks_it = self.blocks_made_previous_epoch.iterator();
        while (prev_blocks_it.next()) |entry| {
            try file.writeAll(entry.key_ptr);
            std.mem.writeInt(u64, &buf, entry.value_ptr.*, .big);
            try file.writeAll(&buf);
        }

        // Section 16: Current-epoch blocks made
        std.mem.writeInt(u64, &buf, @intCast(self.blocks_made_current_epoch.count()), .big);
        try file.writeAll(&buf);
        var cur_blocks_it = self.blocks_made_current_epoch.iterator();
        while (cur_blocks_it.next()) |entry| {
            try file.writeAll(entry.key_ptr);
            std.mem.writeInt(u64, &buf, entry.value_ptr.*, .big);
            try file.writeAll(&buf);
        }

        // Section 17: MIR delta reserves
        writeDeltaCoinToFile(file, self.mir_delta_reserves);

        // Section 18: MIR delta treasury
        writeDeltaCoinToFile(file, self.mir_delta_treasury);

        // Section 19: MIR reserves
        std.mem.writeInt(u64, &buf, @intCast(self.mir_reserves.count()), .big);
        try file.writeAll(&buf);
        var mir_reserves_it = self.mir_reserves.iterator();
        while (mir_reserves_it.next()) |entry| {
            try file.writeAll(&[_]u8{@intFromEnum(entry.key_ptr.cred_type)});
            try file.writeAll(&entry.key_ptr.hash);
            std.mem.writeInt(u64, &buf, entry.value_ptr.*, .big);
            try file.writeAll(&buf);
        }

        // Section 20: MIR treasury
        std.mem.writeInt(u64, &buf, @intCast(self.mir_treasury.count()), .big);
        try file.writeAll(&buf);
        var mir_treasury_it = self.mir_treasury.iterator();
        while (mir_treasury_it.next()) |entry| {
            try file.writeAll(&[_]u8{@intFromEnum(entry.key_ptr.cred_type)});
            try file.writeAll(&entry.key_ptr.hash);
            std.mem.writeInt(u64, &buf, entry.value_ptr.*, .big);
            try file.writeAll(&buf);
        }
    }

    /// Load ledger state from a binary checkpoint file.
    /// Returns true if a valid checkpoint was loaded, false if not found.
    pub fn loadCheckpoint(self: *LedgerDB, path: []const u8) !bool {
        var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close();

        self.resetCheckpointState();

        var buf: [8]u8 = undefined;

        // Header
        var magic: [4]u8 = undefined;
        _ = file.readAll(&magic) catch return false;
        if (!std.mem.eql(u8, &magic, "KLED")) return false;

        var ver_buf: [4]u8 = undefined;
        _ = file.readAll(&ver_buf) catch return false;
        const version = std.mem.readInt(u32, &ver_buf, .big);
        if (version != 1 and version != 2 and version != 3 and version != 4 and version != 5 and version != 6) return false;

        _ = file.readAll(&buf) catch return false;
        const tip_slot_val = std.mem.readInt(u64, &buf, .big);
        var has_tip_buf: [1]u8 = undefined;
        _ = file.readAll(&has_tip_buf) catch return false;
        self.tip_slot = if (has_tip_buf[0] != 0) tip_slot_val else null;

        // Section 1: Scalars
        _ = try file.readAll(&buf);
        self.treasury_balance = std.mem.readInt(u64, &buf, .big);
        _ = try file.readAll(&buf);
        self.reserves_balance = std.mem.readInt(u64, &buf, .big);
        _ = try file.readAll(&buf);
        self.fees_balance = std.mem.readInt(u64, &buf, .big);
        _ = try file.readAll(&buf);
        self.snapshot_fees = std.mem.readInt(u64, &buf, .big);
        var tracked_buf: [1]u8 = undefined;
        _ = try file.readAll(&tracked_buf);
        self.reward_balances_tracked = tracked_buf[0] != 0;

        // Section 2: UTxO count (skipped — loaded from Mithril)
        _ = try file.readAll(&buf);

        // Section 3: Reward balances
        _ = try file.readAll(&buf);
        const reward_count = std.mem.readInt(u64, &buf, .big);
        var i: u64 = 0;
        while (i < reward_count) : (i += 1) {
            var entry_buf: [1 + 1 + 28 + 8]u8 = undefined;
            _ = try file.readAll(&entry_buf);
            const network: types.Network = @enumFromInt(entry_buf[0]);
            const cred_type: types.CredentialType = @enumFromInt(entry_buf[1]);
            var hash: types.Hash28 = undefined;
            @memcpy(&hash, entry_buf[2..30]);
            const amount = std.mem.readInt(u64, entry_buf[30..38], .big);
            try self.reward_balances.put(
                .{ .network = network, .credential = .{ .cred_type = cred_type, .hash = hash } },
                amount,
            );
        }

        // Section 4: Stake deposits
        _ = try file.readAll(&buf);
        const stake_count = std.mem.readInt(u64, &buf, .big);
        i = 0;
        while (i < stake_count) : (i += 1) {
            var entry_buf: [1 + 28 + 8]u8 = undefined;
            _ = try file.readAll(&entry_buf);
            const cred_type: types.CredentialType = @enumFromInt(entry_buf[0]);
            var hash: types.Hash28 = undefined;
            @memcpy(&hash, entry_buf[1..29]);
            const amount = std.mem.readInt(u64, entry_buf[29..37], .big);
            try self.stake_deposits.put(.{ .cred_type = cred_type, .hash = hash }, amount);
        }

        // Section 5: Pool deposits
        _ = try file.readAll(&buf);
        const pool_dep_count = std.mem.readInt(u64, &buf, .big);
        i = 0;
        while (i < pool_dep_count) : (i += 1) {
            var entry_buf: [28 + 8]u8 = undefined;
            _ = try file.readAll(&entry_buf);
            var pool: KeyHash = undefined;
            @memcpy(&pool, entry_buf[0..28]);
            const amount = std.mem.readInt(u64, entry_buf[28..36], .big);
            try self.pool_deposits.put(pool, amount);
        }

        // Section 6: Pool reward accounts
        _ = try file.readAll(&buf);
        const pool_acct_count = std.mem.readInt(u64, &buf, .big);
        i = 0;
        while (i < pool_acct_count) : (i += 1) {
            var entry_buf: [28 + 1 + 1 + 28]u8 = undefined;
            _ = try file.readAll(&entry_buf);
            var pool: KeyHash = undefined;
            @memcpy(&pool, entry_buf[0..28]);
            const network: types.Network = @enumFromInt(entry_buf[28]);
            const cred_type: types.CredentialType = @enumFromInt(entry_buf[29]);
            var hash: types.Hash28 = undefined;
            @memcpy(&hash, entry_buf[30..58]);
            try self.pool_reward_accounts.put(pool, .{
                .network = network,
                .credential = .{ .cred_type = cred_type, .hash = hash },
            });
        }

        // Section 7: Pool retirements
        _ = try file.readAll(&buf);
        const pool_ret_count = std.mem.readInt(u64, &buf, .big);
        i = 0;
        while (i < pool_ret_count) : (i += 1) {
            var entry_buf: [28 + 8]u8 = undefined;
            _ = try file.readAll(&entry_buf);
            var pool: KeyHash = undefined;
            @memcpy(&pool, entry_buf[0..28]);
            const epoch = std.mem.readInt(u64, entry_buf[28..36], .big);
            try self.pool_retirements.put(pool, epoch);
        }

        // Section 8: Stake pool delegations
        _ = try file.readAll(&buf);
        const deleg_count = std.mem.readInt(u64, &buf, .big);
        i = 0;
        while (i < deleg_count) : (i += 1) {
            var entry_buf: [1 + 28 + 28]u8 = undefined;
            _ = try file.readAll(&entry_buf);
            const cred_type: types.CredentialType = @enumFromInt(entry_buf[0]);
            var hash: types.Hash28 = undefined;
            @memcpy(&hash, entry_buf[1..29]);
            var pool: KeyHash = undefined;
            @memcpy(&pool, entry_buf[29..57]);
            try self.stake_pool_delegations.put(.{ .cred_type = cred_type, .hash = hash }, pool);
        }

        // Section 9: DRep deposits
        _ = try file.readAll(&buf);
        const drep_dep_count = std.mem.readInt(u64, &buf, .big);
        i = 0;
        while (i < drep_dep_count) : (i += 1) {
            var entry_buf: [1 + 28 + 8]u8 = undefined;
            _ = try file.readAll(&entry_buf);
            const cred_type: types.CredentialType = @enumFromInt(entry_buf[0]);
            var hash: types.Hash28 = undefined;
            @memcpy(&hash, entry_buf[1..29]);
            const amount = std.mem.readInt(u64, entry_buf[29..37], .big);
            try self.drep_deposits.put(.{ .cred_type = cred_type, .hash = hash }, amount);
        }

        // Section 10: DRep delegations
        _ = try file.readAll(&buf);
        const drep_deleg_count = std.mem.readInt(u64, &buf, .big);
        i = 0;
        while (i < drep_deleg_count) : (i += 1) {
            var entry_buf: [1 + 28]u8 = undefined;
            _ = try file.readAll(&entry_buf);
            const cred_type: types.CredentialType = @enumFromInt(entry_buf[0]);
            var hash: types.Hash28 = undefined;
            @memcpy(&hash, entry_buf[1..29]);
            const drep = try readDRepFromFile(file);
            try self.drep_delegations.put(.{ .cred_type = cred_type, .hash = hash }, drep);
        }

        if (version >= 2) {
            _ = try file.readAll(&buf);
            const pool_cfg_count = std.mem.readInt(u64, &buf, .big);
            i = 0;
            while (i < pool_cfg_count) : (i += 1) {
                var entry_buf: [28 + 8 + 8]u8 = undefined;
                _ = try file.readAll(&entry_buf);
                var pool: KeyHash = undefined;
                @memcpy(&pool, entry_buf[0..28]);
                const pledge = std.mem.readInt(u64, entry_buf[28..36], .big);
                const cost = std.mem.readInt(u64, entry_buf[36..44], .big);
                const margin = try readUnitIntervalFromFile(file);
                try self.pool_configs.put(pool, .{
                    .pledge = pledge,
                    .cost = cost,
                    .margin = margin,
                });
            }
        }

        if (version >= 3) {
            _ = try file.readAll(&buf);
            const future_pool_count = std.mem.readInt(u64, &buf, .big);
            i = 0;
            while (i < future_pool_count) : (i += 1) {
                var entry_buf: [28 + 8 + 8 + 1 + 1 + 28]u8 = undefined;
                _ = try file.readAll(entry_buf[0..44]);
                var pool: KeyHash = undefined;
                @memcpy(&pool, entry_buf[0..28]);
                const pledge = std.mem.readInt(u64, entry_buf[28..36], .big);
                const cost = std.mem.readInt(u64, entry_buf[36..44], .big);
                const margin = try readUnitIntervalFromFile(file);
                _ = try file.readAll(entry_buf[44..74]);
                const network: types.Network = @enumFromInt(entry_buf[44]);
                const cred_type: types.CredentialType = @enumFromInt(entry_buf[45]);
                var hash: types.Hash28 = undefined;
                @memcpy(&hash, entry_buf[46..74]);
                try self.future_pool_params.put(pool, .{
                    .config = .{
                        .pledge = pledge,
                        .cost = cost,
                        .margin = margin,
                    },
                    .reward_account = .{
                        .network = network,
                        .credential = .{ .cred_type = cred_type, .hash = hash },
                    },
                });
            }
        }

        if (version >= 4) {
            _ = try file.readAll(&buf);
            const pool_owner_count = std.mem.readInt(u64, &buf, .big);
            i = 0;
            while (i < pool_owner_count) : (i += 1) {
                var entry_buf: [56]u8 = undefined;
                _ = try file.readAll(&entry_buf);
                var pool: KeyHash = undefined;
                @memcpy(&pool, entry_buf[0..28]);
                var owner: KeyHash = undefined;
                @memcpy(&owner, entry_buf[28..56]);
                try self.pool_owners.put(.{
                    .pool = pool,
                    .owner = owner,
                }, {});
            }

            _ = try file.readAll(&buf);
            const future_pool_owner_count = std.mem.readInt(u64, &buf, .big);
            i = 0;
            while (i < future_pool_owner_count) : (i += 1) {
                var entry_buf: [56]u8 = undefined;
                _ = try file.readAll(&entry_buf);
                var pool: KeyHash = undefined;
                @memcpy(&pool, entry_buf[0..28]);
                var owner: KeyHash = undefined;
                @memcpy(&owner, entry_buf[28..56]);
                try self.future_pool_owners.put(.{
                    .pool = pool,
                    .owner = owner,
                }, {});
            }
        }

        if (version >= 5) {
            _ = try file.readAll(&buf);
            const previous_epoch_blocks_count = std.mem.readInt(u64, &buf, .big);
            i = 0;
            while (i < previous_epoch_blocks_count) : (i += 1) {
                var entry_buf: [28 + 8]u8 = undefined;
                _ = try file.readAll(&entry_buf);
                var pool: KeyHash = undefined;
                @memcpy(&pool, entry_buf[0..28]);
                const count = std.mem.readInt(u64, entry_buf[28..36], .big);
                try self.blocks_made_previous_epoch.put(pool, count);
            }

            _ = try file.readAll(&buf);
            const current_epoch_blocks_count = std.mem.readInt(u64, &buf, .big);
            i = 0;
            while (i < current_epoch_blocks_count) : (i += 1) {
                var entry_buf: [28 + 8]u8 = undefined;
                _ = try file.readAll(&entry_buf);
                var pool: KeyHash = undefined;
                @memcpy(&pool, entry_buf[0..28]);
                const count = std.mem.readInt(u64, entry_buf[28..36], .big);
                try self.blocks_made_current_epoch.put(pool, count);
            }
        }

        if (version >= 6) {
            self.mir_delta_reserves = try readDeltaCoinFromFile(file);
            self.mir_delta_treasury = try readDeltaCoinFromFile(file);

            _ = try file.readAll(&buf);
            const mir_reserves_count = std.mem.readInt(u64, &buf, .big);
            i = 0;
            while (i < mir_reserves_count) : (i += 1) {
                var entry_buf: [1 + 28 + 8]u8 = undefined;
                _ = try file.readAll(&entry_buf);
                const cred_type: types.CredentialType = @enumFromInt(entry_buf[0]);
                var hash: types.Hash28 = undefined;
                @memcpy(&hash, entry_buf[1..29]);
                const amount = std.mem.readInt(u64, entry_buf[29..37], .big);
                try self.mir_reserves.put(.{ .cred_type = cred_type, .hash = hash }, amount);
            }

            _ = try file.readAll(&buf);
            const mir_treasury_count = std.mem.readInt(u64, &buf, .big);
            i = 0;
            while (i < mir_treasury_count) : (i += 1) {
                var entry_buf: [1 + 28 + 8]u8 = undefined;
                _ = try file.readAll(&entry_buf);
                const cred_type: types.CredentialType = @enumFromInt(entry_buf[0]);
                var hash: types.Hash28 = undefined;
                @memcpy(&hash, entry_buf[1..29]);
                const amount = std.mem.readInt(u64, entry_buf[29..37], .big);
                try self.mir_treasury.put(.{ .cred_type = cred_type, .hash = hash }, amount);
            }
        }

        return true;
    }

    fn resetCheckpointState(self: *LedgerDB) void {
        self.tip_slot = null;
        self.treasury_balance = 0;
        self.reserves_balance = 0;
        self.fees_balance = 0;
        self.snapshot_fees = 0;
        self.mir_delta_reserves = 0;
        self.mir_delta_treasury = 0;
        self.reward_balances_tracked = false;
        self.reward_balances.clearRetainingCapacity();
        self.mir_reserves.clearRetainingCapacity();
        self.mir_treasury.clearRetainingCapacity();
        self.stake_deposits.clearRetainingCapacity();
        self.pool_deposits.clearRetainingCapacity();
        self.pool_configs.clearRetainingCapacity();
        self.future_pool_params.clearRetainingCapacity();
        self.pool_reward_accounts.clearRetainingCapacity();
        self.pool_owners.clearRetainingCapacity();
        self.future_pool_owners.clearRetainingCapacity();
        self.pool_retirements.clearRetainingCapacity();
        self.drep_deposits.clearRetainingCapacity();
        self.stake_pool_delegations.clearRetainingCapacity();
        self.drep_delegations.clearRetainingCapacity();
        self.blocks_made_previous_epoch.clearRetainingCapacity();
        self.blocks_made_current_epoch.clearRetainingCapacity();
        self.stake_snapshots.deinit();
        self.stake_snapshots = StakeSnapshots.init(self.allocator);
    }

    fn isRegisteredRewardCredential(self: *const LedgerDB, credential: Credential) bool {
        if (self.stake_deposits.contains(credential)) return true;
        return self.reward_balances.contains(.{
            .network = self.reward_account_network,
            .credential = credential,
        });
    }

    /// Total number of UTxOs in the set.
    pub fn utxoCount(self: *const LedgerDB) usize {
        return self.utxo_set.count();
    }

    /// Current tip slot.
    pub fn getTipSlot(self: *const LedgerDB) ?SlotNo {
        return self.tip_slot;
    }
};

fn writeDRepToFile(file: std.fs.File, drep: DRep) !void {
    switch (drep) {
        .key_hash => |h| {
            try file.writeAll(&[_]u8{0});
            try file.writeAll(&h);
        },
        .script_hash => |h| {
            try file.writeAll(&[_]u8{1});
            try file.writeAll(&h);
        },
        .always_abstain => try file.writeAll(&[_]u8{2}),
        .always_no_confidence => try file.writeAll(&[_]u8{3}),
    }
}

fn writeUnitIntervalToFile(file: std.fs.File, interval: UnitInterval) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, interval.numerator, .big);
    try file.writeAll(&buf);
    std.mem.writeInt(u64, &buf, interval.denominator, .big);
    try file.writeAll(&buf);
}

fn writeDeltaCoinToFile(file: std.fs.File, delta: DeltaCoin) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, delta, .big);
    file.writeAll(&buf) catch unreachable;
}

fn readDRepFromFile(file: std.fs.File) !DRep {
    var tag_buf: [1]u8 = undefined;
    _ = try file.readAll(&tag_buf);
    switch (tag_buf[0]) {
        0 => {
            var h: types.Hash28 = undefined;
            _ = try file.readAll(&h);
            return .{ .key_hash = h };
        },
        1 => {
            var h: types.Hash28 = undefined;
            _ = try file.readAll(&h);
            return .{ .script_hash = h };
        },
        2 => return .{ .always_abstain = {} },
        3 => return .{ .always_no_confidence = {} },
        else => return error.InvalidCheckpoint,
    }
}

fn readUnitIntervalFromFile(file: std.fs.File) !UnitInterval {
    var buf: [8]u8 = undefined;
    _ = try file.readAll(&buf);
    const numerator = std.mem.readInt(u64, &buf, .big);
    _ = try file.readAll(&buf);
    const denominator = std.mem.readInt(u64, &buf, .big);
    const interval = UnitInterval{
        .numerator = numerator,
        .denominator = denominator,
    };
    if (!interval.isValid()) return error.InvalidCheckpoint;
    return interval;
}

fn readDeltaCoinFromFile(file: std.fs.File) !DeltaCoin {
    var buf: [8]u8 = undefined;
    _ = try file.readAll(&buf);
    return std.mem.readInt(i64, &buf, .big);
}

fn freeEntries(allocator: Allocator, entries: []const UtxoEntry) void {
    for (entries) |entry| {
        allocator.free(entry.raw_cbor);
    }
    allocator.free(entries);
}

fn appendPoolReapRewardChange(
    allocator: Allocator,
    changes: *std.ArrayList(RewardBalanceChange),
    ledger: *const LedgerDB,
    account: RewardAccount,
    added: Coin,
) !void {
    for (changes.items) |*change| {
        if (change.account.network == account.network and
            Credential.eql(change.account.credential, account.credential))
        {
            const current = change.next orelse 0;
            change.next = current + added;
            return;
        }
    }

    const previous = ledger.lookupRewardBalance(account);
    try changes.append(allocator, .{
        .account = account,
        .previous = previous,
        .next = (previous orelse 0) + added,
    });
}

fn freeRewardChanges(allocator: Allocator, changes: []const RewardBalanceChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freeMIRRewardChanges(allocator: Allocator, changes: []const MIRRewardChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freeStakeChanges(allocator: Allocator, changes: []const StakeDepositChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freePoolChanges(allocator: Allocator, changes: []const PoolDepositChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freePoolConfigChanges(allocator: Allocator, changes: []const PoolConfigChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freeFuturePoolParamChanges(allocator: Allocator, changes: []const FuturePoolParamsChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freePoolRewardAccountChanges(allocator: Allocator, changes: []const PoolRewardAccountChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freePoolOwnerMembershipChanges(allocator: Allocator, changes: []const PoolOwnerMembershipChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freePoolRetirementChanges(allocator: Allocator, changes: []const PoolRetirementChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freeDRepChanges(allocator: Allocator, changes: []const DRepDepositChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freeStakePoolDelegationChanges(allocator: Allocator, changes: []const StakePoolDelegationChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freeDRepDelegationChanges(allocator: Allocator, changes: []const DRepDelegationChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn freeBlocksMadeChanges(allocator: Allocator, changes: []const BlocksMadeChange) void {
    if (changes.len > 0) allocator.free(changes);
}

fn applyCoinStateChange(state: *Coin, change: ?CoinStateChange) void {
    if (change) |updated| {
        state.* = updated.next;
    }
}

fn applyDeltaCoinStateChange(state: *DeltaCoin, change: ?DeltaCoinStateChange) void {
    if (change) |updated| {
        state.* = updated.next;
    }
}

fn rollbackCoinStateChange(state: *Coin, change: ?CoinStateChange) void {
    if (change) |updated| {
        state.* = updated.previous;
    }
}

fn rollbackDeltaCoinStateChange(state: *DeltaCoin, change: ?DeltaCoinStateChange) void {
    if (change) |updated| {
        state.* = updated.previous;
    }
}

fn applyRewardBalanceChanges(
    map: *std.AutoHashMap(RewardAccount, Coin),
    changes: []const RewardBalanceChange,
) void {
    for (changes) |change| {
        if (change.next) |balance| {
            map.put(change.account, balance) catch unreachable;
        } else {
            _ = map.remove(change.account);
        }
    }
}

fn rollbackRewardBalanceChanges(
    map: *std.AutoHashMap(RewardAccount, Coin),
    changes: []const RewardBalanceChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |balance| {
            map.put(change.account, balance) catch unreachable;
        } else {
            _ = map.remove(change.account);
        }
    }
}

fn applyMIRRewardChanges(
    map: *std.AutoHashMap(Credential, Coin),
    changes: []const MIRRewardChange,
) void {
    for (changes) |change| {
        if (change.next) |amount| {
            map.put(change.credential, amount) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn rollbackMIRRewardChanges(
    map: *std.AutoHashMap(Credential, Coin),
    changes: []const MIRRewardChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |amount| {
            map.put(change.credential, amount) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn addDeltaCoinChecked(base: Coin, delta: DeltaCoin) ?Coin {
    if (delta >= 0) {
        return base + @as(Coin, @intCast(delta));
    }

    const abs_delta: Coin = @intCast(-delta);
    if (abs_delta > base) return null;
    return base - abs_delta;
}

fn applyStakeDepositChanges(
    map: *std.AutoHashMap(Credential, Coin),
    changes: []const StakeDepositChange,
) void {
    for (changes) |change| {
        if (change.next) |deposit| {
            map.put(change.credential, deposit) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn rollbackStakeDepositChanges(
    map: *std.AutoHashMap(Credential, Coin),
    changes: []const StakeDepositChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |deposit| {
            map.put(change.credential, deposit) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn applyPoolDepositChanges(
    map: *std.AutoHashMap(KeyHash, Coin),
    changes: []const PoolDepositChange,
) void {
    for (changes) |change| {
        if (change.next) |deposit| {
            map.put(change.pool, deposit) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn rollbackPoolDepositChanges(
    map: *std.AutoHashMap(KeyHash, Coin),
    changes: []const PoolDepositChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |deposit| {
            map.put(change.pool, deposit) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn applyPoolConfigChanges(
    map: *std.AutoHashMap(KeyHash, PoolConfig),
    changes: []const PoolConfigChange,
) void {
    for (changes) |change| {
        if (change.next) |config| {
            map.put(change.pool, config) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn rollbackPoolConfigChanges(
    map: *std.AutoHashMap(KeyHash, PoolConfig),
    changes: []const PoolConfigChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |config| {
            map.put(change.pool, config) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn applyFuturePoolParamChanges(
    map: *std.AutoHashMap(KeyHash, FuturePoolParams),
    changes: []const FuturePoolParamsChange,
) void {
    for (changes) |change| {
        if (change.next) |params| {
            map.put(change.pool, params) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn rollbackFuturePoolParamChanges(
    map: *std.AutoHashMap(KeyHash, FuturePoolParams),
    changes: []const FuturePoolParamsChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |params| {
            map.put(change.pool, params) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn applyPoolRewardAccountChanges(
    map: *std.AutoHashMap(KeyHash, RewardAccount),
    changes: []const PoolRewardAccountChange,
) void {
    for (changes) |change| {
        if (change.next) |account| {
            map.put(change.pool, account) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn rollbackPoolRewardAccountChanges(
    map: *std.AutoHashMap(KeyHash, RewardAccount),
    changes: []const PoolRewardAccountChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |account| {
            map.put(change.pool, account) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn applyPoolOwnerMembershipChanges(
    map: *std.AutoHashMap(PoolOwnerMembership, void),
    changes: []const PoolOwnerMembershipChange,
) void {
    for (changes) |change| {
        if (change.next) {
            map.put(change.membership, {}) catch unreachable;
        } else {
            _ = map.remove(change.membership);
        }
    }
}

fn rollbackPoolOwnerMembershipChanges(
    map: *std.AutoHashMap(PoolOwnerMembership, void),
    changes: []const PoolOwnerMembershipChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) {
            map.put(change.membership, {}) catch unreachable;
        } else {
            _ = map.remove(change.membership);
        }
    }
}

fn applyPoolRetirementChanges(
    map: *std.AutoHashMap(KeyHash, EpochNo),
    changes: []const PoolRetirementChange,
) void {
    for (changes) |change| {
        if (change.next) |epoch| {
            map.put(change.pool, epoch) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn rollbackPoolRetirementChanges(
    map: *std.AutoHashMap(KeyHash, EpochNo),
    changes: []const PoolRetirementChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |epoch| {
            map.put(change.pool, epoch) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn applyDRepDepositChanges(
    map: *std.AutoHashMap(Credential, Coin),
    changes: []const DRepDepositChange,
) void {
    for (changes) |change| {
        if (change.next) |deposit| {
            map.put(change.credential, deposit) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn rollbackDRepDepositChanges(
    map: *std.AutoHashMap(Credential, Coin),
    changes: []const DRepDepositChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |deposit| {
            map.put(change.credential, deposit) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn applyStakePoolDelegationChanges(
    map: *std.AutoHashMap(Credential, KeyHash),
    changes: []const StakePoolDelegationChange,
) void {
    for (changes) |change| {
        if (change.next) |pool| {
            map.put(change.credential, pool) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn rollbackStakePoolDelegationChanges(
    map: *std.AutoHashMap(Credential, KeyHash),
    changes: []const StakePoolDelegationChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |pool| {
            map.put(change.credential, pool) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn applyDRepDelegationChanges(
    map: *std.AutoHashMap(Credential, DRep),
    changes: []const DRepDelegationChange,
) void {
    for (changes) |change| {
        if (change.next) |drep| {
            map.put(change.credential, drep) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn rollbackDRepDelegationChanges(
    map: *std.AutoHashMap(Credential, DRep),
    changes: []const DRepDelegationChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |drep| {
            map.put(change.credential, drep) catch unreachable;
        } else {
            _ = map.remove(change.credential);
        }
    }
}

fn applyBlocksMadeChanges(
    map: *std.AutoHashMap(KeyHash, u64),
    changes: []const BlocksMadeChange,
) void {
    for (changes) |change| {
        if (change.next) |count| {
            map.put(change.pool, count) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

fn rollbackBlocksMadeChanges(
    map: *std.AutoHashMap(KeyHash, u64),
    changes: []const BlocksMadeChange,
) void {
    var i: usize = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        if (change.previous) |count| {
            map.put(change.pool, count) catch unreachable;
        } else {
            _ = map.remove(change.pool);
        }
    }
}

// ──────────────────────────────────── Tests ────────────────────────────────────

fn makeTxIn(id_byte: u8, ix: u16) TxIn {
    return .{ .tx_id = [_]u8{id_byte} ** 32, .tx_ix = ix };
}

test "ledgerdb: init and deinit" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger");
    defer db.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.utxoCount());
    try std.testing.expect(db.getTipSlot() == null);
}

test "ledgerdb: apply diff adds utxos" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger2");
    defer db.deinit();

    const produced = try allocator.alloc(UtxoEntry, 2);
    produced[0] = .{ .tx_in = makeTxIn(0x01, 0), .value = 1_000_000, .raw_cbor = try allocator.dupe(u8, "utxo1") };
    produced[1] = .{ .tx_in = makeTxIn(0x01, 1), .value = 2_000_000, .raw_cbor = try allocator.dupe(u8, "utxo2") };

    const consumed = try allocator.alloc(UtxoEntry, 0);

    try db.applyDiff(.{
        .slot = 100,
        .block_hash = [_]u8{0xaa} ** 32,
        .consumed = consumed,
        .produced = produced,
    });

    try std.testing.expectEqual(@as(usize, 2), db.utxoCount());
    try std.testing.expectEqual(@as(?SlotNo, 100), db.getTipSlot());

    // Lookup specific UTxO
    const entry = db.lookupUtxo(makeTxIn(0x01, 0)).?;
    try std.testing.expectEqual(@as(Coin, 1_000_000), entry.value);
}

test "ledgerdb: apply diff tracks and rolls back stake deposits" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-stake-deposits");
    defer db.deinit();

    const cred = Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xcc} ** 28,
    };

    try db.applyDiff(.{
        .slot = 10,
        .block_hash = [_]u8{0x11} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = try allocator.alloc(UtxoEntry, 0),
        .stake_deposit_changes = try allocator.dupe(StakeDepositChange, &[_]StakeDepositChange{
            .{
                .credential = cred,
                .previous = null,
                .next = 2_000_000,
            },
        }),
    });

    try std.testing.expectEqual(@as(?Coin, 2_000_000), db.lookupStakeDeposit(cred));

    try db.rollback(1);
    try std.testing.expect(db.lookupStakeDeposit(cred) == null);
}

test "ledgerdb: apply diff tracks and rolls back reward balances" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-reward-balances");
    defer db.deinit();

    const account = RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0xdd} ** 28,
        },
    };

    try db.applyDiff(.{
        .slot = 10,
        .block_hash = [_]u8{0x22} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = try allocator.alloc(UtxoEntry, 0),
        .reward_balance_changes = try allocator.dupe(RewardBalanceChange, &[_]RewardBalanceChange{
            .{
                .account = account,
                .previous = 4_000_000,
                .next = null,
            },
        }),
    });

    try std.testing.expect(db.lookupRewardBalance(account) == null);

    try db.rollback(1);
    try std.testing.expectEqual(@as(?Coin, 4_000_000), db.lookupRewardBalance(account));
}

test "ledgerdb: apply diff tracks and rolls back accounting pots" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-accounting-pots");
    defer db.deinit();

    db.importTreasuryBalance(10);
    db.importReservesBalance(20);
    db.importFeesBalance(30);
    db.importSnapshotFees(40);

    try db.applyDiff(.{
        .slot = 10,
        .block_hash = [_]u8{0x23} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = try allocator.alloc(UtxoEntry, 0),
        .treasury_balance_change = .{ .previous = 10, .next = 15 },
        .reserves_balance_change = .{ .previous = 20, .next = 18 },
        .fees_balance_change = .{ .previous = 30, .next = 35 },
        .snapshot_fees_change = .{ .previous = 40, .next = 50 },
    });

    try std.testing.expectEqual(@as(Coin, 15), db.getTreasuryBalance());
    try std.testing.expectEqual(@as(Coin, 18), db.getReservesBalance());
    try std.testing.expectEqual(@as(Coin, 35), db.getFeesBalance());
    try std.testing.expectEqual(@as(Coin, 50), db.getSnapshotFees());

    try db.rollback(1);
    try std.testing.expectEqual(@as(Coin, 10), db.getTreasuryBalance());
    try std.testing.expectEqual(@as(Coin, 20), db.getReservesBalance());
    try std.testing.expectEqual(@as(Coin, 30), db.getFeesBalance());
    try std.testing.expectEqual(@as(Coin, 40), db.getSnapshotFees());
}

test "ledgerdb: apply diff tracks and rolls back delegations" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-delegations");
    defer db.deinit();

    const cred = Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xee} ** 28,
    };
    const pool = [_]u8{0x44} ** 28;
    const drep = DRep{ .always_abstain = {} };

    try db.applyDiff(.{
        .slot = 10,
        .block_hash = [_]u8{0x33} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = try allocator.alloc(UtxoEntry, 0),
        .stake_pool_delegation_changes = try allocator.dupe(StakePoolDelegationChange, &[_]StakePoolDelegationChange{
            .{
                .credential = cred,
                .previous = null,
                .next = pool,
            },
        }),
        .drep_delegation_changes = try allocator.dupe(DRepDelegationChange, &[_]DRepDelegationChange{
            .{
                .credential = cred,
                .previous = null,
                .next = drep,
            },
        }),
    });

    try std.testing.expectEqual(@as(?KeyHash, pool), db.lookupStakePoolDelegation(cred));
    try std.testing.expectEqual(drep, db.lookupDRepDelegation(cred).?);

    try db.rollback(1);
    try std.testing.expect(db.lookupStakePoolDelegation(cred) == null);
    try std.testing.expect(db.lookupDRepDelegation(cred) == null);
}

test "ledgerdb: apply diff tracks and rolls back pool state" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-pool-state");
    defer db.deinit();

    const pool = [_]u8{0x51} ** 28;
    const account = RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0x52} ** 28,
        },
    };
    const future_account = RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0x53} ** 28,
        },
    };
    const owner = [_]u8{0x54} ** 28;
    const future_owner = [_]u8{0x55} ** 28;

    try db.applyDiff(.{
        .slot = 10,
        .block_hash = [_]u8{0x34} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = try allocator.alloc(UtxoEntry, 0),
        .pool_deposit_changes = try allocator.dupe(PoolDepositChange, &[_]PoolDepositChange{
            .{
                .pool = pool,
                .previous = null,
                .next = 500_000_000,
            },
        }),
        .pool_config_changes = try allocator.dupe(PoolConfigChange, &[_]PoolConfigChange{
            .{
                .pool = pool,
                .previous = null,
                .next = .{
                    .pledge = 250_000_000,
                    .cost = 340_000_000,
                    .margin = .{ .numerator = 1, .denominator = 20 },
                },
            },
        }),
        .future_pool_param_changes = try allocator.dupe(FuturePoolParamsChange, &[_]FuturePoolParamsChange{
            .{
                .pool = pool,
                .previous = null,
                .next = .{
                    .config = .{
                        .pledge = 300_000_000,
                        .cost = 345_000_000,
                        .margin = .{ .numerator = 1, .denominator = 10 },
                    },
                    .reward_account = future_account,
                },
            },
        }),
        .pool_reward_account_changes = try allocator.dupe(PoolRewardAccountChange, &[_]PoolRewardAccountChange{
            .{
                .pool = pool,
                .previous = null,
                .next = account,
            },
        }),
        .pool_owner_changes = try allocator.dupe(PoolOwnerMembershipChange, &[_]PoolOwnerMembershipChange{
            .{
                .membership = .{ .pool = pool, .owner = owner },
                .previous = false,
                .next = true,
            },
        }),
        .future_pool_owner_changes = try allocator.dupe(PoolOwnerMembershipChange, &[_]PoolOwnerMembershipChange{
            .{
                .membership = .{ .pool = pool, .owner = future_owner },
                .previous = false,
                .next = true,
            },
        }),
        .pool_retirement_changes = try allocator.dupe(PoolRetirementChange, &[_]PoolRetirementChange{
            .{
                .pool = pool,
                .previous = null,
                .next = 9,
            },
        }),
    });

    try std.testing.expectEqual(@as(?Coin, 500_000_000), db.lookupPoolDeposit(pool));
    try std.testing.expectEqual(PoolConfig{
        .pledge = 250_000_000,
        .cost = 340_000_000,
        .margin = .{ .numerator = 1, .denominator = 20 },
    }, db.lookupPoolConfig(pool).?);
    try std.testing.expectEqual(FuturePoolParams{
        .config = .{
            .pledge = 300_000_000,
            .cost = 345_000_000,
            .margin = .{ .numerator = 1, .denominator = 10 },
        },
        .reward_account = future_account,
    }, db.lookupFuturePoolParams(pool).?);
    try std.testing.expectEqual(account, db.lookupPoolRewardAccount(pool).?);
    try std.testing.expect(db.isPoolOwner(pool, owner));
    try std.testing.expect(db.isFuturePoolOwner(pool, future_owner));
    try std.testing.expectEqual(@as(?EpochNo, 9), db.lookupPoolRetirement(pool));

    try db.rollback(1);
    try std.testing.expect(db.lookupPoolDeposit(pool) == null);
    try std.testing.expect(db.lookupPoolConfig(pool) == null);
    try std.testing.expect(db.lookupFuturePoolParams(pool) == null);
    try std.testing.expect(db.lookupPoolRewardAccount(pool) == null);
    try std.testing.expect(!db.isPoolOwner(pool, owner));
    try std.testing.expect(!db.isFuturePoolOwner(pool, future_owner));
    try std.testing.expect(db.lookupPoolRetirement(pool) == null);
}

test "ledgerdb: pool reap routes unclaimed refunds to treasury" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-pool-reap-treasury");
    defer db.deinit();

    const pool = [_]u8{0x61} ** 28;
    const reward_account = RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0x62} ** 28,
        },
    };

    db.importTreasuryBalance(500);
    try db.importPoolDeposit(pool, 2_000_000);
    try db.importPoolConfig(pool, .{
        .pledge = 500_000_000,
        .cost = 340_000_000,
        .margin = .{ .numerator = 1, .denominator = 10 },
    });
    try db.importPoolRewardAccount(pool, reward_account);
    try db.importPoolRetirement(pool, 9);

    const diff = (try db.buildPoolReapDiff(allocator, 90, [_]u8{0x63} ** 32, 9)).?;
    try db.applyDiff(diff);

    try std.testing.expectEqual(@as(Coin, 2_000_500), db.getTreasuryBalance());
    try std.testing.expect(db.lookupRewardBalance(reward_account) == null);
    try std.testing.expect(db.lookupPoolDeposit(pool) == null);
    try std.testing.expect(db.lookupPoolConfig(pool) == null);
    try std.testing.expect(db.lookupPoolRewardAccount(pool) == null);
    try std.testing.expect(db.lookupPoolRetirement(pool) == null);

    try db.rollback(1);
    try std.testing.expectEqual(@as(Coin, 500), db.getTreasuryBalance());
    try std.testing.expectEqual(@as(?Coin, 2_000_000), db.lookupPoolDeposit(pool));
    try std.testing.expectEqual(PoolConfig{
        .pledge = 500_000_000,
        .cost = 340_000_000,
        .margin = .{ .numerator = 1, .denominator = 10 },
    }, db.lookupPoolConfig(pool).?);
    try std.testing.expectEqual(reward_account, db.lookupPoolRewardAccount(pool).?);
    try std.testing.expectEqual(@as(?EpochNo, 9), db.lookupPoolRetirement(pool));
}

test "ledgerdb: pool epoch transition activates future params" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-future-pool-params");
    defer db.deinit();

    const pool = [_]u8{0x64} ** 28;
    const current_account = RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0x65} ** 28,
        },
    };
    const future_account = RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0x66} ** 28,
        },
    };

    try db.importPoolConfig(pool, .{
        .pledge = 200_000_000,
        .cost = 340_000_000,
        .margin = .{ .numerator = 1, .denominator = 20 },
    });
    try db.importPoolRewardAccount(pool, current_account);
    try db.importPoolOwnerMembership(pool, [_]u8{0x67} ** 28);
    try db.importFuturePoolParams(pool, .{
        .config = .{
            .pledge = 300_000_000,
            .cost = 350_000_000,
            .margin = .{ .numerator = 1, .denominator = 10 },
        },
        .reward_account = future_account,
    });
    try db.importFuturePoolOwnerMembership(pool, [_]u8{0x68} ** 28);

    const diff = (try db.buildPoolReapDiff(allocator, 90, [_]u8{0x67} ** 32, 9)).?;
    try db.applyDiff(diff);

    try std.testing.expectEqual(PoolConfig{
        .pledge = 300_000_000,
        .cost = 350_000_000,
        .margin = .{ .numerator = 1, .denominator = 10 },
    }, db.lookupPoolConfig(pool).?);
    try std.testing.expectEqual(future_account, db.lookupPoolRewardAccount(pool).?);
    try std.testing.expect(db.lookupFuturePoolParams(pool) == null);
    try std.testing.expect(!db.isPoolOwner(pool, [_]u8{0x67} ** 28));
    try std.testing.expect(db.isPoolOwner(pool, [_]u8{0x68} ** 28));
    try std.testing.expect(!db.isFuturePoolOwner(pool, [_]u8{0x68} ** 28));

    try db.rollback(1);
    try std.testing.expectEqual(PoolConfig{
        .pledge = 200_000_000,
        .cost = 340_000_000,
        .margin = .{ .numerator = 1, .denominator = 20 },
    }, db.lookupPoolConfig(pool).?);
    try std.testing.expectEqual(current_account, db.lookupPoolRewardAccount(pool).?);
    try std.testing.expectEqual(FuturePoolParams{
        .config = .{
            .pledge = 300_000_000,
            .cost = 350_000_000,
            .margin = .{ .numerator = 1, .denominator = 10 },
        },
        .reward_account = future_account,
    }, db.lookupFuturePoolParams(pool).?);
    try std.testing.expect(db.isPoolOwner(pool, [_]u8{0x67} ** 28));
    try std.testing.expect(db.isFuturePoolOwner(pool, [_]u8{0x68} ** 28));
}

test "ledgerdb: apply diff consumes utxos" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger3");
    defer db.deinit();

    // First, produce some UTxOs
    const produced1 = try allocator.alloc(UtxoEntry, 2);
    produced1[0] = .{ .tx_in = makeTxIn(0x01, 0), .value = 5_000_000, .raw_cbor = try allocator.dupe(u8, "out1") };
    produced1[1] = .{ .tx_in = makeTxIn(0x01, 1), .value = 3_000_000, .raw_cbor = try allocator.dupe(u8, "out2") };
    try db.applyDiff(.{
        .slot = 100,
        .block_hash = [_]u8{0xaa} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = produced1,
    });

    try std.testing.expectEqual(@as(usize, 2), db.utxoCount());

    // Now consume one UTxO and produce a new one
    const consumed2 = try allocator.alloc(UtxoEntry, 1);
    consumed2[0] = .{
        .tx_in = makeTxIn(0x01, 0),
        .value = 5_000_000,
        .raw_cbor = try allocator.dupe(u8, "out1"),
    };
    const produced2 = try allocator.alloc(UtxoEntry, 1);
    produced2[0] = .{ .tx_in = makeTxIn(0x02, 0), .value = 4_000_000, .raw_cbor = try allocator.dupe(u8, "out3") };

    try db.applyDiff(.{
        .slot = 200,
        .block_hash = [_]u8{0xbb} ** 32,
        .consumed = consumed2,
        .produced = produced2,
    });

    try std.testing.expectEqual(@as(usize, 2), db.utxoCount()); // 2-1+1 = 2
    try std.testing.expect(db.lookupUtxo(makeTxIn(0x01, 0)) == null); // consumed
    try std.testing.expect(db.lookupUtxo(makeTxIn(0x01, 1)) != null); // still there
    try std.testing.expect(db.lookupUtxo(makeTxIn(0x02, 0)) != null); // newly produced
}

test "ledgerdb: rollback removes produced utxos" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger4");
    defer db.deinit();

    // Apply a diff
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{ .tx_in = makeTxIn(0x01, 0), .value = 1_000_000, .raw_cbor = try allocator.dupe(u8, "x") };
    try db.applyDiff(.{
        .slot = 100,
        .block_hash = [_]u8{0xaa} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = produced,
    });

    try std.testing.expectEqual(@as(usize, 1), db.utxoCount());

    // Rollback
    try db.rollback(1);

    try std.testing.expectEqual(@as(usize, 0), db.utxoCount());
    try std.testing.expect(db.getTipSlot() == null);
}

test "ledgerdb: rollback restores consumed utxos" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger5");
    defer db.deinit();

    const original = try allocator.alloc(UtxoEntry, 1);
    original[0] = .{ .tx_in = makeTxIn(0x09, 0), .value = 7_000_000, .raw_cbor = try allocator.dupe(u8, "seed") };
    try db.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = original,
    });

    const consumed = try allocator.alloc(UtxoEntry, 1);
    consumed[0] = .{ .tx_in = makeTxIn(0x09, 0), .value = 7_000_000, .raw_cbor = try allocator.dupe(u8, "seed") };
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{ .tx_in = makeTxIn(0x0a, 0), .value = 6_000_000, .raw_cbor = try allocator.dupe(u8, "new") };

    try db.applyDiff(.{
        .slot = 10,
        .block_hash = [_]u8{0xaa} ** 32,
        .consumed = consumed,
        .produced = produced,
    });

    try std.testing.expect(db.lookupUtxo(makeTxIn(0x09, 0)) == null);
    try db.rollback(1);
    try std.testing.expect(db.lookupUtxo(makeTxIn(0x09, 0)) != null);
    try std.testing.expect(db.lookupUtxo(makeTxIn(0x0a, 0)) == null);
}

test "ledgerdb: checkpoint save and load round-trip" {
    const allocator = std.testing.allocator;
    const ckpt_path = "/tmp/kassadin-test-ledger-checkpoint/ledger/checkpoint";
    std.fs.cwd().deleteTree("/tmp/kassadin-test-ledger-checkpoint") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-ledger-checkpoint") catch {};

    // Build source DB with state
    {
        var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-checkpoint/ledger");
        defer db.deinit();

        db.importTreasuryBalance(42_000);
        db.importReservesBalance(99_000);
        db.importFeesBalance(500);
        db.importSnapshotFees(100);
        db.setRewardBalancesTracked(true);

        const account = RewardAccount{
            .network = .testnet,
            .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0xaa} ** 28 },
        };
        try db.importRewardBalance(account, 7_000);
        try db.importStakeDeposit(account.credential, 2_000_000);

        const pool = [_]u8{0xbb} ** 28;
        try db.importPoolDeposit(pool, 500_000_000);
        try db.importPoolConfig(pool, .{
            .pledge = 250_000_000,
            .cost = 340_000_000,
            .margin = .{ .numerator = 1, .denominator = 20 },
        });
        try db.importFuturePoolParams(pool, .{
            .config = .{
                .pledge = 300_000_000,
                .cost = 345_000_000,
                .margin = .{ .numerator = 1, .denominator = 10 },
            },
            .reward_account = .{
                .network = .testnet,
                .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0xbc} ** 28 },
            },
        });
        try db.importPoolRewardAccount(pool, account);
        try db.importPoolOwnerMembership(pool, [_]u8{0xbd} ** 28);
        try db.importFuturePoolOwnerMembership(pool, [_]u8{0xbe} ** 28);
        try db.importPoolRetirement(pool, 10);
        try db.importStakePoolDelegation(account.credential, pool);
        try db.importPreviousEpochBlocksMade(pool, 7);
        try db.importCurrentEpochBlocksMade(pool, 3);

        const drep_cred = Credential{ .cred_type = .script_hash, .hash = [_]u8{0xcc} ** 28 };
        try db.importMirReward(.reserves, account.credential, 9);
        try db.importMirReward(.treasury, drep_cred, 11);
        db.importMirDeltaReserves(-4);
        db.importMirDeltaTreasury(4);
        try db.importDRepDelegation(drep_cred, .{ .always_abstain = {} });
        try db.drep_deposits.put(drep_cred, 500_000_000);

        db.setTipSlot(12345);

        try db.saveCheckpoint(ckpt_path);
    }

    // Load into fresh DB
    {
        var db2 = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-checkpoint/ledger2");
        defer db2.deinit();

        const loaded = try db2.loadCheckpoint(ckpt_path);
        try std.testing.expect(loaded);

        try std.testing.expectEqual(@as(Coin, 42_000), db2.getTreasuryBalance());
        try std.testing.expectEqual(@as(Coin, 99_000), db2.getReservesBalance());
        try std.testing.expectEqual(@as(Coin, 500), db2.getFeesBalance());
        try std.testing.expectEqual(@as(Coin, 100), db2.getSnapshotFees());
        try std.testing.expect(db2.areRewardBalancesTracked());
        try std.testing.expectEqual(@as(?SlotNo, 12345), db2.getTipSlot());

        const account = RewardAccount{
            .network = .testnet,
            .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0xaa} ** 28 },
        };
        try std.testing.expectEqual(@as(?Coin, 7_000), db2.lookupRewardBalance(account));
        try std.testing.expectEqual(@as(?Coin, 2_000_000), db2.lookupStakeDeposit(account.credential));

        const pool = [_]u8{0xbb} ** 28;
        try std.testing.expectEqual(@as(?Coin, 500_000_000), db2.lookupPoolDeposit(pool));
        try std.testing.expectEqual(PoolConfig{
            .pledge = 250_000_000,
            .cost = 340_000_000,
            .margin = .{ .numerator = 1, .denominator = 20 },
        }, db2.lookupPoolConfig(pool).?);
        try std.testing.expectEqual(FuturePoolParams{
            .config = .{
                .pledge = 300_000_000,
                .cost = 345_000_000,
                .margin = .{ .numerator = 1, .denominator = 10 },
            },
            .reward_account = .{
                .network = .testnet,
                .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0xbc} ** 28 },
            },
        }, db2.lookupFuturePoolParams(pool).?);
        try std.testing.expectEqual(account, db2.lookupPoolRewardAccount(pool).?);
        try std.testing.expect(db2.isPoolOwner(pool, [_]u8{0xbd} ** 28));
        try std.testing.expect(db2.isFuturePoolOwner(pool, [_]u8{0xbe} ** 28));
        try std.testing.expectEqual(@as(?EpochNo, 10), db2.lookupPoolRetirement(pool));
        try std.testing.expectEqual(@as(?KeyHash, pool), db2.lookupStakePoolDelegation(account.credential));
        try std.testing.expectEqual(@as(?u64, 7), db2.lookupPreviousEpochBlocksMade(pool));
        try std.testing.expectEqual(@as(?u64, 3), db2.lookupCurrentEpochBlocksMade(pool));
        const drep_cred = Credential{ .cred_type = .script_hash, .hash = [_]u8{0xcc} ** 28 };
        try std.testing.expectEqual(@as(?Coin, 9), db2.lookupMirReward(.reserves, account.credential));
        try std.testing.expectEqual(@as(?Coin, 11), db2.lookupMirReward(.treasury, drep_cred));
        try std.testing.expectEqual(@as(DeltaCoin, -4), db2.getMirDeltaReserves());
        try std.testing.expectEqual(@as(DeltaCoin, 4), db2.getMirDeltaTreasury());
        try std.testing.expect(db2.lookupDRepDelegation(drep_cred) != null);
        try std.testing.expectEqual(@as(?Coin, 500_000_000), db2.lookupDRepDeposit(drep_cred));
    }
}

test "ledgerdb: checkpoint not found returns false" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-no-ckpt");
    defer db.deinit();

    const loaded = try db.loadCheckpoint("/tmp/kassadin-test-ledger-no-ckpt-does-not-exist");
    try std.testing.expect(!loaded);
}

test "ledgerdb: epoch reward diff excludes owners from member rewards" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-epoch-reward");
    defer db.deinit();

    const pool = [_]u8{0x91} ** 28;
    const reward_account = RewardAccount{
        .network = .testnet,
        .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0x92} ** 28 },
    };
    const owner_cred = Credential{ .cred_type = .key_hash, .hash = [_]u8{0x93} ** 28 };
    const owner_account = RewardAccount{
        .network = .testnet,
        .credential = owner_cred,
    };
    const delegator_cred = Credential{ .cred_type = .key_hash, .hash = [_]u8{0x94} ** 28 };
    const delegator_account = RewardAccount{
        .network = .testnet,
        .credential = delegator_cred,
    };

    try db.importPoolRewardAccount(pool, reward_account);
    try db.importRewardBalance(reward_account, 1_000);
    db.setRewardAccountNetwork(.testnet);
    db.importReservesBalance(14_000_000_000_000_000);
    db.importSnapshotFees(50_000_000_000);
    try db.importPreviousEpochBlocksMade(pool, 21_600);

    // Build a "go" snapshot with one pool
    var go = stake_mod.StakeDistribution.init(allocator, 0);
    try go.setPoolStake(
        pool,
        1_000_000_000_000,
        600_000_000_000,
        500_000_000_000,
        340_000_000,
        .{ .numerator = 0, .denominator = 1 },
        reward_account,
    );
    try go.setDelegatedStake(owner_cred, pool, 600_000_000_000);
    try go.setDelegatedStake(delegator_cred, pool, 400_000_000_000);
    try go.setPoolOwnerMembership(pool, owner_cred.hash);
    go.finalize();

    var snapshots = StakeSnapshots.init(allocator);
    snapshots.go = go;
    db.replaceStakeSnapshots(snapshots);

    const diff = try db.buildEpochRewardDiff(
        allocator,
        100,
        [_]u8{0x93} ** 32,
        rewards_mod.RewardParams.mainnet_defaults,
        432_000,
    );
    try std.testing.expect(diff != null);

    try db.applyDiff(diff.?);

    // Reward account should have increased
    const new_balance = db.lookupRewardBalance(reward_account).?;
    try std.testing.expect(new_balance > 1_000);
    try std.testing.expect(db.lookupRewardBalance(owner_account) == null);
    try std.testing.expect(db.lookupRewardBalance(delegator_account) != null);
    try std.testing.expect(db.lookupRewardBalance(delegator_account).? > 0);
    // Treasury should have increased
    try std.testing.expect(db.getTreasuryBalance() > 0);
    // Snapshot fees should be reset to 0
    try std.testing.expectEqual(@as(Coin, 0), db.getSnapshotFees());

    // Rollback restores original state
    try db.rollback(1);
    try std.testing.expectEqual(@as(?Coin, 1_000), db.lookupRewardBalance(reward_account));
    try std.testing.expect(db.lookupRewardBalance(owner_account) == null);
    try std.testing.expect(db.lookupRewardBalance(delegator_account) == null);
    try std.testing.expectEqual(@as(Coin, 50_000_000_000), db.getSnapshotFees());
}

test "ledgerdb: epoch reward diff requires owner pledge stake" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-epoch-reward-pledge");
    defer db.deinit();

    const pool = [_]u8{0x95} ** 28;
    const reward_account = RewardAccount{
        .network = .testnet,
        .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0x96} ** 28 },
    };
    const owner_cred = Credential{ .cred_type = .key_hash, .hash = [_]u8{0x97} ** 28 };

    try db.importPoolRewardAccount(pool, reward_account);
    db.importReservesBalance(14_000_000_000_000_000);
    db.importSnapshotFees(50_000_000_000);
    try db.importPreviousEpochBlocksMade(pool, 21_600);

    var go = stake_mod.StakeDistribution.init(allocator, 0);
    try go.setPoolStake(
        pool,
        1_000_000_000_000,
        100_000_000_000,
        500_000_000_000,
        340_000_000,
        .{ .numerator = 0, .denominator = 1 },
        reward_account,
    );
    try go.setDelegatedStake(owner_cred, pool, 100_000_000_000);
    try go.setPoolOwnerMembership(pool, owner_cred.hash);
    go.finalize();

    var snapshots = StakeSnapshots.init(allocator);
    snapshots.go = go;
    db.replaceStakeSnapshots(snapshots);

    const diff = try db.buildEpochRewardDiff(
        allocator,
        100,
        [_]u8{0x98} ** 32,
        rewards_mod.RewardParams.mainnet_defaults,
        432_000,
    );
    try std.testing.expect(diff == null);
}

test "ledgerdb: epoch MIR diff credits registered accounts and clears pending state" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-epoch-mir");
    defer db.deinit();

    const registered_cred = Credential{ .cred_type = .key_hash, .hash = [_]u8{0x98} ** 28 };
    const unregistered_cred = Credential{ .cred_type = .script_hash, .hash = [_]u8{0x99} ** 28 };
    const registered_account = RewardAccount{
        .network = .testnet,
        .credential = registered_cred,
    };

    db.setRewardAccountNetwork(.testnet);
    db.importReservesBalance(1_000);
    db.importTreasuryBalance(200);
    try db.importStakeDeposit(registered_cred, 2_000_000);
    try db.importRewardBalance(registered_account, 50);
    try db.importMirReward(.reserves, registered_cred, 100);
    try db.importMirReward(.treasury, unregistered_cred, 25);
    db.importMirDeltaReserves(-20);
    db.importMirDeltaTreasury(20);

    const diff = (try db.buildEpochMirDiff(
        allocator,
        100,
        [_]u8{0x9a} ** 32,
    )).?;
    try db.applyDiff(diff);

    try std.testing.expectEqual(@as(Coin, 880), db.getReservesBalance());
    try std.testing.expectEqual(@as(Coin, 220), db.getTreasuryBalance());
    try std.testing.expectEqual(@as(?Coin, 150), db.lookupRewardBalance(registered_account));
    try std.testing.expectEqual(@as(?Coin, null), db.lookupMirReward(.reserves, registered_cred));
    try std.testing.expectEqual(@as(?Coin, null), db.lookupMirReward(.treasury, unregistered_cred));
    try std.testing.expectEqual(@as(DeltaCoin, 0), db.getMirDeltaReserves());
    try std.testing.expectEqual(@as(DeltaCoin, 0), db.getMirDeltaTreasury());

    try db.rollback(1);
    try std.testing.expectEqual(@as(Coin, 1_000), db.getReservesBalance());
    try std.testing.expectEqual(@as(Coin, 200), db.getTreasuryBalance());
    try std.testing.expectEqual(@as(?Coin, 50), db.lookupRewardBalance(registered_account));
    try std.testing.expectEqual(@as(?Coin, 100), db.lookupMirReward(.reserves, registered_cred));
    try std.testing.expectEqual(@as(?Coin, 25), db.lookupMirReward(.treasury, unregistered_cred));
    try std.testing.expectEqual(@as(DeltaCoin, -20), db.getMirDeltaReserves());
    try std.testing.expectEqual(@as(DeltaCoin, 20), db.getMirDeltaTreasury());
}

test "ledgerdb: current epoch blocks made diff is rollback-safe" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-blocks-made-current");
    defer db.deinit();

    const pool = [_]u8{0x99} ** 28;
    const diff = (try db.buildCurrentEpochBlocksMadeDiff(
        allocator,
        100,
        [_]u8{0x9a} ** 32,
        pool,
    )).?;
    try db.applyDiff(diff);

    try std.testing.expectEqual(@as(?u64, 1), db.lookupCurrentEpochBlocksMade(pool));
    try std.testing.expectEqual(@as(?u64, null), db.lookupPreviousEpochBlocksMade(pool));

    try db.rollback(1);
    try std.testing.expectEqual(@as(?u64, null), db.lookupCurrentEpochBlocksMade(pool));
}

test "ledgerdb: epoch blocks made shift mirrors Haskell bcur to bprev rotation" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-blocks-made-shift");
    defer db.deinit();

    const prev_only_pool = [_]u8{0x9b} ** 28;
    const current_pool = [_]u8{0x9c} ** 28;
    try db.importPreviousEpochBlocksMade(prev_only_pool, 5);
    try db.importCurrentEpochBlocksMade(current_pool, 3);

    const diff = (try db.buildEpochBlocksMadeShiftDiff(
        allocator,
        200,
        [_]u8{0x9d} ** 32,
    )).?;
    try db.applyDiff(diff);

    try std.testing.expectEqual(@as(?u64, null), db.lookupPreviousEpochBlocksMade(prev_only_pool));
    try std.testing.expectEqual(@as(?u64, 3), db.lookupPreviousEpochBlocksMade(current_pool));
    try std.testing.expectEqual(@as(?u64, null), db.lookupCurrentEpochBlocksMade(current_pool));

    try db.rollback(1);
    try std.testing.expectEqual(@as(?u64, 5), db.lookupPreviousEpochBlocksMade(prev_only_pool));
    try std.testing.expectEqual(@as(?u64, 3), db.lookupCurrentEpochBlocksMade(current_pool));
}

test "ledgerdb: epoch fee rollover moves accumulated fees into snapshot pot" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-fee-rollover");
    defer db.deinit();

    db.importFeesBalance(1_500);
    db.importSnapshotFees(250);

    const diff = (try db.buildEpochFeeRolloverDiff(
        allocator,
        100,
        [_]u8{0x94} ** 32,
    )).?;
    try db.applyDiff(diff);

    try std.testing.expectEqual(@as(Coin, 0), db.getFeesBalance());
    try std.testing.expectEqual(@as(Coin, 1_750), db.getSnapshotFees());

    try db.rollback(1);
    try std.testing.expectEqual(@as(Coin, 1_500), db.getFeesBalance());
    try std.testing.expectEqual(@as(Coin, 250), db.getSnapshotFees());
}

test "ledgerdb: rotate stake snapshots builds mark from delegations" {
    const allocator = std.testing.allocator;
    var db = try LedgerDB.init(allocator, "/tmp/kassadin-test-ledger-stake-rotate");
    defer db.deinit();

    const pool = [_]u8{0xa1} ** 28;
    const cred = Credential{ .cred_type = .key_hash, .hash = [_]u8{0xa2} ** 28 };
    const account = RewardAccount{ .network = .testnet, .credential = cred };

    try db.importRewardBalance(account, 5_000_000);
    try db.importStakeDeposit(cred, 2_000_000);
    try db.importPoolDeposit(pool, 500_000_000);
    try db.importPoolRewardAccount(pool, account);
    try db.importPoolOwnerMembership(pool, cred.hash);
    try db.importStakePoolDelegation(cred, pool);

    db.rotateStakeSnapshots(1);

    // mark should exist and contain our pool
    try std.testing.expect(db.getStakeSnapshots().mark != null);
    const mark = db.getStakeSnapshots().mark.?;
    try std.testing.expectEqual(@as(usize, 1), mark.poolCount());
    try std.testing.expectEqual(@as(usize, 1), mark.delegatorCount());
    const ps = mark.getPool(pool).?;
    try std.testing.expectEqual(@as(Coin, 7_000_000), ps.active_stake); // reward + deposit
    try std.testing.expectEqual(@as(Coin, 7_000_000), ps.self_delegated_owner_stake);
    try std.testing.expect(mark.isPoolOwner(pool, cred.hash));
    const delegated = mark.getDelegatedStake(cred).?;
    try std.testing.expectEqual(pool, delegated.pool_id);
    try std.testing.expectEqual(@as(Coin, 7_000_000), delegated.active_stake);
}
