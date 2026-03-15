//! ScriptContext construction for Plutus script evaluation.
//!
//! Plutus scripts receive a ScriptContext as PlutusData. This module builds
//! that context from parsed transaction data.
//!
//! For Plutus V1/V2: scripts receive (datum, redeemer, scriptContext) as 3 arguments.
//! For Plutus V3 (CIP-69): scripts receive a single ScriptContext that embeds
//!   the redeemer and script purpose info.
//!
//! Encoding (V3 / Conway):
//!   ScriptContext = Constr(0, [TxInfo, Redeemer, ScriptInfo])
//!   TxInfo = Constr(0, [inputs, ref_inputs, outputs, fee, mint, certs,
//!                       withdrawals, validity_range, signatories, redeemers,
//!                       datums, tx_id, votes, proposals, treasury, donation])
//!
//! This is a Phase 3 simplified implementation that encodes the core fields
//! (inputs, outputs, fee, signatories, tx_id) and stubs the rest as empty
//! lists/maps so that scripts receive structurally valid data.

const std = @import("std");
const plutuz = @import("plutuz");
const PlutusData = plutuz.data.PlutusData;
const PlutusDataPair = plutuz.data.plutus_data.PlutusDataPair;
const types = @import("../types.zig");
const transaction = @import("transaction.zig");
const plutus = @import("plutus.zig");

const TxBody = transaction.TxBody;
const TxIn = types.TxIn;
const TxId = types.TxId;
const Hash28 = types.Hash28;
const Hash32 = types.Hash32;
const Coin = types.Coin;
const ScriptPurpose = plutus.ScriptPurpose;

// ──────────────────────────────────── TxInfo ────────────────────────────────────

/// Simplified transaction info for script context construction.
/// Holds the data needed to build the TxInfo portion of ScriptContext.
pub const TxInfo = struct {
    inputs: []const TxIn,
    reference_inputs: []const TxIn,
    outputs: []const transaction.TxOut,
    fee: Coin,
    signatories: []const Hash28,
    tx_id: TxId,
    validity_start: ?u64,
    ttl: ?u64,

    /// Build TxInfo from a parsed transaction body.
    pub fn fromTxBody(body: *const TxBody, signatories: []const Hash28) TxInfo {
        return .{
            .inputs = body.inputs,
            .reference_inputs = &.{},
            .outputs = body.outputs,
            .fee = body.fee,
            .signatories = signatories,
            .tx_id = body.tx_id,
            .validity_start = body.validity_start,
            .ttl = body.ttl,
        };
    }
};

// ──────────────────────── PlutusData Encoding Helpers ───────────────────────────

/// Encode a TxId as PlutusData: Constr(0, [ByteString(32)])
fn encodeTxId(allocator: std.mem.Allocator, tx_id: TxId) !*const PlutusData {
    const id_bytes = try PlutusData.byteString(allocator, &tx_id);
    const fields = try allocator.alloc(*const PlutusData, 1);
    fields[0] = id_bytes;
    return PlutusData.constrOf(allocator, 0, fields);
}

/// Encode a TxOutRef as PlutusData: Constr(0, [TxId, Integer(index)])
fn encodeTxOutRef(allocator: std.mem.Allocator, input: TxIn) !*const PlutusData {
    const tx_id_data = try encodeTxId(allocator, input.tx_id);
    const ix_data = try PlutusData.int(allocator, @intCast(input.tx_ix));
    const fields = try allocator.alloc(*const PlutusData, 2);
    fields[0] = tx_id_data;
    fields[1] = ix_data;
    return PlutusData.constrOf(allocator, 0, fields);
}

/// Encode a TxInInfo as PlutusData: Constr(0, [TxOutRef, TxOut])
/// For Phase 3 simplified: we pair the TxOutRef with a minimal TxOut stub.
fn encodeTxInInfo(allocator: std.mem.Allocator, input: TxIn) !*const PlutusData {
    const out_ref = try encodeTxOutRef(allocator, input);
    // Stub TxOut: Constr(0, [address=ByteString(""), value=Constr(Map{}), datum=Constr(1,[]), script=Constr(1,[])])
    const stub_out = try encodeStubTxOut(allocator);
    const fields = try allocator.alloc(*const PlutusData, 2);
    fields[0] = out_ref;
    fields[1] = stub_out;
    return PlutusData.constrOf(allocator, 0, fields);
}

/// Encode a stub TxOut (for inputs where we don't have resolved UTxO data yet).
/// TxOut = Constr(0, [Address, Value, OutputDatum, Maybe(ScriptHash)])
fn encodeStubTxOut(allocator: std.mem.Allocator) !*const PlutusData {
    // Address: Constr(0, [Credential, Maybe StakeCredential])
    // Use a dummy address with empty byte string credential
    const empty_cred = try PlutusData.byteString(allocator, &.{});
    const cred_fields = try allocator.alloc(*const PlutusData, 1);
    cred_fields[0] = empty_cred;
    const cred = try PlutusData.constrOf(allocator, 0, cred_fields); // PubKeyCredential
    const nothing_stake = try encodeNothing(allocator); // Nothing for stake
    const addr_fields = try allocator.alloc(*const PlutusData, 2);
    addr_fields[0] = cred;
    addr_fields[1] = nothing_stake;
    const address = try PlutusData.constrOf(allocator, 0, addr_fields);

    // Value: empty map (no lovelace, no tokens)
    const value = try PlutusData.mapOf(allocator, &.{});

    // OutputDatum: NoOutputDatum = Constr(0, [])
    const no_datum = try PlutusData.constrOf(allocator, 0, &.{});

    // Maybe ScriptHash: Nothing = Constr(1, [])
    const no_script = try encodeNothing(allocator);

    const fields = try allocator.alloc(*const PlutusData, 4);
    fields[0] = address;
    fields[1] = value;
    fields[2] = no_datum;
    fields[3] = no_script;
    return PlutusData.constrOf(allocator, 0, fields);
}

/// Encode an actual TxOut as PlutusData.
/// TxOut = Constr(0, [Address, Value, OutputDatum, Maybe(ScriptHash)])
fn encodeTxOut(allocator: std.mem.Allocator, output: transaction.TxOut) !*const PlutusData {
    // Address: encode raw bytes as a credential-based address
    const address = try encodeAddress(allocator, output.address_raw);

    // Value: Map { ADA policy => Map { "" => lovelace } }
    const value = try encodeValue(allocator, output.value);

    // OutputDatum: NoOutputDatum = Constr(0, []) or DatumHash = Constr(1, [hash])
    const datum = if (output.datum_hash) |dh| blk: {
        const dh_bytes = try PlutusData.byteString(allocator, &dh);
        const datum_fields = try allocator.alloc(*const PlutusData, 1);
        datum_fields[0] = dh_bytes;
        break :blk try PlutusData.constrOf(allocator, 1, datum_fields);
    } else try PlutusData.constrOf(allocator, 0, &.{});

    // Maybe ScriptHash: Nothing
    const no_script = try encodeNothing(allocator);

    const fields = try allocator.alloc(*const PlutusData, 4);
    fields[0] = address;
    fields[1] = value;
    fields[2] = datum;
    fields[3] = no_script;
    return PlutusData.constrOf(allocator, 0, fields);
}

/// Encode an address from raw bytes into PlutusData.
/// Address = Constr(0, [Credential, Maybe StakeCredential])
fn encodeAddress(allocator: std.mem.Allocator, address_raw: []const u8) !*const PlutusData {
    if (address_raw.len >= 29) {
        const header = address_raw[0];
        const addr_type_nibble = header >> 4;
        const payment_hash = address_raw[1..29];

        // Payment credential: Constr(0, [hash]) for key, Constr(1, [hash]) for script
        const is_script = (addr_type_nibble & 1) != 0;
        const cred_tag: u64 = if (is_script) 1 else 0;
        const hash_data = try PlutusData.byteString(allocator, payment_hash);
        const cred_fields = try allocator.alloc(*const PlutusData, 1);
        cred_fields[0] = hash_data;
        const credential = try PlutusData.constrOf(allocator, cred_tag, cred_fields);

        // Stake credential: Nothing for enterprise, Just for base addresses
        const stake_ref = if (address_raw.len >= 57) blk: {
            const stake_hash = address_raw[29..57];
            const stake_is_script = (addr_type_nibble & 2) != 0;
            const stake_cred_tag: u64 = if (stake_is_script) 1 else 0;
            const s_hash = try PlutusData.byteString(allocator, stake_hash);
            const s_cred_fields = try allocator.alloc(*const PlutusData, 1);
            s_cred_fields[0] = s_hash;
            const s_cred = try PlutusData.constrOf(allocator, stake_cred_tag, s_cred_fields);
            // Just(StakingHash(credential)) = Constr(0, [Constr(0, [cred])])
            const staking_fields = try allocator.alloc(*const PlutusData, 1);
            staking_fields[0] = s_cred;
            const staking_hash = try PlutusData.constrOf(allocator, 0, staking_fields);
            const just_fields = try allocator.alloc(*const PlutusData, 1);
            just_fields[0] = staking_hash;
            break :blk try PlutusData.constrOf(allocator, 0, just_fields);
        } else try encodeNothing(allocator);

        const addr_fields = try allocator.alloc(*const PlutusData, 2);
        addr_fields[0] = credential;
        addr_fields[1] = stake_ref;
        return PlutusData.constrOf(allocator, 0, addr_fields);
    }

    // Fallback: use raw bytes as credential
    const raw_cred = try PlutusData.byteString(allocator, address_raw);
    const cred_fields = try allocator.alloc(*const PlutusData, 1);
    cred_fields[0] = raw_cred;
    const cred = try PlutusData.constrOf(allocator, 0, cred_fields);
    const nothing_stake = try encodeNothing(allocator);
    const addr_fields = try allocator.alloc(*const PlutusData, 2);
    addr_fields[0] = cred;
    addr_fields[1] = nothing_stake;
    return PlutusData.constrOf(allocator, 0, addr_fields);
}

/// Encode a lovelace value as PlutusData.
/// Value = Map { CurrencySymbol => Map { TokenName => Integer } }
/// ADA is represented with empty byte string policy id and empty token name.
fn encodeValue(allocator: std.mem.Allocator, lovelace: Coin) !*const PlutusData {
    const amount = try PlutusData.int(allocator, @intCast(lovelace));
    const empty_token = try PlutusData.byteString(allocator, &.{});
    const inner_pairs = try allocator.alloc(PlutusDataPair, 1);
    inner_pairs[0] = .{ .key = empty_token, .value = amount };
    const inner_map = try PlutusData.mapOf(allocator, inner_pairs);

    const ada_policy = try PlutusData.byteString(allocator, &.{});
    const outer_pairs = try allocator.alloc(PlutusDataPair, 1);
    outer_pairs[0] = .{ .key = ada_policy, .value = inner_map };
    return PlutusData.mapOf(allocator, outer_pairs);
}

/// Encode Maybe as Nothing: Constr(1, [])
fn encodeNothing(allocator: std.mem.Allocator) !*const PlutusData {
    return PlutusData.constrOf(allocator, 1, &.{});
}

/// Encode Maybe as Just(x): Constr(0, [x])
fn encodeJust(allocator: std.mem.Allocator, value: *const PlutusData) !*const PlutusData {
    const fields = try allocator.alloc(*const PlutusData, 1);
    fields[0] = value;
    return PlutusData.constrOf(allocator, 0, fields);
}

/// Encode a POSIXTimeRange as PlutusData.
/// Interval = Constr(0, [LowerBound, UpperBound])
/// LowerBound = Constr(0, [Bound, Closure])
/// UpperBound = Constr(0, [Bound, Closure])
/// Bound: NegInf = Constr(0,[]), Finite(t) = Constr(1,[Integer]), PosInf = Constr(2,[])
/// Closure: True = Constr(1,[]), False = Constr(0,[])
fn encodeValidityRange(allocator: std.mem.Allocator, validity_start: ?u64, ttl: ?u64) !*const PlutusData {
    // Lower bound
    const lower_bound_data = if (validity_start) |start| blk: {
        const time_ms = try PlutusData.int(allocator, @intCast(start));
        const finite_fields = try allocator.alloc(*const PlutusData, 1);
        finite_fields[0] = time_ms;
        break :blk try PlutusData.constrOf(allocator, 1, finite_fields); // Finite
    } else try PlutusData.constrOf(allocator, 0, &.{}); // NegInf

    const lower_closure = try PlutusData.constrOf(allocator, 1, &.{}); // True (inclusive)
    const lower_fields = try allocator.alloc(*const PlutusData, 2);
    lower_fields[0] = lower_bound_data;
    lower_fields[1] = lower_closure;
    const lower_bound = try PlutusData.constrOf(allocator, 0, lower_fields);

    // Upper bound
    const upper_bound_data = if (ttl) |t| blk: {
        const time_ms = try PlutusData.int(allocator, @intCast(t));
        const finite_fields = try allocator.alloc(*const PlutusData, 1);
        finite_fields[0] = time_ms;
        break :blk try PlutusData.constrOf(allocator, 1, finite_fields); // Finite
    } else try PlutusData.constrOf(allocator, 2, &.{}); // PosInf

    const upper_closure = try PlutusData.constrOf(allocator, 1, &.{}); // True (inclusive)
    const upper_fields = try allocator.alloc(*const PlutusData, 2);
    upper_fields[0] = upper_bound_data;
    upper_fields[1] = upper_closure;
    const upper_bound = try PlutusData.constrOf(allocator, 0, upper_fields);

    // Interval
    const interval_fields = try allocator.alloc(*const PlutusData, 2);
    interval_fields[0] = lower_bound;
    interval_fields[1] = upper_bound;
    return PlutusData.constrOf(allocator, 0, interval_fields);
}

/// Encode a ScriptPurpose as ScriptInfo (V3).
/// Spending = Constr(0, [TxOutRef, Maybe Datum])
/// Minting  = Constr(1, [CurrencySymbol])
/// Certifying = Constr(4, [Integer, TxCert])
/// Rewarding  = Constr(2, [Credential])
fn encodeScriptInfo(allocator: std.mem.Allocator, purpose: ScriptPurpose) !*const PlutusData {
    switch (purpose) {
        .spending => |input| {
            const out_ref = try encodeTxOutRef(allocator, input);
            const no_datum = try encodeNothing(allocator);
            const fields = try allocator.alloc(*const PlutusData, 2);
            fields[0] = out_ref;
            fields[1] = no_datum;
            return PlutusData.constrOf(allocator, 0, fields);
        },
        .minting => |policy_id| {
            const cs = try PlutusData.byteString(allocator, &policy_id);
            const fields = try allocator.alloc(*const PlutusData, 1);
            fields[0] = cs;
            return PlutusData.constrOf(allocator, 1, fields);
        },
        .rewarding => |credential| {
            const cred_tag: u64 = switch (credential.cred_type) {
                .key_hash => 0,
                .script_hash => 1,
            };
            const hash_data = try PlutusData.byteString(allocator, &credential.hash);
            const cred_fields = try allocator.alloc(*const PlutusData, 1);
            cred_fields[0] = hash_data;
            const cred = try PlutusData.constrOf(allocator, cred_tag, cred_fields);
            const fields = try allocator.alloc(*const PlutusData, 1);
            fields[0] = cred;
            return PlutusData.constrOf(allocator, 2, fields);
        },
        .certifying => |cert_idx| {
            const idx = try PlutusData.int(allocator, @intCast(cert_idx));
            const stub_cert = try PlutusData.constrOf(allocator, 0, &.{}); // stub cert
            const fields = try allocator.alloc(*const PlutusData, 2);
            fields[0] = idx;
            fields[1] = stub_cert;
            return PlutusData.constrOf(allocator, 4, fields);
        },
        .voting => {
            // Voting = Constr(3, [Voter])
            const stub_voter = try PlutusData.constrOf(allocator, 0, &.{});
            const fields = try allocator.alloc(*const PlutusData, 1);
            fields[0] = stub_voter;
            return PlutusData.constrOf(allocator, 3, fields);
        },
        .proposing => |prop_idx| {
            // Proposing = Constr(5, [Integer, ProposalProcedure])
            const idx = try PlutusData.int(allocator, @intCast(prop_idx));
            const stub_proposal = try PlutusData.constrOf(allocator, 0, &.{});
            const fields = try allocator.alloc(*const PlutusData, 2);
            fields[0] = idx;
            fields[1] = stub_proposal;
            return PlutusData.constrOf(allocator, 5, fields);
        },
    }
}

// ──────────────────────── TxInfo PlutusData Encoding ───────────────────────────

/// Encode TxInfo as PlutusData (V3 / Conway format).
///
/// TxInfo = Constr(0, [
///   inputs,         -- [TxInInfo]
///   ref_inputs,     -- [TxInInfo]
///   outputs,        -- [TxOut]
///   fee,            -- Integer (lovelace)
///   mint,           -- Value (Map)
///   certs,          -- [TxCert]
///   withdrawals,    -- Map(Credential, Integer)
///   validity_range, -- POSIXTimeRange
///   signatories,    -- [PubKeyHash]
///   redeemers,      -- Map(ScriptPurpose, Redeemer)
///   datums,         -- Map(DatumHash, Datum)
///   tx_id,          -- TxId
///   votes,          -- Map(Voter, Map(GovActionId, Vote))
///   proposals,      -- [ProposalProcedure]
///   treasury,       -- Maybe Lovelace
///   donation,       -- Maybe Lovelace
/// ])
pub fn encodeTxInfo(allocator: std.mem.Allocator, info: TxInfo) !*const PlutusData {
    // 1. inputs: List of TxInInfo
    const input_items = try allocator.alloc(*const PlutusData, info.inputs.len);
    for (info.inputs, 0..) |input, i| {
        input_items[i] = try encodeTxInInfo(allocator, input);
    }
    const inputs_list = try PlutusData.listOf(allocator, input_items);

    // 2. reference_inputs: List of TxInInfo
    const ref_input_items = try allocator.alloc(*const PlutusData, info.reference_inputs.len);
    for (info.reference_inputs, 0..) |input, i| {
        ref_input_items[i] = try encodeTxInInfo(allocator, input);
    }
    const ref_inputs_list = try PlutusData.listOf(allocator, ref_input_items);

    // 3. outputs: List of TxOut
    const output_items = try allocator.alloc(*const PlutusData, info.outputs.len);
    for (info.outputs, 0..) |output, i| {
        output_items[i] = try encodeTxOut(allocator, output);
    }
    const outputs_list = try PlutusData.listOf(allocator, output_items);

    // 4. fee: Integer (lovelace)
    const fee_data = try PlutusData.int(allocator, @intCast(info.fee));

    // 5. mint: empty map (no minting in simplified version)
    const mint_data = try PlutusData.mapOf(allocator, &.{});

    // 6. certs: empty list
    const certs_data = try PlutusData.listOf(allocator, &.{});

    // 7. withdrawals: empty map
    const withdrawals_data = try PlutusData.mapOf(allocator, &.{});

    // 8. validity_range: POSIXTimeRange
    const validity_range = try encodeValidityRange(allocator, info.validity_start, info.ttl);

    // 9. signatories: List of PubKeyHash (ByteString)
    const sig_items = try allocator.alloc(*const PlutusData, info.signatories.len);
    for (info.signatories, 0..) |sig, i| {
        sig_items[i] = try PlutusData.byteString(allocator, &sig);
    }
    const signatories_list = try PlutusData.listOf(allocator, sig_items);

    // 10. redeemers: empty map
    const redeemers_data = try PlutusData.mapOf(allocator, &.{});

    // 11. datums: empty map
    const datums_data = try PlutusData.mapOf(allocator, &.{});

    // 12. tx_id: TxId
    const tx_id_data = try encodeTxId(allocator, info.tx_id);

    // 13. votes: empty map
    const votes_data = try PlutusData.mapOf(allocator, &.{});

    // 14. proposals: empty list
    const proposals_data = try PlutusData.listOf(allocator, &.{});

    // 15. treasury: Nothing
    const treasury_data = try encodeNothing(allocator);

    // 16. donation: Nothing
    const donation_data = try encodeNothing(allocator);

    // Build the TxInfo Constr(0, [...])
    const fields = try allocator.alloc(*const PlutusData, 16);
    fields[0] = inputs_list;
    fields[1] = ref_inputs_list;
    fields[2] = outputs_list;
    fields[3] = fee_data;
    fields[4] = mint_data;
    fields[5] = certs_data;
    fields[6] = withdrawals_data;
    fields[7] = validity_range;
    fields[8] = signatories_list;
    fields[9] = redeemers_data;
    fields[10] = datums_data;
    fields[11] = tx_id_data;
    fields[12] = votes_data;
    fields[13] = proposals_data;
    fields[14] = treasury_data;
    fields[15] = donation_data;

    return PlutusData.constrOf(allocator, 0, fields);
}

// ──────────────────────── ScriptContext Construction ────────────────────────────

/// Build a Plutus V3 ScriptContext as PlutusData.
///
/// ScriptContext = Constr(0, [TxInfo, Redeemer, ScriptInfo])
///
/// The redeemer is passed as raw PlutusData. If the caller doesn't have
/// one, they can pass a unit-like Constr(0, []).
pub fn buildScriptContext(
    allocator: std.mem.Allocator,
    info: TxInfo,
    redeemer: *const PlutusData,
    purpose: ScriptPurpose,
) !*const PlutusData {
    const tx_info_data = try encodeTxInfo(allocator, info);
    const script_info = try encodeScriptInfo(allocator, purpose);

    const fields = try allocator.alloc(*const PlutusData, 3);
    fields[0] = tx_info_data;
    fields[1] = redeemer;
    fields[2] = script_info;

    return PlutusData.constrOf(allocator, 0, fields);
}

/// Build a Plutus V1/V2 ScriptContext as PlutusData.
///
/// V1/V2 ScriptContext = Constr(0, [TxInfo, ScriptPurpose])
///
/// Note: V1/V2 scripts receive (datum, redeemer, context) as 3 separate arguments,
/// so the redeemer is NOT embedded in the context.
pub fn buildScriptContextV2(
    allocator: std.mem.Allocator,
    info: TxInfo,
    purpose: ScriptPurpose,
) !*const PlutusData {
    const tx_info_data = try encodeTxInfo(allocator, info);
    const purpose_data = try encodeScriptPurposeV2(allocator, purpose);

    const fields = try allocator.alloc(*const PlutusData, 2);
    fields[0] = tx_info_data;
    fields[1] = purpose_data;

    return PlutusData.constrOf(allocator, 0, fields);
}

/// Encode ScriptPurpose for V1/V2.
/// Spending = Constr(1, [TxOutRef])
/// Minting  = Constr(0, [CurrencySymbol])
/// Certifying = Constr(3, [DCert])
/// Rewarding  = Constr(2, [StakingCredential])
fn encodeScriptPurposeV2(allocator: std.mem.Allocator, purpose: ScriptPurpose) !*const PlutusData {
    switch (purpose) {
        .spending => |input| {
            const out_ref = try encodeTxOutRef(allocator, input);
            const fields = try allocator.alloc(*const PlutusData, 1);
            fields[0] = out_ref;
            return PlutusData.constrOf(allocator, 1, fields);
        },
        .minting => |policy_id| {
            const cs = try PlutusData.byteString(allocator, &policy_id);
            const fields = try allocator.alloc(*const PlutusData, 1);
            fields[0] = cs;
            return PlutusData.constrOf(allocator, 0, fields);
        },
        .rewarding => |credential| {
            const cred_tag: u64 = switch (credential.cred_type) {
                .key_hash => 0,
                .script_hash => 1,
            };
            const hash_data = try PlutusData.byteString(allocator, &credential.hash);
            const cred_fields = try allocator.alloc(*const PlutusData, 1);
            cred_fields[0] = hash_data;
            const cred = try PlutusData.constrOf(allocator, cred_tag, cred_fields);
            // StakingHash = Constr(0, [Credential])
            const staking_fields = try allocator.alloc(*const PlutusData, 1);
            staking_fields[0] = cred;
            const staking = try PlutusData.constrOf(allocator, 0, staking_fields);
            const fields = try allocator.alloc(*const PlutusData, 1);
            fields[0] = staking;
            return PlutusData.constrOf(allocator, 2, fields);
        },
        .certifying => |cert_idx| {
            const stub_cert = try PlutusData.int(allocator, @intCast(cert_idx));
            const fields = try allocator.alloc(*const PlutusData, 1);
            fields[0] = stub_cert;
            return PlutusData.constrOf(allocator, 3, fields);
        },
        .voting, .proposing => {
            // V2 doesn't have voting/proposing, encode as empty constr
            return PlutusData.constrOf(allocator, 0, &.{});
        },
    }
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "script_context: encodeTxId produces Constr(0, [ByteString])" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tx_id = [_]u8{0xaa} ** 32;
    const result = try encodeTxId(a, tx_id);

    try std.testing.expect(result.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), result.constr.tag);
    try std.testing.expectEqual(@as(usize, 1), result.constr.fields.len);
    try std.testing.expect(result.constr.fields[0].* == .byte_string);
    try std.testing.expectEqualSlices(u8, &tx_id, result.constr.fields[0].byte_string);
}

test "script_context: encodeTxOutRef produces Constr(0, [TxId, Integer])" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input = TxIn{ .tx_id = [_]u8{0xbb} ** 32, .tx_ix = 3 };
    const result = try encodeTxOutRef(a, input);

    try std.testing.expect(result.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), result.constr.tag);
    try std.testing.expectEqual(@as(usize, 2), result.constr.fields.len);

    // First field: TxId = Constr(0, [ByteString])
    const tx_id_field = result.constr.fields[0];
    try std.testing.expect(tx_id_field.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), tx_id_field.constr.tag);

    // Second field: Integer(3)
    const ix_field = result.constr.fields[1];
    try std.testing.expect(ix_field.* == .integer);
}

test "script_context: encodeValue produces ADA value map" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try encodeValue(a, 2_000_000);

    // Value is Map { "" => Map { "" => 2000000 } }
    try std.testing.expect(result.* == .map);
    try std.testing.expectEqual(@as(usize, 1), result.map.len);

    // Outer key: empty byte string (ADA policy)
    const outer_key = result.map[0].key;
    try std.testing.expect(outer_key.* == .byte_string);
    try std.testing.expectEqual(@as(usize, 0), outer_key.byte_string.len);

    // Outer value: inner map
    const inner_map = result.map[0].value;
    try std.testing.expect(inner_map.* == .map);
    try std.testing.expectEqual(@as(usize, 1), inner_map.map.len);

    // Inner value: integer 2000000
    const amount = inner_map.map[0].value;
    try std.testing.expect(amount.* == .integer);
}

test "script_context: encodeValidityRange with bounds" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // With both bounds
    const range = try encodeValidityRange(a, 1000, 2000);
    try std.testing.expect(range.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), range.constr.tag);
    try std.testing.expectEqual(@as(usize, 2), range.constr.fields.len);

    // Lower bound: Constr(0, [Finite(1000), True])
    const lower = range.constr.fields[0];
    try std.testing.expect(lower.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), lower.constr.tag);
    const lower_bound = lower.constr.fields[0];
    try std.testing.expectEqual(@as(u64, 1), lower_bound.constr.tag); // Finite

    // Upper bound: Constr(0, [Finite(2000), True])
    const upper = range.constr.fields[1];
    try std.testing.expect(upper.* == .constr);
    const upper_bound = upper.constr.fields[0];
    try std.testing.expectEqual(@as(u64, 1), upper_bound.constr.tag); // Finite
}

test "script_context: encodeValidityRange unbounded" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No bounds
    const range = try encodeValidityRange(a, null, null);
    try std.testing.expect(range.* == .constr);

    // Lower bound: NegInf = Constr(0, [Constr(0,[]), ...])
    const lower = range.constr.fields[0];
    const lower_bound = lower.constr.fields[0];
    try std.testing.expectEqual(@as(u64, 0), lower_bound.constr.tag); // NegInf

    // Upper bound: PosInf = Constr(2, [])
    const upper = range.constr.fields[1];
    const upper_bound = upper.constr.fields[0];
    try std.testing.expectEqual(@as(u64, 2), upper_bound.constr.tag); // PosInf
}

test "script_context: build V3 ScriptContext from simple tx" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Set up a simple transaction
    const input = TxIn{ .tx_id = [_]u8{0xaa} ** 32, .tx_ix = 0 };
    const addr_bytes = [_]u8{0x61} ++ [_]u8{0xbb} ** 28;
    const output = transaction.TxOut{
        .address_raw = &addr_bytes,
        .value = 2_000_000,
        .datum_hash = null,
        .raw_cbor = &.{},
    };
    const signer = [_]u8{0xcc} ** 28;
    const tx_id = [_]u8{0xdd} ** 32;

    const inputs = [_]TxIn{input};
    const outputs = [_]transaction.TxOut{output};
    const signers = [_]Hash28{signer};

    const info = TxInfo{
        .inputs = &inputs,
        .reference_inputs = &.{},
        .outputs = &outputs,
        .fee = 200_000,
        .signatories = &signers,
        .tx_id = tx_id,
        .validity_start = null,
        .ttl = null,
    };

    const redeemer = try PlutusData.constrOf(a, 0, &.{});
    const purpose = ScriptPurpose{ .spending = input };

    const ctx = try buildScriptContext(a, info, redeemer, purpose);

    // ScriptContext = Constr(0, [TxInfo, Redeemer, ScriptInfo])
    try std.testing.expect(ctx.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), ctx.constr.tag);
    try std.testing.expectEqual(@as(usize, 3), ctx.constr.fields.len);

    // Field 0: TxInfo = Constr(0, [16 fields])
    const tx_info = ctx.constr.fields[0];
    try std.testing.expect(tx_info.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), tx_info.constr.tag);
    try std.testing.expectEqual(@as(usize, 16), tx_info.constr.fields.len);

    // TxInfo field 0: inputs (list with 1 element)
    const inputs_field = tx_info.constr.fields[0];
    try std.testing.expect(inputs_field.* == .list);
    try std.testing.expectEqual(@as(usize, 1), inputs_field.list.len);

    // TxInfo field 2: outputs (list with 1 element)
    const outputs_field = tx_info.constr.fields[2];
    try std.testing.expect(outputs_field.* == .list);
    try std.testing.expectEqual(@as(usize, 1), outputs_field.list.len);

    // TxInfo field 3: fee (Integer 200000)
    const fee_field = tx_info.constr.fields[3];
    try std.testing.expect(fee_field.* == .integer);

    // TxInfo field 8: signatories (list with 1 element)
    const sigs_field = tx_info.constr.fields[8];
    try std.testing.expect(sigs_field.* == .list);
    try std.testing.expectEqual(@as(usize, 1), sigs_field.list.len);

    // TxInfo field 11: tx_id = Constr(0, [ByteString])
    const txid_field = tx_info.constr.fields[11];
    try std.testing.expect(txid_field.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), txid_field.constr.tag);

    // Field 1: Redeemer = Constr(0, [])
    const redeemer_field = ctx.constr.fields[1];
    try std.testing.expect(redeemer_field.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), redeemer_field.constr.tag);

    // Field 2: ScriptInfo (Spending) = Constr(0, [TxOutRef, Maybe Datum])
    const script_info = ctx.constr.fields[2];
    try std.testing.expect(script_info.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), script_info.constr.tag);
    try std.testing.expectEqual(@as(usize, 2), script_info.constr.fields.len);
}

test "script_context: build V2 ScriptContext" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tx_id = [_]u8{0xee} ** 32;
    const info = TxInfo{
        .inputs = &.{},
        .reference_inputs = &.{},
        .outputs = &.{},
        .fee = 100_000,
        .signatories = &.{},
        .tx_id = tx_id,
        .validity_start = null,
        .ttl = null,
    };

    const policy_id = [_]u8{0xff} ** 28;
    const purpose = ScriptPurpose{ .minting = policy_id };

    const ctx = try buildScriptContextV2(a, info, purpose);

    // V2 ScriptContext = Constr(0, [TxInfo, ScriptPurpose])
    try std.testing.expect(ctx.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), ctx.constr.tag);
    try std.testing.expectEqual(@as(usize, 2), ctx.constr.fields.len);

    // ScriptPurpose for minting: Constr(0, [CurrencySymbol])
    const purpose_field = ctx.constr.fields[1];
    try std.testing.expect(purpose_field.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), purpose_field.constr.tag);
}

test "script_context: ScriptInfo encoding for all purpose variants" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Spending
    {
        const input = TxIn{ .tx_id = [_]u8{0x01} ** 32, .tx_ix = 5 };
        const result = try encodeScriptInfo(a, .{ .spending = input });
        try std.testing.expectEqual(@as(u64, 0), result.constr.tag);
        try std.testing.expectEqual(@as(usize, 2), result.constr.fields.len);
    }

    // Minting
    {
        const policy = [_]u8{0x02} ** 28;
        const result = try encodeScriptInfo(a, .{ .minting = policy });
        try std.testing.expectEqual(@as(u64, 1), result.constr.tag);
        try std.testing.expectEqual(@as(usize, 1), result.constr.fields.len);
    }

    // Rewarding
    {
        const cred = types.Credential{ .cred_type = .key_hash, .hash = [_]u8{0x03} ** 28 };
        const result = try encodeScriptInfo(a, .{ .rewarding = cred });
        try std.testing.expectEqual(@as(u64, 2), result.constr.tag);
        try std.testing.expectEqual(@as(usize, 1), result.constr.fields.len);
    }

    // Certifying
    {
        const result = try encodeScriptInfo(a, .{ .certifying = 7 });
        try std.testing.expectEqual(@as(u64, 4), result.constr.tag);
        try std.testing.expectEqual(@as(usize, 2), result.constr.fields.len);
    }

    // Voting
    {
        const result = try encodeScriptInfo(a, .{ .voting = {} });
        try std.testing.expectEqual(@as(u64, 3), result.constr.tag);
    }

    // Proposing
    {
        const result = try encodeScriptInfo(a, .{ .proposing = 2 });
        try std.testing.expectEqual(@as(u64, 5), result.constr.tag);
    }
}

test "script_context: TxInfo has correct field count and types" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tx_id = [_]u8{0x11} ** 32;
    const signer1 = [_]u8{0x22} ** 28;
    const signer2 = [_]u8{0x33} ** 28;
    const signers = [_]Hash28{ signer1, signer2 };

    const info = TxInfo{
        .inputs = &.{},
        .reference_inputs = &.{},
        .outputs = &.{},
        .fee = 500_000,
        .signatories = &signers,
        .tx_id = tx_id,
        .validity_start = 100,
        .ttl = 200,
    };

    const tx_info = try encodeTxInfo(a, info);

    try std.testing.expect(tx_info.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), tx_info.constr.tag);
    try std.testing.expectEqual(@as(usize, 16), tx_info.constr.fields.len);

    // Field types verification
    try std.testing.expect(tx_info.constr.fields[0].* == .list); // inputs
    try std.testing.expect(tx_info.constr.fields[1].* == .list); // ref_inputs
    try std.testing.expect(tx_info.constr.fields[2].* == .list); // outputs
    try std.testing.expect(tx_info.constr.fields[3].* == .integer); // fee
    try std.testing.expect(tx_info.constr.fields[4].* == .map); // mint
    try std.testing.expect(tx_info.constr.fields[5].* == .list); // certs
    try std.testing.expect(tx_info.constr.fields[6].* == .map); // withdrawals
    try std.testing.expect(tx_info.constr.fields[7].* == .constr); // validity_range
    try std.testing.expect(tx_info.constr.fields[8].* == .list); // signatories
    try std.testing.expect(tx_info.constr.fields[9].* == .map); // redeemers
    try std.testing.expect(tx_info.constr.fields[10].* == .map); // datums
    try std.testing.expect(tx_info.constr.fields[11].* == .constr); // tx_id
    try std.testing.expect(tx_info.constr.fields[12].* == .map); // votes
    try std.testing.expect(tx_info.constr.fields[13].* == .list); // proposals
    try std.testing.expect(tx_info.constr.fields[14].* == .constr); // treasury (Nothing)
    try std.testing.expect(tx_info.constr.fields[15].* == .constr); // donation (Nothing)

    // Signatories should have 2 entries
    try std.testing.expectEqual(@as(usize, 2), tx_info.constr.fields[8].list.len);
}

test "script_context: TxInfo.fromTxBody helper" {
    const tx_id = [_]u8{0x44} ** 32;
    const input = TxIn{ .tx_id = [_]u8{0x55} ** 32, .tx_ix = 1 };
    const inputs = [_]TxIn{input};
    const outputs = [_]transaction.TxOut{};
    const signer = [_]u8{0x66} ** 28;
    const signers = [_]Hash28{signer};

    const body = TxBody{
        .tx_id = tx_id,
        .inputs = &inputs,
        .outputs = &outputs,
        .fee = 180_000,
        .ttl = 50_000_000,
        .validity_start = 49_000_000,
        .raw_cbor = &.{},
    };

    const info = TxInfo.fromTxBody(&body, &signers);
    try std.testing.expectEqual(@as(usize, 1), info.inputs.len);
    try std.testing.expectEqual(@as(Coin, 180_000), info.fee);
    try std.testing.expectEqual(@as(usize, 1), info.signatories.len);
    try std.testing.expectEqual(@as(?u64, 49_000_000), info.validity_start);
    try std.testing.expectEqual(@as(?u64, 50_000_000), info.ttl);
    try std.testing.expectEqualSlices(u8, &tx_id, &info.tx_id);
}

test "script_context: output encoding with datum hash" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const addr_bytes = [_]u8{0x61} ++ [_]u8{0xab} ** 28;
    const datum_hash = [_]u8{0xde} ** 32;
    const output = transaction.TxOut{
        .address_raw = &addr_bytes,
        .value = 5_000_000,
        .datum_hash = datum_hash,
        .raw_cbor = &.{},
    };

    const result = try encodeTxOut(a, output);

    // TxOut = Constr(0, [Address, Value, OutputDatum, Maybe ScriptHash])
    try std.testing.expect(result.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), result.constr.tag);
    try std.testing.expectEqual(@as(usize, 4), result.constr.fields.len);

    // OutputDatum with hash: Constr(1, [hash])
    const datum_field = result.constr.fields[2];
    try std.testing.expect(datum_field.* == .constr);
    try std.testing.expectEqual(@as(u64, 1), datum_field.constr.tag);
    try std.testing.expectEqual(@as(usize, 1), datum_field.constr.fields.len);
}

test "script_context: encodeNothing and encodeJust" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nothing = try encodeNothing(a);
    try std.testing.expect(nothing.* == .constr);
    try std.testing.expectEqual(@as(u64, 1), nothing.constr.tag);
    try std.testing.expectEqual(@as(usize, 0), nothing.constr.fields.len);

    const val = try PlutusData.int(a, 42);
    const just = try encodeJust(a, val);
    try std.testing.expect(just.* == .constr);
    try std.testing.expectEqual(@as(u64, 0), just.constr.tag);
    try std.testing.expectEqual(@as(usize, 1), just.constr.fields.len);
    try std.testing.expect(just.constr.fields[0].* == .integer);
}

test "script_context: PlutusData can be wrapped as plutuz Constant for CEK" {
    // Verify that PlutusData we build can be wrapped in a Constant::data,
    // which is the form needed to pass to the CEK machine.
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tx_id = [_]u8{0xaa} ** 32;
    const info = TxInfo{
        .inputs = &.{},
        .reference_inputs = &.{},
        .outputs = &.{},
        .fee = 200_000,
        .signatories = &.{},
        .tx_id = tx_id,
        .validity_start = null,
        .ttl = null,
    };

    const redeemer = try PlutusData.constrOf(a, 0, &.{});
    const input = TxIn{ .tx_id = [_]u8{0xbb} ** 32, .tx_ix = 0 };
    const purpose = ScriptPurpose{ .spending = input };

    const ctx = try buildScriptContext(a, info, redeemer, purpose);

    // Wrap as a plutuz Constant::data — this is how it gets passed to scripts
    const Constant = plutuz.ast.Constant;
    const data_const = try Constant.dat(a, ctx);
    try std.testing.expect(data_const.* == .data);

    // And wrap as a Term::constant — this is the CEK machine input form
    const DeBruijnTerm = plutuz.DeBruijnTerm;
    const term = try DeBruijnTerm.con(a, data_const);
    try std.testing.expect(term.* == .constant);
    try std.testing.expect(term.constant.* == .data);
}
