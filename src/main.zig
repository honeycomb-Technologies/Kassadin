const std = @import("std");

pub const crypto = struct {
    pub const hash = @import("crypto/hash.zig");
    pub const ed25519 = @import("crypto/ed25519.zig");
    pub const vrf = @import("crypto/vrf.zig");
    pub const kes = @import("crypto/kes.zig");
    pub const opcert = @import("crypto/opcert.zig");
    pub const bech32 = @import("crypto/bech32.zig");
};

pub const cbor = @import("cbor/cbor.zig");
pub const types = @import("types.zig");

pub const network = struct {
    pub const protocol = @import("network/protocol.zig");
    pub const mux = @import("network/mux.zig");
    pub const handshake = @import("network/handshake.zig");
    pub const chainsync = @import("network/chainsync.zig");
    pub const keepalive = @import("network/keepalive.zig");
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Kassadin — Cardano Node in Zig\n", .{});
    try stdout.print("Version: 0.0.0 (Phase 0: Foundation)\n", .{});
    try stdout.print("Status: Crypto + CBOR complete\n", .{});
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
