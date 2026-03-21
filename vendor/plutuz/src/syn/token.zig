//! Token types for the UPLC lexer.

const std = @import("std");

/// Token types produced by the lexer.
pub const TokenType = enum {
    // End of file
    eof,
    // Error token
    err,

    // Punctuation
    left_paren, // (
    right_paren, // )
    left_bracket, // [
    right_bracket, // ]
    dot, // .
    comma, // ,

    // Literals
    number, // e.g., 123, -456
    identifier, // e.g., x, addInteger
    string, // e.g., "hello"
    byte_string, // e.g., #aaBB
    point, // e.g., 0xc000...

    // Boolean literals
    true_, // True
    false_, // False

    // Unit
    unit, // ()

    // Keywords
    lam, // lam
    delay, // delay
    force, // force
    builtin, // builtin
    constr, // constr
    case, // case
    con, // con
    error_, // error
    program, // program

    // Type keywords
    list, // list
    array, // array
    pair, // pair

    // Data constructors
    data_i, // I (integer data)
    data_b, // B (bytestring data)
    data_list, // List
    data_map, // Map
    data_constr, // Constr
};

/// A token produced by the lexer.
pub const Token = struct {
    /// The type of this token
    type: TokenType,
    /// The source text of this token
    lexeme: []const u8,
    /// Position in the source (byte offset)
    position: usize,
    /// Line number (1-based)
    line: usize,
    /// Column number (1-based)
    column: usize,

    /// Create an end-of-file token.
    pub fn eof(position: usize, line: usize, column: usize) Token {
        return .{
            .type = .eof,
            .lexeme = "",
            .position = position,
            .line = line,
            .column = column,
        };
    }

    /// Create an error token.
    pub fn err(message: []const u8, position: usize, line: usize, column: usize) Token {
        return .{
            .type = .err,
            .lexeme = message,
            .position = position,
            .line = line,
            .column = column,
        };
    }

    /// Write the token to a writer for debugging.
    pub fn writeTo(self: Token, writer: anytype) !void {
        try writer.print("{s}('{s}' @ {d}:{d})", .{
            @tagName(self.type),
            self.lexeme,
            self.line,
            self.column,
        });
    }
};

/// Keyword lookup table.
pub const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "lam", .lam },
    .{ "delay", .delay },
    .{ "force", .force },
    .{ "builtin", .builtin },
    .{ "constr", .constr },
    .{ "case", .case },
    .{ "con", .con },
    .{ "error", .error_ },
    .{ "program", .program },
    .{ "list", .list },
    .{ "array", .array },
    .{ "pair", .pair },
    .{ "True", .true_ },
    .{ "False", .false_ },
    .{ "I", .data_i },
    .{ "B", .data_b },
    .{ "List", .data_list },
    .{ "Map", .data_map },
    .{ "Constr", .data_constr },
});

test "keyword lookup" {
    const testing = std.testing;

    try testing.expectEqual(TokenType.lam, keywords.get("lam").?);
    try testing.expectEqual(TokenType.true_, keywords.get("True").?);
    try testing.expectEqual(TokenType.data_i, keywords.get("I").?);
    try testing.expect(keywords.get("notAKeyword") == null);
}

test "token writeTo" {
    const testing = std.testing;

    const tok = Token{
        .type = .identifier,
        .lexeme = "foo",
        .position = 10,
        .line = 2,
        .column = 5,
    };

    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try tok.writeTo(stream.writer());
    try testing.expectEqualStrings("identifier('foo' @ 2:5)", stream.getWritten());
}
