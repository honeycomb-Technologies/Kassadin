const std = @import("std");
const Allocator = std.mem.Allocator;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");
const block_mod = @import("../ledger/block.zig");
const protocol_update = @import("../ledger/protocol_update.zig");
const header_validation = @import("../consensus/header_validation.zig");
const praos = @import("../consensus/praos.zig");
const runtime_control = @import("runtime_control.zig");

pub const RestoreResult = struct {
    state: ?praos.PraosState = null,
    blocks_scanned: u64 = 0,
    shelley_blocks_scanned: u64 = 0,
};

pub fn reconstructFromImmutable(
    allocator: Allocator,
    immutable_path: []const u8,
    target_slot: types.SlotNo,
    raw_cbor_boundary: ?u32,
    config: *const protocol_update.GovernanceConfig,
) !RestoreResult {
    var result = RestoreResult{};
    const reader = try @import("chunk_reader.zig").ChunkReader.init(immutable_path);
    if (reader.total_chunks == 0) return result;

    var state: ?praos.PraosState = null;
    var last_shelley_slot: ?types.SlotNo = null;

    std.debug.print("Reconstructing Praos state from {} immutable chunks (this may take several minutes)...\n", .{reader.total_chunks});

    var chunk_idx: u32 = 0;
    outer: while (chunk_idx < reader.total_chunks) : (chunk_idx += 1) {
        if (runtime_control.stopRequested()) return error.Interrupted;

        if (chunk_idx > 0 and chunk_idx % 500 == 0) {
            std.debug.print("  Praos reconstruction: chunk {}/{} ({}%)...\n", .{
                chunk_idx, reader.total_chunks, chunk_idx * 100 / reader.total_chunks,
            });
        }

        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>5}.chunk", .{
            immutable_path,
            chunk_idx,
        });
        const chunk_data = try std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024 * 1024);
        defer allocator.free(chunk_data);

        const raw_cbor_chunk = raw_cbor_boundary != null and chunk_idx <= raw_cbor_boundary.?;
        var pos: usize = 0;
        while (pos < chunk_data.len) {
            if (runtime_control.stopRequested()) return error.Interrupted;

            const raw = if (raw_cbor_chunk) blk: {
                var dec = Decoder.init(chunk_data[pos..]);
                const block_slice = dec.sliceOfNextValue() catch break;
                const raw = chunk_data[pos .. pos + block_slice.len];
                pos += block_slice.len;
                break :blk raw;
            } else blk: {
                if (chunk_data.len - pos < 4) break;
                const block_len = std.mem.readInt(u32, chunk_data[pos..][0..4], .big);
                pos += 4;
                if (block_len == 0 or block_len > chunk_data.len - pos) break;
                const raw = chunk_data[pos .. pos + block_len];
                pos += block_len;
                break :blk raw;
            };

            const block = block_mod.parseBlock(raw) catch break; // end of parseable immutable data
            result.blocks_scanned += 1;

            if (block.header.slot > target_slot) break :outer;
            if (block.era == .byron) continue;

            if (state == null) {
                state = praos.PraosState.initWithNonce(config.initial_nonce);
            }

            const is_new_epoch = if (last_shelley_slot) |last_slot|
                config.slotToEpoch(block.header.slot) >
                    config.slotToEpoch(last_slot)
            else
                false;

            switch (block.era) {
                .shelley, .allegra, .mary, .alonzo => state.?.tickTpraos(is_new_epoch, config.extra_entropy),
                .babbage, .conway => state.?.tickPraos(is_new_epoch),
                else => {},
            }
            const nonce_output = try header_validation.extractBlockNonceOutput(&block.header);
            const block_nonce = switch (block.era) {
                .babbage, .conway => praos.praosNonceFromVrfOutput(nonce_output),
                else => praos.nonceFromVrfOutput(nonce_output),
            };
            // Babbage uses 3k/f (backwards compat), Conway+ uses 4k/f.
            const nonce_window = switch (block.era) {
                .conway => if (config.randomness_stabilisation_window > 0)
                    config.randomness_stabilisation_window
                else
                    config.stability_window,
                else => config.stability_window,
            };
            state.?.updateWithBlock(
                block.header.slot,
                block.header.prev_hash,
                block_nonce,
                config.epoch_length,
                nonce_window,
                config.era_start_slot,
            );

            last_shelley_slot = block.header.slot;
            result.shelley_blocks_scanned += 1;
        }
    }

    result.state = state;
    return result;
}
