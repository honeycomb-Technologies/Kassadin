//! DeBruijn binder for UPLC.
//! DeBruijn indices represent variables by their binding depth.

const std = @import("std");

/// A DeBruijn index binder.
/// Variables are represented by the number of lambda abstractions
/// between the variable and its binding site.
pub const DeBruijn = struct {
    /// The DeBruijn index (0-based)
    index: usize,

    /// Create a new DeBruijn binder.
    pub fn create(allocator: std.mem.Allocator, idx: usize) !*const DeBruijn {
        const d = try allocator.create(DeBruijn);
        d.* = .{ .index = idx };
        return d;
    }

    /// Write to a writer.
    pub fn writeTo(self: DeBruijn, writer: anytype) !void {
        try writer.print("i{d}", .{self.index});
    }
};

test "debruijn creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const db = try DeBruijn.create(allocator, 3);
    defer allocator.destroy(db);

    try testing.expectEqual(@as(usize, 3), db.index);
}
