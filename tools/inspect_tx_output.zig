const std = @import("std");
const Decoder = @import("cbor/decoder.zig").Decoder;
const block_mod = @import("ledger/block.zig");
const tx_mod = @import("ledger/transaction.zig");

fn readChunkData(allocator: std.mem.Allocator, immutable_path: []const u8, chunk_num: u32) ![]u8 {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{ immutable_path, chunk_num });
    return std.fs.cwd().readFileAlloc(allocator, path, 512 * 1024 * 1024);
}

fn countChunks(immutable_path: []const u8) !u32 {
    var dir = try std.fs.cwd().openDir(immutable_path, .{ .iterate = true });
    defer dir.close();

    var max_chunk: ?u32 = null;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".chunk")) continue;
        const num = std.fmt.parseInt(u32, entry.name[0 .. entry.name.len - 6], 10) catch continue;
        max_chunk = if (max_chunk) |current| @max(current, num) else num;
    }

    return if (max_chunk) |num| num + 1 else 0;
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.debug.print("usage: zig run src/inspect_tx_output.zig -- <immutable_path> <txid_hex>\n", .{});
        return;
    }

    const immutable_path = args[1];
    const txid_hex = args[2];
    if (txid_hex.len != 64) return error.InvalidArgument;

    var target_txid: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&target_txid, txid_hex);

    const total_chunks = try countChunks(immutable_path);
    var chunk_num = total_chunks;
    while (chunk_num > 0) {
        chunk_num -= 1;
        const chunk_data = readChunkData(allocator, immutable_path, chunk_num) catch continue;
        defer allocator.free(chunk_data);

        var pos: usize = 0;
        while (pos < chunk_data.len) {
            var dec = Decoder.init(chunk_data[pos..]);
            const block_slice = dec.sliceOfNextValue() catch break;
            const raw = chunk_data[pos .. pos + block_slice.len];
            pos += block_slice.len;

            const block = block_mod.parseBlock(raw) catch continue;

            var tx_dec = Decoder.init(block.tx_bodies_raw);
            const num_txs = (tx_dec.decodeArrayLen() catch null) orelse 0;

            var tx_idx: u64 = 0;
            while (tx_idx < num_txs) : (tx_idx += 1) {
                const tx_raw = tx_dec.sliceOfNextValue() catch break;
                var tx = tx_mod.parseTxBody(allocator, tx_raw) catch continue;
                defer tx_mod.freeTxBody(allocator, &tx);

                if (!std.mem.eql(u8, &tx.tx_id, &target_txid)) continue;

                std.debug.print(
                    "found tx in chunk={d:0>5} slot={} block={} tx_index={}\n",
                    .{ chunk_num, block.header.slot, block.header.block_no, tx_idx },
                );
                for (tx.outputs, 0..) |out, ix| {
                    std.debug.print("  output[{}] value={} raw_len={}\n", .{ ix, out.value, out.raw_cbor.len });
                }
                return;
            }
        }
    }

    std.debug.print("tx not found\n", .{});
}
