const std = @import("std");

/// Agency indicates which side of a protocol has the right to send the next message.
pub const Agency = enum {
    client, // Client (initiator) has agency
    server, // Server (responder) has agency
    none, // Terminal state — no agency
};

/// Mini-protocol numbers as assigned in the Ouroboros network specification.
pub const MiniProtocolNum = enum(u15) {
    handshake = 0,
    chain_sync = 2,
    block_fetch = 3,
    tx_submission = 4,
    chain_sync_local = 5,
    local_tx_submission = 6,
    local_state_query = 7,
    keep_alive = 8,
    local_tx_monitor = 9,
    peer_sharing = 10,
};

/// Timeout values from the Haskell reference implementation (seconds).
pub const Timeouts = struct {
    // Chain-Sync
    pub const chain_sync_idle: u64 = 3673;
    pub const chain_sync_can_await: u64 = 10;
    pub const chain_sync_must_reply_min: u64 = 601;
    pub const chain_sync_must_reply_max: u64 = 911;
    pub const chain_sync_intersect: u64 = 10;

    // Block-Fetch
    pub const block_fetch_busy: u64 = 60;
    pub const block_fetch_streaming: u64 = 60;

    // Tx-Submission
    pub const tx_submission_blocking: u64 = 0; // wait forever
    pub const tx_submission_nonblocking: u64 = 10;
    pub const tx_submission_txs: u64 = 10;

    // Keep-Alive
    pub const keep_alive_client: u64 = 97;
    pub const keep_alive_server: u64 = 60;

    // Peer-Sharing
    pub const peer_sharing_busy: u64 = 60;

    // Handshake
    pub const handshake: u64 = 10;
};

/// Per-protocol size limits (bytes) from the Haskell reference.
pub const SizeLimits = struct {
    pub const handshake: usize = 5760; // 4 TCP segments @ 1440
    pub const chain_sync: usize = 65535;
    pub const block_fetch_idle: usize = 65535;
    pub const block_fetch_streaming: usize = 2_500_000;
    pub const tx_submission_idle: usize = 5760;
    pub const tx_submission_data: usize = 2_500_000;
    pub const keep_alive: usize = 1408;
    pub const peer_sharing: usize = 5760;
};

/// Per-protocol ingress buffer sizes (bytes) from N2N defaults.
pub const IngressBufferSizes = struct {
    pub const chain_sync: usize = 462_000;
    pub const block_fetch: usize = 230_686_940;
    pub const tx_submission: usize = 721_424;
    pub const keep_alive: usize = 1_408;
    pub const peer_sharing: usize = 5_760;
};

/// Network magic values for known Cardano networks.
pub const NetworkMagic = struct {
    pub const mainnet: u32 = 764824073;
    pub const preprod: u32 = 1;
    pub const preview: u32 = 2;
};

/// NodeToNode protocol versions currently supported.
pub const N2NVersion = enum(u64) {
    v14 = 14,
    v15 = 15,
};

/// Peer sharing mode for version negotiation.
pub const PeerSharing = enum(u8) {
    disabled = 0,
    enabled = 1,
};

/// Version data exchanged during N2N handshake.
pub const N2NVersionData = struct {
    network_magic: u32,
    initiator_only: bool,
    peer_sharing: PeerSharing,
    query: bool,
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "protocol: mini-protocol numbers match spec" {
    try std.testing.expectEqual(@as(u15, 0), @intFromEnum(MiniProtocolNum.handshake));
    try std.testing.expectEqual(@as(u15, 2), @intFromEnum(MiniProtocolNum.chain_sync));
    try std.testing.expectEqual(@as(u15, 3), @intFromEnum(MiniProtocolNum.block_fetch));
    try std.testing.expectEqual(@as(u15, 4), @intFromEnum(MiniProtocolNum.tx_submission));
    try std.testing.expectEqual(@as(u15, 8), @intFromEnum(MiniProtocolNum.keep_alive));
    try std.testing.expectEqual(@as(u15, 10), @intFromEnum(MiniProtocolNum.peer_sharing));
}

test "protocol: network magic values" {
    try std.testing.expectEqual(@as(u32, 764824073), NetworkMagic.mainnet);
    try std.testing.expectEqual(@as(u32, 2), NetworkMagic.preview);
    try std.testing.expectEqual(@as(u32, 1), NetworkMagic.preprod);
}

test "protocol: size limits" {
    // Verify critical size limits match Haskell defaults
    try std.testing.expectEqual(@as(usize, 12288), @import("mux.zig").max_sdu_payload);
    try std.testing.expectEqual(@as(usize, 2_500_000), SizeLimits.block_fetch_streaming);
    try std.testing.expectEqual(@as(usize, 5760), SizeLimits.handshake);
}
