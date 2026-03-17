const std = @import("std");
const Allocator = std.mem.Allocator;
const Encoder = @import("../cbor/encoder.zig").Encoder;
const tx_mod = @import("../ledger/transaction.zig");
const types = @import("../types.zig");
const UtxoEntry = @import("../storage/ledger.zig").UtxoEntry;

pub const TxIn = types.TxIn;
pub const Hash32 = types.Hash32;

pub const BlockRef = struct {
    slot: u64 = 0,
    hash: Hash32 = [_]u8{0} ** 32,
    height: u64 = 0,
    timestamp: u64 = 0,
};

pub const Client = struct {
    allocator: Allocator,
    base_url: []const u8,

    pub fn init(allocator: Allocator, endpoint: []const u8) !Client {
        const trimmed = std.mem.trimRight(u8, endpoint, "/");
        if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://")) {
            return .{
                .allocator = allocator,
                .base_url = try allocator.dupe(u8, trimmed),
            };
        }

        return .{
            .allocator = allocator,
            .base_url = try std.fmt.allocPrint(allocator, "http://{s}", .{trimmed}),
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.base_url);
    }

    pub fn readTip(self: *Client) !BlockRef {
        const response = try self.unary("/utxorpc.v1alpha.sync.SyncService/ReadTip", &.{}, 64 * 1024);
        defer self.allocator.free(response);

        var reader = ProtoReader.init(response);
        while (try reader.nextField()) |field| {
            switch (field.number) {
                1 => return decodeBlockRef(try reader.readBytes()),
                else => try reader.skip(field.wire_type),
            }
        }

        return error.InvalidProto;
    }

    pub fn fetchBlock(self: *Client, block_ref: BlockRef) !?[]u8 {
        var request = std.ArrayList(u8).empty;
        defer request.deinit(self.allocator);

        const ref_bytes = try encodeBlockRef(self.allocator, block_ref);
        defer self.allocator.free(ref_bytes);
        try appendMessageField(self.allocator, &request, 1, ref_bytes);

        const response = try self.unary(
            "/utxorpc.v1alpha.sync.SyncService/FetchBlock",
            request.items,
            16 * 1024 * 1024,
        );
        defer self.allocator.free(response);

        var reader = ProtoReader.init(response);
        while (try reader.nextField()) |field| {
            switch (field.number) {
                1 => {
                    const block_bytes = try decodeAnyChainBlock(try reader.readBytes());
                    if (block_bytes) |raw| {
                        return try self.allocator.dupe(u8, raw);
                    }
                },
                else => try reader.skip(field.wire_type),
            }
        }

        return null;
    }

    pub fn readUtxos(self: *Client, allocator: Allocator, txins: []const TxIn) ![]UtxoEntry {
        if (txins.len == 0) {
            return allocator.alloc(UtxoEntry, 0);
        }

        const sorted = try allocator.dupe(TxIn, txins);
        defer allocator.free(sorted);

        std.mem.sort(TxIn, sorted, {}, TxIn.lessThan);

        var unique_len: usize = 0;
        for (sorted) |txin| {
            if (unique_len > 0 and TxIn.eql(sorted[unique_len - 1], txin)) continue;
            sorted[unique_len] = txin;
            unique_len += 1;
        }

        var request = std.ArrayList(u8).empty;
        defer request.deinit(self.allocator);

        for (sorted[0..unique_len]) |txin| {
            const key_bytes = try encodeTxoRef(self.allocator, txin);
            defer self.allocator.free(key_bytes);
            try appendMessageField(self.allocator, &request, 1, key_bytes);
        }

        const response = try self.unary(
            "/utxorpc.v1alpha.query.QueryService/ReadUtxos",
            request.items,
            16 * 1024 * 1024,
        );
        defer self.allocator.free(response);

        var entries: std.ArrayList(UtxoEntry) = .empty;
        defer entries.deinit(allocator);

        var reader = ProtoReader.init(response);
        while (try reader.nextField()) |field| {
            switch (field.number) {
                1 => {
                    const entry = try decodeAnyUtxoData(allocator, try reader.readBytes());
                    if (entry) |value| {
                        try entries.append(allocator, value);
                    }
                },
                else => try reader.skip(field.wire_type),
            }
        }

        return entries.toOwnedSlice(allocator);
    }

    pub fn readHistoricalUtxos(self: *Client, allocator: Allocator, txins: []const TxIn) ![]UtxoEntry {
        if (txins.len == 0) {
            return allocator.alloc(UtxoEntry, 0);
        }

        const sorted = try allocator.dupe(TxIn, txins);
        defer allocator.free(sorted);

        std.mem.sort(TxIn, sorted, {}, TxIn.lessThan);

        var unique_len: usize = 0;
        for (sorted) |txin| {
            if (unique_len > 0 and TxIn.eql(sorted[unique_len - 1], txin)) continue;
            sorted[unique_len] = txin;
            unique_len += 1;
        }

        var result: std.ArrayList(UtxoEntry) = .empty;
        defer result.deinit(allocator);

        var start: usize = 0;
        while (start < unique_len) {
            const tx_id = sorted[start].tx_id;
            var end = start + 1;
            while (end < unique_len and std.mem.eql(u8, &sorted[end].tx_id, &tx_id)) : (end += 1) {}

            const outputs = try self.readTxOutputs(allocator, tx_id);
            defer freeReadUtxos(allocator, outputs);

            for (sorted[start..end]) |txin| {
                for (outputs) |output| {
                    if (output.tx_in.tx_ix != txin.tx_ix) continue;
                    try result.append(allocator, .{
                        .tx_in = output.tx_in,
                        .value = output.value,
                        .raw_cbor = try allocator.dupe(u8, output.raw_cbor),
                    });
                    break;
                }
            }

            start = end;
        }

        return result.toOwnedSlice(allocator);
    }

    fn unary(self: *Client, method_path: []const u8, payload: []const u8, max_output_bytes: usize) ![]u8 {
        const framed = try frameGrpcMessage(self.allocator, payload);
        defer self.allocator.free(framed);

        const request_path = try allocTempPath(self.allocator, "request.bin");
        defer self.allocator.free(request_path);
        defer std.fs.cwd().deleteFile(request_path) catch {};

        const header_path = try allocTempPath(self.allocator, "headers.txt");
        defer self.allocator.free(header_path);
        defer std.fs.cwd().deleteFile(header_path) catch {};

        {
            var file = try std.fs.cwd().createFile(request_path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(framed);
        }

        const request_arg = try std.fmt.allocPrint(self.allocator, "@{s}", .{request_path});
        defer self.allocator.free(request_arg);

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, method_path });
        defer self.allocator.free(url);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "curl",
                "-sS",
                "--http2-prior-knowledge",
                "-H",
                "content-type: application/grpc",
                "-H",
                "te: trailers",
                "--dump-header",
                header_path,
                "--data-binary",
                request_arg,
                url,
            },
            .max_output_bytes = max_output_bytes,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            if (result.stderr.len > 0) {
                std.debug.print("curl grpc request failed: {s}\n", .{result.stderr});
            }
            return error.CurlFailed;
        }

        const headers = std.fs.cwd().readFileAlloc(self.allocator, header_path, 128 * 1024) catch |err| switch (err) {
            error.FileNotFound => &.{},
            else => return err,
        };
        defer if (headers.len > 0) self.allocator.free(headers);

        try ensureGrpcSuccess(headers);
        return decodeGrpcUnaryMessage(self.allocator, result.stdout);
    }

    fn readTxOutputs(self: *Client, allocator: Allocator, tx_id: Hash32) ![]UtxoEntry {
        var request = std.ArrayList(u8).empty;
        defer request.deinit(self.allocator);
        try appendBytesField(self.allocator, &request, 1, &tx_id);

        const response = try self.unary(
            "/utxorpc.v1alpha.query.QueryService/ReadTx",
            request.items,
            16 * 1024 * 1024,
        );
        defer self.allocator.free(response);

        var reader = ProtoReader.init(response);
        while (try reader.nextField()) |field| {
            switch (field.number) {
                1 => return decodeAnyChainTxOutputs(allocator, tx_id, try reader.readBytes()),
                else => try reader.skip(field.wire_type),
            }
        }

        return allocator.alloc(UtxoEntry, 0);
    }
};

pub fn freeReadUtxos(allocator: Allocator, entries: []const UtxoEntry) void {
    for (entries) |entry| {
        allocator.free(entry.raw_cbor);
    }
    allocator.free(entries);
}

var temp_counter: u64 = 0;

fn allocTempPath(allocator: Allocator, suffix: []const u8) ![]u8 {
    temp_counter += 1;
    return std.fmt.allocPrint(allocator, ".kassadin-grpc-{d}-{d}-{s}", .{
        std.time.microTimestamp(),
        temp_counter,
        suffix,
    });
}

fn frameGrpcMessage(allocator: Allocator, payload: []const u8) ![]u8 {
    const framed = try allocator.alloc(u8, 5 + payload.len);
    framed[0] = 0;
    std.mem.writeInt(u32, framed[1..5], @intCast(payload.len), .big);
    @memcpy(framed[5..], payload);
    return framed;
}

fn decodeGrpcUnaryMessage(allocator: Allocator, framed: []const u8) ![]u8 {
    if (framed.len < 5) return error.InvalidGrpcFrame;
    if (framed[0] != 0) return error.UnsupportedCompressedGrpcMessage;

    const msg_len = std.mem.readInt(u32, framed[1..5], .big);
    if (framed.len < 5 + msg_len) return error.InvalidGrpcFrame;
    if (framed.len != 5 + msg_len) return error.InvalidGrpcFrame;

    return allocator.dupe(u8, framed[5 .. 5 + msg_len]);
}

fn ensureGrpcSuccess(headers: []const u8) !void {
    if (headers.len == 0) return;

    var http_ok = false;
    var grpc_status: ?u32 = null;

    var it = std.mem.splitScalar(u8, headers, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            if (std.mem.indexOf(u8, line, " 200 ") != null or std.mem.endsWith(u8, line, " 200")) {
                http_ok = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "grpc-status:")) {
            const value = std.mem.trim(u8, line["grpc-status:".len..], " \t");
            grpc_status = std.fmt.parseInt(u32, value, 10) catch return error.GrpcRequestFailed;
        }
    }

    if (!http_ok) return error.HttpRequestFailed;
    if (grpc_status) |status| {
        if (status != 0) return error.GrpcRequestFailed;
    }
}

const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    bytes = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
};

const Field = struct {
    number: u64,
    wire_type: WireType,
};

const ProtoReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn init(data: []const u8) ProtoReader {
        return .{ .data = data };
    }

    fn nextField(self: *ProtoReader) !?Field {
        if (self.pos >= self.data.len) return null;
        const key = try self.readVarint();
        return .{
            .number = key >> 3,
            .wire_type = std.meta.intToEnum(WireType, @as(u3, @intCast(key & 0x07))) catch return error.UnsupportedProtoWireType,
        };
    }

    fn readVarint(self: *ProtoReader) !u64 {
        var shift: u6 = 0;
        var value: u64 = 0;

        while (self.pos < self.data.len and shift <= 63) {
            const byte = self.data[self.pos];
            self.pos += 1;
            value |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) return value;
            shift += 7;
        }

        return error.InvalidProto;
    }

    fn readBytes(self: *ProtoReader) ![]const u8 {
        const len = try self.readVarint();
        const usize_len: usize = @intCast(len);
        if (self.pos + usize_len > self.data.len) return error.InvalidProto;
        const bytes = self.data[self.pos .. self.pos + usize_len];
        self.pos += usize_len;
        return bytes;
    }

    fn skip(self: *ProtoReader, wire_type: WireType) !void {
        switch (wire_type) {
            .varint => _ = try self.readVarint(),
            .fixed64 => {
                if (self.pos + 8 > self.data.len) return error.InvalidProto;
                self.pos += 8;
            },
            .bytes => _ = try self.readBytes(),
            .fixed32 => {
                if (self.pos + 4 > self.data.len) return error.InvalidProto;
                self.pos += 4;
            },
            else => return error.UnsupportedProtoWireType,
        }
    }
};

fn appendFieldKey(allocator: Allocator, list: *std.ArrayList(u8), field_number: u64, wire_type: WireType) !void {
    try appendVarint(allocator, list, (field_number << 3) | @intFromEnum(wire_type));
}

fn appendVarint(allocator: Allocator, list: *std.ArrayList(u8), value: u64) !void {
    var remaining = value;
    while (remaining >= 0x80) {
        try list.append(allocator, @intCast((remaining & 0x7f) | 0x80));
        remaining >>= 7;
    }
    try list.append(allocator, @intCast(remaining));
}

fn appendBytesField(allocator: Allocator, list: *std.ArrayList(u8), field_number: u64, bytes: []const u8) !void {
    try appendFieldKey(allocator, list, field_number, .bytes);
    try appendVarint(allocator, list, bytes.len);
    try list.appendSlice(allocator, bytes);
}

fn appendUint32Field(allocator: Allocator, list: *std.ArrayList(u8), field_number: u64, value: u32) !void {
    try appendFieldKey(allocator, list, field_number, .varint);
    try appendVarint(allocator, list, value);
}

fn appendUint64Field(allocator: Allocator, list: *std.ArrayList(u8), field_number: u64, value: u64) !void {
    try appendFieldKey(allocator, list, field_number, .varint);
    try appendVarint(allocator, list, value);
}

fn appendMessageField(allocator: Allocator, list: *std.ArrayList(u8), field_number: u64, message: []const u8) !void {
    try appendBytesField(allocator, list, field_number, message);
}

fn encodeTxoRef(allocator: Allocator, txin: TxIn) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try appendBytesField(allocator, &list, 1, &txin.tx_id);
    try appendUint32Field(allocator, &list, 2, txin.tx_ix);
    return list.toOwnedSlice(allocator);
}

fn encodeBlockRef(allocator: Allocator, block_ref: BlockRef) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    if (block_ref.slot != 0) try appendUint64Field(allocator, &list, 1, block_ref.slot);
    if (!std.mem.eql(u8, &block_ref.hash, &([_]u8{0} ** 32))) try appendBytesField(allocator, &list, 2, &block_ref.hash);
    if (block_ref.height != 0) try appendUint64Field(allocator, &list, 3, block_ref.height);
    if (block_ref.timestamp != 0) try appendUint64Field(allocator, &list, 4, block_ref.timestamp);

    return list.toOwnedSlice(allocator);
}

fn decodeBlockRef(data: []const u8) !BlockRef {
    var block_ref = BlockRef{};
    var reader = ProtoReader.init(data);

    while (try reader.nextField()) |field| {
        switch (field.number) {
            1 => {
                if (field.wire_type != .varint) return error.InvalidProto;
                block_ref.slot = try reader.readVarint();
            },
            2 => {
                if (field.wire_type != .bytes) return error.InvalidProto;
                const hash = try reader.readBytes();
                if (hash.len != 32) return error.InvalidProto;
                @memcpy(&block_ref.hash, hash);
            },
            3 => {
                if (field.wire_type != .varint) return error.InvalidProto;
                block_ref.height = try reader.readVarint();
            },
            4 => {
                if (field.wire_type != .varint) return error.InvalidProto;
                block_ref.timestamp = try reader.readVarint();
            },
            else => try reader.skip(field.wire_type),
        }
    }

    if (std.mem.eql(u8, &block_ref.hash, &([_]u8{0} ** 32))) return error.InvalidProto;
    return block_ref;
}

fn decodeAnyChainBlock(data: []const u8) !?[]const u8 {
    var reader = ProtoReader.init(data);
    while (try reader.nextField()) |field| {
        switch (field.number) {
            1 => return try reader.readBytes(),
            else => try reader.skip(field.wire_type),
        }
    }
    return null;
}

fn decodeAnyChainTxOutputs(allocator: Allocator, tx_id: Hash32, data: []const u8) ![]UtxoEntry {
    var reader = ProtoReader.init(data);
    var native_bytes: ?[]const u8 = null;
    var cardano_bytes: ?[]const u8 = null;

    while (try reader.nextField()) |field| {
        switch (field.number) {
            1 => native_bytes = try reader.readBytes(),
            2 => cardano_bytes = try reader.readBytes(),
            else => try reader.skip(field.wire_type),
        }
    }

    if (native_bytes) |raw| {
        const maybe_tx = tx_mod.parseTxBody(allocator, raw) catch null;
        if (maybe_tx) |parsed_tx| {
            var parsed = parsed_tx;
            defer tx_mod.freeTxBody(allocator, &parsed);
            if (std.mem.eql(u8, &parsed.tx_id, &tx_id)) {
                return buildEntriesFromTxBody(allocator, &parsed);
            }
        }
    }

    if (cardano_bytes) |cardano_tx| {
        return decodeCardanoTxOutputs(allocator, tx_id, cardano_tx);
    }

    return error.InvalidProto;
}

fn decodeAnyUtxoData(allocator: Allocator, data: []const u8) !?UtxoEntry {
    var reader = ProtoReader.init(data);
    var raw_cbor: ?[]const u8 = null;
    var txo_ref: ?TxIn = null;

    while (try reader.nextField()) |field| {
        switch (field.number) {
            1 => raw_cbor = try reader.readBytes(),
            2 => txo_ref = try decodeTxoRef(try reader.readBytes()),
            else => try reader.skip(field.wire_type),
        }
    }

    if (raw_cbor == null or txo_ref == null) return null;

    const tx_out = try tx_mod.parseTxOut(raw_cbor.?);
    return .{
        .tx_in = txo_ref.?,
        .value = tx_out.value,
        .raw_cbor = try allocator.dupe(u8, raw_cbor.?),
    };
}

fn decodeTxoRef(data: []const u8) !TxIn {
    var txin: TxIn = .{ .tx_id = [_]u8{0} ** 32, .tx_ix = 0 };
    var saw_hash = false;

    var reader = ProtoReader.init(data);
    while (try reader.nextField()) |field| {
        switch (field.number) {
            1 => {
                const hash = try reader.readBytes();
                if (hash.len != 32) return error.InvalidProto;
                @memcpy(&txin.tx_id, hash);
                saw_hash = true;
            },
            2 => {
                if (field.wire_type != .varint) return error.InvalidProto;
                const index = try reader.readVarint();
                txin.tx_ix = std.math.cast(u16, index) orelse return error.InvalidProto;
            },
            else => try reader.skip(field.wire_type),
        }
    }

    if (!saw_hash) return error.InvalidProto;
    return txin;
}

fn buildEntriesFromTxBody(allocator: Allocator, tx: *const tx_mod.TxBody) ![]UtxoEntry {
    var outputs: std.ArrayList(UtxoEntry) = .empty;
    defer outputs.deinit(allocator);

    for (tx.outputs, 0..) |out, ix| {
        try outputs.append(allocator, .{
            .tx_in = .{
                .tx_id = tx.tx_id,
                .tx_ix = @intCast(ix),
            },
            .value = out.value,
            .raw_cbor = try allocator.dupe(u8, out.raw_cbor),
        });
    }

    return outputs.toOwnedSlice(allocator);
}

fn decodeCardanoTxOutputs(allocator: Allocator, tx_id: Hash32, data: []const u8) ![]UtxoEntry {
    var outputs: std.ArrayList(UtxoEntry) = .empty;
    defer outputs.deinit(allocator);

    var reader = ProtoReader.init(data);
    var index: u16 = 0;
    while (try reader.nextField()) |field| {
        switch (field.number) {
            2 => {
                const parsed = try decodeCardanoTxOutput(allocator, try reader.readBytes());
                try outputs.append(allocator, .{
                    .tx_in = .{ .tx_id = tx_id, .tx_ix = index },
                    .value = parsed.value,
                    .raw_cbor = parsed.raw_cbor,
                });
                index +%= 1;
            },
            else => try reader.skip(field.wire_type),
        }
    }

    return outputs.toOwnedSlice(allocator);
}

fn decodeCardanoTxOutput(allocator: Allocator, data: []const u8) !struct { value: u64, raw_cbor: []u8 } {
    var address: []const u8 = &.{};
    var coin: u64 = 0;

    var reader = ProtoReader.init(data);
    while (try reader.nextField()) |field| {
        switch (field.number) {
            1 => address = try reader.readBytes(),
            2 => coin = try decodeBigIntCoin(try reader.readBytes()),
            else => try reader.skip(field.wire_type),
        }
    }

    if (address.len == 0) return error.InvalidProto;
    return .{
        .value = coin,
        .raw_cbor = try encodeMinimalTxOut(allocator, address, coin),
    };
}

fn decodeBigIntCoin(data: []const u8) !u64 {
    var reader = ProtoReader.init(data);
    while (try reader.nextField()) |field| {
        switch (field.number) {
            1 => {
                if (field.wire_type != .varint) return error.InvalidProto;
                return try reader.readVarint();
            },
            2 => {
                const bytes = try reader.readBytes();
                if (bytes.len > 8) return error.UnsupportedBigInt;
                var value: u64 = 0;
                for (bytes) |byte| {
                    value = (value << 8) | byte;
                }
                return value;
            },
            3 => return error.NegativeCoinUnsupported,
            else => try reader.skip(field.wire_type),
        }
    }
    return 0;
}

fn encodeMinimalTxOut(allocator: Allocator, address: []const u8, coin: u64) ![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();

    try enc.encodeArrayLen(2);
    try enc.encodeBytes(address);
    try enc.encodeUint(coin);
    return enc.toOwnedSlice();
}

test "dolos_grpc_client: encode txo ref request key" {
    const allocator = std.testing.allocator;
    const txin = TxIn{
        .tx_id = [_]u8{0x22} ** 32,
        .tx_ix = 7,
    };

    const encoded = try encodeTxoRef(allocator, txin);
    defer allocator.free(encoded);

    var reader = ProtoReader.init(encoded);
    try std.testing.expect((try reader.nextField()).?.number == 1);
    try std.testing.expectEqualSlices(u8, &txin.tx_id, try reader.readBytes());
    try std.testing.expect((try reader.nextField()).?.number == 2);
    try std.testing.expectEqual(@as(u64, 7), try reader.readVarint());
    try std.testing.expect((try reader.nextField()) == null);
}

test "dolos_grpc_client: decode read-utxos response item" {
    const allocator = std.testing.allocator;

    var tx_out = std.ArrayList(u8).empty;
    defer tx_out.deinit(allocator);
    try tx_out.appendSlice(allocator, &.{
        0x82,
        0x58,
        0x1d,
    });
    try tx_out.appendNTimes(allocator, 0x61, 29);
    try tx_out.appendSlice(allocator, &.{ 0x1a, 0x00, 0x16, 0xe3, 0x60 });

    const txin = TxIn{
        .tx_id = [_]u8{0x44} ** 32,
        .tx_ix = 3,
    };
    const txo_ref = try encodeTxoRef(allocator, txin);
    defer allocator.free(txo_ref);

    var any_utxo = std.ArrayList(u8).empty;
    defer any_utxo.deinit(allocator);
    try appendBytesField(allocator, &any_utxo, 1, tx_out.items);
    try appendMessageField(allocator, &any_utxo, 2, txo_ref);

    const entry = (try decodeAnyUtxoData(allocator, any_utxo.items)).?;
    defer allocator.free(entry.raw_cbor);

    try std.testing.expectEqual(txin.tx_ix, entry.tx_in.tx_ix);
    try std.testing.expectEqual(@as(u64, 1_500_000), entry.value);
    try std.testing.expectEqualSlices(u8, tx_out.items, entry.raw_cbor);
}

test "dolos_grpc_client: decode block ref" {
    const allocator = std.testing.allocator;

    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(allocator);
    try appendUint64Field(allocator, &encoded, 1, 42);
    try appendBytesField(allocator, &encoded, 2, &([_]u8{0xaa} ** 32));
    try appendUint64Field(allocator, &encoded, 3, 99);

    const decoded = try decodeBlockRef(encoded.items);
    try std.testing.expectEqual(@as(u64, 42), decoded.slot);
    try std.testing.expectEqual(@as(u64, 99), decoded.height);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xaa} ** 32), &decoded.hash);
}
