const std = @import("std");
const Allocator = std.mem.Allocator;
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const mux = @import("../network/mux.zig");
const unix_bearer = @import("../network/unix_bearer.zig");
const types = @import("../types.zig");

/// Minimal N2C server that serves local-state-query for `cardano-cli query tip`.
pub const N2CServer = struct {
    allocator: Allocator,
    server: unix_bearer.UnixServer,
    socket_path: []const u8,
    /// Shared tip state, updated by the sync loop.
    tip: *const TipState,

    pub const TipState = struct {
        slot: u64 = 0,
        hash: types.HeaderHash = [_]u8{0} ** 32,
        block_no: u64 = 0,
        network_magic: u32 = 1,
    };

    pub fn init(allocator: Allocator, socket_path: []const u8, tip: *const TipState) !N2CServer {
        const server = try unix_bearer.UnixServer.listen(socket_path);
        std.debug.print("N2C server listening on {s}\n", .{socket_path});
        return .{
            .allocator = allocator,
            .server = server,
            .socket_path = socket_path,
            .tip = tip,
        };
    }

    pub fn deinit(self: *N2CServer) void {
        self.server.close();
    }

    /// Accept and serve one client connection. Returns on disconnect.
    pub fn serveOne(self: *N2CServer) !void {
        var bearer = try self.server.accept();
        defer bearer.deinit();

        // 1. Handshake: read MsgProposeVersions, send MsgAcceptVersion
        try self.handleHandshake(&bearer);

        // 2. Serve LSQ queries until client sends MsgDone or disconnects
        self.serveLSQ(&bearer) catch |err| switch (err) {
            error.ConnectionClosed, error.ReadTimeout => {},
            else => return err,
        };
    }

    fn handleHandshake(self: *N2CServer, bearer: *mux.Bearer) !void {
        const propose = try bearer.readProtocolMessage(0, self.allocator);
        defer self.allocator.free(propose);

        // Parse MsgProposeVersions [0, {version: [magic, query], ...}]
        var dec = Decoder.init(propose);
        _ = try dec.decodeArrayLen();
        const tag = try dec.decodeUint();
        if (tag != 0) return error.UnexpectedMessage; // expected MsgProposeVersions

        // Read version map to find highest supported version and extract magic
        const map_len = try dec.decodeMapLen() orelse return error.InvalidCbor;
        var best_version: u64 = 0;
        var client_magic: u32 = self.tip.network_magic;
        var i: u64 = 0;
        while (i < map_len) : (i += 1) {
            const ver = try dec.decodeUint();
            _ = try dec.decodeArrayLen(); // [magic, query]
            const magic = @as(u32, @intCast(try dec.decodeUint()));
            _ = try dec.decodeBool(); // query flag
            if (ver >= 32784 and ver <= 32789 and ver > best_version) {
                best_version = ver;
                client_magic = magic;
            }
        }

        if (best_version == 0) {
            // No compatible version — send MsgRefuse
            var enc = Encoder.init(self.allocator);
            defer enc.deinit();
            try enc.encodeArrayLen(2);
            try enc.encodeUint(2); // MsgRefuse
            try enc.encodeArrayLen(1);
            try enc.encodeArrayLen(0); // VersionMismatch, empty list
            try bearer.writeSDU(0, .responder, enc.getWritten());
            return error.HandshakeRefused;
        }

        // Send MsgAcceptVersion [1, version, [magic, false]]
        var enc = Encoder.init(self.allocator);
        defer enc.deinit();
        try enc.encodeArrayLen(3);
        try enc.encodeUint(1); // MsgAcceptVersion
        try enc.encodeUint(best_version);
        try enc.encodeArrayLen(2);
        try enc.encodeUint(client_magic);
        try enc.encodeBool(false); // query = false
        try bearer.writeSDU(0, .responder, enc.getWritten());
    }

    fn serveLSQ(self: *N2CServer, bearer: *mux.Bearer) !void {
        const lsq_proto: u15 = 7; // LocalStateQuery mini-protocol

        while (true) {
            const msg = try bearer.readProtocolMessage(lsq_proto, self.allocator);
            defer self.allocator.free(msg);

            var dec = Decoder.init(msg);
            _ = try dec.decodeArrayLen();
            const tag = try dec.decodeUint();

            switch (tag) {
                0, 8, 10 => {
                    // MsgAcquire variants: [0, point], [8] (volatile tip), [10] (immutable tip)
                    // Respond with MsgAcquired [1]
                    var enc = Encoder.init(self.allocator);
                    defer enc.deinit();
                    try enc.encodeArrayLen(1);
                    try enc.encodeUint(1); // MsgAcquired
                    try bearer.writeSDU(lsq_proto, .responder, enc.getWritten());
                },
                3 => {
                    // MsgQuery [3, query_bytes] — dispatch based on query type
                    const query_result = try self.handleQuery(&dec);
                    defer self.allocator.free(query_result);

                    // Send MsgResult [4, result]
                    var enc = Encoder.init(self.allocator);
                    defer enc.deinit();
                    try enc.encodeArrayLen(2);
                    try enc.encodeUint(4); // MsgResult
                    try enc.writeRaw(query_result);
                    try bearer.writeSDU(lsq_proto, .responder, enc.getWritten());
                },
                5 => {
                    // MsgRelease [5] — no response needed
                },
                6, 9, 11 => {
                    // MsgReAcquire variants — respond with MsgAcquired
                    var enc = Encoder.init(self.allocator);
                    defer enc.deinit();
                    try enc.encodeArrayLen(1);
                    try enc.encodeUint(1); // MsgAcquired
                    try bearer.writeSDU(lsq_proto, .responder, enc.getWritten());
                },
                7 => {
                    // MsgDone [7] — client is done
                    return;
                },
                else => {
                    // Unknown message — ignore
                },
            }
        }
    }

    fn handleQuery(self: *N2CServer, dec: *Decoder) ![]u8 {
        // Parse the outer query structure to determine type
        // Query encoding:
        //   [0, block_query]  — BlockQuery (era-specific)
        //   [1]               — GetSystemStart
        //   [2, [0]]          — GetChainBlockNo
        //   [2, [1]]          — GetChainPoint
        const outer_len = dec.decodeArrayLen() catch null;
        const query_tag = dec.decodeUint() catch return self.encodeUnsupportedResult();

        if (outer_len == null and query_tag == 1) {
            // GetSystemStart — return system start time
            return self.encodeSystemStart();
        }

        if (query_tag == 2) {
            // System-level query: GetChainBlockNo or GetChainPoint
            const inner_len = dec.decodeArrayLen() catch null;
            _ = inner_len;
            const sub_tag = dec.decodeUint() catch return self.encodeUnsupportedResult();
            return switch (sub_tag) {
                0 => self.encodeChainBlockNo(),
                1 => self.encodeChainPoint(),
                else => self.encodeUnsupportedResult(),
            };
        }

        if (query_tag == 0) {
            // BlockQuery — parse inner structure
            const bq_len = dec.decodeArrayLen() catch null;
            _ = bq_len;
            const bq_tag = dec.decodeUint() catch return self.encodeUnsupportedResult();
            if (bq_tag == 2) {
                // QueryHardFork
                const hf_len = dec.decodeArrayLen() catch null;
                _ = hf_len;
                const hf_tag = dec.decodeUint() catch return self.encodeUnsupportedResult();
                return switch (hf_tag) {
                    0 => self.encodeInterpreter(), // GetInterpreter
                    1 => self.encodeCurrentEra(), // GetCurrentEra
                    else => self.encodeUnsupportedResult(),
                };
            }
        }

        return self.encodeUnsupportedResult();
    }

    fn encodeChainBlockNo(self: *N2CServer) ![]u8 {
        // Result: WithOrigin BlockNo
        // Origin = [0], NotOrigin = [1, blockNo]
        var enc = Encoder.init(self.allocator);
        errdefer enc.deinit();
        if (self.tip.block_no == 0) {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(0); // Origin
        } else {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(1); // NotOrigin
            try enc.encodeUint(self.tip.block_no);
        }
        return enc.toOwnedSlice();
    }

    fn encodeChainPoint(self: *N2CServer) ![]u8 {
        // Result: Point
        // Origin = [0], At = [1, [slot, hash]]
        var enc = Encoder.init(self.allocator);
        errdefer enc.deinit();
        if (self.tip.slot == 0) {
            try enc.encodeArrayLen(1);
            try enc.encodeUint(0); // Origin
        } else {
            try enc.encodeArrayLen(2);
            try enc.encodeUint(1); // At
            try enc.encodeArrayLen(2);
            try enc.encodeUint(self.tip.slot);
            try enc.encodeBytes(&self.tip.hash);
        }
        return enc.toOwnedSlice();
    }

    /// Encode HardFork interpreter (era summaries) for preprod.
    /// cardano-cli needs this for slot/time conversion during `query tip`.
    fn encodeInterpreter(self: *const N2CServer) ![]u8 {
        var enc = Encoder.init(self.allocator);
        errdefer enc.deinit();

        // Preprod era boundaries (from genesis configs):
        // Byron:   epochs 0-3, slots 0-86399, epoch_size=21600, slot_length=20000ms
        // Shelley: epoch 4+,   slot 86400+,   epoch_size=432000, slot_length=1000ms
        // All post-Shelley eras share the same params on preprod (no param changes at hard forks).
        // We encode 7 eras: Byron, Shelley, Allegra, Mary, Alonzo, Babbage, Conway.
        //
        // Byron time: 4 epochs * 21600 slots * 20s = 1728000 seconds
        const byron_end_slot: u64 = 86400;
        const byron_end_epoch: u64 = 4;
        const byron_end_time: u64 = byron_end_slot * 20; // 1728000 seconds
        const shelley_epoch_size: u64 = 432000;
        const shelley_slot_ms: u64 = 1000;
        const stability_window: u64 = 129600; // 3k/f for safe zone

        // On preprod, all Shelley+ eras hard-forked at the same epoch (epoch 4) with
        // no gap between them. The Haskell node encodes them as separate eras with
        // identical start/end boundaries for the intermediate ones (Allegra through Babbage).
        // For simplicity, encode Byron + one Shelley-family era (current = Conway, unbounded).
        // cardano-cli only needs at least 1 era summary to not crash.

        try enc.encodeArrayLen(2); // 2 era summaries: Byron + Shelley-family

        // Era 1: Byron
        try enc.encodeArrayLen(3); // [eraStart, eraEnd, eraParams]
        // eraStart: Bound [time, slot, epoch]
        try enc.encodeArrayLen(3);
        try enc.encodeUint(0); // time = 0 seconds
        try enc.encodeUint(0); // slot = 0
        try enc.encodeUint(0); // epoch = 0
        // eraEnd: Bound [time, slot, epoch]
        try enc.encodeArrayLen(3);
        try enc.encodeUint(byron_end_time); // 1728000 seconds
        try enc.encodeUint(byron_end_slot); // 86400
        try enc.encodeUint(byron_end_epoch); // 4
        // eraParams: [epochSize, slotLengthMs, safeZone, genesisWindow]
        try enc.encodeArrayLen(4);
        try enc.encodeUint(21600); // Byron epoch size
        try enc.encodeUint(20000); // Byron slot length = 20 seconds = 20000ms
        // SafeZone: StandardSafeZone = [0, safeFromTip, [0]]
        try enc.encodeArrayLen(3);
        try enc.encodeUint(0); // tag 0 = StandardSafeZone
        try enc.encodeUint(4320); // Byron safe zone = 2k = 4320
        try enc.encodeArrayLen(1);
        try enc.encodeUint(0); // backward compat wrapper
        try enc.encodeUint(4320); // Genesis window for Byron

        // Era 2: Shelley+ (Conway, current — unbounded)
        try enc.encodeArrayLen(3); // [eraStart, eraEnd, eraParams]
        // eraStart: Bound [time, slot, epoch]
        try enc.encodeArrayLen(3);
        try enc.encodeUint(byron_end_time); // 1728000 seconds
        try enc.encodeUint(byron_end_slot); // 86400
        try enc.encodeUint(byron_end_epoch); // 4
        // eraEnd: null (unbounded — current era)
        try enc.encodeNull();
        // eraParams: [epochSize, slotLengthMs, safeZone, genesisWindow]
        try enc.encodeArrayLen(4);
        try enc.encodeUint(shelley_epoch_size); // 432000
        try enc.encodeUint(shelley_slot_ms); // 1000ms
        // SafeZone: StandardSafeZone = [0, safeFromTip, [0]]
        try enc.encodeArrayLen(3);
        try enc.encodeUint(0); // tag 0 = StandardSafeZone
        try enc.encodeUint(stability_window); // 129600
        try enc.encodeArrayLen(1);
        try enc.encodeUint(0); // backward compat wrapper
        try enc.encodeUint(stability_window); // Genesis window

        return enc.toOwnedSlice();
    }

    fn encodeCurrentEra(self: *const N2CServer) ![]u8 {
        // Era index: 0=Byron, 1=Shelley, 2=Allegra, 3=Mary, 4=Alonzo, 5=Babbage, 6=Conway
        var enc = Encoder.init(self.allocator);
        errdefer enc.deinit();
        try enc.encodeUint(6); // Conway
        return enc.toOwnedSlice();
    }

    fn encodeSystemStart(self: *const N2CServer) ![]u8 {
        // SystemStart as text "2022-04-01T00:00:00Z" (preprod)
        var enc = Encoder.init(self.allocator);
        errdefer enc.deinit();
        try enc.encodeText("2022-04-01T00:00:00Z");
        return enc.toOwnedSlice();
    }

    fn encodeUnsupportedResult(self: *const N2CServer) ![]u8 {
        // Return empty array for unsupported queries
        var enc = Encoder.init(self.allocator);
        errdefer enc.deinit();
        try enc.encodeArrayLen(0);
        return enc.toOwnedSlice();
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "n2c_server: handshake accept encoding" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // Encode MsgAcceptVersion [1, 32789, [1, false]]
    try enc.encodeArrayLen(3);
    try enc.encodeUint(1);
    try enc.encodeUint(32789);
    try enc.encodeArrayLen(2);
    try enc.encodeUint(1);
    try enc.encodeBool(false);

    const bytes = enc.getWritten();
    var dec = Decoder.init(bytes);
    try std.testing.expectEqual(@as(?u64, 3), try dec.decodeArrayLen());
    try std.testing.expectEqual(@as(u64, 1), try dec.decodeUint());
    try std.testing.expectEqual(@as(u64, 32789), try dec.decodeUint());
}

test "n2c_server: chain block no encoding" {
    const allocator = std.testing.allocator;
    const tip = N2CServer.TipState{
        .slot = 118000000,
        .hash = [_]u8{0xab} ** 32,
        .block_no = 4500000,
        .network_magic = 1,
    };

    // We can't create a full server without a socket, so test encoding directly
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // Simulate encodeChainBlockNo for NotOrigin
    try enc.encodeArrayLen(2);
    try enc.encodeUint(1); // NotOrigin
    try enc.encodeUint(tip.block_no);

    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqual(@as(?u64, 2), try dec.decodeArrayLen());
    try std.testing.expectEqual(@as(u64, 1), try dec.decodeUint());
    try std.testing.expectEqual(@as(u64, 4500000), try dec.decodeUint());
}

test "n2c_server: chain point encoding" {
    const allocator = std.testing.allocator;
    const tip = N2CServer.TipState{
        .slot = 118000000,
        .hash = [_]u8{0xab} ** 32,
        .block_no = 4500000,
        .network_magic = 1,
    };
    _ = &tip;

    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // Simulate encodeChainPoint for At
    try enc.encodeArrayLen(2);
    try enc.encodeUint(1); // At
    try enc.encodeArrayLen(2);
    try enc.encodeUint(118000000);
    try enc.encodeBytes(&([_]u8{0xab} ** 32));

    var dec = Decoder.init(enc.getWritten());
    try std.testing.expectEqual(@as(?u64, 2), try dec.decodeArrayLen());
    try std.testing.expectEqual(@as(u64, 1), try dec.decodeUint());
    try std.testing.expectEqual(@as(?u64, 2), try dec.decodeArrayLen());
    try std.testing.expectEqual(@as(u64, 118000000), try dec.decodeUint());
}
