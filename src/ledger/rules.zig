const std = @import("std");
const types = @import("../types.zig");
const transaction = @import("transaction.zig");
const cert_mod = @import("certificates.zig");
const LedgerDB = @import("../storage/ledger.zig").LedgerDB;
const UtxoEntry = @import("../storage/ledger.zig").UtxoEntry;
const RewardBalanceChange = @import("../storage/ledger.zig").RewardBalanceChange;
const StakeDepositChange = @import("../storage/ledger.zig").StakeDepositChange;
const PoolDepositChange = @import("../storage/ledger.zig").PoolDepositChange;
const PoolConfig = @import("../storage/ledger.zig").PoolConfig;
const PoolConfigChange = @import("../storage/ledger.zig").PoolConfigChange;
const FuturePoolParams = @import("../storage/ledger.zig").FuturePoolParams;
const FuturePoolParamsChange = @import("../storage/ledger.zig").FuturePoolParamsChange;
const PoolRewardAccountChange = @import("../storage/ledger.zig").PoolRewardAccountChange;
const PoolOwnerMembershipChange = @import("../storage/ledger.zig").PoolOwnerMembershipChange;
const PoolRetirementChange = @import("../storage/ledger.zig").PoolRetirementChange;
const DRepDepositChange = @import("../storage/ledger.zig").DRepDepositChange;
const StakePoolDelegationChange = @import("../storage/ledger.zig").StakePoolDelegationChange;
const DRepDelegationChange = @import("../storage/ledger.zig").DRepDelegationChange;

pub const TxIn = types.TxIn;
pub const Coin = types.Coin;
pub const TxBody = transaction.TxBody;
pub const Withdrawal = transaction.Withdrawal;
pub const DRep = cert_mod.DRep;

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

    /// Mainnet defaults (approximate, for testing)
    pub const mainnet_defaults = ProtocolParams{
        .min_fee_a = 44,
        .min_fee_b = 155381,
        .min_utxo_value = 1_000_000,
        .max_tx_size = 16384,
        .key_deposit = 2_000_000,
        .pool_deposit = 500_000_000,
        .max_block_body_size = 90112,
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
    };
};

pub const CertificateEffect = struct {
    deposits: Coin,
    refunds: Coin,
    stake_deposit_changes: []const StakeDepositChange,
    pool_deposit_changes: []const PoolDepositChange,
    pool_config_changes: []const PoolConfigChange,
    future_pool_param_changes: []const FuturePoolParamsChange,
    pool_reward_account_changes: []const PoolRewardAccountChange,
    pool_owner_changes: []const PoolOwnerMembershipChange,
    future_pool_owner_changes: []const PoolOwnerMembershipChange,
    pool_retirement_changes: []const PoolRetirementChange,
    drep_deposit_changes: []const DRepDepositChange,
    stake_pool_delegation_changes: []const StakePoolDelegationChange,
    drep_delegation_changes: []const DRepDelegationChange,

    pub fn empty() CertificateEffect {
        return .{
            .deposits = 0,
            .refunds = 0,
            .stake_deposit_changes = &.{},
            .pool_deposit_changes = &.{},
            .pool_config_changes = &.{},
            .future_pool_param_changes = &.{},
            .pool_reward_account_changes = &.{},
            .pool_owner_changes = &.{},
            .future_pool_owner_changes = &.{},
            .pool_retirement_changes = &.{},
            .drep_deposit_changes = &.{},
            .stake_pool_delegation_changes = &.{},
            .drep_delegation_changes = &.{},
        };
    }

    pub fn deinit(self: *CertificateEffect, allocator: std.mem.Allocator) void {
        if (self.stake_deposit_changes.len > 0) allocator.free(self.stake_deposit_changes);
        if (self.pool_deposit_changes.len > 0) allocator.free(self.pool_deposit_changes);
        if (self.pool_config_changes.len > 0) allocator.free(self.pool_config_changes);
        if (self.future_pool_param_changes.len > 0) allocator.free(self.future_pool_param_changes);
        if (self.pool_reward_account_changes.len > 0) allocator.free(self.pool_reward_account_changes);
        if (self.pool_owner_changes.len > 0) allocator.free(self.pool_owner_changes);
        if (self.future_pool_owner_changes.len > 0) allocator.free(self.future_pool_owner_changes);
        if (self.pool_retirement_changes.len > 0) allocator.free(self.pool_retirement_changes);
        if (self.drep_deposit_changes.len > 0) allocator.free(self.drep_deposit_changes);
        if (self.stake_pool_delegation_changes.len > 0) allocator.free(self.stake_pool_delegation_changes);
        if (self.drep_delegation_changes.len > 0) allocator.free(self.drep_delegation_changes);
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

    var cert_effect = evaluateCertificateEffect(std.heap.page_allocator, tx, utxo, pp) catch {
        return error.InvalidCertificate;
    };
    defer cert_effect.deinit(std.heap.page_allocator);
    consumed_value += withdrawal_effect.withdrawn + cert_effect.refunds;

    // 3. Fee must meet minimum
    const min_fee = calculateMinFee(pp, tx.raw_cbor.len);
    if (tx.fee < min_fee) return error.InsufficientFee;

    // 4. Validity interval
    if (tx.ttl) |ttl| {
        if (current_slot >= ttl) return error.Expired;
    }
    if (tx.validity_start) |vs| {
        if (current_slot < vs) return error.NotYetValid;
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
        return .{
            .withdrawn = tx.withdrawal_total,
            .reward_balance_changes = &.{},
        };
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
            return error.InvalidWithdrawal;
        };
        if (withdrawal.amount != current_balance) return error.InvalidWithdrawal;

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
    if (tx.certificates.len == 0) return CertificateEffect.empty();

    var stake_changes: std.ArrayList(StakeDepositChange) = .empty;
    defer stake_changes.deinit(allocator);
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
    var drep_changes: std.ArrayList(DRepDepositChange) = .empty;
    defer drep_changes.deinit(allocator);
    var stake_pool_delegation_changes: std.ArrayList(StakePoolDelegationChange) = .empty;
    defer stake_pool_delegation_changes.deinit(allocator);
    var drep_delegation_changes: std.ArrayList(DRepDelegationChange) = .empty;
    defer drep_delegation_changes.deinit(allocator);

    var deposits: Coin = 0;
    var refunds: Coin = 0;

    for (tx.certificates) |cert| {
        switch (cert) {
            .stake_registration => |cred| {
                if (findPendingStakeNext(stake_changes.items, cred) != null or ledger.lookupStakeDeposit(cred) != null) {
                    return error.InvalidCertificate;
                }
                deposits += pp.key_deposit;
                try stake_changes.append(allocator, .{
                    .credential = cred,
                    .previous = ledger.lookupStakeDeposit(cred),
                    .next = pp.key_deposit,
                });
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
            .reg_deposit => |reg| {
                if (findPendingStakeNext(stake_changes.items, reg.cred) != null or ledger.lookupStakeDeposit(reg.cred) != null) {
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
        .stake_deposit_changes = try stake_changes.toOwnedSlice(allocator),
        .pool_deposit_changes = try pool_changes.toOwnedSlice(allocator),
        .pool_config_changes = try pool_config_changes.toOwnedSlice(allocator),
        .future_pool_param_changes = try future_pool_param_changes.toOwnedSlice(allocator),
        .pool_reward_account_changes = try pool_reward_account_changes.toOwnedSlice(allocator),
        .pool_owner_changes = try pool_owner_changes.toOwnedSlice(allocator),
        .future_pool_owner_changes = try future_pool_owner_changes.toOwnedSlice(allocator),
        .pool_retirement_changes = try pool_retirement_changes.toOwnedSlice(allocator),
        .drep_deposit_changes = try drep_changes.toOwnedSlice(allocator),
        .stake_pool_delegation_changes = try stake_pool_delegation_changes.toOwnedSlice(allocator),
        .drep_delegation_changes = try drep_delegation_changes.toOwnedSlice(allocator),
    };
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

fn findPendingStakeNext(changes: []const StakeDepositChange, credential: types.Credential) ??Coin {
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

test "rules: untracked reward withdrawal still accepts amount on faith" {
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

    const effect = try evaluateWithdrawalEffect(allocator, &tx, &ledger);
    defer {
        var mutable = effect;
        mutable.deinit(allocator);
    }
    try std.testing.expectEqual(@as(Coin, 4_000_000), effect.withdrawn);
    try std.testing.expectEqual(@as(usize, 0), effect.reward_balance_changes.len);
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
