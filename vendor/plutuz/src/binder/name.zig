//! Name binder for UPLC.
//! Names consist of a text identifier and a unique number for disambiguation.

const std = @import("std");

/// A name binder with text and unique identifier.
/// This is the human-readable representation used in source code.
pub const Name = struct {
    /// The textual name
    text: []const u8,
    /// Unique identifier for disambiguation
    unique: usize,

    /// Create a new name.
    pub fn create(allocator: std.mem.Allocator, txt: []const u8, uniq: usize) !*const Name {
        const n = try allocator.create(Name);
        n.* = .{
            .text = txt,
            .unique = uniq,
        };
        return n;
    }

    /// Format the name for display (writes to a buffer).
    pub fn writeTo(self: Name, writer: anytype) !void {
        try writer.writeAll(self.text);
    }
};

test "name creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const n = try Name.create(allocator, "foo", 0);
    defer allocator.destroy(n);

    try testing.expectEqualStrings("foo", n.text);
    try testing.expectEqual(@as(usize, 0), n.unique);
}
