//! NamedDeBruijn binder for UPLC.
//! Combines a human-readable name with a DeBruijn index.

const std = @import("std");

/// A binder that combines a textual name with a DeBruijn index.
/// This provides both human readability and precise binding information.
pub const NamedDeBruijn = struct {
    /// The textual name (for display purposes)
    text: []const u8,
    /// The DeBruijn index
    index: usize,

    /// Create a new NamedDeBruijn binder.
    pub fn create(allocator: std.mem.Allocator, txt: []const u8, idx: usize) !*const NamedDeBruijn {
        const ndb = try allocator.create(NamedDeBruijn);
        ndb.* = .{
            .text = txt,
            .index = idx,
        };
        return ndb;
    }

    /// Write to a writer.
    pub fn writeTo(self: NamedDeBruijn, writer: anytype) !void {
        try writer.writeAll(self.text);
    }
};

test "named_debruijn creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ndb = try NamedDeBruijn.create(allocator, "x", 1);
    defer allocator.destroy(ndb);

    try testing.expectEqualStrings("x", ndb.text);
    try testing.expectEqual(@as(usize, 1), ndb.index);
}
