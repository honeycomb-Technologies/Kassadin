const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const Encoder = @import("../cbor/encoder.zig").Encoder;
const UtxoEntry = @import("../storage/ledger.zig").UtxoEntry;
const Blake2b224 = @import("../crypto/hash.zig").Blake2b224;
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

pub fn decodeByronBase58Address(allocator: Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return error.InvalidBase58;

    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(allocator);

    for (text) |ch| {
        const value = base58Value(ch) orelse return error.InvalidBase58;

        var carry: u32 = value;
        for (digits.items) |*digit| {
            const accum = (@as(u32, digit.*) * 58) + carry;
            digit.* = @intCast(accum & 0xff);
            carry = accum >> 8;
        }
        while (carry > 0) {
            try digits.append(allocator, @intCast(carry & 0xff));
            carry >>= 8;
        }
    }

    var leading_zeroes: usize = 0;
    for (text) |ch| {
        if (ch != '1') break;
        leading_zeroes += 1;
    }
    try digits.appendNTimes(allocator, 0, leading_zeroes);

    const out = try allocator.alloc(u8, digits.items.len);
    for (digits.items, 0..) |digit, idx| {
        out[out.len - 1 - idx] = digit;
    }
    return out;
}

pub fn decodeCompactRedeemVkBase64Url(text: []const u8) ![32]u8 {
    const decoder = if (std.mem.indexOfScalar(u8, text, '=') != null)
        std.base64.url_safe.Decoder
    else
        std.base64.url_safe_no_pad.Decoder;

    const decoded_len = try decoder.calcSizeForSlice(text);
    if (decoded_len != 32) return error.InvalidRedeemVerificationKey;

    var out: [32]u8 = undefined;
    try decoder.decode(out[0..decoded_len], text);
    return out;
}

pub fn makeByronRedeemAddress(
    allocator: Allocator,
    protocol_magic: u32,
    redeem_vk: [32]u8,
) ![]u8 {
    var address_prime = Encoder.init(allocator);
    defer address_prime.deinit();
    try encodeAddressPrime(&address_prime, protocol_magic, &redeem_vk);

    var sha3_digest: [32]u8 = undefined;
    var sha3 = std.crypto.hash.sha3.Sha3_256.init(.{});
    sha3.update(address_prime.getWritten());
    sha3.final(&sha3_digest);

    const root = Blake2b224.hash(&sha3_digest);

    var body = Encoder.init(allocator);
    defer body.deinit();
    try body.encodeArrayLen(3);
    try body.encodeBytes(&root);
    try encodeAddressAttributes(&body, protocol_magic);
    try body.encodeUint(2); // ATRedeem

    const crc = std.hash.Crc32.hash(body.getWritten());

    var out = Encoder.init(allocator);
    defer out.deinit();
    try out.encodeArrayLen(2);
    try out.encodeTag(24);
    try out.encodeBytes(body.getWritten());
    try out.encodeUint(crc);
    return out.toOwnedSlice();
}

pub fn computeGenesisTxIn(address_cbor: []const u8) types.TxIn {
    return .{
        .tx_id = Blake2b256.hash(address_cbor),
        .tx_ix = 0,
    };
}

pub fn encodeByronTxOut(allocator: Allocator, address_cbor: []const u8, coin: u64) ![]u8 {
    var enc = Encoder.init(allocator);
    defer enc.deinit();
    try enc.encodeArrayLen(2);
    try enc.writeRaw(address_cbor);
    try enc.encodeUint(coin);
    return enc.toOwnedSlice();
}

pub fn buildNonAvvmUtxoEntry(
    allocator: Allocator,
    address_text: []const u8,
    lovelace: u64,
) !UtxoEntry {
    const address_cbor = try decodeByronBase58Address(allocator, address_text);
    defer allocator.free(address_cbor);

    return .{
        .tx_in = computeGenesisTxIn(address_cbor),
        .value = lovelace,
        .raw_cbor = try encodeByronTxOut(allocator, address_cbor, lovelace),
    };
}

pub fn buildAvvmUtxoEntry(
    allocator: Allocator,
    protocol_magic: u32,
    redeem_vk_text: []const u8,
    lovelace: u64,
) !UtxoEntry {
    const redeem_vk = try decodeCompactRedeemVkBase64Url(redeem_vk_text);
    const address_cbor = try makeByronRedeemAddress(allocator, protocol_magic, redeem_vk);
    defer allocator.free(address_cbor);

    return .{
        .tx_in = computeGenesisTxIn(address_cbor),
        .value = lovelace,
        .raw_cbor = try encodeByronTxOut(allocator, address_cbor, lovelace),
    };
}

fn encodeAddressPrime(enc: *Encoder, protocol_magic: u32, redeem_vk: *const [32]u8) !void {
    try enc.encodeArrayLen(3);
    try enc.encodeUint(2); // ATRedeem
    try enc.encodeArrayLen(2);
    try enc.encodeUint(2); // RedeemASD
    try enc.encodeBytes(redeem_vk);
    try encodeAddressAttributes(enc, protocol_magic);
}

fn encodeAddressAttributes(enc: *Encoder, protocol_magic: u32) !void {
    if (protocol_magic == 764_824_073) {
        try enc.encodeMapLen(0);
        return;
    }

    var nested = Encoder.init(enc.allocator);
    defer nested.deinit();
    try nested.encodeUint(protocol_magic);

    try enc.encodeMapLen(1);
    try enc.encodeUint(2);
    try enc.encodeBytes(nested.getWritten());
}

fn base58Value(ch: u8) ?u8 {
    return switch (ch) {
        '1'...'9' => ch - '1',
        'A'...'H' => 9 + (ch - 'A'),
        'J'...'N' => 17 + (ch - 'J'),
        'P'...'Z' => 22 + (ch - 'P'),
        'a'...'k' => 33 + (ch - 'a'),
        'm'...'z' => 44 + (ch - 'm'),
        else => null,
    };
}

fn hexDecode(comptime len: usize, hex: *const [len * 2]u8) [len]u8 {
    var out: [len]u8 = undefined;
    for (0..len) |i| {
        out[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return out;
}

test "byron genesis utxo: decode non-AVVM base58 address and pseudo input" {
    const allocator = std.testing.allocator;

    const address = try decodeByronBase58Address(
        allocator,
        "FHnt4NL7yPXhCzCHVywZLqVsvwuG3HvwmjKXQJBrXh3h2aigv6uxkePbpzRNV8q",
    );
    defer allocator.free(address);

    const expected_address = hexDecode(46, "82d818582483581c056d8907b4530dabec0ab77456a2b5c7e695150d7534380a8093091ea1024101001ae0af87de");
    try std.testing.expectEqualSlices(u8, &expected_address, address);

    const tx_in = computeGenesisTxIn(address);
    const expected_tx_id = hexDecode(32, "8e0280beebc3d12626e87b182f4205d75e49981042f54081cd35f3a4a85630b0");
    try std.testing.expectEqualSlices(u8, &expected_tx_id, &tx_in.tx_id);
    try std.testing.expectEqual(@as(types.TxIx, 0), tx_in.tx_ix);
}

test "byron genesis utxo: construct mainnet AVVM redeem address and pseudo input" {
    const allocator = std.testing.allocator;

    const address = try makeByronRedeemAddress(
        allocator,
        764_824_073,
        try decodeCompactRedeemVkBase64Url("-0BJDi-gauylk4LptQTgjMeo7kY9lTCbZv12vwOSTZk="),
    );
    defer allocator.free(address);

    const expected_address = hexDecode(43, "82d818582183581cccdf735b7d5cafe44e65e75a82fd4305fe7712924a8e1196fefdbddfa0021a9cbc2ffe");
    try std.testing.expectEqualSlices(u8, &expected_address, address);

    const tx_in = computeGenesisTxIn(address);
    const expected_tx_id = hexDecode(32, "8ee33c9906974706223d7d500d63bbee2369d7150f972757a9fdded2f706b938");
    try std.testing.expectEqualSlices(u8, &expected_tx_id, &tx_in.tx_id);
    try std.testing.expectEqual(@as(types.TxIx, 0), tx_in.tx_ix);
}
