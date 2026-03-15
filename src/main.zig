const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Kassadin — Cardano Node in Zig\n", .{});
    try stdout.print("Version: 0.0.0 (Phase 0: Foundation)\n", .{});
    try stdout.print("Status: Scaffolding\n", .{});
}

test "placeholder" {
    try std.testing.expect(true);
}
