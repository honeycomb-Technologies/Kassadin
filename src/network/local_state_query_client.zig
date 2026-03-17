const std = @import("std");
const Allocator = std.mem.Allocator;
const Encoder = @import("../cbor/encoder.zig").Encoder;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");
const tx_mod = @import("../ledger/transaction.zig");
const UtxoEntry = @import("../storage/ledger.zig").UtxoEntry;
const local_state_query = @import("local_state_query.zig");
const mux = @import("mux.zig");
const n2c_handshake = @import("n2c_handshake.zig");
const protocol = @import("protocol.zig");
const unix_bearer = @import("unix_bearer.zig");

pub const Point = types.Point;
pub const TxIn = types.TxIn;

pub const QueryClient = struct {
    const DecodedMessage = struct {
        bytes: []u8,
        msg: local_state_query.LocalStateQueryMsg,

        fn deinit(self: *DecodedMessage, allocator: Allocator) void {
            allocator.free(self.bytes);
        }
    };

    allocator: Allocator,
    bearer: mux.Bearer,
    acquired: bool = false,

    pub fn connectUnix(allocator: Allocator, socket_path: []const u8, network_magic: u32) !QueryClient {
        var bearer = try unix_bearer.connectUnix(socket_path);
        errdefer bearer.deinit();

        const handshake = try n2c_handshake.performHandshake(allocator, &bearer, network_magic);
        switch (handshake) {
            .accepted => |accepted| {
                if (accepted.version_data.network_magic != network_magic) {
                    return error.NetworkMagicMismatch;
                }
            },
            .refused => return error.HandshakeRefused,
        }

        return .{
            .allocator = allocator,
            .bearer = bearer,
        };
    }

    pub fn deinit(self: *QueryClient) void {
        if (self.acquired) {
            self.release() catch {};
        }
        self.done() catch {};
        self.bearer.deinit();
    }

    pub fn acquirePoint(self: *QueryClient, point: ?Point) !void {
        try self.send(.{ .acquire_point = point });

        var response = try self.recv();
        defer response.deinit(self.allocator);

        switch (response.msg) {
            .acquired => {
                self.acquired = true;
            },
            .failure => |reason| switch (reason) {
                .point_too_old => return error.PointTooOld,
                .point_not_on_chain => return error.PointNotOnChain,
            },
            else => return error.UnexpectedMessage,
        }
    }

    pub fn queryCurrentEra(self: *QueryClient) !u8 {
        const query_raw = try encodeGetCurrentEraQuery(self.allocator);
        defer self.allocator.free(query_raw);

        const result_raw = try self.queryRaw(query_raw);
        defer self.allocator.free(result_raw);

        var dec = Decoder.init(result_raw);
        return @as(u8, @intCast(try dec.decodeUint()));
    }

    pub fn queryUtxoByTxIn(self: *QueryClient, allocator: Allocator, era_index: u8, txins: []const TxIn) ![]UtxoEntry {
        if (txins.len == 0) {
            return allocator.alloc(UtxoEntry, 0);
        }

        const query_raw = try encodeGetUtxoByTxInQuery(self.allocator, era_index, txins);
        defer self.allocator.free(query_raw);

        const result_raw = try self.queryRaw(query_raw);
        defer self.allocator.free(result_raw);

        return decodeUtxoByTxInResult(allocator, result_raw);
    }

    pub fn release(self: *QueryClient) !void {
        if (!self.acquired) return;
        try self.send(.release);
        self.acquired = false;
    }

    pub fn done(self: *QueryClient) !void {
        try self.send(.done);
    }

    fn queryRaw(self: *QueryClient, query_raw: []const u8) ![]u8 {
        if (!self.acquired) return error.NotAcquired;

        try self.send(.{ .query = query_raw });

        var response = try self.recv();
        defer response.deinit(self.allocator);

        return switch (response.msg) {
            .result => |result_raw| try self.allocator.dupe(u8, result_raw),
            else => error.UnexpectedMessage,
        };
    }

    fn send(self: *QueryClient, msg: local_state_query.LocalStateQueryMsg) !void {
        const bytes = try local_state_query.encodeMsg(self.allocator, msg);
        defer self.allocator.free(bytes);

        try self.bearer.writeSDU(
            @intFromEnum(protocol.MiniProtocolNum.local_state_query),
            .initiator,
            bytes,
        );
    }

    fn recv(self: *QueryClient) !DecodedMessage {
        const bytes = try self.bearer.readProtocolMessage(
            @intFromEnum(protocol.MiniProtocolNum.local_state_query),
            self.allocator,
        );
        errdefer self.allocator.free(bytes);

        return .{
            .bytes = bytes,
            .msg = try local_state_query.decodeMsg(bytes),
        };
    }
};

pub fn freeQueriedUtxos(allocator: Allocator, entries: []const UtxoEntry) void {
    for (entries) |entry| {
        allocator.free(entry.raw_cbor);
    }
    allocator.free(entries);
}

pub fn encodeGetCurrentEraQuery(allocator: Allocator) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    try enc.encodeArrayLen(2);
    try enc.encodeUint(0); // BlockQuery
    try enc.encodeArrayLen(2);
    try enc.encodeUint(2); // QueryHardFork
    try enc.encodeArrayLen(1);
    try enc.encodeUint(1); // GetCurrentEra

    return enc.toOwnedSlice();
}

pub fn encodeGetUtxoByTxInQuery(allocator: Allocator, era_index: u8, txins: []const TxIn) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    try enc.encodeArrayLen(2);
    try enc.encodeUint(0); // BlockQuery
    try enc.encodeArrayLen(2);
    try enc.encodeUint(0); // QueryIfCurrent
    try enc.encodeArrayLen(2);
    try enc.encodeUint(era_index);
    try enc.encodeArrayLen(2);
    try enc.encodeUint(15); // GetUTxOByTxIn
    try encodeTxInSet(allocator, &enc, txins);

    return enc.toOwnedSlice();
}

fn encodeTxInSet(allocator: Allocator, enc: *Encoder, txins: []const TxIn) !void {
    const sorted = try allocator.dupe(TxIn, txins);
    defer allocator.free(sorted);

    std.mem.sort(TxIn, sorted, {}, TxIn.lessThan);

    var unique_len: usize = 0;
    for (sorted) |txin| {
        if (unique_len > 0 and TxIn.eql(sorted[unique_len - 1], txin)) continue;
        sorted[unique_len] = txin;
        unique_len += 1;
    }

    try enc.encodeTag(258);
    try enc.encodeArrayLen(unique_len);
    for (sorted[0..unique_len]) |txin| {
        try enc.encodeArrayLen(2);
        try enc.encodeBytes(&txin.tx_id);
        try enc.encodeUint(txin.tx_ix);
    }
}

pub fn decodeUtxoByTxInResult(allocator: Allocator, data: []const u8) ![]UtxoEntry {
    var dec = Decoder.init(data);
    const first_major = try dec.peekMajorType();
    if (first_major == 4) {
        const wrapper_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
        switch (wrapper_len) {
            1 => {},
            2 => {
                std.debug.print("UTxO query returned mismatch wrapper: {x}\n", .{data[0..@min(data.len, 32)]});
                return error.EraMismatch;
            },
            else => {
                std.debug.print("UTxO query returned unexpected wrapper len {} bytes={x}\n", .{ wrapper_len, data[0..@min(data.len, 32)] });
                return error.InvalidCbor;
            },
        }
    }

    const map_len = (try dec.decodeMapLen()) orelse return error.InvalidCbor;

    var entries: std.ArrayList(UtxoEntry) = .empty;
    defer entries.deinit(allocator);

    try entries.ensureTotalCapacity(allocator, @intCast(map_len));

    var i: u64 = 0;
    while (i < map_len) : (i += 1) {
        _ = try dec.decodeArrayLen();
        const txid_bytes = try dec.decodeBytes();
        if (txid_bytes.len != 32) return error.InvalidCbor;

        var txid: types.TxId = undefined;
        @memcpy(&txid, txid_bytes);

        const tx_ix = @as(u16, @intCast(try dec.decodeUint()));
        const tx_out_raw = try dec.sliceOfNextValue();
        const tx_out = try tx_mod.parseTxOut(tx_out_raw);

        try entries.append(allocator, .{
            .tx_in = .{ .tx_id = txid, .tx_ix = tx_ix },
            .value = tx_out.value,
            .raw_cbor = try allocator.dupe(u8, tx_out_raw),
        });
    }

    return entries.toOwnedSlice(allocator);
}

test "local_state_query_client: encode current era query" {
    const allocator = std.testing.allocator;
    const bytes = try encodeGetCurrentEraQuery(allocator);
    defer allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x00, 0x82, 0x02, 0x81, 0x01 }, bytes);
}

test "local_state_query_client: encode utxo-by-txin query shape" {
    const allocator = std.testing.allocator;
    const txins = [_]TxIn{
        .{ .tx_id = [_]u8{0x22} ** 32, .tx_ix = 1 },
        .{ .tx_id = [_]u8{0x11} ** 32, .tx_ix = 0 },
        .{ .tx_id = [_]u8{0x11} ** 32, .tx_ix = 0 },
    };

    const bytes = try encodeGetUtxoByTxInQuery(allocator, 6, &txins);
    defer allocator.free(bytes);

    var dec = Decoder.init(bytes);
    try std.testing.expectEqual(@as(?u64, 2), try dec.decodeArrayLen());
    try std.testing.expectEqual(@as(u64, 0), try dec.decodeUint());
    try std.testing.expectEqual(@as(?u64, 2), try dec.decodeArrayLen());
    try std.testing.expectEqual(@as(u64, 0), try dec.decodeUint());
    try std.testing.expectEqual(@as(?u64, 2), try dec.decodeArrayLen());
    try std.testing.expectEqual(@as(u64, 6), try dec.decodeUint());
    try std.testing.expectEqual(@as(?u64, 2), try dec.decodeArrayLen());
    try std.testing.expectEqual(@as(u64, 15), try dec.decodeUint());
    try std.testing.expectEqual(@as(u64, 258), try dec.decodeTag());
    try std.testing.expectEqual(@as(?u64, 2), try dec.decodeArrayLen());
}

test "local_state_query_client: decode utxo-by-txin result" {
    const allocator = std.testing.allocator;
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    try enc.encodeMapLen(1);
    try enc.encodeArrayLen(2);
    try enc.encodeBytes(&([_]u8{0x44} ** 32));
    try enc.encodeUint(3);
    try enc.encodeArrayLen(2);
    try enc.encodeBytes(&([_]u8{0x61} ++ [_]u8{0xbb} ** 28));
    try enc.encodeUint(1_500_000);

    const entries = try decodeUtxoByTxInResult(allocator, enc.getWritten());
    defer freeQueriedUtxos(allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u16, 3), entries[0].tx_in.tx_ix);
    try std.testing.expectEqual(@as(u64, 1_500_000), entries[0].value);
}
