const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const block_mod = @import("block.zig");
const transaction = @import("transaction.zig");
const cert_mod = @import("certificates.zig");
const rewards_mod = @import("rewards.zig");
const LedgerDB = @import("../storage/ledger.zig").LedgerDB;
const UtxoEntry = @import("../storage/ledger.zig").UtxoEntry;
const RewardBalanceChange = @import("../storage/ledger.zig").RewardBalanceChange;
const DeltaCoinStateChange = @import("../storage/ledger.zig").DeltaCoinStateChange;
const MIRRewardChange = @import("../storage/ledger.zig").MIRRewardChange;
const StakeDepositChange = @import("../storage/ledger.zig").StakeDepositChange;
const PoolDepositChange = @import("../storage/ledger.zig").PoolDepositChange;
const PoolConfig = @import("../storage/ledger.zig").PoolConfig;
const PoolConfigChange = @import("../storage/ledger.zig").PoolConfigChange;
const FuturePoolParams = @import("../storage/ledger.zig").FuturePoolParams;
const FuturePoolParamsChange = @import("../storage/ledger.zig").FuturePoolParamsChange;
const PoolRewardAccountChange = @import("../storage/ledger.zig").PoolRewardAccountChange;
const PoolOwnerMembershipChange = @import("../storage/ledger.zig").PoolOwnerMembershipChange;
const PoolRetirementChange = @import("../storage/ledger.zig").PoolRetirementChange;
const GenesisDelegation = @import("../storage/ledger.zig").GenesisDelegation;
const FutureGenesisDelegation = @import("../storage/ledger.zig").FutureGenesisDelegation;
const GenesisDelegationChange = @import("../storage/ledger.zig").GenesisDelegationChange;
const FutureGenesisDelegationChange = @import("../storage/ledger.zig").FutureGenesisDelegationChange;
const DRepDepositChange = @import("../storage/ledger.zig").DRepDepositChange;
const StakePoolDelegationChange = @import("../storage/ledger.zig").StakePoolDelegationChange;
const DRepDelegationChange = @import("../storage/ledger.zig").DRepDelegationChange;
const StakePointerChange = @import("../storage/ledger.zig").StakePointerChange;

pub const TxIn = types.TxIn;
pub const Credential = types.Credential;
pub const RewardAccount = types.RewardAccount;
pub const Coin = types.Coin;
pub const DeltaCoin = types.DeltaCoin;
pub const TxBody = transaction.TxBody;
pub const Withdrawal = transaction.Withdrawal;
pub const DRep = cert_mod.DRep;
pub const MIRPot = cert_mod.MIRPot;

/// Validation errors that can occur when applying a transaction.
pub const ValidationError = error{
    // UTxO rule violations
    InputNotInUtxo,
    InsufficientFee,
    ValueNotPreserved,
    NoInputs,
    OutputTooSmall,
    InvalidCertificate,
    InvalidWithdrawal,

    // Validity interval
    Expired,
    NotYetValid,

    // Size limits
    TxTooLarge,
};

/// Protocol parameters relevant to transaction validation.
pub const ProtocolParams = struct {
    min_fee_a: u64, // fee per byte
    min_fee_b: u64, // fixed fee component
    min_utxo_value: Coin, // minimum lovelace per UTxO
    max_tx_size: u32, // maximum transaction size in bytes
    key_deposit: Coin, // deposit for stake key registration
    pool_deposit: Coin, // deposit for pool registration
    max_block_body_size: u32,
    optimal_pool_count: u16 = rewards_mod.RewardParams.mainnet_defaults.n_opt,
    pool_pledge_influence: types.UnitInterval = .{ .numerator = 3, .denominator = 10 },
    monetary_expand_rate: types.UnitInterval = .{ .numerator = 3, .denominator = 1000 },
    treasury_growth_rate: types.UnitInterval = .{ .numerator = 2, .denominator = 10 },
    min_pool_cost: Coin = 340_000_000,

    pub fn rewardParams(self: ProtocolParams, base: rewards_mod.RewardParams) rewards_mod.RewardParams {
        var params = base;
        params.n_opt = self.optimal_pool_count;
        params.a0 = self.pool_pledge_influence;
        params.rho = self.monetary_expand_rate;
        params.tau = self.treasury_growth_rate;
        return params;
    }

    /// Mainnet defaults (approximate, for testing)
    pub const mainnet_defaults = ProtocolParams{
        .min_fee_a = 44,
        .min_fee_b = 155381,
        .min_utxo_value = 1_000_000,
        .max_tx_size = 16384,
        .key_deposit = 2_000_000,
        .pool_deposit = 500_000_000,
        .max_block_body_size = 90112,
        .optimal_pool_count = 500,
        .pool_pledge_influence = .{ .numerator = 3, .denominator = 10 },
        .monetary_expand_rate = .{ .numerator = 3, .denominator = 1000 },
        .treasury_growth_rate = .{ .numerator = 2, .denominator = 10 },
        .min_pool_cost = 340_000_000,
    };

    /// Temporary compatibility defaults for bootstrap/runtime validation before
    /// genesis or snapshot protocol parameters are loaded.
    pub const compatibility_defaults = ProtocolParams{
        .min_fee_a = 44,
        .min_fee_b = 155381,
        .min_utxo_value = 0,
        .max_tx_size = 16384,
        .key_deposit = 2_000_000,
        .pool_deposit = 500_000_000,
        .max_block_body_size = 90112,
        .optimal_pool_count = 500,
        .pool_pledge_influence = .{ .numerator = 3, .denominator = 10 },
        .monetary_expand_rate = .{ .numerator = 3, .denominator = 1000 },
        .treasury_growth_rate = .{ .numerator = 2, .denominator = 10 },
        .min_pool_cost = 340_000_000,
    };
};

pub const ValidationContext = struct {
    current_slot: u64,
    protocol_version_major: u64 = 0,
    epoch_length: ?u64 = null,
    stability_window: ?u64 = null,
    tx_index: ?u64 = null,
    supports_stake_pointers: bool = false,

    fn mirTransferAllowed(self: ValidationContext) bool {
        return self.protocol_version_major > 4;
    }

    fn mirTooLateInEpoch(self: ValidationContext) bool {
        const epoch_length = self.epoch_length orelse return false;
        const stability_window = self.stability_window orelse return false;
        const next_epoch = types.slotToEpoch(self.current_slot, epoch_length) + 1;
        const too_late_slot = types.epochFirstSlot(next_epoch, epoch_length) -| stability_window;
        return self.current_slot >= too_late_slot;
    }
};

pub const CertificateEffect = struct {
    deposits: Coin,
    refunds: Coin,
    mir_delta_reserves_change: ?DeltaCoinStateChange,
    mir_delta_treasury_change: ?DeltaCoinStateChange,
    stake_deposit_changes: []const StakeDepositChange,
    mir_reserves_changes: []const MIRRewardChange,
    mir_treasury_changes: []const MIRRewardChange,
    pool_deposit_changes: []const PoolDepositChange,
    pool_config_changes: []const PoolConfigChange,
    future_pool_param_changes: []const FuturePoolParamsChange,
    pool_reward_account_changes: []const PoolRewardAccountChange,
    pool_owner_changes: []const PoolOwnerMembershipChange,
    future_pool_owner_changes: []const PoolOwnerMembershipChange,
    pool_retirement_changes: []const PoolRetirementChange,
    genesis_delegation_changes: []const GenesisDelegationChange,
    future_genesis_delegation_changes: []const FutureGenesisDelegationChange,
    drep_deposit_changes: []const DRepDepositChange,
    stake_pool_delegation_changes: []const StakePoolDelegationChange,
    drep_delegation_changes: []const DRepDelegationChange,
    stake_pointer_changes: []const StakePointerChange,

    pub fn empty() CertificateEffect {
        return .{
            .deposits = 0,
            .refunds = 0,
            .mir_delta_reserves_change = null,
            .mir_delta_treasury_change = null,
            .stake_deposit_changes = &.{},
            .mir_reserves_changes = &.{},
            .mir_treasury_changes = &.{},
            .pool_deposit_changes = &.{},
            .pool_config_changes = &.{},
            .future_pool_param_changes = &.{},
            .pool_reward_account_changes = &.{},
            .pool_owner_changes = &.{},
            .future_pool_owner_changes = &.{},
            .pool_retirement_changes = &.{},
            .genesis_delegation_changes = &.{},
            .future_genesis_delegation_changes = &.{},
            .drep_deposit_changes = &.{},
            .stake_pool_delegation_changes = &.{},
            .drep_delegation_changes = &.{},
            .stake_pointer_changes = &.{},
        };
    }

    pub fn deinit(self: *CertificateEffect, allocator: std.mem.Allocator) void {
        if (self.stake_deposit_changes.len > 0) allocator.free(self.stake_deposit_changes);
        if (self.mir_reserves_changes.len > 0) allocator.free(self.mir_reserves_changes);
        if (self.mir_treasury_changes.len > 0) allocator.free(self.mir_treasury_changes);
        if (self.pool_deposit_changes.len > 0) allocator.free(self.pool_deposit_changes);
        if (self.pool_config_changes.len > 0) allocator.free(self.pool_config_changes);
        if (self.future_pool_param_changes.len > 0) allocator.free(self.future_pool_param_changes);
        if (self.pool_reward_account_changes.len > 0) allocator.free(self.pool_reward_account_changes);
        if (self.pool_owner_changes.len > 0) allocator.free(self.pool_owner_changes);
        if (self.future_pool_owner_changes.len > 0) allocator.free(self.future_pool_owner_changes);
        if (self.pool_retirement_changes.len > 0) allocator.free(self.pool_retirement_changes);
        if (self.genesis_delegation_changes.len > 0) allocator.free(self.genesis_delegation_changes);
        if (self.future_genesis_delegation_changes.len > 0) allocator.free(self.future_genesis_delegation_changes);
        if (self.drep_deposit_changes.len > 0) allocator.free(self.drep_deposit_changes);
        if (self.stake_pool_delegation_changes.len > 0) allocator.free(self.stake_pool_delegation_changes);
        if (self.drep_delegation_changes.len > 0) allocator.free(self.drep_delegation_changes);
        if (self.stake_pointer_changes.len > 0) allocator.free(self.stake_pointer_changes);
    }
};

pub const WithdrawalEffect = struct {
    withdrawn: Coin,
    reward_balance_changes: []const RewardBalanceChange,

    pub fn empty() WithdrawalEffect {
        return .{
            .withdrawn = 0,
            .reward_balance_changes = &.{},
        };
    }

    pub fn deinit(self: *WithdrawalEffect, allocator: std.mem.Allocator) void {
        if (self.reward_balance_changes.len > 0) allocator.free(self.reward_balance_changes);
    }
};

fn debugPrintDuplicateStakeRegistration(ledger: *const LedgerDB, cert_name: []const u8, credential: Credential) void {
    if (builtin.is_test) return;

    const reward_account = RewardAccount{
        .network = ledger.reward_account_network,
        .credential = credential,
    };
    const reward_balance = ledger.lookupRewardBalance(reward_account) orelse 0;
    const deposit = ledger.lookupStakeDeposit(credential);
    const pointer = ledger.lookupStakePointer(credential);
    const pool = ledger.lookupStakePoolDelegation(credential);
    const drep = ledger.lookupDRepDelegation(credential);
    std.debug.print(
        "      Duplicate {s}: cred={x:0>2}{x:0>2}{x:0>2}{x:0>2}... registered={} deposit={any} reward={} pointer={} pool={} drep={}\n",
        .{
            cert_name,
            credential.hash[0],
            credential.hash[1],
            credential.hash[2],
            credential.hash[3],
            ledger.isStakeCredentialRegistered(credential),
            deposit,
            reward_balance,
            pointer != null,
            pool != null,
            drep != null,
        },
    );
}

/// Calculate the minimum fee for a transaction.
/// fee = min_fee_b + (tx_size * min_fee_a)
pub fn calculateMinFee(pp: ProtocolParams, tx_size: usize) Coin {
    return pp.min_fee_b + (@as(u64, @intCast(tx_size)) * pp.min_fee_a);
}

/// Validate a transaction against the UTxO set and protocol parameters.
/// Returns the total consumed value on success.
pub fn validateTx(
    tx: *const TxBody,
    utxo: *const LedgerDB,
    pp: ProtocolParams,
    current_slot: u64,
    enforce_legacy_min_utxo: bool,
) ValidationError!Coin {
    return validateTxWithContext(tx, utxo, pp, .{ .current_slot = current_slot }, enforce_legacy_min_utxo);
}

pub fn validateTxWithContext(
    tx: *const TxBody,
    utxo: *const LedgerDB,
    pp: ProtocolParams,
    context: ValidationContext,
    enforce_legacy_min_utxo: bool,
) ValidationError!Coin {
    // 1. Must have at least one input
    if (tx.inputs.len == 0) return error.NoInputs;

    // 2. All inputs must exist in UTxO
    var consumed_value: Coin = 0;
    for (tx.inputs) |input| {
        const entry = utxo.lookupUtxo(input) orelse return error.InputNotInUtxo;
        consumed_value += entry.value;
    }

    var withdrawal_effect = evaluateWithdrawalEffect(std.heap.page_allocator, tx, utxo) catch {
        return error.InvalidWithdrawal;
    };
    defer withdrawal_effect.deinit(std.heap.page_allocator);

    var cert_effect = evaluateCertificateEffectWithContext(std.heap.page_allocator, tx, utxo, pp, context) catch {
        return error.InvalidCertificate;
    };
    defer cert_effect.deinit(std.heap.page_allocator);
    consumed_value += withdrawal_effect.withdrawn + cert_effect.refunds;

    // 3. Fee must meet minimum
    const min_fee = calculateMinFee(pp, tx.raw_cbor.len);
    if (tx.fee < min_fee) return error.InsufficientFee;

    // 4. Validity interval
    if (tx.ttl) |ttl| {
        if (context.current_slot >= ttl) return error.Expired;
    }
    if (tx.validity_start) |vs| {
        if (context.current_slot < vs) return error.NotYetValid;
    }

    // 5. Transaction size limit
    if (tx.raw_cbor.len > pp.max_tx_size) return error.TxTooLarge;

    // 6. All outputs must have minimum value
    if (enforce_legacy_min_utxo) {
        for (tx.outputs) |output| {
            if (output.value < pp.min_utxo_value) return error.OutputTooSmall;
        }
    }

    // 7. Preservation of value: consumed = produced + fee
    // consumed = sum of input values
    // produced = sum of output values + fee (+ deposits - refunds, simplified)
    const produced_value = tx.totalOutputValue() + tx.fee + cert_effect.deposits;
    if (consumed_value != produced_value) return error.ValueNotPreserved;

    return consumed_value;
}

pub fn evaluateWithdrawalEffect(
    allocator: std.mem.Allocator,
    tx: *const TxBody,
    ledger: *const LedgerDB,
) !WithdrawalEffect {
    if (tx.withdrawals.len == 0) return WithdrawalEffect.empty();

    if (!ledger.areRewardBalancesTracked()) {
        return error.InvalidWithdrawal;
    }

    var reward_changes: std.ArrayList(RewardBalanceChange) = .empty;
    defer reward_changes.deinit(allocator);

    var withdrawn: Coin = 0;
    for (tx.withdrawals) |withdrawal| {
        if (findPendingRewardNext(reward_changes.items, withdrawal.account) != null) {
            return error.InvalidWithdrawal;
        }

        // Match the Haskell ledger's `withdrawalsThatDoNotDrainAccounts` rule:
        // once reward balances are tracked locally, withdrawals must target a
        // known reward account and must drain that balance exactly.
        const current_balance = ledger.lookupRewardBalance(withdrawal.account) orelse {
            const h = withdrawal.account.credential.hash;
            const deposit = ledger.lookupStakeDeposit(withdrawal.account.credential);
            if (!builtin.is_test) {
                if (ledger.lookupStakePoolDelegation(withdrawal.account.credential)) |pool| {
                    std.debug.print("  InvalidWithdrawal: cred={x:0>2}{x:0>2}{x:0>2}{x:0>2}... NOT FOUND in reward balances (withdrawal_amount={} deposit={?} pool={x:0>2}{x:0>2}{x:0>2}{x:0>2}...)\n", .{
                        h[0], h[1], h[2], h[3], withdrawal.amount, deposit, pool[0], pool[1], pool[2], pool[3],
                    });
                } else {
                    std.debug.print("  InvalidWithdrawal: cred={x:0>2}{x:0>2}{x:0>2}{x:0>2}... NOT FOUND in reward balances (withdrawal_amount={} deposit={?} pool=null)\n", .{
                        h[0], h[1], h[2], h[3], withdrawal.amount, deposit,
                    });
                }
            }
            return error.InvalidWithdrawal;
        };
        if (withdrawal.amount != current_balance) {
            const h = withdrawal.account.credential.hash;
            if (!builtin.is_test) {
                if (ledger.lookupStakePoolDelegation(withdrawal.account.credential)) |pool| {
                    std.debug.print("  InvalidWithdrawal: cred={x:0>2}{x:0>2}{x:0>2}{x:0>2}... withdrawal_amount={} current_balance={} pool={x:0>2}{x:0>2}{x:0>2}{x:0>2}...\n", .{
                        h[0], h[1], h[2], h[3], withdrawal.amount, current_balance, pool[0], pool[1], pool[2], pool[3],
                    });
                } else {
                    std.debug.print("  InvalidWithdrawal: cred={x:0>2}{x:0>2}{x:0>2}{x:0>2}... withdrawal_amount={} current_balance={} pool=null\n", .{
                        h[0], h[1], h[2], h[3], withdrawal.amount, current_balance,
                    });
                }
            }
            return error.InvalidWithdrawal;
        }

        withdrawn += current_balance;
        try reward_changes.append(allocator, .{
            .account = withdrawal.account,
            .previous = current_balance,
            .next = null,
        });
    }

    return .{
        .withdrawn = withdrawn,
        .reward_balance_changes = try reward_changes.toOwnedSlice(allocator),
    };
}

pub fn evaluateCertificateEffect(
    allocator: std.mem.Allocator,
    tx: *const TxBody,
    ledger: *const LedgerDB,
    pp: ProtocolParams,
) !CertificateEffect {
    return evaluateCertificateEffectWithContext(allocator, tx, ledger, pp, .{ .current_slot = 0 });
}

pub fn evaluateCertificateEffectWithContext(
    allocator: std.mem.Allocator,
    tx: *const TxBody,
    ledger: *const LedgerDB,
    pp: ProtocolParams,
    context: ValidationContext,
) !CertificateEffect {
    if (tx.certificates.len == 0) return CertificateEffect.empty();

    var stake_changes: std.ArrayList(StakeDepositChange) = .empty;
    defer stake_changes.deinit(allocator);
    var mir_reserves_changes: std.ArrayList(MIRRewardChange) = .empty;
    defer mir_reserves_changes.deinit(allocator);
    var mir_treasury_changes: std.ArrayList(MIRRewardChange) = .empty;
    defer mir_treasury_changes.deinit(allocator);
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
    var genesis_delegation_changes: std.ArrayList(GenesisDelegationChange) = .empty;
    defer genesis_delegation_changes.deinit(allocator);
    var future_genesis_delegation_changes: std.ArrayList(FutureGenesisDelegationChange) = .empty;
    defer future_genesis_delegation_changes.deinit(allocator);
    var drep_changes: std.ArrayList(DRepDepositChange) = .empty;
    defer drep_changes.deinit(allocator);
    var stake_pool_delegation_changes: std.ArrayList(StakePoolDelegationChange) = .empty;
    defer stake_pool_delegation_changes.deinit(allocator);
    var drep_delegation_changes: std.ArrayList(DRepDelegationChange) = .empty;
    defer drep_delegation_changes.deinit(allocator);
    var stake_pointer_changes: std.ArrayList(StakePointerChange) = .empty;
    defer stake_pointer_changes.deinit(allocator);

    var deposits: Coin = 0;
    var refunds: Coin = 0;
    var mir_delta_reserves_change: ?DeltaCoinStateChange = null;
    var mir_delta_treasury_change: ?DeltaCoinStateChange = null;

    for (tx.certificates, 0..) |cert, cert_ix| {
        switch (cert) {
            .stake_registration => |cred| {
                if (findPendingStakeNext(stake_changes.items, cred) != null or ledger.lookupStakeDeposit(cred) != null) {
                    debugPrintDuplicateStakeRegistration(ledger, "stake_registration", cred);
                    return error.InvalidCertificate;
                }
                deposits += pp.key_deposit;
                try stake_changes.append(allocator, .{
                    .credential = cred,
                    .previous = ledger.lookupStakeDeposit(cred),
                    .next = pp.key_deposit,
                });
                if (stakePointerForCertificate(context, cert_ix)) |pointer| {
                    try setPendingStakePointerNext(allocator, &stake_pointer_changes, ledger, cred, pointer);
                }
            },
            .stake_delegation => |deleg| {
                if (!isStakeRegistered(stake_changes.items, ledger, deleg.cred)) return error.InvalidCertificate;
                if (!isPoolRegistered(pool_changes.items, ledger, deleg.pool)) return error.InvalidCertificate;
                try setPendingStakePoolDelegationNext(
                    allocator,
                    &stake_pool_delegation_changes,
                    ledger,
                    deleg.cred,
                    deleg.pool,
                );
            },
            .stake_deregistration => |cred| {
                if (rewardBalanceAfterWithdrawals(tx, ledger, cred) != 0) return error.InvalidCertificate;
                if (findPendingStakeNext(stake_changes.items, cred)) |pending| {
                    const deposit = pending orelse return error.InvalidCertificate;
                    refunds += deposit;
                    try setPendingStakeNext(allocator, &stake_changes, cred, null);
                } else if (ledger.lookupStakeDeposit(cred)) |deposit| {
                    refunds += deposit;
                    try stake_changes.append(allocator, .{
                        .credential = cred,
                        .previous = deposit,
                        .next = null,
                    });
                } else {
                    return error.InvalidCertificate;
                }
                try setPendingStakePointerNext(allocator, &stake_pointer_changes, ledger, cred, null);
                try setPendingStakePoolDelegationNext(allocator, &stake_pool_delegation_changes, ledger, cred, null);
                try setPendingDRepDelegationNext(allocator, &drep_delegation_changes, ledger, cred, null);
            },
            .pool_registration => |pool| {
                const current_pool_deposit = if (findPendingPoolNext(pool_changes.items, pool.operator)) |pending|
                    pending
                else
                    ledger.lookupPoolDeposit(pool.operator);

                if (current_pool_deposit == null) {
                    deposits += pp.pool_deposit;
                    try setPendingPoolConfigNext(
                        allocator,
                        &pool_config_changes,
                        ledger,
                        pool.operator,
                        .{
                            .vrf_keyhash = pool.vrf_keyhash,
                            .pledge = pool.pledge,
                            .cost = pool.cost,
                            .margin = pool.margin,
                        },
                    );
                    try setPendingPoolRewardAccountNext(
                        allocator,
                        &pool_reward_account_changes,
                        ledger,
                        pool.operator,
                        pool.reward_account,
                    );
                    try setPendingPoolOwnerSetNext(
                        allocator,
                        &pool_owner_changes,
                        ledger,
                        pool.operator,
                        pool.owners,
                        false,
                    );
                } else {
                    try setPendingFuturePoolParamsNext(
                        allocator,
                        &future_pool_param_changes,
                        ledger,
                        pool.operator,
                        .{
                            .config = .{
                                .vrf_keyhash = pool.vrf_keyhash,
                                .pledge = pool.pledge,
                                .cost = pool.cost,
                                .margin = pool.margin,
                            },
                            .reward_account = pool.reward_account,
                        },
                    );
                    try setPendingPoolOwnerSetNext(
                        allocator,
                        &future_pool_owner_changes,
                        ledger,
                        pool.operator,
                        pool.owners,
                        true,
                    );
                }
                try setPendingPoolDepositNext(allocator, &pool_changes, ledger, pool.operator, if (current_pool_deposit == null) pp.pool_deposit else current_pool_deposit);
                try setPendingPoolRetirementNext(
                    allocator,
                    &pool_retirement_changes,
                    ledger,
                    pool.operator,
                    null,
                );
            },
            .pool_retirement => |retirement| {
                if (!isPoolRegistered(pool_changes.items, ledger, retirement.pool)) {
                    return error.InvalidCertificate;
                }
                try setPendingPoolRetirementNext(
                    allocator,
                    &pool_retirement_changes,
                    ledger,
                    retirement.pool,
                    retirement.epoch,
                );
            },
            .genesis_delegation => |deleg| {
                const current = ledger.lookupGenesisDelegation(deleg.genesis) orelse return error.InvalidCertificate;
                _ = current;

                const stability_window = context.stability_window orelse return error.InvalidCertificate;
                if (hasConflictingGenesisDelegate(
                    future_genesis_delegation_changes.items,
                    ledger,
                    deleg.genesis,
                    deleg.delegate,
                )) return error.InvalidCertificate;
                if (hasConflictingGenesisVrf(
                    future_genesis_delegation_changes.items,
                    ledger,
                    deleg.genesis,
                    deleg.vrf,
                )) return error.InvalidCertificate;

                try setPendingFutureGenesisDelegationNext(
                    allocator,
                    &future_genesis_delegation_changes,
                    ledger,
                    .{
                        .slot = context.current_slot + stability_window,
                        .genesis = deleg.genesis,
                    },
                    .{
                        .delegate = deleg.delegate,
                        .vrf = deleg.vrf,
                    },
                );
            },
            .mir => |mir| {
                if (context.mirTooLateInEpoch()) return error.InvalidCertificate;

                switch (mir.target) {
                    .stake_addresses => |rewards| {
                        if (context.mirTransferAllowed()) {
                            try applyPostAlonzoMirRewards(
                                allocator,
                                ledger,
                                mir.pot,
                                rewards,
                                &mir_reserves_changes,
                                &mir_treasury_changes,
                                mir_delta_reserves_change,
                                mir_delta_treasury_change,
                            );
                        } else {
                            try applyPreAlonzoMirRewards(
                                allocator,
                                ledger,
                                mir.pot,
                                rewards,
                                &mir_reserves_changes,
                                &mir_treasury_changes,
                            );
                        }
                    },
                    .send_to_other_pot => |coin| {
                        if (!context.mirTransferAllowed()) return error.InvalidCertificate;
                        try applyMirPotTransfer(
                            ledger,
                            mir.pot,
                            coin,
                            &mir_reserves_changes,
                            &mir_treasury_changes,
                            &mir_delta_reserves_change,
                            &mir_delta_treasury_change,
                        );
                    },
                }
            },
            .reg_deposit => |reg| {
                if (findPendingStakeNext(stake_changes.items, reg.cred) != null or ledger.lookupStakeDeposit(reg.cred) != null) {
                    debugPrintDuplicateStakeRegistration(ledger, "reg_deposit", reg.cred);
                    return error.InvalidCertificate;
                }
                if (reg.deposit != pp.key_deposit) return error.InvalidCertificate;
                deposits += pp.key_deposit;
                try stake_changes.append(allocator, .{
                    .credential = reg.cred,
                    .previous = ledger.lookupStakeDeposit(reg.cred),
                    .next = pp.key_deposit,
                });
            },
            .unreg_deposit => |unreg| {
                if (rewardBalanceAfterWithdrawals(tx, ledger, unreg.cred) != 0) return error.InvalidCertificate;
                if (findPendingStakeNext(stake_changes.items, unreg.cred)) |pending| {
                    const deposit = pending orelse return error.InvalidCertificate;
                    if (deposit != unreg.refund) return error.InvalidCertificate;
                    refunds += unreg.refund;
                    try setPendingStakeNext(allocator, &stake_changes, unreg.cred, null);
                } else if (ledger.lookupStakeDeposit(unreg.cred)) |deposit| {
                    if (deposit != unreg.refund) return error.InvalidCertificate;
                    refunds += unreg.refund;
                    try stake_changes.append(allocator, .{
                        .credential = unreg.cred,
                        .previous = deposit,
                        .next = null,
                    });
                } else {
                    return error.InvalidCertificate;
                }
                try setPendingStakePointerNext(allocator, &stake_pointer_changes, ledger, unreg.cred, null);
                try setPendingStakePoolDelegationNext(allocator, &stake_pool_delegation_changes, ledger, unreg.cred, null);
                try setPendingDRepDelegationNext(allocator, &drep_delegation_changes, ledger, unreg.cred, null);
            },
            .vote_delegation => |deleg| {
                if (!isStakeRegistered(stake_changes.items, ledger, deleg.cred)) return error.InvalidCertificate;
                if (!isDRepRegistered(drep_changes.items, ledger, deleg.drep)) return error.InvalidCertificate;
                try setPendingDRepDelegationNext(
                    allocator,
                    &drep_delegation_changes,
                    ledger,
                    deleg.cred,
                    deleg.drep,
                );
            },
            .stake_vote_delegation => |deleg| {
                if (!isStakeRegistered(stake_changes.items, ledger, deleg.cred)) return error.InvalidCertificate;
                if (!isPoolRegistered(pool_changes.items, ledger, deleg.pool)) return error.InvalidCertificate;
                if (!isDRepRegistered(drep_changes.items, ledger, deleg.drep)) return error.InvalidCertificate;
                try setPendingStakePoolDelegationNext(
                    allocator,
                    &stake_pool_delegation_changes,
                    ledger,
                    deleg.cred,
                    deleg.pool,
                );
                try setPendingDRepDelegationNext(
                    allocator,
                    &drep_delegation_changes,
                    ledger,
                    deleg.cred,
                    deleg.drep,
                );
            },
            .stake_reg_delegation => |reg| {
                if (findPendingStakeNext(stake_changes.items, reg.cred) != null or ledger.lookupStakeDeposit(reg.cred) != null) {
                    debugPrintDuplicateStakeRegistration(ledger, "stake_reg_delegation", reg.cred);
                    return error.InvalidCertificate;
                }
                if (reg.deposit != pp.key_deposit) return error.InvalidCertificate;
                if (!isPoolRegistered(pool_changes.items, ledger, reg.pool)) return error.InvalidCertificate;
                deposits += pp.key_deposit;
                try stake_changes.append(allocator, .{
                    .credential = reg.cred,
                    .previous = ledger.lookupStakeDeposit(reg.cred),
                    .next = pp.key_deposit,
                });
                try setPendingStakePoolDelegationNext(
                    allocator,
                    &stake_pool_delegation_changes,
                    ledger,
                    reg.cred,
                    reg.pool,
                );
            },
            .vote_reg_delegation => |reg| {
                if (findPendingStakeNext(stake_changes.items, reg.cred) != null or ledger.lookupStakeDeposit(reg.cred) != null) {
                    debugPrintDuplicateStakeRegistration(ledger, "vote_reg_delegation", reg.cred);
                    return error.InvalidCertificate;
                }
                if (reg.deposit != pp.key_deposit) return error.InvalidCertificate;
                if (!isDRepRegistered(drep_changes.items, ledger, reg.drep)) return error.InvalidCertificate;
                deposits += pp.key_deposit;
                try stake_changes.append(allocator, .{
                    .credential = reg.cred,
                    .previous = ledger.lookupStakeDeposit(reg.cred),
                    .next = pp.key_deposit,
                });
                try setPendingDRepDelegationNext(
                    allocator,
                    &drep_delegation_changes,
                    ledger,
                    reg.cred,
                    reg.drep,
                );
            },
            .stake_vote_reg_delegation => |reg| {
                if (findPendingStakeNext(stake_changes.items, reg.cred) != null or ledger.lookupStakeDeposit(reg.cred) != null) {
                    debugPrintDuplicateStakeRegistration(ledger, "stake_vote_reg_delegation", reg.cred);
                    return error.InvalidCertificate;
                }
                if (reg.deposit != pp.key_deposit) return error.InvalidCertificate;
                if (!isPoolRegistered(pool_changes.items, ledger, reg.pool)) return error.InvalidCertificate;
                if (!isDRepRegistered(drep_changes.items, ledger, reg.drep)) return error.InvalidCertificate;
                deposits += pp.key_deposit;
                try stake_changes.append(allocator, .{
                    .credential = reg.cred,
                    .previous = ledger.lookupStakeDeposit(reg.cred),
                    .next = pp.key_deposit,
                });
                try setPendingStakePoolDelegationNext(
                    allocator,
                    &stake_pool_delegation_changes,
                    ledger,
                    reg.cred,
                    reg.pool,
                );
                try setPendingDRepDelegationNext(
                    allocator,
                    &drep_delegation_changes,
                    ledger,
                    reg.cred,
                    reg.drep,
                );
            },
            .drep_registration => |reg| {
                if (findPendingDRepNext(drep_changes.items, reg.cred) != null or ledger.lookupDRepDeposit(reg.cred) != null) {
                    return error.InvalidCertificate;
                }
                deposits += reg.deposit;
                try drep_changes.append(allocator, .{
                    .credential = reg.cred,
                    .previous = ledger.lookupDRepDeposit(reg.cred),
                    .next = reg.deposit,
                });
            },
            .drep_deregistration => |unreg| {
                if (findPendingDRepNext(drep_changes.items, unreg.cred)) |pending| {
                    const deposit = pending orelse return error.InvalidCertificate;
                    if (deposit != unreg.refund) return error.InvalidCertificate;
                    refunds += unreg.refund;
                    try setPendingDRepNext(allocator, &drep_changes, unreg.cred, null);
                } else if (ledger.lookupDRepDeposit(unreg.cred)) |deposit| {
                    if (deposit != unreg.refund) return error.InvalidCertificate;
                    refunds += unreg.refund;
                    try drep_changes.append(allocator, .{
                        .credential = unreg.cred,
                        .previous = deposit,
                        .next = null,
                    });
                } else {
                    return error.InvalidCertificate;
                }
            },
            .drep_update => |update| {
                const drep = DRep{ .key_hash = update.cred.hash };
                if (update.cred.cred_type == .script_hash) {
                    if (!isDRepRegisteredCredential(drep_changes.items, ledger, update.cred)) return error.InvalidCertificate;
                } else if (!isDRepRegistered(drep_changes.items, ledger, drep)) {
                    return error.InvalidCertificate;
                }
            },
            else => {},
        }
    }

    return .{
        .deposits = deposits,
        .refunds = refunds,
        .mir_delta_reserves_change = mir_delta_reserves_change,
        .mir_delta_treasury_change = mir_delta_treasury_change,
        .stake_deposit_changes = try stake_changes.toOwnedSlice(allocator),
        .mir_reserves_changes = try mir_reserves_changes.toOwnedSlice(allocator),
        .mir_treasury_changes = try mir_treasury_changes.toOwnedSlice(allocator),
        .pool_deposit_changes = try pool_changes.toOwnedSlice(allocator),
        .pool_config_changes = try pool_config_changes.toOwnedSlice(allocator),
        .future_pool_param_changes = try future_pool_param_changes.toOwnedSlice(allocator),
        .pool_reward_account_changes = try pool_reward_account_changes.toOwnedSlice(allocator),
        .pool_owner_changes = try pool_owner_changes.toOwnedSlice(allocator),
        .future_pool_owner_changes = try future_pool_owner_changes.toOwnedSlice(allocator),
        .pool_retirement_changes = try pool_retirement_changes.toOwnedSlice(allocator),
        .genesis_delegation_changes = try genesis_delegation_changes.toOwnedSlice(allocator),
        .future_genesis_delegation_changes = try future_genesis_delegation_changes.toOwnedSlice(allocator),
        .drep_deposit_changes = try drep_changes.toOwnedSlice(allocator),
        .stake_pool_delegation_changes = try stake_pool_delegation_changes.toOwnedSlice(allocator),
        .drep_delegation_changes = try drep_delegation_changes.toOwnedSlice(allocator),
        .stake_pointer_changes = try stake_pointer_changes.toOwnedSlice(allocator),
    };
}

fn applyPreAlonzoMirRewards(
    allocator: std.mem.Allocator,
    ledger: *const LedgerDB,
    pot: MIRPot,
    rewards: []const cert_mod.MIRReward,
    mir_reserves_changes: *std.ArrayList(MIRRewardChange),
    mir_treasury_changes: *std.ArrayList(MIRRewardChange),
) !void {
    const target_changes = switch (pot) {
        .reserves => mir_reserves_changes,
        .treasury => mir_treasury_changes,
    };

    for (rewards) |reward| {
        if (reward.delta < 0) return error.InvalidCertificate;
        try setPendingMirRewardNext(
            allocator,
            target_changes,
            ledger,
            pot,
            reward.credential,
            if (reward.delta == 0) null else @as(Coin, @intCast(reward.delta)),
        );
    }

    const available = switch (pot) {
        .reserves => ledger.getReservesBalance(),
        .treasury => ledger.getTreasuryBalance(),
    };
    if (sumPendingMirRewards(ledger, pot, target_changes.items) > available) return error.InvalidCertificate;
}

fn applyPostAlonzoMirRewards(
    allocator: std.mem.Allocator,
    ledger: *const LedgerDB,
    pot: MIRPot,
    rewards: []const cert_mod.MIRReward,
    mir_reserves_changes: *std.ArrayList(MIRRewardChange),
    mir_treasury_changes: *std.ArrayList(MIRRewardChange),
    mir_delta_reserves_change: ?DeltaCoinStateChange,
    mir_delta_treasury_change: ?DeltaCoinStateChange,
) !void {
    const target_changes = switch (pot) {
        .reserves => mir_reserves_changes,
        .treasury => mir_treasury_changes,
    };

    for (rewards) |reward| {
        const previous = effectiveMirReward(target_changes.items, ledger, pot, reward.credential) orelse 0;
        const next_amount = @as(i128, @intCast(previous)) + reward.delta;
        if (next_amount < 0 or next_amount > std.math.maxInt(Coin)) return error.InvalidCertificate;
        try setPendingMirRewardNext(
            allocator,
            target_changes,
            ledger,
            pot,
            reward.credential,
            if (next_amount == 0) null else @as(Coin, @intCast(next_amount)),
        );
    }

    const available = effectiveMirPotBalance(ledger, pot, mir_delta_reserves_change, mir_delta_treasury_change) orelse {
        return error.InvalidCertificate;
    };
    if (sumPendingMirRewards(ledger, pot, target_changes.items) > available) return error.InvalidCertificate;
}

fn applyMirPotTransfer(
    ledger: *const LedgerDB,
    pot: MIRPot,
    coin: Coin,
    mir_reserves_changes: *const std.ArrayList(MIRRewardChange),
    mir_treasury_changes: *const std.ArrayList(MIRRewardChange),
    mir_delta_reserves_change: *?DeltaCoinStateChange,
    mir_delta_treasury_change: *?DeltaCoinStateChange,
) !void {
    const available = switch (pot) {
        .reserves => blk: {
            const pot_total = effectiveMirPotBalance(ledger, .reserves, mir_delta_reserves_change.*, mir_delta_treasury_change.*) orelse break :blk 0;
            break :blk pot_total -| sumPendingMirRewards(ledger, .reserves, mir_reserves_changes.items);
        },
        .treasury => blk: {
            const pot_total = effectiveMirPotBalance(ledger, .treasury, mir_delta_reserves_change.*, mir_delta_treasury_change.*) orelse break :blk 0;
            break :blk pot_total -| sumPendingMirRewards(ledger, .treasury, mir_treasury_changes.items);
        },
    };
    if (coin > available) return error.InvalidCertificate;

    const transfer_delta = std.math.cast(DeltaCoin, coin) orelse return error.InvalidCertificate;
    const current_reserves_delta = effectiveMirDelta(ledger.getMirDeltaReserves(), mir_delta_reserves_change.*);
    const current_treasury_delta = effectiveMirDelta(ledger.getMirDeltaTreasury(), mir_delta_treasury_change.*);

    switch (pot) {
        .reserves => {
            setPendingDeltaCoinChange(mir_delta_reserves_change, ledger.getMirDeltaReserves(), current_reserves_delta - transfer_delta);
            setPendingDeltaCoinChange(mir_delta_treasury_change, ledger.getMirDeltaTreasury(), current_treasury_delta + transfer_delta);
        },
        .treasury => {
            setPendingDeltaCoinChange(mir_delta_reserves_change, ledger.getMirDeltaReserves(), current_reserves_delta + transfer_delta);
            setPendingDeltaCoinChange(mir_delta_treasury_change, ledger.getMirDeltaTreasury(), current_treasury_delta - transfer_delta);
        },
    }
}

fn isStakeRegistered(
    changes: []const StakeDepositChange,
    ledger: *const LedgerDB,
    credential: types.Credential,
) bool {
    if (findPendingStakeNext(changes, credential)) |pending| {
        return pending != null;
    }
    return ledger.lookupStakeDeposit(credential) != null;
}

fn isPoolRegistered(
    changes: []const PoolDepositChange,
    ledger: *const LedgerDB,
    pool: types.KeyHash,
) bool {
    if (findPendingPool(changes, pool) != null) return true;
    return ledger.lookupPoolDeposit(pool) != null;
}

fn isDRepRegistered(
    changes: []const DRepDepositChange,
    ledger: *const LedgerDB,
    drep: DRep,
) bool {
    const credential = switch (drep) {
        .always_abstain, .always_no_confidence => return true,
        .key_hash => |hash| types.Credential{ .cred_type = .key_hash, .hash = hash },
        .script_hash => |hash| types.Credential{ .cred_type = .script_hash, .hash = hash },
    };
    return isDRepRegisteredCredential(changes, ledger, credential);
}

fn isDRepRegisteredCredential(
    changes: []const DRepDepositChange,
    ledger: *const LedgerDB,
    credential: types.Credential,
) bool {
    if (findPendingDRepNext(changes, credential)) |pending| {
        return pending != null;
    }
    return ledger.lookupDRepDeposit(credential) != null;
}

fn findPendingStakePoolDelegationNext(
    changes: []const StakePoolDelegationChange,
    credential: types.Credential,
) ??types.KeyHash {
    for (changes) |change| {
        if (types.Credential.eql(change.credential, credential)) return change.next;
    }
    return null;
}

fn setPendingStakePoolDelegationNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(StakePoolDelegationChange),
    ledger: *const LedgerDB,
    credential: types.Credential,
    next: ?types.KeyHash,
) !void {
    for (changes.items) |*change| {
        if (types.Credential.eql(change.credential, credential)) {
            change.next = next;
            return;
        }
    }
    try changes.append(allocator, .{
        .credential = credential,
        .previous = if (findPendingStakePoolDelegationNext(changes.items, credential)) |pending| pending else ledger.lookupStakePoolDelegation(credential),
        .next = next,
    });
}

fn findPendingDRepDelegationNext(
    changes: []const DRepDelegationChange,
    credential: types.Credential,
) ??DRep {
    for (changes) |change| {
        if (types.Credential.eql(change.credential, credential)) return change.next;
    }
    return null;
}

fn setPendingDRepDelegationNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(DRepDelegationChange),
    ledger: *const LedgerDB,
    credential: types.Credential,
    next: ?DRep,
) !void {
    for (changes.items) |*change| {
        if (types.Credential.eql(change.credential, credential)) {
            change.next = next;
            return;
        }
    }
    try changes.append(allocator, .{
        .credential = credential,
        .previous = if (findPendingDRepDelegationNext(changes.items, credential)) |pending| pending else ledger.lookupDRepDelegation(credential),
        .next = next,
    });
}

fn findPendingRewardNext(changes: []const RewardBalanceChange, account: types.RewardAccount) ??Coin {
    for (changes) |change| {
        if (change.account.network == account.network and
            types.Credential.eql(change.account.credential, account.credential))
        {
            return change.next;
        }
    }
    return null;
}

fn findPendingMirRewardNext(
    changes: []const MIRRewardChange,
    credential: types.Credential,
) ??Coin {
    for (changes) |change| {
        if (types.Credential.eql(change.credential, credential)) return change.next;
    }
    return null;
}

fn setPendingMirRewardNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(MIRRewardChange),
    ledger: *const LedgerDB,
    pot: MIRPot,
    credential: types.Credential,
    next: ?Coin,
) !void {
    for (changes.items) |*change| {
        if (types.Credential.eql(change.credential, credential)) {
            change.next = next;
            return;
        }
    }

    try changes.append(allocator, .{
        .credential = credential,
        .previous = ledger.lookupMirReward(pot, credential),
        .next = next,
    });
}

fn effectiveMirReward(
    changes: []const MIRRewardChange,
    ledger: *const LedgerDB,
    pot: MIRPot,
    credential: types.Credential,
) ?Coin {
    if (findPendingMirRewardNext(changes, credential)) |pending| {
        return pending;
    }
    return ledger.lookupMirReward(pot, credential);
}

fn sumPendingMirRewards(
    ledger: *const LedgerDB,
    pot: MIRPot,
    changes: []const MIRRewardChange,
) Coin {
    const map = switch (pot) {
        .reserves => &ledger.mir_reserves,
        .treasury => &ledger.mir_treasury,
    };

    var total: Coin = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (findPendingMirRewardNext(changes, entry.key_ptr.*)) |pending| {
            if (pending) |amount| total += amount;
        } else {
            total += entry.value_ptr.*;
        }
    }

    for (changes) |change| {
        if (ledger.lookupMirReward(pot, change.credential) != null) continue;
        if (change.next) |amount| total += amount;
    }

    return total;
}

fn effectiveMirDelta(current: DeltaCoin, change: ?DeltaCoinStateChange) DeltaCoin {
    if (change) |pending| return pending.next;
    return current;
}

fn effectiveMirPotBalance(
    ledger: *const LedgerDB,
    pot: MIRPot,
    mir_delta_reserves_change: ?DeltaCoinStateChange,
    mir_delta_treasury_change: ?DeltaCoinStateChange,
) ?Coin {
    return switch (pot) {
        .reserves => addDeltaCoinChecked(
            ledger.getReservesBalance(),
            effectiveMirDelta(ledger.getMirDeltaReserves(), mir_delta_reserves_change),
        ),
        .treasury => addDeltaCoinChecked(
            ledger.getTreasuryBalance(),
            effectiveMirDelta(ledger.getMirDeltaTreasury(), mir_delta_treasury_change),
        ),
    };
}

fn setPendingDeltaCoinChange(
    change: *?DeltaCoinStateChange,
    previous: DeltaCoin,
    next: DeltaCoin,
) void {
    if (change.*) |*pending| {
        pending.next = next;
    } else {
        change.* = .{
            .previous = previous,
            .next = next,
        };
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

fn rewardBalanceAfterWithdrawals(
    tx: *const TxBody,
    ledger: *const LedgerDB,
    credential: types.Credential,
) Coin {
    if (!ledger.areRewardBalancesTracked()) return 0;

    const account = types.RewardAccount{
        .network = ledger.reward_account_network,
        .credential = credential,
    };
    const current = ledger.lookupRewardBalance(account) orelse 0;
    if (current == 0) return 0;

    for (tx.withdrawals) |withdrawal| {
        if (withdrawal.account.network == account.network and
            types.Credential.eql(withdrawal.account.credential, account.credential))
        {
            return 0;
        }
    }

    return current;
}

fn stakePointerForCertificate(context: ValidationContext, cert_ix: usize) ?types.Pointer {
    if (!context.supports_stake_pointers) return null;
    const tx_index = context.tx_index orelse return null;
    return .{
        .slot = context.current_slot,
        .tx_ix = tx_index,
        .cert_ix = cert_ix,
    };
}

fn findPendingStakeNext(changes: []const StakeDepositChange, credential: types.Credential) ??Coin {
    for (changes) |change| {
        if (types.Credential.eql(change.credential, credential)) return change.next;
    }
    return null;
}

fn findPendingStakePointerNext(
    changes: []const StakePointerChange,
    credential: types.Credential,
) ??types.Pointer {
    for (changes) |change| {
        if (types.Credential.eql(change.credential, credential)) return change.next;
    }
    return null;
}

fn setPendingStakeNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(StakeDepositChange),
    credential: types.Credential,
    next: ?Coin,
) !void {
    for (changes.items) |*change| {
        if (types.Credential.eql(change.credential, credential)) {
            change.next = next;
            return;
        }
    }
    try changes.append(allocator, .{
        .credential = credential,
        .previous = null,
        .next = next,
    });
}

fn setPendingStakePointerNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(StakePointerChange),
    ledger: *const LedgerDB,
    credential: types.Credential,
    next: ?types.Pointer,
) !void {
    for (changes.items) |*change| {
        if (types.Credential.eql(change.credential, credential)) {
            change.next = next;
            return;
        }
    }
    try changes.append(allocator, .{
        .credential = credential,
        .previous = if (findPendingStakePointerNext(changes.items, credential)) |pending| pending else ledger.lookupStakePointer(credential),
        .next = next,
    });
}

fn findPendingPool(changes: []const PoolDepositChange, pool: types.KeyHash) ?usize {
    for (changes, 0..) |change, i| {
        if (std.mem.eql(u8, &change.pool, &pool)) return i;
    }
    return null;
}

fn findPendingPoolNext(changes: []const PoolDepositChange, pool: types.KeyHash) ??Coin {
    for (changes) |change| {
        if (std.mem.eql(u8, &change.pool, &pool)) return change.next;
    }
    return null;
}

fn setPendingPoolDepositNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(PoolDepositChange),
    ledger: *const LedgerDB,
    pool: types.KeyHash,
    next: ?Coin,
) !void {
    for (changes.items) |*change| {
        if (std.mem.eql(u8, &change.pool, &pool)) {
            change.next = next;
            return;
        }
    }
    try changes.append(allocator, .{
        .pool = pool,
        .previous = ledger.lookupPoolDeposit(pool),
        .next = next,
    });
}

fn findPendingPoolConfigNext(
    changes: []const PoolConfigChange,
    pool: types.KeyHash,
) ??PoolConfig {
    for (changes) |change| {
        if (std.mem.eql(u8, &change.pool, &pool)) return change.next;
    }
    return null;
}

fn setPendingPoolConfigNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(PoolConfigChange),
    ledger: *const LedgerDB,
    pool: types.KeyHash,
    next: ?PoolConfig,
) !void {
    for (changes.items) |*change| {
        if (std.mem.eql(u8, &change.pool, &pool)) {
            change.next = next;
            return;
        }
    }
    try changes.append(allocator, .{
        .pool = pool,
        .previous = if (findPendingPoolConfigNext(changes.items, pool)) |pending| pending else ledger.lookupPoolConfig(pool),
        .next = next,
    });
}

fn findPendingFuturePoolParamsNext(
    changes: []const FuturePoolParamsChange,
    pool: types.KeyHash,
) ??FuturePoolParams {
    for (changes) |change| {
        if (std.mem.eql(u8, &change.pool, &pool)) return change.next;
    }
    return null;
}

fn setPendingFuturePoolParamsNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(FuturePoolParamsChange),
    ledger: *const LedgerDB,
    pool: types.KeyHash,
    next: ?FuturePoolParams,
) !void {
    for (changes.items) |*change| {
        if (std.mem.eql(u8, &change.pool, &pool)) {
            change.next = next;
            return;
        }
    }
    try changes.append(allocator, .{
        .pool = pool,
        .previous = if (findPendingFuturePoolParamsNext(changes.items, pool)) |pending| pending else ledger.lookupFuturePoolParams(pool),
        .next = next,
    });
}

fn findPendingPoolRewardAccountNext(
    changes: []const PoolRewardAccountChange,
    pool: types.KeyHash,
) ??types.RewardAccount {
    for (changes) |change| {
        if (std.mem.eql(u8, &change.pool, &pool)) return change.next;
    }
    return null;
}

fn setPendingPoolRewardAccountNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(PoolRewardAccountChange),
    ledger: *const LedgerDB,
    pool: types.KeyHash,
    next: ?types.RewardAccount,
) !void {
    for (changes.items) |*change| {
        if (std.mem.eql(u8, &change.pool, &pool)) {
            change.next = next;
            return;
        }
    }
    try changes.append(allocator, .{
        .pool = pool,
        .previous = ledger.lookupPoolRewardAccount(pool),
        .next = next,
    });
}

fn keyHashSliceContains(owners: []const types.KeyHash, owner: types.KeyHash) bool {
    for (owners) |candidate| {
        if (std.mem.eql(u8, &candidate, &owner)) return true;
    }
    return false;
}

fn setPendingPoolOwnerMembershipNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(PoolOwnerMembershipChange),
    ledger: *const LedgerDB,
    membership: types.PoolOwnerMembership,
    next: bool,
    future: bool,
) !void {
    for (changes.items) |*change| {
        if (std.mem.eql(u8, &change.membership.pool, &membership.pool) and
            std.mem.eql(u8, &change.membership.owner, &membership.owner))
        {
            change.next = next;
            return;
        }
    }

    try changes.append(allocator, .{
        .membership = membership,
        .previous = if (future)
            ledger.isFuturePoolOwner(membership.pool, membership.owner)
        else
            ledger.isPoolOwner(membership.pool, membership.owner),
        .next = next,
    });
}

fn setPendingPoolOwnerSetNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(PoolOwnerMembershipChange),
    ledger: *const LedgerDB,
    pool: types.KeyHash,
    owners: []const types.KeyHash,
    future: bool,
) !void {
    const existing = try ledger.listPoolOwners(allocator, pool, future);
    defer if (existing.len > 0) allocator.free(existing);

    for (existing) |owner| {
        if (!keyHashSliceContains(owners, owner)) {
            try setPendingPoolOwnerMembershipNext(allocator, changes, ledger, .{
                .pool = pool,
                .owner = owner,
            }, false, future);
        }
    }

    for (owners) |owner| {
        try setPendingPoolOwnerMembershipNext(allocator, changes, ledger, .{
            .pool = pool,
            .owner = owner,
        }, true, future);
    }
}

fn findPendingPoolRetirementNext(
    changes: []const PoolRetirementChange,
    pool: types.KeyHash,
) ??types.EpochNo {
    for (changes) |change| {
        if (std.mem.eql(u8, &change.pool, &pool)) return change.next;
    }
    return null;
}

fn setPendingPoolRetirementNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(PoolRetirementChange),
    ledger: *const LedgerDB,
    pool: types.KeyHash,
    next: ?types.EpochNo,
) !void {
    for (changes.items) |*change| {
        if (std.mem.eql(u8, &change.pool, &pool)) {
            change.next = next;
            return;
        }
    }
    try changes.append(allocator, .{
        .pool = pool,
        .previous = if (findPendingPoolRetirementNext(changes.items, pool)) |pending| pending else ledger.lookupPoolRetirement(pool),
        .next = next,
    });
}

fn findPendingFutureGenesisDelegationNext(
    changes: []const FutureGenesisDelegationChange,
    future: FutureGenesisDelegation,
) ??GenesisDelegation {
    for (changes) |change| {
        if (change.future.slot == future.slot and
            std.mem.eql(u8, &change.future.genesis, &future.genesis))
        {
            return change.next;
        }
    }
    return null;
}

fn setPendingFutureGenesisDelegationNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(FutureGenesisDelegationChange),
    ledger: *const LedgerDB,
    future: FutureGenesisDelegation,
    next: ?GenesisDelegation,
) !void {
    for (changes.items) |*change| {
        if (change.future.slot == future.slot and
            std.mem.eql(u8, &change.future.genesis, &future.genesis))
        {
            change.next = next;
            return;
        }
    }

    try changes.append(allocator, .{
        .future = future,
        .previous = if (findPendingFutureGenesisDelegationNext(changes.items, future)) |pending|
            pending
        else
            ledger.lookupFutureGenesisDelegation(future),
        .next = next,
    });
}

fn hasConflictingGenesisDelegate(
    pending_changes: []const FutureGenesisDelegationChange,
    ledger: *const LedgerDB,
    genesis: types.KeyHash,
    delegate: types.KeyHash,
) bool {
    if (ledger.hasOtherCurrentGenesisDelegate(genesis, delegate)) return true;
    if (ledger.hasOtherFutureGenesisDelegate(genesis, delegate)) return true;

    for (pending_changes) |change| {
        const pending = change.next orelse continue;
        if (std.mem.eql(u8, &change.future.genesis, &genesis)) continue;
        if (std.mem.eql(u8, &pending.delegate, &delegate)) return true;
    }

    return false;
}

fn hasConflictingGenesisVrf(
    pending_changes: []const FutureGenesisDelegationChange,
    ledger: *const LedgerDB,
    genesis: types.KeyHash,
    vrf: types.Hash32,
) bool {
    if (ledger.hasOtherCurrentGenesisVrf(genesis, vrf)) return true;
    if (ledger.hasOtherFutureGenesisVrf(genesis, vrf)) return true;

    for (pending_changes) |change| {
        const pending = change.next orelse continue;
        if (std.mem.eql(u8, &change.future.genesis, &genesis)) continue;
        if (std.mem.eql(u8, &pending.vrf, &vrf)) return true;
    }

    return false;
}

fn findPendingDRepNext(changes: []const DRepDepositChange, credential: types.Credential) ??Coin {
    for (changes) |change| {
        if (types.Credential.eql(change.credential, credential)) return change.next;
    }
    return null;
}

fn setPendingDRepNext(
    allocator: std.mem.Allocator,
    changes: *std.ArrayList(DRepDepositChange),
    credential: types.Credential,
    next: ?Coin,
) !void {
    for (changes.items) |*change| {
        if (types.Credential.eql(change.credential, credential)) {
            change.next = next;
            return;
        }
    }
    try changes.append(allocator, .{
        .credential = credential,
        .previous = null,
        .next = next,
    });
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "rules: minimum fee calculation" {
    const pp = ProtocolParams.mainnet_defaults;

    // 200-byte tx: 155381 + (200 * 44) = 155381 + 8800 = 164181
    const fee = calculateMinFee(pp, 200);
    try std.testing.expectEqual(@as(Coin, 164181), fee);

    // 0-byte tx: just the fixed component
    try std.testing.expectEqual(@as(Coin, 155381), calculateMinFee(pp, 0));
}

test "rules: validate simple tx — preservation of value" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules1");
    defer ledger.deinit();

    // Seed the UTxO set with one entry: 10 ADA
    const input_txin = TxIn{ .tx_id = [_]u8{0x01} ** 32, .tx_ix = 0 };
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{
        .tx_in = input_txin,
        .value = 10_000_000,
        .raw_cbor = try allocator.dupe(u8, "seed_utxo"),
    };
    try ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = produced,
    });

    // Create a valid tx: spend 10 ADA → 8 ADA output + 2 ADA fee
    // (fee is very high but keeps the example simple)
    const tx = TxBody{
        .tx_id = [_]u8{0xaa} ** 32,
        .inputs = &[_]TxIn{input_txin},
        .outputs = &[_]transaction.TxOut{
            .{
                .address_raw = &([_]u8{0x61} ++ [_]u8{0xbb} ** 28),
                .value = 8_000_000,
                .datum_hash = null,
                .raw_cbor = "output",
            },
        },
        .certificates = &[_]transaction.Certificate{},
        .fee = 2_000_000,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{0} ** 200, // fake 200-byte tx
    };

    const pp = ProtocolParams{
        .min_fee_a = 44,
        .min_fee_b = 155381,
        .min_utxo_value = 1_000_000,
        .max_tx_size = 16384,
        .key_deposit = 2_000_000,
        .pool_deposit = 500_000_000,
        .max_block_body_size = 90112,
    };

    const consumed = try validateTx(&tx, &ledger, pp, 100, true);
    try std.testing.expectEqual(@as(Coin, 10_000_000), consumed);
}

test "rules: reject tx with missing input" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules2");
    defer ledger.deinit();

    const tx = TxBody{
        .tx_id = [_]u8{0xaa} ** 32,
        .inputs = &[_]TxIn{.{ .tx_id = [_]u8{0xff} ** 32, .tx_ix = 0 }},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{},
        .fee = 200_000,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{0} ** 100,
    };

    const result = validateTx(&tx, &ledger, ProtocolParams.mainnet_defaults, 100, true);
    try std.testing.expectError(error.InputNotInUtxo, result);
}

test "rules: reject tx with no inputs" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules3");
    defer ledger.deinit();

    const tx = TxBody{
        .tx_id = [_]u8{0xaa} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{},
        .fee = 200_000,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{0} ** 100,
    };

    const result = validateTx(&tx, &ledger, ProtocolParams.mainnet_defaults, 100, true);
    try std.testing.expectError(error.NoInputs, result);
}

test "rules: reject expired tx" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules4");
    defer ledger.deinit();

    // Seed UTxO
    const input = TxIn{ .tx_id = [_]u8{0x01} ** 32, .tx_ix = 0 };
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{ .tx_in = input, .value = 10_000_000, .raw_cbor = try allocator.dupe(u8, "x") };
    try ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = produced,
    });

    const tx = TxBody{
        .tx_id = [_]u8{0xaa} ** 32,
        .inputs = &[_]TxIn{input},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{},
        .fee = 10_000_000,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = 50, // expires at slot 50
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{0} ** 200,
    };

    // Current slot = 100, TTL = 50 → expired
    const result = validateTx(&tx, &ledger, ProtocolParams.mainnet_defaults, 100, true);
    try std.testing.expectError(error.Expired, result);
}

test "rules: reject value not preserved" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules5");
    defer ledger.deinit();

    const input = TxIn{ .tx_id = [_]u8{0x01} ** 32, .tx_ix = 0 };
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{ .tx_in = input, .value = 10_000_000, .raw_cbor = try allocator.dupe(u8, "x") };
    try ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = produced,
    });

    // Try to create 20 ADA from 10 ADA input
    const tx = TxBody{
        .tx_id = [_]u8{0xaa} ** 32,
        .inputs = &[_]TxIn{input},
        .outputs = &[_]transaction.TxOut{
            .{
                .address_raw = &([_]u8{0x61} ++ [_]u8{0xbb} ** 28),
                .value = 19_000_000, // trying to create value
                .datum_hash = null,
                .raw_cbor = "bad_output",
            },
        },
        .certificates = &[_]transaction.Certificate{},
        .fee = 1_000_000,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{0} ** 200,
    };

    const result = validateTx(&tx, &ledger, ProtocolParams.mainnet_defaults, 100, true);
    try std.testing.expectError(error.ValueNotPreserved, result);
}

test "rules: certificate effect charges and refunds stake deposit in same tx" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-cert-effect");
    defer ledger.deinit();

    const cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xaa} ** 28,
    };
    const tx = TxBody{
        .tx_id = [_]u8{0x44} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{ .stake_registration = cred },
            .{ .stake_deregistration = cred },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    var effect = try evaluateCertificateEffect(allocator, &tx, &ledger, ProtocolParams.mainnet_defaults);
    defer effect.deinit(allocator);

    try std.testing.expectEqual(ProtocolParams.mainnet_defaults.key_deposit, effect.deposits);
    try std.testing.expectEqual(ProtocolParams.mainnet_defaults.key_deposit, effect.refunds);
    try std.testing.expectEqual(@as(usize, 1), effect.stake_deposit_changes.len);
    try std.testing.expect(effect.stake_deposit_changes[0].next == null);
}

test "rules: pre-Conway stake registration stages stake pointer" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-stake-pointer");
    defer ledger.deinit();

    const cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xac} ** 28,
    };
    const tx = TxBody{
        .tx_id = [_]u8{0x45} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{ .stake_registration = cred },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    var effect = try evaluateCertificateEffectWithContext(
        allocator,
        &tx,
        &ledger,
        ProtocolParams.mainnet_defaults,
        .{
            .current_slot = 123,
            .tx_index = 4,
            .supports_stake_pointers = true,
        },
    );
    defer effect.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), effect.stake_pointer_changes.len);
    try std.testing.expect(effect.stake_pointer_changes[0].previous == null);
    try std.testing.expectEqual(@as(u64, 123), effect.stake_pointer_changes[0].next.?.slot);
    try std.testing.expectEqual(@as(u64, 4), effect.stake_pointer_changes[0].next.?.tx_ix);
    try std.testing.expectEqual(@as(u64, 0), effect.stake_pointer_changes[0].next.?.cert_ix);
}

test "rules: explicit stake deposit cert must match current pp" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-explicit-deposit");
    defer ledger.deinit();

    const cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xbb} ** 28,
    };
    const tx = TxBody{
        .tx_id = [_]u8{0x55} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{ .reg_deposit = .{ .cred = cred, .deposit = ProtocolParams.mainnet_defaults.key_deposit + 1 } },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    try std.testing.expectError(
        error.InvalidCertificate,
        evaluateCertificateEffect(allocator, &tx, &ledger, ProtocolParams.mainnet_defaults),
    );
}

test "rules: post-Alonzo MIR cert stages rewards and pot transfer" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-mir-post-alonzo");
    defer ledger.deinit();

    const cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xca} ** 28,
    };
    ledger.importReservesBalance(200);
    ledger.importTreasuryBalance(50);

    const tx = TxBody{
        .tx_id = [_]u8{0x70} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{ .mir = .{
                .pot = .reserves,
                .target = .{ .stake_addresses = &[_]cert_mod.MIRReward{
                    .{ .credential = cred, .delta = 40 },
                } },
            } },
            .{ .mir = .{
                .pot = .reserves,
                .target = .{ .send_to_other_pot = 25 },
            } },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    var effect = try evaluateCertificateEffectWithContext(
        allocator,
        &tx,
        &ledger,
        ProtocolParams.mainnet_defaults,
        .{
            .current_slot = 10,
            .protocol_version_major = 5,
            .epoch_length = 100,
            .stability_window = 10,
        },
    );
    defer effect.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), effect.mir_reserves_changes.len);
    try std.testing.expectEqual(@as(?Coin, 40), effect.mir_reserves_changes[0].next);
    try std.testing.expectEqual(@as(?DeltaCoinStateChange, .{ .previous = 0, .next = -25 }), effect.mir_delta_reserves_change);
    try std.testing.expectEqual(@as(?DeltaCoinStateChange, .{ .previous = 0, .next = 25 }), effect.mir_delta_treasury_change);
}

test "rules: pre-Alonzo MIR rejects negative updates" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-mir-pre-alonzo");
    defer ledger.deinit();

    const tx = TxBody{
        .tx_id = [_]u8{0x71} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{ .mir = .{
                .pot = .reserves,
                .target = .{ .stake_addresses = &[_]cert_mod.MIRReward{
                    .{
                        .credential = .{
                            .cred_type = .key_hash,
                            .hash = [_]u8{0xcb} ** 28,
                        },
                        .delta = -1,
                    },
                } },
            } },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    try std.testing.expectError(
        error.InvalidCertificate,
        evaluateCertificateEffectWithContext(
            allocator,
            &tx,
            &ledger,
            ProtocolParams.mainnet_defaults,
            .{
                .current_slot = 10,
                .protocol_version_major = 4,
                .epoch_length = 100,
                .stability_window = 10,
            },
        ),
    );
}

test "rules: genesis delegation stages future adoption at stability window" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-genesis-delegation");
    defer ledger.deinit();

    const genesis = [_]u8{0xa0} ** 28;
    try ledger.importGenesisDelegation(genesis, .{
        .delegate = [_]u8{0xb0} ** 28,
        .vrf = [_]u8{0xc0} ** 32,
    });
    try ledger.importGenesisDelegation([_]u8{0xa1} ** 28, .{
        .delegate = [_]u8{0xb1} ** 28,
        .vrf = [_]u8{0xc1} ** 32,
    });

    const tx = TxBody{
        .tx_id = [_]u8{0x72} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{ .genesis_delegation = .{
                .genesis = genesis,
                .delegate = [_]u8{0xd0} ** 28,
                .vrf = [_]u8{0xe0} ** 32,
            } },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    var effect = try evaluateCertificateEffectWithContext(
        allocator,
        &tx,
        &ledger,
        ProtocolParams.mainnet_defaults,
        .{
            .current_slot = 10,
            .protocol_version_major = 5,
            .epoch_length = 100,
            .stability_window = 7,
        },
    );
    defer effect.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), effect.future_genesis_delegation_changes.len);
    try std.testing.expectEqual(@as(u64, 17), effect.future_genesis_delegation_changes[0].future.slot);
    try std.testing.expectEqual(genesis, effect.future_genesis_delegation_changes[0].future.genesis);
    try std.testing.expectEqual(GenesisDelegation{
        .delegate = [_]u8{0xd0} ** 28,
        .vrf = [_]u8{0xe0} ** 32,
    }, effect.future_genesis_delegation_changes[0].next.?);
}

test "rules: stake delegation requires registered stake key" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-stake-delegation-missing-key");
    defer ledger.deinit();

    const cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xcc} ** 28,
    };
    const pool = [_]u8{0xdd} ** 28;
    const reward_account = types.RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0xdc} ** 28,
        },
    };
    const tx = TxBody{
        .tx_id = [_]u8{0x56} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{
                .pool_registration = .{
                    .operator = pool,
                    .vrf_keyhash = [_]u8{0xee} ** 32,
                    .pledge = 0,
                    .cost = 0,
                    .margin = .{ .numerator = 0, .denominator = 1 },
                    .reward_account = reward_account,
                    .owners = &.{},
                },
            },
            .{ .stake_delegation = .{ .cred = cred, .pool = pool } },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    try std.testing.expectError(
        error.InvalidCertificate,
        evaluateCertificateEffect(allocator, &tx, &ledger, ProtocolParams.mainnet_defaults),
    );
}

test "rules: stake delegation accepts pending pool registration" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-stake-delegation-pool");
    defer ledger.deinit();

    const cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xcf} ** 28,
    };
    try ledger.importStakeDeposit(cred, ProtocolParams.mainnet_defaults.key_deposit);

    const pool = [_]u8{0xde} ** 28;
    const reward_account = types.RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0xdf} ** 28,
        },
    };
    const tx = TxBody{
        .tx_id = [_]u8{0x57} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{
                .pool_registration = .{
                    .operator = pool,
                    .vrf_keyhash = [_]u8{0xef} ** 32,
                    .pledge = 0,
                    .cost = 0,
                    .margin = .{ .numerator = 0, .denominator = 1 },
                    .reward_account = reward_account,
                    .owners = &.{},
                },
            },
            .{ .stake_delegation = .{ .cred = cred, .pool = pool } },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    var effect = try evaluateCertificateEffect(allocator, &tx, &ledger, ProtocolParams.mainnet_defaults);
    defer effect.deinit(allocator);

    try std.testing.expectEqual(ProtocolParams.mainnet_defaults.pool_deposit, effect.deposits);
    try std.testing.expectEqual(@as(Coin, 0), effect.refunds);
    try std.testing.expectEqual(@as(usize, 0), effect.stake_deposit_changes.len);
    try std.testing.expectEqual(@as(usize, 1), effect.pool_deposit_changes.len);
    try std.testing.expectEqual(@as(usize, 1), effect.pool_config_changes.len);
    try std.testing.expectEqual(@as(usize, 0), effect.future_pool_param_changes.len);
}

test "rules: pool re-registration stages future params and clears retirement" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-pool-reregistration");
    defer ledger.deinit();

    const pool = [_]u8{0xe1} ** 28;
    const previous_reward_account = types.RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0xe2} ** 28,
        },
    };
    const next_reward_account = types.RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0xe3} ** 28,
        },
    };
    try ledger.importPoolDeposit(pool, ProtocolParams.mainnet_defaults.pool_deposit);
    try ledger.importPoolConfig(pool, .{
        .pledge = 10,
        .cost = 20,
        .margin = .{ .numerator = 0, .denominator = 1 },
    });
    try ledger.importPoolRewardAccount(pool, previous_reward_account);
    try ledger.importPoolRetirement(pool, 11);

    const tx = TxBody{
        .tx_id = [_]u8{0x60} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{
                .pool_registration = .{
                    .operator = pool,
                    .vrf_keyhash = [_]u8{0xe4} ** 32,
                    .pledge = 0,
                    .cost = 0,
                    .margin = .{ .numerator = 1, .denominator = 10 },
                    .reward_account = next_reward_account,
                    .owners = &.{},
                },
            },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    var effect = try evaluateCertificateEffect(allocator, &tx, &ledger, ProtocolParams.mainnet_defaults);
    defer effect.deinit(allocator);

    try std.testing.expectEqual(@as(Coin, 0), effect.deposits);
    try std.testing.expectEqual(@as(usize, 1), effect.pool_deposit_changes.len);
    try std.testing.expectEqual(@as(?Coin, ProtocolParams.mainnet_defaults.pool_deposit), effect.pool_deposit_changes[0].next);
    try std.testing.expectEqual(@as(usize, 0), effect.pool_config_changes.len);
    try std.testing.expectEqual(@as(usize, 1), effect.future_pool_param_changes.len);
    try std.testing.expectEqual(FuturePoolParams{
        .config = .{
            .vrf_keyhash = [_]u8{0xe4} ** 32,
            .pledge = 0,
            .cost = 0,
            .margin = .{ .numerator = 1, .denominator = 10 },
        },
        .reward_account = next_reward_account,
    }, effect.future_pool_param_changes[0].next.?);
    try std.testing.expectEqual(@as(usize, 0), effect.pool_reward_account_changes.len);
    try std.testing.expectEqual(@as(usize, 1), effect.pool_retirement_changes.len);
    try std.testing.expect(effect.pool_retirement_changes[0].next == null);
}

test "rules: pool retirement schedules retirement epoch" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-pool-retirement");
    defer ledger.deinit();

    const pool = [_]u8{0xe5} ** 28;
    try ledger.importPoolDeposit(pool, ProtocolParams.mainnet_defaults.pool_deposit);

    const tx = TxBody{
        .tx_id = [_]u8{0x61} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{ .pool_retirement = .{ .pool = pool, .epoch = 17 } },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    var effect = try evaluateCertificateEffect(allocator, &tx, &ledger, ProtocolParams.mainnet_defaults);
    defer effect.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), effect.pool_retirement_changes.len);
    try std.testing.expectEqual(@as(?types.EpochNo, 17), effect.pool_retirement_changes[0].next);
}

test "rules: vote delegation accepts pending DRep registration" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-vote-delegation-drep");
    defer ledger.deinit();

    const stake_cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xa1} ** 28,
    };
    try ledger.importStakeDeposit(stake_cred, ProtocolParams.mainnet_defaults.key_deposit);

    const drep_cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xa2} ** 28,
    };
    const tx = TxBody{
        .tx_id = [_]u8{0x58} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{ .drep_registration = .{ .cred = drep_cred, .deposit = 500_000_000 } },
            .{
                .vote_delegation = .{
                    .cred = stake_cred,
                    .drep = .{ .key_hash = drep_cred.hash },
                },
            },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    var effect = try evaluateCertificateEffect(allocator, &tx, &ledger, ProtocolParams.mainnet_defaults);
    defer effect.deinit(allocator);

    try std.testing.expectEqual(@as(Coin, 500_000_000), effect.deposits);
    try std.testing.expectEqual(@as(usize, 1), effect.drep_deposit_changes.len);
}

test "rules: vote delegation rejects unknown DRep" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-vote-delegation-missing-drep");
    defer ledger.deinit();

    const stake_cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0xb1} ** 28,
    };
    try ledger.importStakeDeposit(stake_cred, ProtocolParams.mainnet_defaults.key_deposit);

    const tx = TxBody{
        .tx_id = [_]u8{0x59} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{
                .vote_delegation = .{
                    .cred = stake_cred,
                    .drep = .{ .key_hash = [_]u8{0xb2} ** 28 },
                },
            },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    try std.testing.expectError(
        error.InvalidCertificate,
        evaluateCertificateEffect(allocator, &tx, &ledger, ProtocolParams.mainnet_defaults),
    );
}

test "rules: tracked reward withdrawal must drain full balance" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-withdrawal");
    defer ledger.deinit();

    const account = types.RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0x77} ** 28,
        },
    };
    ledger.setRewardBalancesTracked(true);
    try ledger.setRewardBalance(account, 5_000_000);

    const tx = TxBody{
        .tx_id = [_]u8{0x66} ** 32,
        .inputs = &[_]TxIn{.{ .tx_id = [_]u8{0x99} ** 32, .tx_ix = 0 }},
        .outputs = &[_]transaction.TxOut{
            .{
                .address_raw = &([_]u8{0x61} ++ [_]u8{0xaa} ** 28),
                .value = 4_800_000,
                .datum_hash = null,
                .raw_cbor = "reward-output",
            },
        },
        .certificates = &[_]transaction.Certificate{},
        .fee = 200_000,
        .withdrawals = &[_]Withdrawal{
            .{
                .account = account,
                .amount = 5_000_000,
            },
        },
        .withdrawal_total = 5_000_000,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{0} ** 1024,
    };

    const effect = try evaluateWithdrawalEffect(allocator, &tx, &ledger);
    defer {
        var mutable = effect;
        mutable.deinit(allocator);
    }
    try std.testing.expectEqual(@as(Coin, 5_000_000), effect.withdrawn);
    try std.testing.expectEqual(@as(usize, 1), effect.reward_balance_changes.len);
    try std.testing.expect(effect.reward_balance_changes[0].next == null);
}

test "rules: tracked reward withdrawal rejects partial amount" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-withdrawal-partial");
    defer ledger.deinit();

    const account = types.RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0x88} ** 28,
        },
    };
    ledger.setRewardBalancesTracked(true);
    try ledger.setRewardBalance(account, 5_000_000);

    const tx = TxBody{
        .tx_id = [_]u8{0x67} ** 32,
        .inputs = &[_]TxIn{.{ .tx_id = [_]u8{0x98} ** 32, .tx_ix = 0 }},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{},
        .fee = 0,
        .withdrawals = &[_]Withdrawal{
            .{
                .account = account,
                .amount = 4_000_000,
            },
        },
        .withdrawal_total = 4_000_000,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{0} ** 1024,
    };

    try std.testing.expectError(
        error.InvalidWithdrawal,
        evaluateWithdrawalEffect(allocator, &tx, &ledger),
    );
}

test "rules: untracked reward withdrawal is rejected" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-withdrawal-untracked");
    defer ledger.deinit();

    const account = types.RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0x89} ** 28,
        },
    };

    const tx = TxBody{
        .tx_id = [_]u8{0x68} ** 32,
        .inputs = &[_]TxIn{.{ .tx_id = [_]u8{0x97} ** 32, .tx_ix = 0 }},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{},
        .fee = 0,
        .withdrawals = &[_]Withdrawal{
            .{
                .account = account,
                .amount = 4_000_000,
            },
        },
        .withdrawal_total = 4_000_000,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{0} ** 1024,
    };

    try std.testing.expectError(
        error.InvalidWithdrawal,
        evaluateWithdrawalEffect(allocator, &tx, &ledger),
    );
}

test "rules: stake deregistration rejects non-empty tracked reward account" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-stake-dereg-reward");
    defer ledger.deinit();

    const cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0x8a} ** 28,
    };
    const account = types.RewardAccount{
        .network = .testnet,
        .credential = cred,
    };
    ledger.setRewardAccountNetwork(.testnet);
    ledger.setRewardBalancesTracked(true);
    try ledger.importStakeDeposit(cred, ProtocolParams.mainnet_defaults.key_deposit);
    try ledger.setRewardBalance(account, 3_000_000);

    const tx = TxBody{
        .tx_id = [_]u8{0x74} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{ .stake_deregistration = cred },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    try std.testing.expectError(
        error.InvalidCertificate,
        evaluateCertificateEffect(allocator, &tx, &ledger, ProtocolParams.mainnet_defaults),
    );
}

test "rules: stake deregistration accepts same-tx reward drain" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-stake-dereg-withdraw");
    defer ledger.deinit();

    const cred = types.Credential{
        .cred_type = .key_hash,
        .hash = [_]u8{0x8b} ** 28,
    };
    const account = types.RewardAccount{
        .network = .testnet,
        .credential = cred,
    };
    ledger.setRewardAccountNetwork(.testnet);
    ledger.setRewardBalancesTracked(true);
    try ledger.importStakeDeposit(cred, ProtocolParams.mainnet_defaults.key_deposit);
    try ledger.setRewardBalance(account, 3_000_000);

    const tx = TxBody{
        .tx_id = [_]u8{0x75} ** 32,
        .inputs = &[_]TxIn{},
        .outputs = &[_]transaction.TxOut{},
        .certificates = &[_]transaction.Certificate{
            .{ .stake_deregistration = cred },
        },
        .fee = 0,
        .withdrawals = &[_]transaction.Withdrawal{
            .{
                .account = account,
                .amount = 3_000_000,
            },
        },
        .withdrawal_total = 3_000_000,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{},
    };

    var effect = try evaluateCertificateEffect(allocator, &tx, &ledger, ProtocolParams.mainnet_defaults);
    defer effect.deinit(allocator);

    try std.testing.expectEqual(@as(Coin, ProtocolParams.mainnet_defaults.key_deposit), effect.refunds);
    try std.testing.expectEqual(@as(usize, 1), effect.stake_deposit_changes.len);
    try std.testing.expect(effect.stake_deposit_changes[0].next == null);
}

test "rules: validateTx rejects invalid certificate instead of falling back" {
    const allocator = std.testing.allocator;
    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-test-rules-invalid-cert-validate");
    defer ledger.deinit();

    const input = TxIn{ .tx_id = [_]u8{0x31} ** 32, .tx_ix = 0 };
    const produced = try allocator.alloc(UtxoEntry, 1);
    produced[0] = .{
        .tx_in = input,
        .value = 10_000_000,
        .raw_cbor = try allocator.dupe(u8, "seed"),
    };
    try ledger.applyDiff(.{
        .slot = 0,
        .block_hash = [_]u8{0} ** 32,
        .consumed = try allocator.alloc(UtxoEntry, 0),
        .produced = produced,
    });

    const tx = TxBody{
        .tx_id = [_]u8{0x32} ** 32,
        .inputs = &[_]TxIn{input},
        .outputs = &[_]transaction.TxOut{
            .{
                .address_raw = &([_]u8{0x61} ++ [_]u8{0xbb} ** 28),
                .value = 9_000_000,
                .datum_hash = null,
                .raw_cbor = "output",
            },
        },
        .certificates = &[_]transaction.Certificate{
            .{ .stake_delegation = .{
                .cred = .{ .cred_type = .key_hash, .hash = [_]u8{0x41} ** 28 },
                .pool = [_]u8{0x42} ** 28,
            } },
        },
        .fee = 1_000_000,
        .withdrawals = &[_]transaction.Withdrawal{},
        .withdrawal_total = 0,
        .ttl = null,
        .validity_start = null,
        .update = null,
        .raw_cbor = &[_]u8{0} ** 200,
    };

    try std.testing.expectError(
        error.InvalidCertificate,
        validateTx(&tx, &ledger, ProtocolParams.mainnet_defaults, 100, true),
    );
}
