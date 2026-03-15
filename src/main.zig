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
    pub const blockfetch = @import("network/blockfetch.zig");
    pub const txsubmission = @import("network/txsubmission.zig");
    pub const keepalive = @import("network/keepalive.zig");
    pub const peersharing = @import("network/peersharing.zig");
    pub const peer = @import("network/peer.zig");
};

pub const storage = struct {
    pub const immutable = @import("storage/immutable.zig");
    pub const volatile_db = @import("storage/volatile.zig");
    pub const ledger = @import("storage/ledger.zig");
    pub const chaindb = @import("storage/chaindb.zig");
};

pub const ledger = struct {
    pub const block = @import("ledger/block.zig");
    pub const transaction = @import("ledger/transaction.zig");
    pub const rules = @import("ledger/rules.zig");
    pub const multiasset = @import("ledger/multiasset.zig");
    pub const certificates = @import("ledger/certificates.zig");
    pub const scripts = @import("ledger/scripts.zig");
    pub const plutus = @import("ledger/plutus.zig");
    pub const stake = @import("ledger/stake.zig");
    pub const apply = @import("ledger/apply.zig");
    pub const rewards = @import("ledger/rewards.zig");
};

pub const consensus = struct {
    pub const praos = @import("consensus/praos.zig");
};

pub const mempool = @import("mempool/mempool.zig");
pub const node = @import("node/node.zig");

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("Kassadin — Cardano Node in Zig\n", .{});
    try w.interface.print("Version: 0.0.0 (Phase 0: Foundation)\n", .{});
    try w.interface.print("Status: Crypto + CBOR complete\n", .{});
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
