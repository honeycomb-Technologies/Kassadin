const std = @import("std");
const types = @import("../types.zig");
const Hash28 = types.Hash28;

/// Execution budget for a Plutus script.
pub const ExUnits = struct {
    mem: u64, // memory units
    steps: u64, // CPU steps

    pub fn add(a: ExUnits, b: ExUnits) ExUnits {
        return .{ .mem = a.mem + b.mem, .steps = a.steps + b.steps };
    }

    pub fn fits(self: ExUnits, limit: ExUnits) bool {
        return self.mem <= limit.mem and self.steps <= limit.steps;
    }
};

/// Script purpose — what the script is validating.
pub const ScriptPurpose = union(enum) {
    spending: types.TxIn, // Validating a UTxO spend
    minting: Hash28, // Validating a minting/burning policy
    certifying: u32, // Validating a certificate (index)
    rewarding: types.Credential, // Validating a reward withdrawal
    voting: void, // Conway: validating a vote
    proposing: u32, // Conway: validating a proposal
};

/// Redeemer — data provided by the transaction submitter for script validation.
pub const Redeemer = struct {
    tag: RedeemerTag,
    index: u32,
    data_cbor: []const u8, // PlutusData as raw CBOR
    ex_units: ExUnits,
};

pub const RedeemerTag = enum(u8) {
    spend = 0,
    mint = 1,
    cert = 2,
    reward = 3,
    voting = 4, // Conway
    proposing = 5, // Conway
};

/// Result of evaluating a Plutus script.
pub const EvalResult = union(enum) {
    success: ExUnits, // consumed budget
    failure: []const u8, // error message
    not_available: void, // plutuz not linked
};

/// Evaluate a Plutus script.
///
/// This is a stub that will be connected to plutuz when Zig 0.15.2+ is available
/// or when we build plutuz as a C library.
///
/// For Phase 3 testing, scripts are assumed to pass (optimistic evaluation).
/// Real evaluation requires:
/// 1. Flat-decode the script bytes to get a UPLC program
/// 2. Construct ScriptContext as PlutusData from transaction info
/// 3. Apply arguments: [datum, redeemer, context] for V1/V2, [context] for V3
/// 4. Evaluate via CEK machine with cost model
/// 5. Check consumed budget fits ExUnits
pub fn evaluateScript(
    language: ScriptLanguage,
    script_bytes: []const u8,
    datum: ?[]const u8,
    redeemer: []const u8,
    context: []const u8,
    budget: ExUnits,
    cost_model: []const i64,
) EvalResult {
    // Suppress unused parameter warnings
    _ = language;
    _ = script_bytes;
    _ = datum;
    _ = redeemer;
    _ = context;
    _ = budget;
    _ = cost_model;
    // TODO: Connect to plutuz
    // For now, return not_available to clearly indicate scripts aren't evaluated
    return .not_available;
}

pub const ScriptLanguage = enum(u8) {
    plutus_v1 = 1,
    plutus_v2 = 2,
    plutus_v3 = 3,
};

/// Cost model parameters per language version.
pub const CostModel = struct {
    language: ScriptLanguage,
    params: []const i64,
};

/// Default mainnet cost model sizes.
pub const cost_model_sizes = struct {
    pub const plutus_v1: usize = 166;
    pub const plutus_v2: usize = 175;
    pub const plutus_v3: usize = 233;
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "plutus: ExUnits arithmetic" {
    const a = ExUnits{ .mem = 100, .steps = 200 };
    const b = ExUnits{ .mem = 50, .steps = 150 };
    const sum = ExUnits.add(a, b);
    try std.testing.expectEqual(@as(u64, 150), sum.mem);
    try std.testing.expectEqual(@as(u64, 350), sum.steps);

    const limit = ExUnits{ .mem = 200, .steps = 400 };
    try std.testing.expect(sum.fits(limit));
    try std.testing.expect(!sum.fits(.{ .mem = 100, .steps = 400 }));
}

test "plutus: evaluate returns not_available" {
    const result = evaluateScript(
        .plutus_v1,
        "fake_script",
        null,
        "redeemer",
        "context",
        .{ .mem = 1000000, .steps = 1000000 },
        &[_]i64{},
    );
    try std.testing.expect(result == .not_available);
}

test "plutus: redeemer tags" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(RedeemerTag.spend));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(RedeemerTag.mint));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(RedeemerTag.voting));
}

test "plutus: cost model sizes" {
    try std.testing.expectEqual(@as(usize, 166), cost_model_sizes.plutus_v1);
    try std.testing.expectEqual(@as(usize, 175), cost_model_sizes.plutus_v2);
    try std.testing.expectEqual(@as(usize, 233), cost_model_sizes.plutus_v3);
}
