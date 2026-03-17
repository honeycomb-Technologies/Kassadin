const std = @import("std");
const types = @import("../types.zig");
const transaction = @import("transaction.zig");
const LedgerDB = @import("../storage/ledger.zig").LedgerDB;
const UtxoEntry = @import("../storage/ledger.zig").UtxoEntry;
const StakeDepositChange = @import("../storage/ledger.zig").StakeDepositChange;
const PoolDepositChange = @import("../storage/ledger.zig").PoolDepositChange;
const DRepDepositChange = @import("../storage/ledger.zig").DRepDepositChange;

pub const TxIn = types.TxIn;
pub const Coin = types.Coin;
pub const TxBody = transaction.TxBody;

/// Validation errors that can occur when applying a transaction.
pub const ValidationError = error{
    // UTxO rule violations
    InputNotInUtxo,
    InsufficientFee,
    ValueNotPreserved,
    NoInputs,
    OutputTooSmall,
    InvalidCertificate,

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
    drep_deposit_changes: []const DRepDepositChange,

    pub fn empty() CertificateEffect {
        return .{
            .deposits = 0,
            .refunds = 0,
            .stake_deposit_changes = &.{},
            .pool_deposit_changes = &.{},
            .drep_deposit_changes = &.{},
        };
    }

    pub fn deinit(self: *CertificateEffect, allocator: std.mem.Allocator) void {
        if (self.stake_deposit_changes.len > 0) allocator.free(self.stake_deposit_changes);
        if (self.pool_deposit_changes.len > 0) allocator.free(self.pool_deposit_changes);
        if (self.drep_deposit_changes.len > 0) allocator.free(self.drep_deposit_changes);
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

    var cert_effect = evaluateCertificateEffect(std.heap.page_allocator, tx, utxo, pp) catch {
        return error.InvalidCertificate;
    };
    defer cert_effect.deinit(std.heap.page_allocator);
    consumed_value += tx.withdrawal_total + cert_effect.refunds;

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
    var drep_changes: std.ArrayList(DRepDepositChange) = .empty;
    defer drep_changes.deinit(allocator);

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
            },
            .pool_registration => |pool| {
                if (findPendingPool(pool_changes.items, pool.operator) != null or ledger.lookupPoolDeposit(pool.operator) != null) {
                    continue;
                }
                deposits += pp.pool_deposit;
                try pool_changes.append(allocator, .{
                    .pool = pool.operator,
                    .previous = ledger.lookupPoolDeposit(pool.operator),
                    .next = pp.pool_deposit,
                });
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
            },
            .stake_reg_delegation => |reg| {
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
            .vote_reg_delegation => |reg| {
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
            .stake_vote_reg_delegation => |reg| {
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
            else => {},
        }
    }

    return .{
        .deposits = deposits,
        .refunds = refunds,
        .stake_deposit_changes = try stake_changes.toOwnedSlice(allocator),
        .pool_deposit_changes = try pool_changes.toOwnedSlice(allocator),
        .drep_deposit_changes = try drep_changes.toOwnedSlice(allocator),
    };
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
