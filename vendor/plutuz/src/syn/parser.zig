//! Recursive descent parser for UPLC.
//! Parses UPLC source code into an AST.

const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Term = @import("../ast/term.zig").Term;
const Program = @import("../ast/program.zig").Program;
const Version = @import("../ast/program.zig").Version;
const Constant = @import("../ast/constant.zig").Constant;
const Type = @import("../ast/typ.zig").Type;
const DefaultFunction = @import("../ast/builtin.zig").DefaultFunction;
const PlutusData = @import("../data/plutus_data.zig").PlutusData;
const PlutusDataPair = @import("../data/plutus_data.zig").PlutusDataPair;
const Name = @import("../binder/name.zig").Name;
const blst = @import("../crypto/blst.zig");
const value_mod = @import("../ast/value.zig");
const Value = value_mod.Value;
const Integer = std.math.big.int.Managed;

/// Parser error types.
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidVersion,
    InvalidInteger,
    InvalidByteString,
    InvalidString,
    InvalidPoint,
    UnknownBuiltin,
    UnknownType,
    VersionError,
    OutOfMemory,
};

/// A parser for UPLC source code.
pub fn Parser(comptime Binder: type) type {
    return struct {
        /// The lexer providing tokens
        lexer: Lexer,
        /// Current token
        current: Token,
        /// Previous token
        previous: Token,
        /// Memory allocator
        allocator: std.mem.Allocator,
        /// Unique name counter
        unique_counter: usize,
        /// Interned names: text -> unique (same name gets same unique)
        interned: std.StringHashMapUnmanaged(usize),
        /// Whether an error has occurred
        had_error: bool,
        /// Error message if any
        error_message: ?[]const u8,
        /// Program version (set during parsing)
        version: Version,

        const Self = @This();
        const TermType = Term(Binder);
        const ProgramType = Program(Binder);

        /// Initialize a new parser.
        pub fn init(allocator: std.mem.Allocator, source: []const u8) Self {
            var parser = Self{
                .lexer = Lexer.init(source),
                .current = undefined,
                .previous = undefined,
                .allocator = allocator,
                .unique_counter = 0,
                .interned = .{},
                .had_error = false,
                .error_message = null,
                .version = Version.v1_0_0,
            };
            // Prime the parser with the first token
            parser.advance();
            return parser;
        }

        /// Check if version is before 1.1.0
        fn isBeforeV1_1_0(self: *Self) bool {
            return self.version.major < 2 and self.version.minor < 1;
        }

        /// Parse a complete program.
        pub fn parseProgram(self: *Self) ParseError!*const ProgramType {
            // Expect: (program <version> <term>)
            try self.expect(.left_paren);
            try self.expect(.program);

            const version = try self.parseVersion();
            self.version = version; // Store version for validation
            const term = try self.parseTerm();

            try self.expect(.right_paren);

            return ProgramType.create(self.allocator, version, term) catch return error.OutOfMemory;
        }

        /// Parse a version string like "1.0.0".
        fn parseVersion(self: *Self) ParseError!Version {
            const major = try self.parseVersionComponent();
            try self.expect(.dot);
            const minor = try self.parseVersionComponent();
            try self.expect(.dot);
            const patch = try self.parseVersionComponent();

            return Version.create(major, minor, patch);
        }

        fn parseVersionComponent(self: *Self) ParseError!u32 {
            try self.expect(.number);
            return std.fmt.parseInt(u32, self.previous.lexeme, 10) catch return error.InvalidVersion;
        }

        /// Parse a term.
        pub fn parseTerm(self: *Self) ParseError!*const TermType {
            switch (self.current.type) {
                .left_paren => return self.parseParenTerm(),
                .left_bracket => return self.parseApplication(),
                .identifier => return self.parseVariable(),
                else => {
                    self.errorAtCurrent("Expected term");
                    return error.UnexpectedToken;
                },
            }
        }

        fn parseParenTerm(self: *Self) ParseError!*const TermType {
            try self.expect(.left_paren);

            const result: *const TermType = switch (self.current.type) {
                .lam => try self.parseLambda(),
                .delay => try self.parseDelay(),
                .force => try self.parseForce(),
                .con => try self.parseConstant(),
                .builtin => try self.parseBuiltin(),
                .error_ => try self.parseError(),
                .case => try self.parseCase(),
                .constr => try self.parseConstr(),
                else => {
                    self.errorAtCurrent("Expected term keyword");
                    return error.UnexpectedToken;
                },
            };

            try self.expect(.right_paren);
            return result;
        }

        fn parseLambda(self: *Self) ParseError!*const TermType {
            try self.expect(.lam);
            const param = try self.parseBinder();
            const body = try self.parseTerm();
            return TermType.lam(self.allocator, param, body) catch return error.OutOfMemory;
        }

        fn parseDelay(self: *Self) ParseError!*const TermType {
            try self.expect(.delay);
            const term = try self.parseTerm();
            return TermType.del(self.allocator, term) catch return error.OutOfMemory;
        }

        fn parseForce(self: *Self) ParseError!*const TermType {
            try self.expect(.force);
            const term = try self.parseTerm();
            return TermType.frc(self.allocator, term) catch return error.OutOfMemory;
        }

        fn parseConstant(self: *Self) ParseError!*const TermType {
            try self.expect(.con);
            const constant = try self.parseConstantValue();
            return TermType.con(self.allocator, constant) catch return error.OutOfMemory;
        }

        fn parseBuiltin(self: *Self) ParseError!*const TermType {
            try self.expect(.builtin);
            try self.expect(.identifier);

            const builtin = DefaultFunction.fromName(self.previous.lexeme) orelse {
                self.errorAtPrevious("Unknown builtin function");
                return error.UnknownBuiltin;
            };

            return TermType.builtinOf(self.allocator, builtin) catch return error.OutOfMemory;
        }

        fn parseError(self: *Self) ParseError!*const TermType {
            try self.expect(.error_);
            return TermType.errorTerm(self.allocator) catch return error.OutOfMemory;
        }

        fn parseCase(self: *Self) ParseError!*const TermType {
            if (self.isBeforeV1_1_0()) {
                self.errorAtCurrent("case can't be used before version 1.1.0");
                return error.VersionError;
            }

            try self.expect(.case);
            const scrutinee = try self.parseTerm();

            var branches: std.ArrayListUnmanaged(*const TermType) = .empty;
            defer branches.deinit(self.allocator);

            while (self.current.type != .right_paren and self.current.type != .eof) {
                const branch = try self.parseTerm();
                branches.append(self.allocator, branch) catch return error.OutOfMemory;
            }

            const owned_branches = branches.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            return TermType.caseOf(self.allocator, scrutinee, owned_branches) catch return error.OutOfMemory;
        }

        fn parseConstr(self: *Self) ParseError!*const TermType {
            if (self.isBeforeV1_1_0()) {
                self.errorAtCurrent("constr can't be used before version 1.1.0");
                return error.VersionError;
            }

            try self.expect(.constr);
            try self.expect(.number);

            const tag = std.fmt.parseInt(usize, self.previous.lexeme, 10) catch return error.InvalidInteger;

            var fields: std.ArrayListUnmanaged(*const TermType) = .empty;
            defer fields.deinit(self.allocator);

            while (self.current.type != .right_paren and self.current.type != .eof) {
                const field = try self.parseTerm();
                fields.append(self.allocator, field) catch return error.OutOfMemory;
            }

            const owned_fields = fields.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            return TermType.constrOf(self.allocator, tag, owned_fields) catch return error.OutOfMemory;
        }

        fn parseApplication(self: *Self) ParseError!*const TermType {
            try self.expect(.left_bracket);

            const func = try self.parseTerm();
            const arg = try self.parseTerm();

            var result = TermType.app(self.allocator, func, arg) catch return error.OutOfMemory;

            // Handle multiple arguments: [f a b c] = (((f a) b) c)
            while (self.current.type != .right_bracket and self.current.type != .eof) {
                const next_arg = try self.parseTerm();
                result = TermType.app(self.allocator, result, next_arg) catch return error.OutOfMemory;
            }

            try self.expect(.right_bracket);
            return result;
        }

        fn parseVariable(self: *Self) ParseError!*const TermType {
            try self.expect(.identifier);
            const binder = try self.parseBinder();
            return TermType.variable(self.allocator, binder) catch return error.OutOfMemory;
        }

        fn parseBinder(self: *Self) ParseError!*const Binder {
            // For Name binder, we expect an identifier
            if (Binder == Name) {
                if (self.previous.type != .identifier) {
                    try self.expect(.identifier);
                }
                const unique = self.internName(self.previous.lexeme);
                return Name.create(self.allocator, self.previous.lexeme, unique) catch return error.OutOfMemory;
            }
            // Add other binder types here
            @compileError("Unsupported binder type");
        }

        fn parseConstantValue(self: *Self) ParseError!*const Constant {
            const typ = try self.parseType();
            return self.parseConstantOfType(typ);
        }

        fn parseType(self: *Self) ParseError!*const Type {
            switch (self.current.type) {
                .identifier => {
                    self.advance();
                    const type_name = self.previous.lexeme;

                    if (std.mem.eql(u8, type_name, "integer")) {
                        return Type.int(self.allocator) catch return error.OutOfMemory;
                    } else if (std.mem.eql(u8, type_name, "bytestring")) {
                        return Type.byteString(self.allocator) catch return error.OutOfMemory;
                    } else if (std.mem.eql(u8, type_name, "string")) {
                        return Type.str(self.allocator) catch return error.OutOfMemory;
                    } else if (std.mem.eql(u8, type_name, "bool")) {
                        return Type.boolean(self.allocator) catch return error.OutOfMemory;
                    } else if (std.mem.eql(u8, type_name, "unit")) {
                        return Type.unt(self.allocator) catch return error.OutOfMemory;
                    } else if (std.mem.eql(u8, type_name, "data")) {
                        return Type.dat(self.allocator) catch return error.OutOfMemory;
                    } else if (std.mem.eql(u8, type_name, "bls12_381_G1_element")) {
                        return Type.g1(self.allocator) catch return error.OutOfMemory;
                    } else if (std.mem.eql(u8, type_name, "bls12_381_G2_element")) {
                        return Type.g2(self.allocator) catch return error.OutOfMemory;
                    } else if (std.mem.eql(u8, type_name, "bls12_381_mlresult")) {
                        return Type.mlResult(self.allocator) catch return error.OutOfMemory;
                    } else if (std.mem.eql(u8, type_name, "value")) {
                        return Type.val(self.allocator) catch return error.OutOfMemory;
                    }

                    self.errorAtPrevious("Unknown type");
                    return error.UnknownType;
                },
                .left_paren => {
                    self.advance();

                    if (self.current.type == .list) {
                        self.advance();
                        const inner = try self.parseType();
                        try self.expect(.right_paren);
                        return Type.listOf(self.allocator, inner) catch return error.OutOfMemory;
                    } else if (self.current.type == .array) {
                        self.advance();
                        const inner = try self.parseType();
                        try self.expect(.right_paren);
                        return Type.arrayOf(self.allocator, inner) catch return error.OutOfMemory;
                    } else if (self.current.type == .pair) {
                        self.advance();
                        const fst = try self.parseType();
                        const snd = try self.parseType();
                        try self.expect(.right_paren);
                        return Type.pairOf(self.allocator, fst, snd) catch return error.OutOfMemory;
                    }

                    self.errorAtCurrent("Expected list, array, or pair");
                    return error.UnknownType;
                },
                else => {
                    self.errorAtCurrent("Expected type");
                    return error.UnexpectedToken;
                },
            }
        }

        fn parseConstantOfType(self: *Self, typ: *const Type) ParseError!*const Constant {
            switch (typ.*) {
                .integer => {
                    try self.expect(.number);
                    return self.parseBigInteger() catch return error.OutOfMemory;
                },
                .byte_string => {
                    try self.expect(.byte_string);
                    return self.parseByteStringValue() catch return error.OutOfMemory;
                },
                .string => {
                    try self.expect(.string);
                    // Remove quotes and handle escapes
                    const quoted = self.previous.lexeme;
                    const unquoted = self.parseStringEscapes(quoted[1 .. quoted.len - 1]) catch return error.OutOfMemory;
                    return Constant.str(self.allocator, unquoted) catch return error.OutOfMemory;
                },
                .bool => {
                    if (self.current.type == .true_) {
                        self.advance();
                        return Constant.boolVal(self.allocator, true) catch return error.OutOfMemory;
                    } else if (self.current.type == .false_) {
                        self.advance();
                        return Constant.boolVal(self.allocator, false) catch return error.OutOfMemory;
                    }
                    self.errorAtCurrent("Expected True or False");
                    return error.UnexpectedToken;
                },
                .unit => {
                    try self.expect(.unit);
                    return Constant.unt(self.allocator) catch return error.OutOfMemory;
                },
                .list => |inner_type| {
                    try self.expect(.left_bracket);

                    var items: std.ArrayListUnmanaged(*const Constant) = .empty;
                    defer items.deinit(self.allocator);

                    while (self.current.type != .right_bracket and self.current.type != .eof) {
                        const item = try self.parseConstantOfType(inner_type);
                        items.append(self.allocator, item) catch return error.OutOfMemory;

                        if (self.current.type == .comma) {
                            self.advance();
                        }
                    }

                    try self.expect(.right_bracket);
                    const owned_items = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                    return Constant.protoList(self.allocator, inner_type, owned_items) catch return error.OutOfMemory;
                },
                .array => |inner_type| {
                    try self.expect(.left_bracket);

                    var items: std.ArrayListUnmanaged(*const Constant) = .empty;
                    defer items.deinit(self.allocator);

                    while (self.current.type != .right_bracket and self.current.type != .eof) {
                        const item = try self.parseConstantOfType(inner_type);
                        items.append(self.allocator, item) catch return error.OutOfMemory;

                        if (self.current.type == .comma) {
                            self.advance();
                        }
                    }

                    try self.expect(.right_bracket);
                    const owned_items = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                    return Constant.protoArray(self.allocator, inner_type, owned_items) catch return error.OutOfMemory;
                },
                .pair => |pair_types| {
                    try self.expect(.left_paren);
                    const fst = try self.parseConstantOfType(pair_types.fst);
                    try self.expect(.comma);
                    const snd = try self.parseConstantOfType(pair_types.snd);
                    try self.expect(.right_paren);
                    return Constant.protoPair(self.allocator, pair_types.fst, pair_types.snd, fst, snd) catch return error.OutOfMemory;
                },
                .data => {
                    // Data in a list/pair context: no parens, directly parse PlutusData
                    // Data in top-level (con data ...): wrapped in parens
                    if (self.current.type == .left_paren) {
                        self.advance();
                        const data_val = try self.parsePlutusData();
                        try self.expect(.right_paren);
                        return Constant.dat(self.allocator, data_val) catch return error.OutOfMemory;
                    } else {
                        // No parens - parse directly (happens in list/pair context)
                        const data_val = try self.parsePlutusData();
                        return Constant.dat(self.allocator, data_val) catch return error.OutOfMemory;
                    }
                },
                .value => {
                    return self.parseValueConstant();
                },
                .bls12_381_g1_element => {
                    try self.expect(.point);
                    const hex = self.previous.lexeme[2..]; // Skip "0x"
                    if (hex.len != 96) { // 48 bytes = 96 hex chars
                        self.errorAtPrevious("BLS G1 element must be 48 bytes");
                        return error.InvalidPoint;
                    }
                    var bytes: [48]u8 = undefined;
                    for (0..48) |i| {
                        bytes[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return error.InvalidPoint;
                    }
                    // Decompress and validate the point - store uncompressed
                    const point = blst.uncompressG1(&bytes) catch {
                        self.errorAtPrevious("Invalid BLS G1 point");
                        return error.InvalidPoint;
                    };
                    const c = self.allocator.create(Constant) catch return error.OutOfMemory;
                    c.* = .{ .bls12_381_g1_element = point };
                    return c;
                },
                .bls12_381_g2_element => {
                    try self.expect(.point);
                    const hex = self.previous.lexeme[2..]; // Skip "0x"
                    if (hex.len != 192) { // 96 bytes = 192 hex chars
                        self.errorAtPrevious("BLS G2 element must be 96 bytes");
                        return error.InvalidPoint;
                    }
                    var bytes: [96]u8 = undefined;
                    for (0..96) |i| {
                        bytes[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return error.InvalidPoint;
                    }
                    // Decompress and validate the point - store uncompressed
                    const point = blst.uncompressG2(&bytes) catch {
                        self.errorAtPrevious("Invalid BLS G2 point");
                        return error.InvalidPoint;
                    };
                    const c = self.allocator.create(Constant) catch return error.OutOfMemory;
                    c.* = .{ .bls12_381_g2_element = point };
                    return c;
                },
                .bls12_381_ml_result => {
                    self.errorAtCurrent("BLS ML result cannot be parsed from source");
                    return error.UnexpectedToken;
                },
            }
        }

        fn parseBigInteger(self: *Self) !*const Constant {
            const c = try self.allocator.create(Constant);
            var managed = try std.math.big.int.Managed.init(self.allocator);
            errdefer managed.deinit();

            // Handle potential leading sign
            const lexeme = self.previous.lexeme;
            const is_negative = lexeme[0] == '-';
            const digits = if (is_negative or lexeme[0] == '+') lexeme[1..] else lexeme;

            // Set value from string
            managed.setString(10, digits) catch return error.InvalidInteger;
            if (is_negative) {
                managed.negate();
            }

            c.* = .{ .integer = managed };
            return c;
        }

        fn parseByteStringValue(self: *Self) !*const Constant {
            // Skip the # prefix
            const hex = self.previous.lexeme[1..];
            const bytes = try self.allocator.alloc(u8, hex.len / 2);
            for (0..hex.len / 2) |i| {
                bytes[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return error.InvalidByteString;
            }
            return Constant.byteString(self.allocator, bytes);
        }

        /// Parse a value constant: [(#ccy, [(#tok, qty), ...]), ...]
        /// Normalizes: sorts keys, removes zero-quantity entries, removes empty currency entries.
        /// Validates: key lengths <= 32, quantity in 128-bit signed range.
        fn parseValueConstant(self: *Self) ParseError!*const Constant {
            try self.expect(.left_bracket);

            var currency_entries = std.ArrayListUnmanaged(Value.CurrencyEntry).empty;
            defer currency_entries.deinit(self.allocator);

            while (self.current.type != .right_bracket and self.current.type != .eof) {
                try self.expect(.left_paren);

                // Parse currency symbol bytestring
                try self.expect(.byte_string);
                const ccy_hex = self.previous.lexeme[1..]; // skip #
                const ccy_bytes = self.allocator.alloc(u8, ccy_hex.len / 2) catch return error.OutOfMemory;
                for (0..ccy_hex.len / 2) |i| {
                    ccy_bytes[i] = std.fmt.parseInt(u8, ccy_hex[i * 2 .. i * 2 + 2], 16) catch return error.InvalidByteString;
                }

                // Validate currency key length
                if (ccy_bytes.len > 32) {
                    self.errorAtPrevious("Currency symbol must be at most 32 bytes");
                    return error.InvalidByteString;
                }

                try self.expect(.comma);

                // Parse token list: [(#tok, qty), ...]
                try self.expect(.left_bracket);

                var token_entries = std.ArrayListUnmanaged(Value.TokenEntry).empty;
                defer token_entries.deinit(self.allocator);

                while (self.current.type != .right_bracket and self.current.type != .eof) {
                    try self.expect(.left_paren);

                    // Parse token name bytestring
                    try self.expect(.byte_string);
                    const tok_hex = self.previous.lexeme[1..]; // skip #
                    const tok_bytes = self.allocator.alloc(u8, tok_hex.len / 2) catch return error.OutOfMemory;
                    for (0..tok_hex.len / 2) |i| {
                        tok_bytes[i] = std.fmt.parseInt(u8, tok_hex[i * 2 .. i * 2 + 2], 16) catch return error.InvalidByteString;
                    }

                    // Validate token name length
                    if (tok_bytes.len > 32) {
                        self.errorAtPrevious("Token name must be at most 32 bytes");
                        return error.InvalidByteString;
                    }

                    try self.expect(.comma);

                    // Parse quantity integer
                    try self.expect(.number);
                    const lexeme = self.previous.lexeme;
                    const is_negative = lexeme[0] == '-';
                    const digits = if (is_negative or lexeme[0] == '+') lexeme[1..] else lexeme;

                    var managed = Integer.init(self.allocator) catch return error.OutOfMemory;
                    managed.setString(10, digits) catch return error.InvalidInteger;
                    if (is_negative) {
                        managed.negate();
                    }

                    // Validate quantity range: -(2^127) to (2^127 - 1)
                    if (!managed.eqlZero()) {
                        const bits = managed.bitCountAbs();
                        if (bits > 128) {
                            self.errorAtPrevious("Value quantity out of 128-bit signed range");
                            return error.InvalidInteger;
                        }
                        if (bits == 128) {
                            if (managed.isPositive()) {
                                self.errorAtPrevious("Value quantity out of 128-bit signed range");
                                return error.InvalidInteger;
                            }
                            // Negative with 128 bits: only -(2^127) is valid
                            const limbs = managed.toConst().limbs;
                            const limb_bits = @bitSizeOf(std.math.big.Limb);
                            const target_limb = 127 / limb_bits;
                            const target_bit: std.math.Log2Int(std.math.big.Limb) = @intCast(127 % limb_bits);
                            var valid = true;
                            for (limbs, 0..) |limb, idx| {
                                if (idx == target_limb) {
                                    if (limb != (@as(std.math.big.Limb, 1) << target_bit)) valid = false;
                                } else {
                                    if (limb != 0) valid = false;
                                }
                            }
                            if (!valid) {
                                self.errorAtPrevious("Value quantity out of 128-bit signed range");
                                return error.InvalidInteger;
                            }
                        }
                    }

                    try self.expect(.right_paren);

                    // Skip zero-quantity entries (normalize)
                    if (!managed.eqlZero()) {
                        token_entries.append(self.allocator, .{ .name = tok_bytes, .quantity = managed }) catch return error.OutOfMemory;
                    }

                    if (self.current.type == .comma) {
                        self.advance();
                    }
                }

                try self.expect(.right_bracket);
                try self.expect(.right_paren);

                // Sort token entries by name
                const sorted_tokens = token_entries.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                std.mem.sort(Value.TokenEntry, sorted_tokens, {}, struct {
                    fn lessThan(_: void, a: Value.TokenEntry, b: Value.TokenEntry) bool {
                        return std.mem.order(u8, a.name, b.name) == .lt;
                    }
                }.lessThan);

                // Merge duplicate token names by adding quantities
                const tokens = mergeTokenDuplicates(self.allocator, sorted_tokens) catch return error.OutOfMemory;

                // Only add non-empty currency entries
                if (tokens.len > 0) {
                    currency_entries.append(self.allocator, .{ .currency = ccy_bytes, .tokens = tokens }) catch return error.OutOfMemory;
                }

                if (self.current.type == .comma) {
                    self.advance();
                }
            }

            try self.expect(.right_bracket);

            // Sort currency entries by currency symbol
            const sorted_entries = currency_entries.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            std.mem.sort(Value.CurrencyEntry, sorted_entries, {}, struct {
                fn lessThan(_: void, a: Value.CurrencyEntry, b: Value.CurrencyEntry) bool {
                    return std.mem.order(u8, a.currency, b.currency) == .lt;
                }
            }.lessThan);

            // Merge duplicate currency entries
            const entries = mergeCurrencyDuplicates(self.allocator, sorted_entries) catch return error.OutOfMemory;

            var total_size: usize = 0;
            for (entries) |e| {
                total_size += e.tokens.len;
            }
            const v = Value{ .entries = entries, .size = total_size };
            return Constant.val(self.allocator, v) catch return error.OutOfMemory;
        }

        fn parseStringEscapes(self: *Self, s: []const u8) ![]const u8 {
            var result: std.ArrayListUnmanaged(u8) = .{};
            errdefer result.deinit(self.allocator);

            var i: usize = 0;
            while (i < s.len) {
                if (s[i] == '\\' and i + 1 < s.len) {
                    i += 1;
                    const escape_char = s[i];

                    // Simple one-char escapes
                    const simple_escape: ?u8 = switch (escape_char) {
                        'a' => '\x07', // bell
                        'b' => '\x08', // backspace
                        'f' => '\x0c', // form feed
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'v' => '\x0b', // vertical tab
                        '"' => '"',
                        '\\' => '\\',
                        else => null,
                    };

                    if (simple_escape) |c| {
                        try result.append(self.allocator, c);
                        i += 1;
                        continue;
                    }

                    // Unicode escape: \uXXXX
                    if (escape_char == 'u') {
                        i += 1;
                        const hex_end = findHexEnd(s, i, 4);
                        if (hex_end > i) {
                            const codepoint = std.fmt.parseInt(u21, s[i..hex_end], 16) catch {
                                try result.append(self.allocator, '\\');
                                try result.append(self.allocator, 'u');
                                continue;
                            };
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                                try result.append(self.allocator, '\\');
                                try result.append(self.allocator, 'u');
                                continue;
                            };
                            try result.appendSlice(self.allocator, buf[0..len]);
                            i = hex_end;
                            continue;
                        }
                    }

                    // Hex escape: \xXX
                    if (escape_char == 'x') {
                        i += 1;
                        const hex_end = findHexEnd(s, i, 2);
                        if (hex_end > i) {
                            const byte = std.fmt.parseInt(u8, s[i..hex_end], 16) catch {
                                try result.append(self.allocator, '\\');
                                try result.append(self.allocator, 'x');
                                continue;
                            };
                            try result.append(self.allocator, byte);
                            i = hex_end;
                            continue;
                        }
                    }

                    // Octal escape: \oNNN
                    if (escape_char == 'o') {
                        i += 1;
                        const octal_end = findOctalEnd(s, i, 3);
                        if (octal_end > i) {
                            const value = std.fmt.parseInt(u21, s[i..octal_end], 8) catch {
                                try result.append(self.allocator, '\\');
                                try result.append(self.allocator, 'o');
                                continue;
                            };
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(value, &buf) catch {
                                try result.append(self.allocator, '\\');
                                try result.append(self.allocator, 'o');
                                continue;
                            };
                            try result.appendSlice(self.allocator, buf[0..len]);
                            i = octal_end;
                            continue;
                        }
                    }

                    // Named escape: \DEL
                    if (std.ascii.isAlphabetic(escape_char)) {
                        const name_start = i;
                        while (i < s.len and std.ascii.isAlphabetic(s[i])) {
                            i += 1;
                        }
                        const name = s[name_start..i];
                        const named_char: ?u8 = if (std.mem.eql(u8, name, "DEL"))
                            0x7f
                        else if (std.mem.eql(u8, name, "NUL"))
                            0x00
                        else if (std.mem.eql(u8, name, "SOH"))
                            0x01
                        else if (std.mem.eql(u8, name, "STX"))
                            0x02
                        else if (std.mem.eql(u8, name, "ETX"))
                            0x03
                        else if (std.mem.eql(u8, name, "EOT"))
                            0x04
                        else if (std.mem.eql(u8, name, "ENQ"))
                            0x05
                        else if (std.mem.eql(u8, name, "ACK"))
                            0x06
                        else if (std.mem.eql(u8, name, "BEL"))
                            0x07
                        else if (std.mem.eql(u8, name, "BS"))
                            0x08
                        else if (std.mem.eql(u8, name, "HT"))
                            0x09
                        else if (std.mem.eql(u8, name, "LF"))
                            0x0a
                        else if (std.mem.eql(u8, name, "VT"))
                            0x0b
                        else if (std.mem.eql(u8, name, "FF"))
                            0x0c
                        else if (std.mem.eql(u8, name, "CR"))
                            0x0d
                        else if (std.mem.eql(u8, name, "SO"))
                            0x0e
                        else if (std.mem.eql(u8, name, "SI"))
                            0x0f
                        else if (std.mem.eql(u8, name, "DLE"))
                            0x10
                        else if (std.mem.eql(u8, name, "DC1"))
                            0x11
                        else if (std.mem.eql(u8, name, "DC2"))
                            0x12
                        else if (std.mem.eql(u8, name, "DC3"))
                            0x13
                        else if (std.mem.eql(u8, name, "DC4"))
                            0x14
                        else if (std.mem.eql(u8, name, "NAK"))
                            0x15
                        else if (std.mem.eql(u8, name, "SYN"))
                            0x16
                        else if (std.mem.eql(u8, name, "ETB"))
                            0x17
                        else if (std.mem.eql(u8, name, "CAN"))
                            0x18
                        else if (std.mem.eql(u8, name, "EM"))
                            0x19
                        else if (std.mem.eql(u8, name, "SUB"))
                            0x1a
                        else if (std.mem.eql(u8, name, "ESC"))
                            0x1b
                        else if (std.mem.eql(u8, name, "FS"))
                            0x1c
                        else if (std.mem.eql(u8, name, "GS"))
                            0x1d
                        else if (std.mem.eql(u8, name, "RS"))
                            0x1e
                        else if (std.mem.eql(u8, name, "US"))
                            0x1f
                        else if (std.mem.eql(u8, name, "SP"))
                            0x20
                        else
                            null;

                        if (named_char) |c| {
                            try result.append(self.allocator, c);
                            continue;
                        }
                        // Unknown named escape - output literally
                        try result.append(self.allocator, '\\');
                        try result.appendSlice(self.allocator, name);
                        continue;
                    }

                    // Decimal escape: \NNNN (digits after backslash)
                    if (std.ascii.isDigit(escape_char)) {
                        const dec_start = i;
                        while (i < s.len and std.ascii.isDigit(s[i])) {
                            i += 1;
                        }
                        const codepoint = std.fmt.parseInt(u21, s[dec_start..i], 10) catch {
                            try result.append(self.allocator, '\\');
                            try result.appendSlice(self.allocator, s[dec_start..i]);
                            continue;
                        };
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                            try result.append(self.allocator, '\\');
                            try result.appendSlice(self.allocator, s[dec_start..i]);
                            continue;
                        };
                        try result.appendSlice(self.allocator, buf[0..len]);
                        continue;
                    }

                    // Unknown escape - output literally
                    try result.append(self.allocator, '\\');
                    try result.append(self.allocator, escape_char);
                    i += 1;
                } else {
                    try result.append(self.allocator, s[i]);
                    i += 1;
                }
            }

            return result.toOwnedSlice(self.allocator);
        }

        fn findHexEnd(s: []const u8, start: usize, max_len: usize) usize {
            var end = start;
            while (end < s.len and end - start < max_len and std.ascii.isHex(s[end])) {
                end += 1;
            }
            return end;
        }

        fn findOctalEnd(s: []const u8, start: usize, max_len: usize) usize {
            var end = start;
            while (end < s.len and end - start < max_len and s[end] >= '0' and s[end] <= '7') {
                end += 1;
            }
            return end;
        }

        fn parsePlutusData(self: *Self) ParseError!*const PlutusData {
            switch (self.current.type) {
                .data_i => {
                    // I <integer>
                    self.advance();
                    try self.expect(.number);
                    const lexeme = self.previous.lexeme;
                    const is_negative = lexeme[0] == '-';
                    const digits = if (is_negative or lexeme[0] == '+') lexeme[1..] else lexeme;

                    const d = self.allocator.create(PlutusData) catch return error.OutOfMemory;
                    var managed = std.math.big.int.Managed.init(self.allocator) catch return error.OutOfMemory;
                    managed.setString(10, digits) catch return error.InvalidInteger;
                    if (is_negative) {
                        managed.negate();
                    }
                    d.* = .{ .integer = managed };
                    return d;
                },
                .data_b => {
                    // B <bytestring>
                    self.advance();
                    try self.expect(.byte_string);
                    const hex = self.previous.lexeme[1..];
                    const bytes = self.allocator.alloc(u8, hex.len / 2) catch return error.OutOfMemory;
                    for (0..hex.len / 2) |i| {
                        bytes[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return error.InvalidByteString;
                    }
                    return PlutusData.byteString(self.allocator, bytes) catch return error.OutOfMemory;
                },
                .data_list => {
                    // List [...]
                    self.advance();
                    try self.expect(.left_bracket);

                    var items: std.ArrayListUnmanaged(*const PlutusData) = .empty;
                    defer items.deinit(self.allocator);

                    while (self.current.type != .right_bracket and self.current.type != .eof) {
                        const item = try self.parsePlutusData();
                        items.append(self.allocator, item) catch return error.OutOfMemory;

                        if (self.current.type == .comma) {
                            self.advance();
                        }
                    }

                    try self.expect(.right_bracket);
                    const owned_items = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                    return PlutusData.listOf(self.allocator, owned_items) catch return error.OutOfMemory;
                },
                .data_map => {
                    // Map [(k, v), ...]
                    self.advance();
                    try self.expect(.left_bracket);

                    var pairs: std.ArrayListUnmanaged(PlutusDataPair) = .empty;
                    defer pairs.deinit(self.allocator);

                    while (self.current.type != .right_bracket and self.current.type != .eof) {
                        try self.expect(.left_paren);
                        const key = try self.parsePlutusData();
                        try self.expect(.comma);
                        const value = try self.parsePlutusData();
                        try self.expect(.right_paren);

                        pairs.append(self.allocator, .{ .key = key, .value = value }) catch return error.OutOfMemory;

                        if (self.current.type == .comma) {
                            self.advance();
                        }
                    }

                    try self.expect(.right_bracket);
                    const owned_pairs = pairs.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                    return PlutusData.mapOf(self.allocator, owned_pairs) catch return error.OutOfMemory;
                },
                .data_constr => {
                    // Constr <tag> [...]
                    self.advance();
                    try self.expect(.number);
                    const tag = std.fmt.parseInt(u64, self.previous.lexeme, 10) catch return error.InvalidInteger;

                    try self.expect(.left_bracket);

                    var fields: std.ArrayListUnmanaged(*const PlutusData) = .empty;
                    defer fields.deinit(self.allocator);

                    while (self.current.type != .right_bracket and self.current.type != .eof) {
                        const field = try self.parsePlutusData();
                        fields.append(self.allocator, field) catch return error.OutOfMemory;

                        if (self.current.type == .comma) {
                            self.advance();
                        }
                    }

                    try self.expect(.right_bracket);
                    const owned_fields = fields.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
                    return PlutusData.constrOf(self.allocator, tag, owned_fields) catch return error.OutOfMemory;
                },
                else => {
                    self.errorAtCurrent("Expected PlutusData (I, B, List, Map, or Constr)");
                    return error.UnexpectedToken;
                },
            }
        }

        fn advance(self: *Self) void {
            self.previous = self.current;
            self.current = self.lexer.nextToken();
        }

        fn expect(self: *Self, token_type: TokenType) ParseError!void {
            if (self.current.type == token_type) {
                self.advance();
                return;
            }
            self.errorAtCurrent("Unexpected token");
            return error.UnexpectedToken;
        }

        /// Intern a name - same text gets same unique ID.
        fn internName(self: *Self, text: []const u8) usize {
            if (self.interned.get(text)) |unique| {
                return unique;
            }
            const unique = self.unique_counter;
            self.unique_counter += 1;
            self.interned.put(self.allocator, text, unique) catch {};
            return unique;
        }

        fn errorAtCurrent(self: *Self, message: []const u8) void {
            self.errorAt(self.current, message);
        }

        fn errorAtPrevious(self: *Self, message: []const u8) void {
            self.errorAt(self.previous, message);
        }

        fn errorAt(self: *Self, token: Token, message: []const u8) void {
            if (self.had_error) return;
            self.had_error = true;
            self.error_message = message;
            _ = token;
        }
    };
}

/// Merge adjacent duplicate token entries (same name) by adding their quantities.
/// Input must already be sorted by name. Removes entries that sum to zero.
fn mergeTokenDuplicates(allocator: std.mem.Allocator, sorted: []const Value.TokenEntry) ![]const Value.TokenEntry {
    if (sorted.len <= 1) return sorted;

    var result: std.ArrayListUnmanaged(Value.TokenEntry) = .empty;
    defer result.deinit(allocator);

    var current_name = sorted[0].name;
    var current_qty = try Integer.init(allocator);
    try current_qty.copy(sorted[0].quantity.toConst());

    for (sorted[1..]) |entry| {
        if (std.mem.eql(u8, entry.name, current_name)) {
            // Same name - add quantities
            var entry_qty = entry.quantity;
            var sum = try Integer.init(allocator);
            try sum.add(&current_qty, &entry_qty);
            current_qty.deinit();
            current_qty = sum;
        } else {
            // Different name - flush current
            if (!current_qty.eqlZero()) {
                try result.append(allocator, .{ .name = current_name, .quantity = current_qty });
                current_qty = try Integer.init(allocator);
            }
            current_name = entry.name;
            try current_qty.copy(entry.quantity.toConst());
        }
    }
    // Flush last
    if (!current_qty.eqlZero()) {
        try result.append(allocator, .{ .name = current_name, .quantity = current_qty });
    }

    return result.toOwnedSlice(allocator);
}

/// Merge adjacent duplicate currency entries (same currency symbol) by merging their token lists.
/// Input must already be sorted by currency symbol.
fn mergeCurrencyDuplicates(allocator: std.mem.Allocator, sorted: []const Value.CurrencyEntry) ![]const Value.CurrencyEntry {
    if (sorted.len <= 1) return sorted;

    var result: std.ArrayListUnmanaged(Value.CurrencyEntry) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < sorted.len) {
        var j = i + 1;
        while (j < sorted.len and std.mem.eql(u8, sorted[i].currency, sorted[j].currency)) {
            j += 1;
        }

        if (j == i + 1) {
            // No duplicates for this currency
            try result.append(allocator, sorted[i]);
        } else {
            // Merge all token lists for duplicate currencies
            // Concatenate all tokens, sort, then merge duplicates
            var all_tokens: std.ArrayListUnmanaged(Value.TokenEntry) = .empty;
            defer all_tokens.deinit(allocator);
            var k = i;
            while (k < j) : (k += 1) {
                try all_tokens.appendSlice(allocator, sorted[k].tokens);
            }
            const all = try all_tokens.toOwnedSlice(allocator);
            std.mem.sort(Value.TokenEntry, all, {}, struct {
                fn lessThan(_: void, a: Value.TokenEntry, b: Value.TokenEntry) bool {
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lessThan);
            const merged = try mergeTokenDuplicates(allocator, all);
            if (merged.len > 0) {
                try result.append(allocator, .{ .currency = sorted[i].currency, .tokens = merged });
            }
        }
        i = j;
    }

    return result.toOwnedSlice(allocator);
}

test "parse simple program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "(program 1.0.0 (con integer 42))";
    var parser = Parser(Name).init(allocator, source);

    const program = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return err;
    };
    _ = program;
}

test "parse lambda" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "(program 1.0.0 (lam x x))";
    var parser = Parser(Name).init(allocator, source);

    const program = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return err;
    };

    try testing.expectEqual(Version.v1_0_0, program.version);
    try testing.expect(program.term.* == .lambda);
}

test "parse application" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "(program 1.0.0 [x y])";
    var parser = Parser(Name).init(allocator, source);

    const program = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return err;
    };

    try testing.expect(program.term.* == .apply);
}

test "parse builtin" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "(program 1.0.0 (builtin addInteger))";
    var parser = Parser(Name).init(allocator, source);

    const program = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return err;
    };

    try testing.expect(program.term.* == .builtin);
    try testing.expectEqual(DefaultFunction.add_integer, program.term.builtin);
}
