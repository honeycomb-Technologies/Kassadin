//! Builtin function implementations for the CEK machine.

const std = @import("std");
const constant_mod = @import("../../ast/constant.zig");
const Constant = constant_mod.Constant;
const Integer = constant_mod.Integer;
const DefaultFunction = @import("../../ast/builtin.zig").DefaultFunction;
const Value = @import("../value.zig").Value;
const machine_mod = @import("../machine.zig");
const ex_mem = @import("../ex_mem.zig");

const arithmetic = @import("arithmetic.zig");
const bytestring = @import("bytestring.zig");
const string = @import("string.zig");
const data_mod = @import("data.zig");
const list = @import("list.zig");
const crypto = @import("crypto.zig");
const bitwise = @import("bitwise.zig");
const bls_mod = @import("bls.zig");
const value_mod = @import("value.zig");

pub const BuiltinError = @import("helpers.zig").BuiltinError;

/// Evaluate a builtin function with given arguments.
/// Computes argument sizes, spends the builtin cost, then executes the operation.
pub fn evalBuiltin(
    comptime Binder: type,
    machine: *machine_mod.Machine(Binder),
    func: DefaultFunction,
    args: []const *const Value(Binder),
) BuiltinError!*const Value(Binder) {
    const allocator = machine.allocator;
    const semantics = machine.semantics;

    // Compute argument sizes and spend builtin cost
    const sizes = computeArgSizes(Binder, func, args);
    machine.spendBuiltinCost(func, &sizes) catch return error.OutOfBudget;

    // Execute the builtin
    return switch (func) {
        .add_integer => arithmetic.addInteger(Binder, allocator, args),
        .subtract_integer => arithmetic.subtractInteger(Binder, allocator, args),
        .multiply_integer => arithmetic.multiplyInteger(Binder, allocator, args),
        .divide_integer => arithmetic.divideInteger(Binder, allocator, args),
        .quotient_integer => arithmetic.quotientInteger(Binder, allocator, args),
        .remainder_integer => arithmetic.remainderInteger(Binder, allocator, args),
        .mod_integer => arithmetic.modInteger(Binder, allocator, args),
        .equals_integer => arithmetic.equalsInteger(Binder, allocator, args),
        .less_than_integer => arithmetic.lessThanInteger(Binder, allocator, args),
        .less_than_equals_integer => arithmetic.lessThanEqualsInteger(Binder, allocator, args),
        .exp_mod_integer => arithmetic.expModInteger(Binder, allocator, args),
        .append_byte_string => bytestring.appendByteString(Binder, allocator, args),
        .cons_byte_string => bytestring.consByteString(Binder, allocator, semantics, args),
        .slice_byte_string => bytestring.sliceByteString(Binder, allocator, args),
        .length_of_byte_string => bytestring.lengthOfByteString(Binder, allocator, args),
        .equals_byte_string => bytestring.equalsByteString(Binder, allocator, args),
        .less_than_equals_byte_string => bytestring.lessThanEqualsByteString(Binder, allocator, args),
        .less_than_byte_string => bytestring.lessThanByteString(Binder, allocator, args),
        .append_string => string.appendString(Binder, allocator, args),
        .equals_string => string.equalsString(Binder, allocator, args),
        .encode_utf8 => string.encodeUtf8(Binder, allocator, args),
        .decode_utf8 => string.decodeUtf8(Binder, allocator, args),
        .if_then_else => list.ifThenElse(Binder, args),
        .choose_unit => list.chooseUnit(Binder, args),
        .trace => list.trace(Binder, args),
        .fst_pair => list.fstPair(Binder, allocator, args),
        .snd_pair => list.sndPair(Binder, allocator, args),
        .choose_list => list.chooseList(Binder, args),
        .mk_cons => list.mkCons(Binder, allocator, args),
        .head_list => list.headList(Binder, allocator, args),
        .tail_list => list.tailList(Binder, allocator, args),
        .null_list => list.nullList(Binder, allocator, args),
        .drop_list => list.dropList(Binder, allocator, args),
        .length_of_array => list.lengthOfArray(Binder, allocator, args),
        .list_to_array => list.listToArray(Binder, allocator, args),
        .index_array => list.indexArray(Binder, allocator, args),
        .choose_data => data_mod.chooseData(Binder, args),
        .constr_data => data_mod.constrData(Binder, allocator, args),
        .map_data => data_mod.mapData(Binder, allocator, args),
        .list_data => data_mod.listData(Binder, allocator, args),
        .i_data => data_mod.iData(Binder, allocator, args),
        .b_data => data_mod.bData(Binder, allocator, args),
        .un_constr_data => data_mod.unConstrData(Binder, allocator, args),
        .un_map_data => data_mod.unMapData(Binder, allocator, args),
        .un_list_data => data_mod.unListData(Binder, allocator, args),
        .un_i_data => data_mod.unIData(Binder, allocator, args),
        .un_b_data => data_mod.unBData(Binder, allocator, args),
        .equals_data => data_mod.equalsData(Binder, allocator, args),
        .mk_pair_data => data_mod.mkPairData(Binder, allocator, args),
        .serialise_data => data_mod.serialiseData(Binder, allocator, args),
        .mk_nil_data => data_mod.mkNilData(Binder, allocator, args),
        .mk_nil_pair_data => data_mod.mkNilPairData(Binder, allocator, args),
        .sha2_256 => crypto.sha2_256(Binder, allocator, args),
        .sha3_256 => crypto.sha3_256(Binder, allocator, args),
        .blake2b_256 => crypto.blake2b_256(Binder, allocator, args),
        .blake2b_224 => crypto.blake2b_224(Binder, allocator, args),
        .verify_ed25519_signature => crypto.verifyEd25519Signature(Binder, allocator, args),
        .keccak_256 => crypto.keccak_256(Binder, allocator, args),
        .ripemd_160 => crypto.ripemd_160(Binder, allocator, args),
        .index_byte_string => crypto.indexByteString(Binder, allocator, args),
        .verify_ecdsa_secp256k1_signature => crypto.verifyEcdsaSecp256k1Signature(Binder, allocator, args),
        .verify_schnorr_secp256k1_signature => crypto.verifySchnorrSecp256k1Signature(Binder, allocator, args),
        .shift_byte_string => bitwise.shiftByteString(Binder, allocator, args),
        .rotate_byte_string => bitwise.rotateByteString(Binder, allocator, args),
        .replicate_byte => bitwise.replicateByte(Binder, allocator, args),
        .count_set_bits => bitwise.countSetBits(Binder, allocator, args),
        .find_first_set_bit => bitwise.findFirstSetBit(Binder, allocator, args),
        .read_bit => bitwise.readBit(Binder, allocator, args),
        .write_bits => bitwise.writeBits(Binder, allocator, args),
        .and_byte_string => bitwise.andByteString(Binder, allocator, args),
        .or_byte_string => bitwise.orByteString(Binder, allocator, args),
        .xor_byte_string => bitwise.xorByteString(Binder, allocator, args),
        .complement_byte_string => bitwise.complementByteString(Binder, allocator, args),
        .integer_to_byte_string => bitwise.integerToByteString(Binder, allocator, args),
        .byte_string_to_integer => bitwise.byteStringToInteger(Binder, allocator, args),
        .bls12_381_g1_add => bls_mod.bls12381G1Add(Binder, allocator, args),
        .bls12_381_g1_neg => bls_mod.bls12381G1Neg(Binder, allocator, args),
        .bls12_381_g1_scalar_mul => bls_mod.bls12381G1ScalarMul(Binder, allocator, args),
        .bls12_381_g1_equal => bls_mod.bls12381G1Equal(Binder, allocator, args),
        .bls12_381_g1_compress => bls_mod.bls12381G1Compress(Binder, allocator, args),
        .bls12_381_g1_uncompress => bls_mod.bls12381G1Uncompress(Binder, allocator, args),
        .bls12_381_g1_hash_to_group => bls_mod.bls12381G1HashToGroup(Binder, allocator, args),
        .bls12_381_g2_add => bls_mod.bls12381G2Add(Binder, allocator, args),
        .bls12_381_g2_neg => bls_mod.bls12381G2Neg(Binder, allocator, args),
        .bls12_381_g2_scalar_mul => bls_mod.bls12381G2ScalarMul(Binder, allocator, args),
        .bls12_381_g2_equal => bls_mod.bls12381G2Equal(Binder, allocator, args),
        .bls12_381_g2_compress => bls_mod.bls12381G2Compress(Binder, allocator, args),
        .bls12_381_g2_uncompress => bls_mod.bls12381G2Uncompress(Binder, allocator, args),
        .bls12_381_g2_hash_to_group => bls_mod.bls12381G2HashToGroup(Binder, allocator, args),
        .bls12_381_miller_loop => bls_mod.bls12381MillerLoop(Binder, allocator, args),
        .bls12_381_mul_ml_result => bls_mod.bls12381MulMlResult(Binder, allocator, args),
        .bls12_381_final_verify => bls_mod.bls12381FinalVerify(Binder, allocator, args),
        .bls12_381_g1_multi_scalar_mul => bls_mod.bls12381G1MultiScalarMul(Binder, allocator, args),
        .bls12_381_g2_multi_scalar_mul => bls_mod.bls12381G2MultiScalarMul(Binder, allocator, args),
        .insert_coin => value_mod.insertCoinBuiltin(Binder, allocator, args),
        .lookup_coin => value_mod.lookupCoinBuiltin(Binder, allocator, args),
        .union_value => value_mod.unionValueBuiltin(Binder, allocator, args),
        .value_contains => value_mod.valueContainsBuiltin(Binder, allocator, args),
        .value_data => value_mod.valueDataBuiltin(Binder, allocator, args),
        .un_value_data => value_mod.unValueDataBuiltin(Binder, allocator, args),
        .scale_value => value_mod.scaleValueBuiltin(Binder, allocator, args),
    };
}

/// Compute ExMem sizes for builtin arguments based on the function type.
/// Returns up to 3 sizes (padded with 0 for unused positions).
fn computeArgSizes(
    comptime Binder: type,
    func: DefaultFunction,
    args: []const *const Value(Binder),
) [3]i64 {
    return switch (func) {
        // 2-arg integer operations: (int, int)
        .add_integer,
        .subtract_integer,
        .multiply_integer,
        .divide_integer,
        .quotient_integer,
        .remainder_integer,
        .mod_integer,
        .equals_integer,
        .less_than_integer,
        .less_than_equals_integer,
        => intIntSizes(Binder, args),

        // 2-arg bytestring operations: (bs, bs)
        .append_byte_string,
        .equals_byte_string,
        .less_than_byte_string,
        .less_than_equals_byte_string,
        => bsBsSizes(Binder, args),

        // (int, bs)
        .cons_byte_string => .{
            intSize(Binder, args[0]),
            bsSize(Binder, args[1]),
            0,
        },

        // (int, int, bs) - slice
        .slice_byte_string => .{
            intSize(Binder, args[0]),
            intSize(Binder, args[1]),
            bsSize(Binder, args[2]),
        },

        // 1-arg bytestring
        .length_of_byte_string,
        .sha2_256,
        .sha3_256,
        .blake2b_256,
        .blake2b_224,
        .keccak_256,
        .ripemd_160,
        .complement_byte_string,
        .count_set_bits,
        .find_first_set_bit,
        => .{ bsSize(Binder, args[0]), 0, 0 },

        // (bs, int)
        .index_byte_string,
        .read_bit,
        => .{
            bsSize(Binder, args[0]),
            intSize(Binder, args[1]),
            0,
        },

        // (bs, IntegerCostedLiterally)
        .shift_byte_string,
        .rotate_byte_string,
        => .{
            bsSize(Binder, args[0]),
            intLiteralValue(Binder, args[1]),
            0,
        },

        // dropList: args[0] is IntegerCostedLiterally (raw integer value)
        .drop_list => .{
            intLiteralValue(Binder, args[0]),
            listSizeFromArg(Binder, args[1]),
            0,
        },

        // replicateByte: args[0] is an INTEGER (the count), need sizeExMem
        .replicate_byte => .{
            sizeExMemFromArg(Binder, args[0]),
            intSize(Binder, args[1]),
            0,
        },

        // 3-arg signature verification: (bs, bs, bs)
        .verify_ed25519_signature,
        .verify_ecdsa_secp256k1_signature,
        .verify_schnorr_secp256k1_signature,
        => .{
            bsSize(Binder, args[0]),
            bsSize(Binder, args[1]),
            bsSize(Binder, args[2]),
        },

        // 2-arg string operations: (str, str)
        .append_string,
        .equals_string,
        => .{
            strSize(Binder, args[0]),
            strSize(Binder, args[1]),
            0,
        },

        // 1-arg string/bs
        .encode_utf8 => .{ strSize(Binder, args[0]), 0, 0 },
        .decode_utf8 => .{ bsSize(Binder, args[0]), 0, 0 },

        // Constant cost builtins (sizes don't matter)
        .if_then_else,
        .choose_unit,
        .trace,
        .fst_pair,
        .snd_pair,
        .choose_list,
        .mk_cons,
        .head_list,
        .tail_list,
        .null_list,
        .choose_data,
        .constr_data,
        .map_data,
        .list_data,
        .i_data,
        .b_data,
        .un_constr_data,
        .un_map_data,
        .un_list_data,
        .un_i_data,
        .un_b_data,
        .mk_pair_data,
        .mk_nil_data,
        .mk_nil_pair_data,
        .bls12_381_g1_add,
        .bls12_381_g1_neg,
        .bls12_381_g1_equal,
        .bls12_381_g1_compress,
        .bls12_381_g1_uncompress,
        .bls12_381_g2_add,
        .bls12_381_g2_neg,
        .bls12_381_g2_equal,
        .bls12_381_g2_compress,
        .bls12_381_g2_uncompress,
        .bls12_381_miller_loop,
        .bls12_381_mul_ml_result,
        .bls12_381_final_verify,
        .length_of_array,
        .index_array,
        => .{ 0, 0, 0 },

        // insertCoin: .one model, compute ValueMaxDepth of the value arg (args[3])
        .insert_coin => .{ valueMaxDepthFromArg(Binder, args[3]), 0, 0 },

        // (data, data) - equalsData
        .equals_data => .{
            dataSize(Binder, args[0]),
            dataSize(Binder, args[1]),
            0,
        },

        // 1-arg data
        .serialise_data => .{ dataSize(Binder, args[0]), 0, 0 },

        // BLS scalar mul: (int, g1/g2)
        .bls12_381_g1_scalar_mul => .{ intSize(Binder, args[0]), ex_mem.g1ExMem(), 0 },
        .bls12_381_g2_scalar_mul => .{ intSize(Binder, args[0]), ex_mem.g2ExMem(), 0 },

        // BLS hash to group: (bs, bs)
        .bls12_381_g1_hash_to_group,
        .bls12_381_g2_hash_to_group,
        => .{
            bsSize(Binder, args[0]),
            bsSize(Binder, args[1]),
            0,
        },

        // BLS multi scalar mul: (list, list)
        .bls12_381_g1_multi_scalar_mul,
        .bls12_381_g2_multi_scalar_mul,
        => .{
            listSizeFromArg(Binder, args[0]),
            listSizeFromArg(Binder, args[1]),
            0,
        },

        // integerToByteString: (bool, int_sizeExMem, int)
        .integer_to_byte_string => .{
            1,
            sizeExMemFromArg(Binder, args[1]),
            intSize(Binder, args[2]),
        },

        // byteStringToInteger: (bool, bs)
        .byte_string_to_integer => .{
            1,
            bsSize(Binder, args[1]),
            0,
        },

        // 3-arg bitwise: (bool, bs, bs)
        .and_byte_string,
        .or_byte_string,
        .xor_byte_string,
        => .{
            1,
            bsSize(Binder, args[1]),
            bsSize(Binder, args[2]),
        },

        // writeBits: (bs, list, list)
        .write_bits => .{
            bsSize(Binder, args[0]),
            listSizeFromArg(Binder, args[1]),
            listSizeFromArg(Binder, args[2]),
        },

        // expModInteger: (int, int, int)
        .exp_mod_integer => .{
            intSize(Binder, args[0]),
            intSize(Binder, args[1]),
            intSize(Binder, args[2]),
        },

        // listToArray: (list)
        .list_to_array => .{ listSizeFromArg(Binder, args[0]), 0, 0 },

        // lookupCoin: (bs, bs, ValueMaxDepth)
        .lookup_coin => .{
            bsSize(Binder, args[0]),
            bsSize(Binder, args[1]),
            valueMaxDepthFromArg(Binder, args[2]),
        },

        // unionValue: (value, value)
        .union_value => .{
            valueSize(Binder, args[0]),
            valueSize(Binder, args[1]),
            0,
        },

        // valueContains: (value, value)
        .value_contains => .{
            valueSize(Binder, args[0]),
            valueSize(Binder, args[1]),
            0,
        },

        // valueData: (value)
        .value_data => .{ valueSize(Binder, args[0]), 0, 0 },

        // unValueData: (DataNodeCount)
        .un_value_data => .{ dataNodeCountFromArg(Binder, args[0]), 0, 0 },

        // scaleValue: (int, value)
        .scale_value => .{
            intSize(Binder, args[0]),
            valueSize(Binder, args[1]),
            0,
        },
    };
}

// ===== Size computation helpers =====

fn intSize(comptime Binder: type, val: *const Value(Binder)) i64 {
    switch (val.*) {
        .constant => |c| switch (c.*) {
            .integer => |*i| return ex_mem.integerExMem(i),
            else => return 1,
        },
        else => return 1,
    }
}

fn bsSize(comptime Binder: type, val: *const Value(Binder)) i64 {
    switch (val.*) {
        .constant => |c| switch (c.*) {
            .byte_string => |bs| return ex_mem.byteStringExMem(bs),
            else => return 0,
        },
        else => return 0,
    }
}

fn strSize(comptime Binder: type, val: *const Value(Binder)) i64 {
    switch (val.*) {
        .constant => |c| switch (c.*) {
            .string => |s| return ex_mem.stringExMem(s),
            else => return 0,
        },
        else => return 0,
    }
}

fn dataSize(comptime Binder: type, val: *const Value(Binder)) i64 {
    switch (val.*) {
        .constant => |c| switch (c.*) {
            .data => |d| return ex_mem.dataExMem(d),
            else => return 4,
        },
        else => return 4,
    }
}

fn valueSize(comptime Binder: type, val: *const Value(Binder)) i64 {
    switch (val.*) {
        .constant => |c| switch (c.*) {
            .value => |v| return @intCast(v.size),
            else => return 0,
        },
        else => return 0,
    }
}

fn listSizeFromArg(comptime Binder: type, val: *const Value(Binder)) i64 {
    switch (val.*) {
        .constant => |c| switch (c.*) {
            .proto_list => |l| return @intCast(l.values.len),
            else => return 0,
        },
        else => return 0,
    }
}

fn sizeExMemFromArg(comptime Binder: type, val: *const Value(Binder)) i64 {
    switch (val.*) {
        .constant => |c| switch (c.*) {
            .integer => |*i| {
                const int_val = i.toConst().toInt(i64) catch return 0;
                return ex_mem.sizeExMem(int_val);
            },
            else => return 0,
        },
        else => return 0,
    }
}

fn intLiteralValue(comptime Binder: type, val: *const Value(Binder)) i64 {
    switch (val.*) {
        .constant => |c| switch (c.*) {
            .integer => |*i| return ex_mem.integerCostedLiterally(i),
            else => return 0,
        },
        else => return 0,
    }
}

fn valueMaxDepthFromArg(comptime Binder: type, val: *const Value(Binder)) i64 {
    switch (val.*) {
        .constant => |c| switch (c.*) {
            .value => |v| return ex_mem.valueMaxDepth(v),
            else => return 0,
        },
        else => return 0,
    }
}

fn dataNodeCountFromArg(comptime Binder: type, val: *const Value(Binder)) i64 {
    switch (val.*) {
        .constant => |c| switch (c.*) {
            .data => |d| return ex_mem.dataNodeCount(d),
            else => return 0,
        },
        else => return 0,
    }
}

fn intIntSizes(comptime Binder: type, args: []const *const Value(Binder)) [3]i64 {
    return .{
        intSize(Binder, args[0]),
        intSize(Binder, args[1]),
        0,
    };
}

fn bsBsSizes(comptime Binder: type, args: []const *const Value(Binder)) [3]i64 {
    return .{
        bsSize(Binder, args[0]),
        bsSize(Binder, args[1]),
        0,
    };
}
