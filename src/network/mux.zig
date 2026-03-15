const std = @import("std");

/// Direction of a multiplexed message on the wire.
/// From Haskell Codec.hs: InitiatorDir = no bit set, ResponderDir = bit 15 set.
pub const Direction = enum(u1) {
    initiator = 0, // bit 15 clear on wire
    responder = 1, // bit 15 set (ORed with 0x8000)
};

/// Maximum SDU payload size for TCP/Unix sockets (from Haskell MuxBearerSocket).
pub const max_sdu_payload: u16 = 12288;

/// SDU header size in bytes.
pub const header_length: usize = 8;

/// Decoded SDU (Service Data Unit) header — the 8-byte mux framing header.
pub const SDUHeader = struct {
    transmission_time: u32, // Microseconds (lower 32 bits of monotonic clock)
    protocol_num: u15, // Mini-protocol number (0-16383)
    direction: Direction, // Which side sent this
    payload_length: u16, // Payload bytes following this header
};

/// Encode an SDU header to 8 bytes, big-endian.
/// Wire format: [4B timestamp][2B dir|proto][2B length]
pub fn encodeHeader(header: SDUHeader) [header_length]u8 {
    var buf: [header_length]u8 = undefined;

    // Bytes 0-3: transmission_time (u32 big-endian)
    std.mem.writeInt(u32, buf[0..4], header.transmission_time, .big);

    // Bytes 4-5: direction (bit 15) | protocol_num (bits 14-0)
    var proto_info: u16 = @intCast(header.protocol_num);
    if (header.direction == .responder) {
        proto_info |= 0x8000;
    }
    std.mem.writeInt(u16, buf[4..6], proto_info, .big);

    // Bytes 6-7: payload_length (u16 big-endian)
    std.mem.writeInt(u16, buf[6..8], header.payload_length, .big);

    return buf;
}

/// Decode an SDU header from 8 bytes, big-endian.
pub fn decodeHeader(bytes: *const [header_length]u8) SDUHeader {
    const transmission_time = std.mem.readInt(u32, bytes[0..4], .big);
    const proto_info = std.mem.readInt(u16, bytes[4..6], .big);
    const payload_length = std.mem.readInt(u16, bytes[6..8], .big);

    return .{
        .transmission_time = transmission_time,
        .protocol_num = @intCast(proto_info & 0x7FFF),
        .direction = if (proto_info & 0x8000 != 0) .responder else .initiator,
        .payload_length = payload_length,
    };
}

/// Bearer abstraction for reading/writing SDUs over a stream (TCP or Unix socket).
pub const Bearer = struct {
    stream: std.net.Stream,

    /// Per-protocol ingress buffers for multi-SDU reassembly.
    /// Following the Haskell mux design (Network/Mux/Ingress.hs):
    /// one buffer per protocol number for demultiplexing interleaved SDUs.
    ingress_buffers: [16]IngressBuffer = [_]IngressBuffer{IngressBuffer{}} ** 16,

    /// Read one complete SDU (header + payload). Caller must provide buffer.
    /// Returns the decoded header and a slice of the payload within buf.
    pub fn readSDU(self: *Bearer, buf: []u8) !struct { header: SDUHeader, payload: []const u8 } {
        // Read 8-byte header
        var hdr_buf: [header_length]u8 = undefined;
        try self.readExact(&hdr_buf);

        const header = decodeHeader(&hdr_buf);

        if (header.payload_length > buf.len) {
            return error.BufferTooSmall;
        }

        // Read payload
        if (header.payload_length > 0) {
            try self.readExact(buf[0..header.payload_length]);
        }

        return .{
            .header = header,
            .payload = buf[0..header.payload_length],
        };
    }

    /// Write one SDU. If payload exceeds max_sdu_payload, fragments into multiple SDUs.
    pub fn writeSDU(self: *Bearer, protocol_num: u15, direction: Direction, payload: []const u8) !void {
        var offset: usize = 0;
        while (offset < payload.len) {
            const remaining = payload.len - offset;
            const chunk_size: u16 = @intCast(@min(remaining, max_sdu_payload));

            const header = SDUHeader{
                .transmission_time = 0, // TODO: monotonic clock
                .protocol_num = protocol_num,
                .direction = direction,
                .payload_length = chunk_size,
            };

            const hdr_bytes = encodeHeader(header);
            try self.writeAll(&hdr_bytes);
            try self.writeAll(payload[offset .. offset + chunk_size]);
            offset += chunk_size;
        }

        // Handle empty payload (e.g., for signaling)
        if (payload.len == 0) {
            const header = SDUHeader{
                .transmission_time = 0,
                .protocol_num = protocol_num,
                .direction = direction,
                .payload_length = 0,
            };
            const hdr_bytes = encodeHeader(header);
            try self.writeAll(&hdr_bytes);
        }
    }

    const IngressBuffer = struct {
        data: [256 * 1024]u8 = undefined, // 256KB per protocol (enough for large blocks)
        len: usize = 0,

        fn append(self: *IngressBuffer, payload: []const u8) !void {
            if (self.len + payload.len > self.data.len) return error.IngressOverflow;
            @memcpy(self.data[self.len..][0..payload.len], payload);
            self.len += payload.len;
        }

        fn slice(self: *const IngressBuffer) []const u8 {
            return self.data[0..self.len];
        }

        fn clear(self: *IngressBuffer) void {
            self.len = 0;
        }
    };

    /// Read a complete protocol message that may span multiple SDUs.
    ///
    /// Following the Haskell mux design (Network/Mux.hs, Network/Mux/Ingress.hs):
    /// 1. Read SDUs from the bearer
    /// 2. Buffer SDU payloads per protocol (demultiplexing)
    /// 3. After each SDU, try to parse a complete CBOR value from the buffer
    /// 4. If complete, return the message bytes
    /// 5. If incomplete, read more SDUs
    ///
    /// The mux does NOT know message boundaries — CBOR framing determines
    /// when a complete message has been received.
    pub fn readProtocolMessage(self: *Bearer, protocol_num: u15, allocator: std.mem.Allocator) ![]u8 {
        const Decoder = @import("../cbor/decoder.zig").Decoder;

        var sdu_buf: [max_sdu_payload]u8 = undefined;
        const buf_idx: usize = @intCast(@min(protocol_num, 15));

        while (true) {
            // Check if we already have a complete CBOR value in the buffer
            const buffered = self.ingress_buffers[buf_idx].slice();
            if (buffered.len > 0) {
                var dec = Decoder.init(buffered);
                if (dec.sliceOfNextValue()) |complete_msg| {
                    // Found a complete CBOR message
                    const result = try allocator.alloc(u8, complete_msg.len);
                    @memcpy(result, complete_msg);

                    // Shift remaining bytes to front of buffer
                    const remaining = buffered.len - dec.pos;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, self.ingress_buffers[buf_idx].data[0..remaining], buffered[dec.pos..]);
                    }
                    self.ingress_buffers[buf_idx].len = remaining;

                    return result;
                } else |_| {
                    // Incomplete CBOR — need more data
                }
            }

            // Read one SDU from the wire
            const sdu = try self.readSDU(&sdu_buf);

            // Demux: buffer the payload for its protocol
            const sdu_buf_idx: usize = @intCast(@min(sdu.header.protocol_num, 15));
            try self.ingress_buffers[sdu_buf_idx].append(sdu.payload);
        }
    }

    // -- Internal helpers --

    fn readExact(self: *Bearer, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = self.stream.read(buf[total..]) catch |err| {
                return switch (err) {
                    error.ConnectionResetByPeer => error.ConnectionClosed,
                    else => err,
                };
            };
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }
    }

    fn writeAll(self: *Bearer, data: []const u8) !void {
        var total: usize = 0;
        while (total < data.len) {
            total += self.stream.write(data[total..]) catch |err| {
                return switch (err) {
                    error.BrokenPipe => error.ConnectionClosed,
                    else => err,
                };
            };
        }
    }

    pub const Error = error{
        BufferTooSmall,
        ConnectionClosed,
    };
};

/// Create a Bearer from a TCP stream.
pub fn tcpBearer(stream: std.net.Stream) Bearer {
    return .{ .stream = stream };
}

// ──────────────────────────────────── Tests ────────────────────────────────────
// Golden vectors derived from the Haskell Codec.hs encoding rules.

test "mux: encode header — handshake initiator" {
    // Handshake (protocol 0), initiator (bit 15 = 0), 42 bytes payload
    const header = SDUHeader{
        .transmission_time = 0,
        .protocol_num = 0,
        .direction = .initiator,
        .payload_length = 42,
    };
    const bytes = encodeHeader(header);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x00, 0x00, 0x00, // timestamp = 0
        0x00, 0x00, // proto = 0, direction = initiator (no bit set)
        0x00, 0x2a, // length = 42
    }, &bytes);
}

test "mux: encode header — chain-sync responder" {
    // Chain-sync (protocol 2), responder (bit 15 = 1), 100 bytes
    const header = SDUHeader{
        .transmission_time = 1000,
        .protocol_num = 2,
        .direction = .responder,
        .payload_length = 100,
    };
    const bytes = encodeHeader(header);
    // proto_info = 2 | 0x8000 = 0x8002
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x00, 0x03, 0xe8, // timestamp = 1000
        0x80, 0x02, // proto = 2, direction = responder (bit 15 set)
        0x00, 0x64, // length = 100
    }, &bytes);
}

test "mux: decode header round-trip" {
    const original = SDUHeader{
        .transmission_time = 123456789,
        .protocol_num = 10, // peer-sharing
        .direction = .initiator,
        .payload_length = 5760,
    };
    const encoded = encodeHeader(original);
    const decoded = decodeHeader(&encoded);

    try std.testing.expectEqual(original.transmission_time, decoded.transmission_time);
    try std.testing.expectEqual(original.protocol_num, decoded.protocol_num);
    try std.testing.expectEqual(original.direction, decoded.direction);
    try std.testing.expectEqual(original.payload_length, decoded.payload_length);
}

test "mux: direction bit encoding matches Haskell" {
    // Haskell: putNumAndMode (MiniProtocolNum n) InitiatorDir = n (no bit)
    // Haskell: putNumAndMode (MiniProtocolNum n) ResponderDir = n .|. 0x8000
    const init_header = encodeHeader(.{
        .transmission_time = 0,
        .protocol_num = 3, // block-fetch
        .direction = .initiator,
        .payload_length = 0,
    });
    // Bytes 4-5 should be 0x0003 (no bit 15)
    try std.testing.expectEqual(@as(u16, 0x0003), std.mem.readInt(u16, init_header[4..6], .big));

    const resp_header = encodeHeader(.{
        .transmission_time = 0,
        .protocol_num = 3,
        .direction = .responder,
        .payload_length = 0,
    });
    // Bytes 4-5 should be 0x8003 (bit 15 set)
    try std.testing.expectEqual(@as(u16, 0x8003), std.mem.readInt(u16, resp_header[4..6], .big));
}

test "mux: max SDU payload" {
    try std.testing.expectEqual(@as(u16, 12288), max_sdu_payload);
}

test "mux: header length" {
    try std.testing.expectEqual(@as(usize, 8), header_length);
}
