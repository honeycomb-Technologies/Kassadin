//! Program wrapper for UPLC.
//! A program consists of a version number and a term.

const std = @import("std");
const term_mod = @import("term.zig");

/// Semantic versioning for UPLC programs.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    /// Create a version from components.
    pub fn create(major: u32, minor: u32, patch: u32) Version {
        return .{
            .major = major,
            .minor = minor,
            .patch = patch,
        };
    }

    /// Parse a version string like "1.0.0".
    pub fn parse(s: []const u8) !Version {
        var parts = std.mem.splitScalar(u8, s, '.');
        const major_str = parts.next() orelse return error.InvalidVersion;
        const minor_str = parts.next() orelse return error.InvalidVersion;
        const patch_str = parts.next() orelse return error.InvalidVersion;

        if (parts.next() != null) return error.InvalidVersion;

        return .{
            .major = try std.fmt.parseInt(u32, major_str, 10),
            .minor = try std.fmt.parseInt(u32, minor_str, 10),
            .patch = try std.fmt.parseInt(u32, patch_str, 10),
        };
    }

    /// Write the version to a writer.
    pub fn writeTo(self: Version, writer: anytype) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }

    /// The default version for current Plutus.
    pub const v1_0_0: Version = .{ .major = 1, .minor = 0, .patch = 0 };
    pub const v1_1_0: Version = .{ .major = 1, .minor = 1, .patch = 0 };
};

/// A UPLC program with version information.
pub fn Program(comptime Binder: type) type {
    const Term = term_mod.Term(Binder);

    return struct {
        /// The program version
        version: Version,
        /// The program's term
        term: *const Term,

        const Self = @This();

        /// Create a new program.
        pub fn create(allocator: std.mem.Allocator, version: Version, t: *const Term) !*const Self {
            const p = try allocator.create(Self);
            p.* = .{
                .version = version,
                .term = t,
            };
            return p;
        }
    };
}

test "version parsing" {
    const testing = std.testing;

    const v = try Version.parse("1.0.0");
    try testing.expectEqual(@as(u32, 1), v.major);
    try testing.expectEqual(@as(u32, 0), v.minor);
    try testing.expectEqual(@as(u32, 0), v.patch);
}

test "version writeTo" {
    const testing = std.testing;

    const v = Version.create(1, 2, 3);
    var buf: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try v.writeTo(stream.writer());
    try testing.expectEqualStrings("1.2.3", stream.getWritten());
}

test "program creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Name = @import("../binder/name.zig").Name;

    const NameTerm = term_mod.Term(Name);
    const NameProgram = Program(Name);

    const n = try Name.create(allocator, "x", 0);
    defer allocator.destroy(n);

    const t = try NameTerm.variable(allocator, n);
    defer allocator.destroy(t);

    const prog = try NameProgram.create(allocator, Version.v1_0_0, t);
    defer allocator.destroy(prog);

    try testing.expectEqual(@as(u32, 1), prog.version.major);
}
