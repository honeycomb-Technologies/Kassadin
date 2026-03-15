const std = @import("std");
const kassadin = @import("kassadin");
const mux = kassadin.network.mux;
const handshake = kassadin.network.handshake;
const blockfetch = kassadin.network.blockfetch;
const chainsync = kassadin.network.chainsync;
const protocol = kassadin.network.protocol;
const block_mod = kassadin.ledger.block;
const tx_mod = kassadin.ledger.transaction;
const Encoder = kassadin.cbor.enc.Encoder;
const Decoder = kassadin.cbor.Decoder;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Block Fetch Test ===\n\n", .{});

    // Step 1: Connect and handshake
    std.debug.print("[1] Connecting...\n", .{});
    const stream = try std.net.tcpConnectToHost(allocator, "preview-node.play.dev.cardano.org", 3001);
    var bearer = mux.tcpBearer(stream);

    const hs_result = try handshake.performHandshake(allocator, &bearer, protocol.NetworkMagic.preview);
    switch (hs_result) {
        .accepted => |a| std.debug.print("  Handshake v{}\n", .{a.version}),
        .refused => {
            std.debug.print("  Refused\n", .{});
            return;
        },
    }

    // Step 2: Chain-sync to discover a point
    std.debug.print("[2] Chain-sync for point...\n", .{});
    const find_bytes = try chainsync.encodeMsg(allocator, .{ .find_intersect = .{ .points = &[_]chainsync.Point{} } });
    defer allocator.free(find_bytes);
    try bearer.writeSDU(2, .initiator, find_bytes);
    const find_resp = try bearer.readProtocolMessage(2, allocator);
    defer allocator.free(find_resp);
    const find_msg = try chainsync.decodeMsg(find_resp);

    var tip_slot: u64 = 0;
    var tip_hash: [32]u8 = undefined;
    switch (find_msg) {
        .intersect_not_found => |inf| {
            tip_slot = inf.tip.slot;
            tip_hash = inf.tip.hash;
            std.debug.print("  Tip: slot={}\n", .{tip_slot});
        },
        .intersect_found => |isf| {
            tip_slot = isf.tip.slot;
            tip_hash = isf.tip.hash;
        },
        else => return,
    }

    // Get one header to find a block point
    const req_bytes = try chainsync.encodeMsg(allocator, .request_next);
    defer allocator.free(req_bytes);
    try bearer.writeSDU(2, .initiator, req_bytes);
    const req_resp = try bearer.readProtocolMessage(2, allocator);
    defer allocator.free(req_resp);
    const req_msg = try chainsync.decodeMsg(req_resp);

    switch (req_msg) {
        .roll_forward => |rf| {
            tip_slot = rf.tip.slot;
            tip_hash = rf.tip.hash;
            std.debug.print("  Got header, tip: slot={}\n", .{tip_slot});
        },
        else => {},
    }

    // Step 3: Block-fetch using the tip point
    std.debug.print("[3] Block-fetch at slot {}...\n", .{tip_slot});

    const point = chainsync.Point{ .slot = tip_slot, .hash = tip_hash };
    const bf_bytes = try blockfetch.encodeMsg(allocator, .{
        .request_range = .{ .from = point, .to = point },
    });
    defer allocator.free(bf_bytes);

    std.debug.print("  Sending request ({} bytes)...\n", .{bf_bytes.len});
    try bearer.writeSDU(3, .initiator, bf_bytes);

    std.debug.print("  Reading response...\n", .{});
    const bf_resp1 = try bearer.readProtocolMessage(3, allocator);
    defer allocator.free(bf_resp1);

    std.debug.print("  Got {} bytes\n", .{bf_resp1.len});
    const bf_msg1 = try blockfetch.decodeMsg(bf_resp1);

    switch (bf_msg1) {
        .start_batch => {
            std.debug.print("  StartBatch! Reading block...\n", .{});
            const bf_resp2 = try bearer.readProtocolMessage(3, allocator);
            defer allocator.free(bf_resp2);
            std.debug.print("  Got block: {} bytes\n", .{bf_resp2.len});

            // Decode [4, block_cbor]
            var dec = Decoder.init(bf_resp2);
            _ = try dec.decodeArrayLen();
            const tag = try dec.decodeUint();
            if (tag == 4) {
                const block_cbor = try dec.sliceOfNextValue();
                std.debug.print("  Block CBOR: {} bytes\n", .{block_cbor.len});

                const blk = try block_mod.parseBlock(block_cbor);
                std.debug.print("  Era: {}\n", .{@intFromEnum(blk.era)});
                std.debug.print("  Block: {}\n", .{blk.header.block_no});
                std.debug.print("  Slot: {}\n", .{blk.header.slot});

                var tx_dec = Decoder.init(blk.tx_bodies_raw);
                const num_txs = (try tx_dec.decodeArrayLen()) orelse 0;
                std.debug.print("  Txs: {}\n", .{num_txs});

                std.debug.print("\n=== BLOCK FETCH SUCCESS ===\n", .{});
            }
        },
        .no_blocks => std.debug.print("  NoBlocks\n", .{}),
        else => std.debug.print("  Unexpected: {}\n", .{@intFromEnum(bf_msg1)}),
    }

    stream.close();
}
