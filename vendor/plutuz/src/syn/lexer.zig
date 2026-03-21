//! Hand-written lexer for UPLC.
//! Tokenizes UPLC source code into a stream of tokens.

const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const keywords = @import("token.zig").keywords;

/// A lexer for UPLC source code.
pub const Lexer = struct {
    /// The source code being lexed
    source: []const u8,
    /// Current position in the source
    pos: usize,
    /// Start position of the current token
    start: usize,
    /// Current line number (1-based)
    line: usize,
    /// Current column number (1-based)
    column: usize,
    /// Column at start of current token
    start_column: usize,

    /// Initialize a new lexer.
    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .start = 0,
            .line = 1,
            .column = 1,
            .start_column = 1,
        };
    }

    /// Get the next token from the source.
    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        self.start = self.pos;
        self.start_column = self.column;

        if (self.isAtEnd()) {
            return Token.eof(self.pos, self.line, self.column);
        }

        const c = self.advance();

        return switch (c) {
            '(' => self.handleLeftParen(),
            ')' => self.makeToken(.right_paren),
            '[' => self.makeToken(.left_bracket),
            ']' => self.makeToken(.right_bracket),
            '.' => self.makeToken(.dot),
            ',' => self.makeToken(.comma),
            '"' => self.string(),
            '#' => self.byteString(),
            '0' => self.handleZero(),
            '1'...'9' => self.number(),
            '-', '+' => self.signedNumber(),
            else => if (isAlpha(c)) self.identifier() else self.errorToken("Unexpected character"),
        };
    }

    fn handleLeftParen(self: *Lexer) Token {
        // Check for unit ()
        if (self.peek() == ')') {
            _ = self.advance();
            return self.makeToken(.unit);
        }
        return self.makeToken(.left_paren);
    }

    fn handleZero(self: *Lexer) Token {
        // Check for 0x prefix (BLS point)
        if (self.peek() == 'x') {
            _ = self.advance();
            return self.hexLiteral(.point);
        }
        return self.number();
    }

    fn signedNumber(self: *Lexer) Token {
        if (isDigit(self.peek())) {
            return self.number();
        }
        // It's just a sign character, treat as identifier
        return self.identifier();
    }

    fn number(self: *Lexer) Token {
        while (isDigit(self.peek())) {
            _ = self.advance();
        }
        return self.makeToken(.number);
    }

    fn hexLiteral(self: *Lexer, token_type: TokenType) Token {
        while (isHexDigit(self.peek())) {
            _ = self.advance();
        }
        const lexeme = self.currentLexeme();
        // For byte strings, we need to check even length
        // The prefix is either '#' (1 char) or '0x' (2 chars)
        const hex_start: usize = if (token_type == .point) 2 else 1;
        const hex_len = lexeme.len - hex_start;
        if (token_type == .byte_string and hex_len % 2 != 0) {
            return self.errorToken("Byte string must have even length");
        }
        return self.makeToken(token_type);
    }

    fn byteString(self: *Lexer) Token {
        return self.hexLiteral(.byte_string);
    }

    fn string(self: *Lexer) Token {
        while (!self.isAtEnd() and self.peek() != '"') {
            if (self.peek() == '\n') {
                self.line += 1;
                self.column = 0;
            }
            if (self.peek() == '\\' and !self.isAtEnd()) {
                _ = self.advance(); // Skip the backslash
                if (!self.isAtEnd()) {
                    _ = self.advance(); // Skip the escaped character
                }
            } else {
                _ = self.advance();
            }
        }

        if (self.isAtEnd()) {
            return self.errorToken("Unterminated string");
        }

        // Consume the closing quote
        _ = self.advance();
        return self.makeToken(.string);
    }

    fn identifier(self: *Lexer) Token {
        while (isAlphaNumeric(self.peek()) or self.peek() == '_' or self.peek() == '\'' or self.peek() == '-') {
            _ = self.advance();
        }

        const lexeme = self.currentLexeme();
        const token_type = keywords.get(lexeme) orelse .identifier;
        return self.makeToken(token_type);
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\r', '\t' => {
                    _ = self.advance();
                },
                '\n' => {
                    self.line += 1;
                    self.column = 0;
                    _ = self.advance();
                },
                '-' => {
                    if (self.peekNext() == '-') {
                        // Comment - skip until end of line
                        while (!self.isAtEnd() and self.peek() != '\n') {
                            _ = self.advance();
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.pos >= self.source.len;
    }

    fn peek(self: *Lexer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.pos];
    }

    fn peekNext(self: *Lexer) u8 {
        if (self.pos + 1 >= self.source.len) return 0;
        return self.source[self.pos + 1];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        self.column += 1;
        return c;
    }

    fn currentLexeme(self: *Lexer) []const u8 {
        return self.source[self.start..self.pos];
    }

    fn makeToken(self: *Lexer, token_type: TokenType) Token {
        return .{
            .type = token_type,
            .lexeme = self.currentLexeme(),
            .position = self.start,
            .line = self.line,
            .column = self.start_column,
        };
    }

    fn errorToken(self: *Lexer, message: []const u8) Token {
        return Token.err(message, self.start, self.line, self.start_column);
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isAlphaNumeric(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

test "lexer basic tokens" {
    const testing = std.testing;

    var lexer = Lexer.init("( ) [ ] . ,");

    try testing.expectEqual(TokenType.left_paren, lexer.nextToken().type);
    try testing.expectEqual(TokenType.right_paren, lexer.nextToken().type);
    try testing.expectEqual(TokenType.left_bracket, lexer.nextToken().type);
    try testing.expectEqual(TokenType.right_bracket, lexer.nextToken().type);
    try testing.expectEqual(TokenType.dot, lexer.nextToken().type);
    try testing.expectEqual(TokenType.comma, lexer.nextToken().type);
    try testing.expectEqual(TokenType.eof, lexer.nextToken().type);
}

test "lexer unit token" {
    const testing = std.testing;

    var lexer = Lexer.init("()");
    const tok = lexer.nextToken();

    try testing.expectEqual(TokenType.unit, tok.type);
    try testing.expectEqualStrings("()", tok.lexeme);
}

test "lexer numbers" {
    const testing = std.testing;

    var lexer = Lexer.init("123 -456 +789 0");

    var tok = lexer.nextToken();
    try testing.expectEqual(TokenType.number, tok.type);
    try testing.expectEqualStrings("123", tok.lexeme);

    tok = lexer.nextToken();
    try testing.expectEqual(TokenType.number, tok.type);
    try testing.expectEqualStrings("-456", tok.lexeme);

    tok = lexer.nextToken();
    try testing.expectEqual(TokenType.number, tok.type);
    try testing.expectEqualStrings("+789", tok.lexeme);

    tok = lexer.nextToken();
    try testing.expectEqual(TokenType.number, tok.type);
    try testing.expectEqualStrings("0", tok.lexeme);
}

test "lexer strings" {
    const testing = std.testing;

    var lexer = Lexer.init("\"hello world\"");
    const tok = lexer.nextToken();

    try testing.expectEqual(TokenType.string, tok.type);
    try testing.expectEqualStrings("\"hello world\"", tok.lexeme);
}

test "lexer byte strings" {
    const testing = std.testing;

    var lexer = Lexer.init("#deadBEEF");
    const tok = lexer.nextToken();

    try testing.expectEqual(TokenType.byte_string, tok.type);
    try testing.expectEqualStrings("#deadBEEF", tok.lexeme);
}

test "lexer identifiers and keywords" {
    const testing = std.testing;

    var lexer = Lexer.init("lam x con builtin foo'bar addInteger");

    try testing.expectEqual(TokenType.lam, lexer.nextToken().type);
    try testing.expectEqual(TokenType.identifier, lexer.nextToken().type);
    try testing.expectEqual(TokenType.con, lexer.nextToken().type);
    try testing.expectEqual(TokenType.builtin, lexer.nextToken().type);

    const tok = lexer.nextToken();
    try testing.expectEqual(TokenType.identifier, tok.type);
    try testing.expectEqualStrings("foo'bar", tok.lexeme);

    try testing.expectEqual(TokenType.identifier, lexer.nextToken().type);
}

test "lexer comments" {
    const testing = std.testing;

    var lexer = Lexer.init(
        \\-- this is a comment
        \\42
    );

    const tok = lexer.nextToken();
    try testing.expectEqual(TokenType.number, tok.type);
    try testing.expectEqualStrings("42", tok.lexeme);
}

test "lexer booleans" {
    const testing = std.testing;

    var lexer = Lexer.init("True False");

    try testing.expectEqual(TokenType.true_, lexer.nextToken().type);
    try testing.expectEqual(TokenType.false_, lexer.nextToken().type);
}

test "lexer program" {
    const testing = std.testing;

    var lexer = Lexer.init("(program 1.0.0 (con integer 42))");

    try testing.expectEqual(TokenType.left_paren, lexer.nextToken().type);
    try testing.expectEqual(TokenType.program, lexer.nextToken().type);

    const version = lexer.nextToken();
    try testing.expectEqual(TokenType.number, version.type);

    try testing.expectEqual(TokenType.dot, lexer.nextToken().type);

    const minor = lexer.nextToken();
    try testing.expectEqual(TokenType.number, minor.type);

    try testing.expectEqual(TokenType.dot, lexer.nextToken().type);
    try testing.expectEqual(TokenType.number, lexer.nextToken().type);
    try testing.expectEqual(TokenType.left_paren, lexer.nextToken().type);
    try testing.expectEqual(TokenType.con, lexer.nextToken().type);
}
