//! Plutuz - UPLC implementation in Zig.
//!
//! This library provides a parser, formatter, and evaluator for
//! Untyped Plutus Core (UPLC), the core language of Cardano smart contracts.

const std = @import("std");

// AST types
pub const ast = struct {
    pub const builtin = @import("ast/builtin.zig");
    pub const constant = @import("ast/constant.zig");
    pub const program = @import("ast/program.zig");
    pub const term = @import("ast/term.zig");
    pub const typ = @import("ast/typ.zig");
    pub const value = @import("ast/value.zig");

    pub const DefaultFunction = builtin.DefaultFunction;
    pub const Constant = constant.Constant;
    pub const Program = program.Program;
    pub const Version = program.Version;
    pub const Term = term.Term;
    pub const Type = typ.Type;
    pub const Value = value.Value;
};

// Binder types
pub const binder = struct {
    pub const name = @import("binder/name.zig");
    pub const debruijn = @import("binder/debruijn.zig");
    pub const named_debruijn = @import("binder/named_debruijn.zig");

    pub const Name = name.Name;
    pub const DeBruijn = debruijn.DeBruijn;
    pub const NamedDeBruijn = named_debruijn.NamedDeBruijn;
};

// Syntax (parsing/printing)
pub const syn = struct {
    pub const lexer = @import("syn/lexer.zig");
    pub const parser = @import("syn/parser.zig");
    pub const pretty = @import("syn/pretty.zig");
    pub const token = @import("syn/token.zig");

    pub const Lexer = lexer.Lexer;
    pub const Parser = parser.Parser;
    pub const Token = token.Token;
    pub const TokenType = token.TokenType;
};

// Data types
pub const data = struct {
    pub const plutus_data = @import("data/plutus_data.zig");
    pub const cbor = @import("data/cbor.zig");

    pub const PlutusData = plutus_data.PlutusData;
};

// Flat encoding/decoding
pub const flat = struct {
    pub const decode = @import("flat/decode.zig");
    pub const encode = @import("flat/encode.zig");
    pub const zigzag = @import("flat/zigzag.zig");
};

// Cryptography
pub const crypto = struct {
    pub const blst = @import("crypto/blst.zig");
    pub const ripemd160 = @import("crypto/ripemd160.zig");
};

// Conversion
pub const convert = struct {
    pub const name_to_debruijn = @import("convert/name_to_debruijn.zig");

    pub const nameToDeBruijn = name_to_debruijn.convert;
};

// CEK Machine
pub const cek = struct {
    pub const machine = @import("cek/machine.zig");
    pub const value = @import("cek/value.zig");
    pub const cost_model = @import("cek/cost_model.zig");
    pub const costing = @import("cek/costing.zig");
    pub const ex_mem_mod = @import("cek/ex_mem.zig");

    pub const Machine = machine.Machine;
    pub const ExBudget = machine.ExBudget;
    pub const SemanticsVariant = machine.SemanticsVariant;
    pub const StepKind = machine.StepKind;
    pub const CostModel = machine.CostModel;
    pub const Value = value.Value;
    pub const Env = value.Env;
};

// Convenience type aliases
pub const Name = binder.Name;
pub const DeBruijn = binder.DeBruijn;
pub const NamedDeBruijn = binder.NamedDeBruijn;

pub const NameTerm = ast.Term(Name);
pub const DeBruijnTerm = ast.Term(DeBruijn);
pub const NamedDeBruijnTerm = ast.Term(NamedDeBruijn);

pub const NameProgram = ast.Program(Name);
pub const DeBruijnProgram = ast.Program(DeBruijn);
pub const NamedDeBruijnProgram = ast.Program(NamedDeBruijn);

pub const NameParser = syn.Parser(Name);
pub const DeBruijnMachine = cek.Machine(DeBruijn);
pub const SemanticsVariant = cek.SemanticsVariant;

/// Parse a UPLC program from source code.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !*const NameProgram {
    var p = NameParser.init(allocator, source);
    return p.parseProgram();
}

/// Convert a Name program to DeBruijn indices.
pub fn nameToDeBruijn(allocator: std.mem.Allocator, program: *const NameProgram) !*const DeBruijnProgram {
    return convert.nameToDeBruijn(allocator, program);
}

/// Evaluate a DeBruijn program using the CEK machine.
pub fn eval(allocator: std.mem.Allocator, program: *const DeBruijnProgram) !*const DeBruijnTerm {
    var m = DeBruijnMachine.init(allocator);
    m.restricting = true;
    return m.run(program.term);
}

/// Evaluate a DeBruijn program with a specific semantics variant.
pub fn evalVersion(allocator: std.mem.Allocator, program: *const DeBruijnProgram, semantics: SemanticsVariant) !*const DeBruijnTerm {
    var m = DeBruijnMachine.init(allocator);
    m.restricting = true;
    m.semantics = semantics;
    return m.run(program.term);
}

/// Pretty print a Name program to a string.
pub fn pretty(allocator: std.mem.Allocator, program: *const NameProgram) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    try syn.pretty.printProgram(Name, program, list.writer(allocator), allocator);
    return list.toOwnedSlice(allocator);
}

/// Pretty print a DeBruijn term to a string.
pub fn prettyDeBruijnTerm(allocator: std.mem.Allocator, term: *const DeBruijnTerm) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    try syn.pretty.printTerm(DeBruijn, term, list.writer(allocator), allocator);
    return list.toOwnedSlice(allocator);
}

/// Decode a flat-encoded DeBruijn program from bytes.
pub fn decodeFlatDeBruijn(allocator: std.mem.Allocator, bytes: []const u8) !*const DeBruijnProgram {
    return flat.decode.decode(allocator, bytes);
}

/// Encode a DeBruijn program to flat bytes.
pub fn encodeFlatDeBruijn(allocator: std.mem.Allocator, program: *const DeBruijnProgram) ![]const u8 {
    return flat.encode.encode(allocator, program);
}

test "parse and print roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "(program 1.0.0 (con integer 42))";
    const program = try parse(allocator, source);
    _ = program;
}

test {
    // Run all module tests
    _ = ast.builtin;
    _ = ast.constant;
    _ = ast.program;
    _ = ast.term;
    _ = ast.typ;
    _ = ast.value;
    _ = binder.name;
    _ = binder.debruijn;
    _ = binder.named_debruijn;
    _ = syn.lexer;
    _ = syn.parser;
    _ = syn.pretty;
    _ = syn.token;
    _ = data.plutus_data;
    _ = data.cbor;
    _ = convert.name_to_debruijn;
    _ = cek.machine;
    _ = cek.value;
    _ = cek.costing;
    _ = cek.ex_mem_mod;
    _ = cek.cost_model;
    _ = flat.decode;
    _ = flat.encode;
    _ = flat.zigzag;
}
