const std = @import("std");
const Allocator = std.mem.Allocator;
const mux = @import("mux.zig");
const protocol = @import("protocol.zig");
const handshake = @import("handshake.zig");
const chainsync = @import("chainsync.zig");
const blockfetch = @import("blockfetch.zig");
const keepalive = @import("keepalive.zig");
const txsubmission = @import("txsubmission.zig");
const peersharing = @import("peersharing.zig");

/// High-level peer connection. Manages TCP, mux, handshake, and protocol sessions.
pub const Peer = struct {
    allocator: Allocator,
    stream: std.net.Stream,
    bearer: mux.Bearer,
    negotiated_version: ?u64,
    last_cs_response: ?[]u8 = null,

    /// Connect to a Cardano node via TCP and perform N2N handshake.
    pub fn connect(allocator: Allocator, host: []const u8, port: u16, magic: u32) !Peer {
        const stream = try std.net.tcpConnectToHost(allocator, host, port);
        errdefer stream.close();

        var self = Peer{
            .allocator = allocator,
            .stream = stream,
            .bearer = mux.tcpBearer(stream),
            .negotiated_version = null,
        };

        // Perform handshake
        const result = try handshake.performHandshake(allocator, &self.bearer, magic);
        switch (result) {
            .accepted => |a| {
                self.negotiated_version = a.version;
            },
            .refused => return error.HandshakeRefused,
        }

        return self;
    }

    pub fn close(self: *Peer) void {
        if (self.last_cs_response) |resp| self.allocator.free(resp);
        self.bearer.deinit();
    }

    // ── Chain-Sync operations ──

    /// Send MsgFindIntersect.
    pub fn chainSyncFindIntersect(self: *Peer, points: []const chainsync.Point) !chainsync.ChainSyncMsg {
        const msg_bytes = try chainsync.encodeMsg(self.allocator, .{
            .find_intersect = .{ .points = points },
        });
        defer self.allocator.free(msg_bytes);

        try self.bearer.writeSDU(
            @intFromEnum(protocol.MiniProtocolNum.chain_sync),
            .initiator,
            msg_bytes,
        );

        if (self.last_cs_response) |prev| {
            self.allocator.free(prev);
            self.last_cs_response = null;
        }

        const response = try self.bearer.readProtocolMessage(
            @intFromEnum(protocol.MiniProtocolNum.chain_sync),
            self.allocator,
        );
        self.last_cs_response = response;

        return chainsync.decodeMsg(response);
    }

    /// Send MsgRequestNext and read the response.
    /// Note: The returned ChainSyncMsg may contain slices (header_raw) that point
    /// into an internal buffer. These are only valid until the next call to
    /// chainSyncRequestNext. For long-lived header data, copy it immediately.
    pub fn chainSyncRequestNext(self: *Peer) !chainsync.ChainSyncMsg {
        const msg_bytes = try chainsync.encodeMsg(self.allocator, .request_next);
        defer self.allocator.free(msg_bytes);

        try self.bearer.writeSDU(
            @intFromEnum(protocol.MiniProtocolNum.chain_sync),
            .initiator,
            msg_bytes,
        );

        // Free previous response if any
        if (self.last_cs_response) |prev| {
            self.allocator.free(prev);
            self.last_cs_response = null;
        }

        const response = try self.bearer.readProtocolMessage(
            @intFromEnum(protocol.MiniProtocolNum.chain_sync),
            self.allocator,
        );
        self.last_cs_response = response;

        return chainsync.decodeMsg(response);
    }

    // ── Keep-Alive operations ──

    /// Send a keep-alive ping and expect a response with matching cookie.
    pub fn keepAlivePing(self: *Peer, cookie: u16) !u16 {
        const msg_bytes = try keepalive.encodeMsg(self.allocator, .{ .keep_alive = cookie });
        defer self.allocator.free(msg_bytes);

        try self.bearer.writeSDU(
            @intFromEnum(protocol.MiniProtocolNum.keep_alive),
            .initiator,
            msg_bytes,
        );

        const response = try self.bearer.readProtocolMessage(
            @intFromEnum(protocol.MiniProtocolNum.keep_alive),
            self.allocator,
        );
        defer self.allocator.free(response);

        const resp_msg = try keepalive.decodeMsg(response);
        switch (resp_msg) {
            .keep_alive_response => |c| return c,
            else => return error.UnexpectedMessage,
        }
    }

    // ── Block-Fetch operations ──

    /// Request a single block by its point and return the full block CBOR.
    /// Returns owned allocation — caller must free.
    pub fn blockFetchSingle(self: *Peer, point: chainsync.Point) !?[]u8 {
        const msg_bytes = try blockfetch.encodeMsg(self.allocator, .{
            .request_range = .{ .from = point, .to = point },
        });
        defer self.allocator.free(msg_bytes);

        try self.bearer.writeSDU(
            @intFromEnum(protocol.MiniProtocolNum.block_fetch),
            .initiator,
            msg_bytes,
        );

        // Read StartBatch or NoBlocks
        const response1 = try self.bearer.readProtocolMessage(
            @intFromEnum(protocol.MiniProtocolNum.block_fetch),
            self.allocator,
        );
        defer self.allocator.free(response1);

        const resp_msg = try blockfetch.decodeMsg(response1);
        switch (resp_msg) {
            .start_batch => {
                // Read the block: [4, block_cbor]
                const block_msg = try self.bearer.readProtocolMessage(
                    @intFromEnum(protocol.MiniProtocolNum.block_fetch),
                    self.allocator,
                );
                defer self.allocator.free(block_msg);

                const block_response = try blockfetch.decodeMsg(block_msg);
                const block_raw = switch (block_response) {
                    .block => |raw| try self.allocator.dupe(u8, raw),
                    else => return error.UnexpectedMessage,
                };

                // Read BatchDone
                const done_msg = try self.bearer.readProtocolMessage(
                    @intFromEnum(protocol.MiniProtocolNum.block_fetch),
                    self.allocator,
                );
                defer self.allocator.free(done_msg);

                return block_raw;
            },
            .no_blocks => return null,
            else => return error.UnexpectedMessage,
        }
    }

    // ── Tx-Submission operations ──

    /// Send MsgInit for tx-submission protocol.
    pub fn txSubmissionInit(self: *Peer) !void {
        const msg_bytes = try txsubmission.encodeMsg(self.allocator, .init);
        defer self.allocator.free(msg_bytes);

        try self.bearer.writeSDU(
            @intFromEnum(protocol.MiniProtocolNum.tx_submission),
            .initiator,
            msg_bytes,
        );
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "peer: type has expected fields" {
    // Structural test — verify Peer struct compiles with all fields
    const p: Peer = undefined;
    _ = p.allocator;
    _ = p.stream;
    _ = p.bearer;
    _ = p.negotiated_version;
}
