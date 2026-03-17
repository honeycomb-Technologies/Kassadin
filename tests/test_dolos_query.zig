const std = @import("std");
const kassadin = @import("kassadin");
const block_mod = kassadin.ledger.block;
const tx_mod = kassadin.ledger.transaction;
const Decoder = kassadin.cbor.Decoder;

const grpc_client = kassadin.network.dolos_grpc_client;

const dolos_grpc = "127.0.0.1:50051";

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    try stdout.interface.print("=== Kassadin Dolos gRPC Query Test (preprod) ===\n\n", .{});

    var client = grpc_client.Client.init(allocator, dolos_grpc) catch |err| {
        try stdout.interface.print("FAILED to initialize gRPC client: {}\n", .{err});
        std.process.exit(1);
    };
    defer client.deinit();

    const tip = try client.readTip();
    try stdout.interface.print("[1] Tip: slot={} height={} hash={x}{x}{x}{x}...\n", .{
        tip.slot,
        tip.height,
        tip.hash[0],
        tip.hash[1],
        tip.hash[2],
        tip.hash[3],
    });

    var current = tip;
    var depth: u32 = 0;

    while (depth < 16) : (depth += 1) {
        const block_raw = (try client.fetchBlock(current)) orelse {
            try stdout.interface.print("FAILED to fetch block at depth {}\n", .{depth});
            std.process.exit(1);
        };
        defer allocator.free(block_raw);

        const block = try block_mod.parseBlock(block_raw);
        var tx_dec = Decoder.init(block.tx_bodies_raw);
        const num_txs = (try tx_dec.decodeArrayLen()) orelse 0;
        try stdout.interface.print("[2] Depth {}: slot={} block={} txs={}\n", .{
            depth,
            block.header.slot,
            block.header.block_no,
            num_txs,
        });

        var tx_index: usize = 0;
        while (tx_index < num_txs) : (tx_index += 1) {
            const tx_raw = try tx_dec.sliceOfNextValue();
            var tx = tx_mod.parseTxBody(allocator, tx_raw) catch continue;
            defer tx_mod.freeTxBody(allocator, &tx);

            if (tx.outputs.len == 0) continue;

            const probe_count = @min(tx.outputs.len, 8);
            const txins = try allocator.alloc(kassadin.types.TxIn, probe_count);
            defer allocator.free(txins);

            for (0..probe_count) |i| {
                txins[i] = .{
                    .tx_id = tx.tx_id,
                    .tx_ix = @intCast(i),
                };
            }

            const entries = try client.readHistoricalUtxos(allocator, txins);
            defer grpc_client.freeReadUtxos(allocator, entries);

            if (entries.len == probe_count) {
                try stdout.interface.print("[3] ReadTx returned {} historical outputs for tx {x}{x}{x}{x}...\n", .{
                    entries.len,
                    tx.tx_id[0],
                    tx.tx_id[1],
                    tx.tx_id[2],
                    tx.tx_id[3],
                });
                try stdout.interface.print("\n=== DOLOS gRPC QUERY PASSED ===\n", .{});
                return;
            }
        }

        if (block.header.prev_hash) |prev_hash| {
            current = .{ .hash = prev_hash };
        } else {
            break;
        }
    }

    try stdout.interface.print("FAILED to find a recent block with queryable live UTxOs\n", .{});
    std.process.exit(1);
}
