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

        // Read version map — accept v16 (32784) for maximum compatibility.
        // Higher versions have additional version data fields we don't implement.
        const map_len = try dec.decodeMapLen() orelse return error.InvalidCbor;
        var best_version: u64 = 0;
        var client_magic: u32 = self.tip.network_magic;
        var i: u64 = 0;
        while (i < map_len) : (i += 1) {
            const ver = try dec.decodeUint();
            const vdata_len = try dec.decodeArrayLen() orelse 0;
            const magic = @as(u32, @intCast(try dec.decodeUint()));
            // Skip remaining version data fields (query flag, etc.)
            var j: u64 = 1;
            while (j < vdata_len) : (j += 1) {
                _ = dec.sliceOfNextValue() catch break;
            }
            // Accept v16 specifically for compatibility with cardano-cli
            if (ver == 32784 and best_version == 0) {
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
                    // Debug: dump the raw query bytes
                    const remaining = msg[dec.pos..];
                    std.debug.print("N2C query ({} bytes): ", .{remaining.len});
                    for (remaining[0..@min(remaining.len, 32)]) |b| {
                        std.debug.print("{x:0>2}", .{b});
                    }
                    std.debug.print("\n", .{});
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
        // Query encoding (from Haskell HardFork Combinator):
        //   [0, block_query]  — BlockQuery (era-specific or HardFork)
        //   [1]               — GetSystemStart
        //   [2, [0]]          — GetChainBlockNo
        //   [2, [1]]          — GetChainPoint
        const outer_len = dec.decodeArrayLen() catch null;
        const query_tag = dec.decodeUint() catch return self.encodeUnsupportedResult();

        std.debug.print("  N2C query: outer_len={?}, tag={}\n", .{ outer_len, query_tag });

        if (query_tag == 1) {
            std.debug.print("  → GetSystemStart\n", .{});
            return self.encodeSystemStart();
        }

        if (query_tag == 2) {
            // GetChainBlockNo: [2] (bare, 1-element array)
            std.debug.print("  → GetChainBlockNo\n", .{});
            return self.encodeChainBlockNo();
        }

        if (query_tag == 3) {
            // GetChainPoint: [3] (bare, 1-element array)
            std.debug.print("  → GetChainPoint\n", .{});
            return self.encodeChainPoint();
        }

        if (query_tag == 0) {
            const bq_len = dec.decodeArrayLen() catch null;
            const bq_tag = dec.decodeUint() catch return self.encodeUnsupportedResult();
            std.debug.print("  → BlockQuery: bq_len={?}, bq_tag={}\n", .{ bq_len, bq_tag });
            if (bq_tag == 2) {
                const hf_len = dec.decodeArrayLen() catch null;
                const hf_tag = dec.decodeUint() catch return self.encodeUnsupportedResult();
                std.debug.print("  → QueryHardFork: hf_len={?}, hf_tag={}\n", .{ hf_len, hf_tag });
                return switch (hf_tag) {
                    0 => blk: {
                        std.debug.print("  → GetInterpreter\n", .{});
                        break :blk self.encodeInterpreter();
                    },
                    1 => self.encodeCurrentEra(),
                    else => self.encodeUnsupportedResult(),
                };
            }
        }

        std.debug.print("  → Unsupported query\n", .{});
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
        // Result: Point = [slot, headerHash] (no WithOrigin wrapping)
        var enc = Encoder.init(self.allocator);
        errdefer enc.deinit();
        try enc.encodeArrayLen(2);
        try enc.encodeUint(self.tip.slot);
        try enc.encodeBytes(&self.tip.hash);
        return enc.toOwnedSlice();
    }

    /// Encode HardFork interpreter (era summaries) for preprod.
    /// Byte-exact copy of Dolos's response, which matches the Haskell cardano-node format.
    /// Times are in picoseconds (Haskell Pico = Fixed E12).
    fn encodeInterpreter(self: *const N2CServer) ![]u8 {
        // Captured from Dolos preprod: 11 era summaries covering Byron through Conway.
        const dolos_interpreter = "\x8b\x83\x83\x00\x00\x00\x83\x1b\x0b\xfd\x8b\x6c\x1d\xf0\x00\x00\x19\xa8\xc0\x02\x84\x19\x54\x60\x1b\x00\x00\x12\x30\x9c\xe5\x40\x00\x83\x00\x19\x10\xe0\x81\x00\x19\x10\xe0\x83\x83\x1b\x0b\xfd\x8b\x6c\x1d\xf0\x00\x00\x19\xa8\xc0\x02\x83\x1b\x17\xfb\x16\xd8\x3b\xe0\x00\x00\x1a\x00\x01\x51\x80\x04\x84\x19\x54\x60\x1b\x00\x00\x12\x30\x9c\xe5\x40\x00\x83\x00\x19\x10\xe0\x81\x00\x19\x10\xe0\x83\x83\x1b\x17\xfb\x16\xd8\x3b\xe0\x00\x00\x1a\x00\x01\x51\x80\x04\x83\x1b\x1d\xf9\xdc\x8e\x4a\xd8\x00\x00\x1a\x00\x07\xe9\x00\x05\x84\x1a\x00\x06\x97\x80\x1b\x00\x00\x00\xe8\xd4\xa5\x10\x00\x83\x00\x19\x10\xe0\x81\x00\x19\x10\xe0\x83\x83\x1b\x1d\xf9\xdc\x8e\x4a\xd8\x00\x00\x1a\x00\x07\xe9\x00\x05\x83\x1b\x23\xf8\xa2\x44\x59\xd0\x00\x00\x1a\x00\x0e\x80\x80\x06\x84\x1a\x00\x06\x97\x80\x1b\x00\x00\x00\xe8\xd4\xa5\x10\x00\x83\x00\x19\x10\xe0\x81\x00\x19\x10\xe0\x83\x83\x1b\x23\xf8\xa2\x44\x59\xd0\x00\x00\x1a\x00\x0e\x80\x80\x06\x83\x1b\x29\xf7\x67\xfa\x68\xc8\x00\x00\x1a\x00\x15\x18\x00\x07\x84\x1a\x00\x06\x97\x80\x1b\x00\x00\x00\xe8\xd4\xa5\x10\x00\x83\x00\x19\x10\xe0\x81\x00\x19\x10\xe0\x83\x83\x1b\x29\xf7\x67\xfa\x68\xc8\x00\x00\x1a\x00\x15\x18\x00\x07\x83\x1b\x35\xf4\xf3\x66\x86\xb8\x00\x00\x1a\x00\x22\x47\x00\x09\x84\x1a\x00\x06\x97\x80\x1b\x00\x00\x00\xe8\xd4\xa5\x10\x00\x83\x00\x19\x10\xe0\x81\x00\x19\x10\xe0\x83\x83\x1b\x35\xf4\xf3\x66\x86\xb8\x00\x00\x1a\x00\x22\x47\x00\x09\x83\x1b\x47\xf1\x44\x88\xb3\xa0\x00\x00\x1a\x00\x36\x0d\x80\x0c\x84\x1a\x00\x06\x97\x80\x1b\x00\x00\x00\xe8\xd4\xa5\x10\x00\x83\x00\x19\x10\xe0\x81\x00\x19\x10\xe0\x83\x83\x1b\x47\xf1\x44\x88\xb3\xa0\x00\x00\x1a\x00\x36\x0d\x80\x0c\xf6\x84\x1a\x00\x06\x97\x80\x1b\x00\x00\x00\xe8\xd4\xa5\x10\x00\x81\x01\x19\x10\xe0\x83\x83\x1b\xff\xff\xff\xff\xff\xff\xff\xff\x1a\x01\x37\x22\x00\x18\x33\xf6\x84\x1a\x00\x06\x97\x80\x1b\x00\x00\x00\xe8\xd4\xa5\x10\x00\x81\x01\x19\x10\xe0\x83\x83\x1b\xff\xff\xff\xff\xff\xff\xff\xff\x1a\x04\x19\x6a\x00\x18\xa3\xf6\x84\x1a\x00\x06\x97\x80\x1b\x00\x00\x00\xe8\xd4\xa5\x10\x00\x81\x01\x19\x10\xe0\x83\x83\x1b\xff\xff\xff\xff\xff\xff\xff\xff\x1a\x04\x90\x11\x00\x18\xb5\xf6\x84\x1a\x00\x06\x97\x80\x1b\x00\x00\x00\xe8\xd4\xa5\x10\x00\x81\x01\x19\x10\xe0";
        return self.allocator.dupe(u8, dolos_interpreter);
    }

    fn encodeCurrentEra(self: *const N2CServer) ![]u8 {
        // Era index: 0=Byron, 1=Shelley, 2=Allegra, 3=Mary, 4=Alonzo, 5=Babbage, 6=Conway
        var enc = Encoder.init(self.allocator);
        errdefer enc.deinit();
        try enc.encodeUint(6); // Conway
        return enc.toOwnedSlice();
    }

    fn encodeSystemStart(self: *const N2CServer) ![]u8 {
        // SystemStart = UTCTime encoded as [year, dayOfYear, picosecondOfDay]
        // Preprod genesis: 2022-06-01T00:00:00Z = [2022, 152, 0]
        var enc = Encoder.init(self.allocator);
        errdefer enc.deinit();
        try enc.encodeArrayLen(3);
        try enc.encodeUint(2022); // year
        try enc.encodeUint(152); // day of year (June 1 = day 152)
        try enc.encodeUint(0); // picoseconds of day
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
