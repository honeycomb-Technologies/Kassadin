const std = @import("std");
const kassadin = @import("kassadin");
const peer_mod = kassadin.network.peer;
const chainsync = kassadin.network.chainsync;
const protocol = kassadin.network.protocol;
const block_mod = kassadin.ledger.block;
const tx_mod = kassadin.ledger.transaction;
const Decoder = kassadin.cbor.Decoder;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Kassadin Block Fetch Test ===\n\n", .{});

    // Connect to preview
    std.debug.print("[1] Connecting to preview...\n", .{});
    var p = peer_mod.Peer.connect(allocator, "preview-node.play.dev.cardano.org", 3001, protocol.NetworkMagic.preview) catch |err| {
        std.debug.print("Failed: {}\n", .{err});
        return;
    };
    defer p.close();
    std.debug.print("  Connected v{}\n", .{p.negotiated_version.?});

    // Chain-sync to find a block point
    std.debug.print("\n[2] Finding a block point via chain-sync...\n", .{});
    _ = try p.chainSyncFindIntersect(&[_]chainsync.Point{});

    // Get a few headers to find a real point
    var found_point: ?chainsync.Point = null;
    for (0..20) |_| {
        const msg = try p.chainSyncRequestNext();
        switch (msg) {
            .roll_forward => |rf| {
                if (!rf.tip.is_genesis) {
                    found_point = .{ .slot = rf.tip.slot, .hash = rf.tip.hash };
                }
            },
            else => {},
        }
    }

    if (found_point) |point| {
        std.debug.print("  Found point: slot={}\n", .{point.slot});

        // Block-fetch the full block
        std.debug.print("\n[3] Fetching full block at slot {}...\n", .{point.slot});
        const block_data = try p.blockFetchSingle(point);

        if (block_data) |data| {
            defer allocator.free(data);
            std.debug.print("  Block data received: {} bytes\n", .{data.len});

            // The block-fetch response is [4, block_cbor] — extract the block
            var dec = Decoder.init(data);
            const arr_len = try dec.decodeArrayLen();
            if (arr_len) |len| {
                if (len == 2) {
                    const tag = try dec.decodeUint();
                    if (tag == 4) {
                        const block_cbor = try dec.sliceOfNextValue();
                        std.debug.print("  Inner block CBOR: {} bytes\n", .{block_cbor.len});

                        // Parse the block
                        const blk = block_mod.parseBlock(block_cbor) catch |err| {
                            std.debug.print("  Parse error: {}\n", .{err});
                            return;
                        };

                        std.debug.print("  Era: {}\n", .{@intFromEnum(blk.era)});
                        std.debug.print("  Block: {}\n", .{blk.header.block_no});
                        std.debug.print("  Slot: {}\n", .{blk.header.slot});
                        std.debug.print("  Body size: {}\n", .{blk.header.block_body_size});

                        // Parse transactions
                        var tx_dec = Decoder.init(blk.tx_bodies_raw);
                        const num_txs = (try tx_dec.decodeArrayLen()) orelse 0;
                        std.debug.print("  Transactions: {}\n", .{num_txs});

                        if (num_txs > 0) {
                            const tx_raw = try tx_dec.sliceOfNextValue();
                            var tx = tx_mod.parseTxBody(allocator, tx_raw) catch |err| {
                                std.debug.print("  Tx parse error: {}\n", .{err});
                                return;
                            };
                            defer tx_mod.freeTxBody(allocator, &tx);
                            std.debug.print("  Tx 0: {} inputs, {} outputs, fee={}\n", .{
                                tx.inputs.len, tx.outputs.len, tx.fee,
                            });
                        }

                        std.debug.print("\n=== BLOCK FETCH SUCCESS ===\n", .{});
                        std.debug.print("  Downloaded and parsed a REAL block from the Cardano preview network\n", .{});
                    }
                }
            }
        } else {
            std.debug.print("  No blocks returned\n", .{});
        }
    } else {
        std.debug.print("  No points found\n", .{});
    }
}
