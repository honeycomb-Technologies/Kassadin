const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const praos = @import("../consensus/praos.zig");
const protocol_update = @import("../ledger/protocol_update.zig");
const ChainDB = @import("../storage/chaindb.zig").ChainDB;

const checkpoint_version: u32 = 3;

/// Maximum number of OCert counter entries we'll persist.
/// Preprod has ~500 active pools; mainnet ~3,000. 8,192 is generous headroom.
const max_ocert_entries: u32 = 8192;

/// Maximum checkpoint file size: header + nonces + 8192 * 36 bytes.
const max_file_size: usize = 1024 + max_ocert_entries * 36;

pub const LoadResult = struct {
    state: praos.PraosState,
    ocert_counters: []ChainDB.OcertCounterEntry,

    pub fn deinit(self: *LoadResult, allocator: Allocator) void {
        allocator.free(self.ocert_counters);
    }
};

fn checkpointPath(allocator: Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/praos.resume", .{db_path});
}

fn writeFlavor(writer: anytype, flavor: praos.Flavor) !void {
    try writer.writeByte(@intFromEnum(flavor));
}

fn readFlavor(reader: anytype) !praos.Flavor {
    return std.meta.intToEnum(praos.Flavor, try reader.readByte()) catch error.InvalidCheckpoint;
}

fn writeNonce(writer: anytype, nonce: types.Nonce) !void {
    switch (nonce) {
        .neutral => {
            try writer.writeByte(0);
            try writer.writeByteNTimes(0, 32);
        },
        .hash => |hash| {
            try writer.writeByte(1);
            try writer.writeAll(&hash);
        },
    }
}

fn readNonce(reader: anytype) !types.Nonce {
    const tag = try reader.readByte();
    var hash: [32]u8 = undefined;
    try reader.readNoEof(&hash);
    return switch (tag) {
        0 => .neutral,
        1 => .{ .hash = hash },
        else => error.InvalidCheckpoint,
    };
}

pub fn load(
    allocator: Allocator,
    db_path: []const u8,
    point: types.Point,
    config: *const protocol_update.GovernanceConfig,
) !?LoadResult {
    const path = try checkpointPath(allocator, db_path);
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, max_file_size) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(data);

    var stream = std.io.fixedBufferStream(data);
    const reader = stream.reader();
    const version = try reader.readInt(u32, .big);
    if (version != checkpoint_version) return null;

    const stored_slot = try reader.readInt(u64, .big);
    var stored_hash: [32]u8 = undefined;
    try reader.readNoEof(&stored_hash);
    if (stored_slot != point.slot or !std.mem.eql(u8, &stored_hash, &point.hash)) return null;

    const stored_epoch_length = try reader.readInt(u64, .big);
    const stored_stability_window = try reader.readInt(u64, .big);
    if (stored_epoch_length != config.epoch_length or stored_stability_window != config.stability_window) return null;

    if (!types.Nonce.eql(try readNonce(reader), config.initial_nonce)) return null;
    if (!types.Nonce.eql(try readNonce(reader), config.extra_entropy)) return null;

    const state = praos.PraosState{
        .flavor = try readFlavor(reader),
        .evolving_nonce = try readNonce(reader),
        .candidate_nonce = try readNonce(reader),
        .epoch_nonce = try readNonce(reader),
        .previous_epoch_nonce = try readNonce(reader),
        .last_epoch_block_nonce = try readNonce(reader),
        .lab_nonce = try readNonce(reader),
    };

    const ocert_count = try reader.readInt(u32, .big);
    if (ocert_count > max_ocert_entries) return null;

    const counters = try allocator.alloc(ChainDB.OcertCounterEntry, ocert_count);
    errdefer allocator.free(counters);
    for (counters) |*entry| {
        try reader.readNoEof(&entry.issuer);
        entry.counter = try reader.readInt(u64, .big);
    }

    return .{
        .state = state,
        .ocert_counters = counters,
    };
}

pub fn save(
    allocator: Allocator,
    db_path: []const u8,
    point: types.Point,
    config: *const protocol_update.GovernanceConfig,
    state: praos.PraosState,
    ocert_counters: *const std.AutoHashMap(types.KeyHash, u64),
) !void {
    const path = try checkpointPath(allocator, db_path);
    defer allocator.free(path);

    std.fs.cwd().makePath(db_path) catch {};

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.ensureTotalCapacity(allocator, 512 + ocert_counters.count() * 36);
    const writer = bytes.writer(allocator);
    try writer.writeInt(u32, checkpoint_version, .big);
    try writer.writeInt(u64, point.slot, .big);
    try writer.writeAll(&point.hash);
    try writer.writeInt(u64, config.epoch_length, .big);
    try writer.writeInt(u64, config.stability_window, .big);
    try writeNonce(writer, config.initial_nonce);
    try writeNonce(writer, config.extra_entropy);
    try writeFlavor(writer, state.flavor);
    try writeNonce(writer, state.evolving_nonce);
    try writeNonce(writer, state.candidate_nonce);
    try writeNonce(writer, state.epoch_nonce);
    try writeNonce(writer, state.previous_epoch_nonce);
    try writeNonce(writer, state.last_epoch_block_nonce);
    try writeNonce(writer, state.lab_nonce);

    try writer.writeInt(u32, @intCast(ocert_counters.count()), .big);
    var it = ocert_counters.iterator();
    while (it.next()) |entry| {
        try writer.writeAll(&entry.key_ptr.*);
        try writer.writeInt(u64, entry.value_ptr.*, .big);
    }

    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = bytes.items,
    });
}

test "praos checkpoint: round trip with OCert counters" {
    const allocator = std.testing.allocator;
    const db_path = "/tmp/kassadin-praos-checkpoint";
    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};

    const point = types.Point{
        .slot = 1234,
        .hash = [_]u8{0xab} ** 32,
    };
    const config = protocol_update.GovernanceConfig{
        .epoch_length = 100,
        .stability_window = 10,
        .update_quorum = 1,
        .initial_nonce = .{ .hash = [_]u8{0x11} ** 32 },
        .extra_entropy = .{ .hash = [_]u8{0x22} ** 32 },
        .decentralization_param = .{ .numerator = 0, .denominator = 1 },
        .reward_params = @import("../ledger/rewards.zig").RewardParams.mainnet_defaults,
        .initial_genesis_delegations = try allocator.alloc(protocol_update.GenesisDelegation, 0),
    };
    defer allocator.free(config.initial_genesis_delegations);

    const state = praos.PraosState{
        .flavor = .praos,
        .evolving_nonce = .{ .hash = [_]u8{0x31} ** 32 },
        .candidate_nonce = .neutral,
        .epoch_nonce = .{ .hash = [_]u8{0x33} ** 32 },
        .previous_epoch_nonce = .{ .hash = [_]u8{0x34} ** 32 },
        .last_epoch_block_nonce = .neutral,
        .lab_nonce = .{ .hash = [_]u8{0x35} ** 32 },
    };

    var counters = std.AutoHashMap(types.KeyHash, u64).init(allocator);
    defer counters.deinit();
    try counters.put([_]u8{0xaa} ** 28, 42);
    try counters.put([_]u8{0xbb} ** 28, 7);

    try save(allocator, db_path, point, &config, state, &counters);
    var result = (try load(allocator, db_path, point, &config)).?;
    defer result.deinit(allocator);

    try std.testing.expectEqual(praos.Flavor.praos, result.state.flavor);
    try std.testing.expect(types.Nonce.eql(result.state.evolving_nonce, state.evolving_nonce));
    try std.testing.expect(types.Nonce.eql(result.state.candidate_nonce, state.candidate_nonce));
    try std.testing.expect(types.Nonce.eql(result.state.epoch_nonce, state.epoch_nonce));
    try std.testing.expect(types.Nonce.eql(result.state.previous_epoch_nonce, state.previous_epoch_nonce));
    try std.testing.expect(types.Nonce.eql(result.state.last_epoch_block_nonce, state.last_epoch_block_nonce));
    try std.testing.expect(types.Nonce.eql(result.state.lab_nonce, state.lab_nonce));

    try std.testing.expectEqual(@as(usize, 2), result.ocert_counters.len);
    var loaded_map = std.AutoHashMap(types.KeyHash, u64).init(allocator);
    defer loaded_map.deinit();
    for (result.ocert_counters) |entry| {
        try loaded_map.put(entry.issuer, entry.counter);
    }
    try std.testing.expectEqual(@as(u64, 42), loaded_map.get([_]u8{0xaa} ** 28).?);
    try std.testing.expectEqual(@as(u64, 7), loaded_map.get([_]u8{0xbb} ** 28).?);
}

test "praos checkpoint: old version returns null" {
    const allocator = std.testing.allocator;
    const db_path = "/tmp/kassadin-praos-checkpoint-version";
    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};

    std.fs.cwd().makePath(db_path) catch {};
    const path = try checkpointPath(allocator, db_path);
    defer allocator.free(path);

    // Write a file with version 2 (old format)
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, 2, .big);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = &header });

    const point = types.Point{ .slot = 0, .hash = [_]u8{0} ** 32 };
    const config = protocol_update.GovernanceConfig{
        .epoch_length = 100,
        .stability_window = 10,
        .update_quorum = 1,
        .initial_nonce = .neutral,
        .extra_entropy = .neutral,
        .decentralization_param = .{ .numerator = 0, .denominator = 1 },
        .reward_params = @import("../ledger/rewards.zig").RewardParams.mainnet_defaults,
        .initial_genesis_delegations = try allocator.alloc(protocol_update.GenesisDelegation, 0),
    };
    defer allocator.free(config.initial_genesis_delegations);

    const result = try load(allocator, db_path, point, &config);
    try std.testing.expect(result == null);
}
