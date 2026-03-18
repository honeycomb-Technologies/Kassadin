const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const genesis_mod = @import("genesis.zig");
const sync_mod = @import("sync.zig");
const chunk_reader_mod = @import("chunk_reader.zig");
const ledger_snapshot = @import("ledger_snapshot.zig");
const runtime_control = @import("runtime_control.zig");
const snapshot_restore = @import("snapshot_restore.zig");
const block_mod = @import("../ledger/block.zig");
const protocol_update = @import("../ledger/protocol_update.zig");
const ledger_rules = @import("../ledger/rules.zig");
const ChainDB = @import("../storage/chaindb.zig").ChainDB;
const protocol = @import("../network/protocol.zig");

const Point = types.Point;
const checkpoint_version: u32 = 1;
const max_resume_points: usize = 8;

/// Node runner configuration.
pub const RunConfig = struct {
    /// Network to connect to.
    network_magic: u32,
    /// Peer to sync from (hostname:port for N2N, or socket path for N2C).
    peer_host: []const u8,
    peer_port: u16,
    /// Database path for chain storage.
    db_path: []const u8,
    /// Genesis configuration file paths.
    byron_genesis_path: ?[]const u8,
    shelley_genesis_path: ?[]const u8,
    /// Maximum headers to sync (0 = unlimited).
    max_headers: u64,

    pub const preview_defaults = RunConfig{
        .network_magic = protocol.NetworkMagic.preview,
        .peer_host = "preview-node.play.dev.cardano.org",
        .peer_port = 3001,
        .db_path = "db/preview",
        .byron_genesis_path = null,
        .shelley_genesis_path = null,
        .max_headers = 0,
    };

    pub const preprod_defaults = RunConfig{
        .network_magic = protocol.NetworkMagic.preprod,
        .peer_host = "preprod-node.play.dev.cardano.org",
        .peer_port = 3001,
        .db_path = "db/preprod",
        .byron_genesis_path = "byron.json",
        .shelley_genesis_path = "shelley.json",
        .max_headers = 0,
    };
};

/// Run result / status.
pub const RunResult = struct {
    headers_synced: u64,
    blocks_fetched: u64,
    blocks_added_to_chain: u64,
    invalid_blocks: u64,
    tip_slot: u64,
    tip_block_no: u64,
    rollbacks: u64,
    errors: u64,
    genesis_loaded: bool,
    resumed_from_checkpoint: bool,
    resumed_from_snapshot: bool,
    snapshot_anchor_used: bool,
    validation_enabled: bool,
    snapshot_tip_slot: u64,
    snapshot_tip_block: u64,
    base_utxos_primed: u64,
    snapshot_reward_accounts_primed: u64,
    snapshot_stake_deposits_primed: u64,
    snapshot_stake_mark_pools_primed: u64,
    snapshot_stake_set_pools_primed: u64,
    snapshot_stake_go_pools_primed: u64,
    local_ledger_snapshot_slot: u64,
    immutable_blocks_replayed: u64,
    stopped_by_signal: bool,
};

const RuntimeSnapshot = struct {
    layout: snapshot_restore.SnapshotLayout,
    point: Point,
    block_no: u64,

    fn deinit(self: *RuntimeSnapshot, allocator: Allocator) void {
        self.layout.deinit(allocator);
    }
};

fn checkpointPath(allocator: Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sync.resume", .{db_path});
}

fn loadResumePoints(allocator: Allocator, db_path: []const u8) ![]Point {
    const path = try checkpointPath(allocator, db_path);
    defer allocator.free(path);

    const max_bytes = 8 + (max_resume_points * 40);
    const data = std.fs.cwd().readFileAlloc(allocator, path, max_bytes) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Point, 0),
        else => return err,
    };
    defer allocator.free(data);

    if (data.len == 0) return allocator.alloc(Point, 0);
    if (data.len < 8) return error.InvalidCheckpoint;

    const version = std.mem.readInt(u32, data[0..4], .big);
    if (version != checkpoint_version) return allocator.alloc(Point, 0);

    const count = std.mem.readInt(u32, data[4..8], .big);
    if (count > max_resume_points) return error.InvalidCheckpoint;
    if (data.len != 8 + (count * 40)) return error.InvalidCheckpoint;

    const points = try allocator.alloc(Point, count);
    var pos: usize = 8;
    for (points) |*point| {
        point.slot = std.mem.readInt(u64, data[pos..][0..8], .big);
        pos += 8;
        @memcpy(&point.hash, data[pos .. pos + 32]);
        pos += 32;
    }

    return points;
}

fn saveResumePoints(allocator: Allocator, db_path: []const u8, points: []const Point) !void {
    const path = try checkpointPath(allocator, db_path);
    defer allocator.free(path);

    if (points.len == 0) {
        std.fs.cwd().deleteFile(path) catch {};
        return;
    }

    std.fs.cwd().makePath(db_path) catch {};

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], checkpoint_version, .big);
    std.mem.writeInt(u32, header[4..8], @intCast(points.len), .big);
    try file.writeAll(&header);

    for (points) |point| {
        var entry: [40]u8 = undefined;
        std.mem.writeInt(u64, entry[0..8], point.slot, .big);
        @memcpy(entry[8..40], &point.hash);
        try file.writeAll(&entry);
    }
}

fn pushResumePoint(points: *std.ArrayList(Point), allocator: Allocator, point: Point) !void {
    if (points.items.len > 0 and Point.eql(points.items[points.items.len - 1], point)) return;
    if (points.items.len == max_resume_points) {
        _ = points.orderedRemove(0);
    }
    try points.append(allocator, point);
}

fn truncateResumePoints(points: *std.ArrayList(Point), rollback_point: ?Point) void {
    const target = rollback_point orelse {
        points.clearRetainingCapacity();
        return;
    };

    var write_idx: usize = 0;
    for (points.items) |point| {
        if (point.slot < target.slot or (point.slot == target.slot and Point.eql(point, target))) {
            points.items[write_idx] = point;
            write_idx += 1;
        }
    }
    points.items.len = write_idx;
}

fn newestFirstPoints(allocator: Allocator, points: []const Point) ![]Point {
    const reversed = try allocator.alloc(Point, points.len);
    for (points, 0..) |point, idx| {
        reversed[points.len - 1 - idx] = point;
    }
    return reversed;
}

fn discoverRuntimeSnapshot(allocator: Allocator, db_path: []const u8) !?RuntimeSnapshot {
    var layout = snapshot_restore.resolveSnapshotLayout(allocator, db_path) catch return null;

    var reader = chunk_reader_mod.ChunkReader.init(layout.immutable_path) catch {
        layout.deinit(allocator);
        return null;
    };

    const tip_result = reader.readTip(allocator) catch {
        layout.deinit(allocator);
        return null;
    } orelse {
        layout.deinit(allocator);
        return null;
    };
    defer allocator.free(tip_result.raw);

    return .{
        .layout = layout,
        .point = .{
            .slot = tip_result.block.header.slot,
            .hash = tip_result.block.hash(),
        },
        .block_no = tip_result.block.header.block_no,
    };
}

fn initializeSnapshotState(
    allocator: Allocator,
    chain_db: *ChainDB,
    snapshot: *const RuntimeSnapshot,
    network: types.Network,
    result: *RunResult,
) !void {
    result.snapshot_anchor_used = true;
    result.snapshot_tip_slot = snapshot.point.slot;
    result.snapshot_tip_block = snapshot.block_no;

    const current_tip = chain_db.getTip();
    if (current_tip.block_no == 0 and current_tip.slot == 0) {
        try chain_db.attachSnapshotTip(snapshot.point, snapshot.block_no);
    } else if (current_tip.slot != snapshot.point.slot or
        current_tip.block_no != snapshot.block_no or
        !std.mem.eql(u8, &current_tip.hash, &snapshot.point.hash))
    {
        return error.ConflictingSnapshotTip;
    }

    if (snapshot.layout.ledger_path) |ledger_path| {
        if (try ledger_snapshot.findLatestSnapshotAtOrBefore(allocator, ledger_path, snapshot.point.slot)) |local_snapshot| {
            defer {
                var owned = local_snapshot;
                owned.deinit(allocator);
            }

            const load_result = try ledger_snapshot.loadSnapshotIntoLedger(
                allocator,
                &chain_db.ledger,
                local_snapshot,
                network,
            );
            result.base_utxos_primed = load_result.utxos_loaded;
            result.snapshot_reward_accounts_primed = load_result.reward_accounts_loaded;
            result.snapshot_stake_deposits_primed = load_result.stake_deposits_loaded;
            result.snapshot_stake_mark_pools_primed = load_result.stake_snapshot_mark_pools_loaded;
            result.snapshot_stake_set_pools_primed = load_result.stake_snapshot_set_pools_loaded;
            result.snapshot_stake_go_pools_primed = load_result.stake_snapshot_go_pools_loaded;
            result.local_ledger_snapshot_slot = load_result.slot;

            const replay = try ledger_snapshot.replayImmutableFromSlot(
                allocator,
                &chain_db.ledger,
                snapshot.layout.immutable_path,
                load_result.slot,
                chain_db.getProtocolParams(),
                if (chain_db.shelley_governance_config) |config| config.epoch_length else null,
            );
            result.immutable_blocks_replayed = replay.blocks_replayed;

            try chain_db.enableLedgerValidation();
            result.validation_enabled = true;
            std.debug.print(
                "Local ledger snapshot ready: {} UTxOs, {} reward accounts, {} stake deposits, stake snapshots mark/set/go = {}/{}/{}, {} immutable blocks replayed.\n",
                .{
                    result.base_utxos_primed,
                    result.snapshot_reward_accounts_primed,
                    result.snapshot_stake_deposits_primed,
                    result.snapshot_stake_mark_pools_primed,
                    result.snapshot_stake_set_pools_primed,
                    result.snapshot_stake_go_pools_primed,
                    result.immutable_blocks_replayed,
                },
            );
        }
    }
}

fn networkFromMagic(network_magic: u32) types.Network {
    return if (network_magic == types.mainnet.network_magic) .mainnet else .testnet;
}

fn initializeByronGenesisState(
    allocator: Allocator,
    chain_db: *ChainDB,
    byron_genesis_path: []const u8,
    result: *RunResult,
) !void {
    var genesis = try genesis_mod.parseByronGenesis(allocator, byron_genesis_path);
    defer genesis.deinit(allocator);

    const utxos = try genesis_mod.buildByronGenesisUtxos(allocator, &genesis);
    defer genesis_mod.freeGenesisUtxos(allocator, utxos);

    result.base_utxos_primed = try chain_db.primeBaseUtxos(utxos);
    try chain_db.enableLedgerValidation();
    result.validation_enabled = true;
}

/// Run the node: load config, optionally restore from snapshot, connect, sync.
pub fn run(allocator: Allocator, config: RunConfig) !RunResult {
    var result = RunResult{
        .headers_synced = 0,
        .blocks_fetched = 0,
        .blocks_added_to_chain = 0,
        .invalid_blocks = 0,
        .tip_slot = 0,
        .tip_block_no = 0,
        .rollbacks = 0,
        .errors = 0,
        .genesis_loaded = false,
        .resumed_from_checkpoint = false,
        .resumed_from_snapshot = false,
        .snapshot_anchor_used = false,
        .validation_enabled = false,
        .snapshot_tip_slot = 0,
        .snapshot_tip_block = 0,
        .base_utxos_primed = 0,
        .snapshot_reward_accounts_primed = 0,
        .snapshot_stake_deposits_primed = 0,
        .snapshot_stake_mark_pools_primed = 0,
        .snapshot_stake_set_pools_primed = 0,
        .snapshot_stake_go_pools_primed = 0,
        .local_ledger_snapshot_slot = 0,
        .immutable_blocks_replayed = 0,
        .stopped_by_signal = false,
    };

    var runtime_snapshot = try discoverRuntimeSnapshot(allocator, config.db_path);
    defer {
        if (runtime_snapshot) |*snapshot| snapshot.deinit(allocator);
    }

    var loaded_protocol_params: ?ledger_rules.ProtocolParams = null;
    var loaded_governance_config: ?protocol_update.GovernanceConfig = null;
    defer {
        if (loaded_governance_config) |*governance_config| governance_config.deinit(allocator);
    }
    var deferred_shelley_protocol_params: ?ledger_rules.ProtocolParams = null;
    var pending_shelley_protocol_switch = false;

    // Load protocol params appropriate for the starting point.
    if (runtime_snapshot != null) {
        if (config.shelley_genesis_path) |path| {
            if (genesis_mod.loadLedgerProtocolParams(allocator, path) catch null) |protocol_params| {
                loaded_protocol_params = protocol_params;
                result.genesis_loaded = true;
            }
            if (genesis_mod.loadShelleyGovernanceConfig(allocator, path) catch null) |governance_config| {
                loaded_governance_config = governance_config;
                result.genesis_loaded = true;
            }
        }
    } else if (config.byron_genesis_path) |path| {
        if (genesis_mod.loadByronLedgerProtocolParams(allocator, path) catch null) |protocol_params| {
            loaded_protocol_params = protocol_params;
            result.genesis_loaded = true;
        }
        if (config.shelley_genesis_path) |shelley_path| {
            if (genesis_mod.loadLedgerProtocolParams(allocator, shelley_path) catch null) |protocol_params| {
                deferred_shelley_protocol_params = protocol_params;
                pending_shelley_protocol_switch = true;
                result.genesis_loaded = true;
            }
            if (genesis_mod.loadShelleyGovernanceConfig(allocator, shelley_path) catch null) |governance_config| {
                loaded_governance_config = governance_config;
                result.genesis_loaded = true;
            }
        }
    } else if (config.shelley_genesis_path) |path| {
        if (genesis_mod.loadLedgerProtocolParams(allocator, path) catch null) |protocol_params| {
            loaded_protocol_params = protocol_params;
            result.genesis_loaded = true;
        }
        if (genesis_mod.loadShelleyGovernanceConfig(allocator, path) catch null) |governance_config| {
            loaded_governance_config = governance_config;
            result.genesis_loaded = true;
        }
    }

    // Open chain database
    var chain_db = try ChainDB.open(allocator, config.db_path, 2160);
    defer chain_db.close();
    chain_db.ledger.setRewardAccountNetwork(networkFromMagic(config.network_magic));

    if (loaded_protocol_params) |protocol_params| {
        chain_db.setProtocolParams(protocol_params);
    }
    if (loaded_governance_config) |governance_config| {
        try chain_db.configureShelleyGovernanceTracking(governance_config);
        loaded_governance_config = null;
    }

    if (runtime_snapshot) |*snapshot| {
        initializeSnapshotState(allocator, &chain_db, snapshot, networkFromMagic(config.network_magic), &result) catch |err| switch (err) {
            error.Interrupted => {
                const interrupted_tip = chain_db.getTip();
                result.tip_slot = interrupted_tip.slot;
                result.tip_block_no = interrupted_tip.block_no;
                result.validation_enabled = chain_db.isLedgerValidationEnabled();
                result.stopped_by_signal = true;
                return result;
            },
            else => return err,
        };
    } else if (config.byron_genesis_path) |path| {
        const current_tip = chain_db.getTip();
        if (current_tip.block_no == 0 and current_tip.slot == 0) {
            try initializeByronGenesisState(allocator, &chain_db, path, &result);
        }
    }

    const initial_tip = chain_db.getTip();
    result.tip_slot = initial_tip.slot;
    result.tip_block_no = initial_tip.block_no;
    result.validation_enabled = chain_db.isLedgerValidationEnabled();

    const loaded_points = loadResumePoints(allocator, config.db_path) catch blk: {
        result.errors += 1;
        break :blk allocator.alloc(Point, 0) catch unreachable;
    };
    defer allocator.free(loaded_points);

    var resume_points: std.ArrayList(Point) = .empty;
    defer resume_points.deinit(allocator);
    try resume_points.appendSlice(allocator, loaded_points);

    // Connect to peer
    var client = try sync_mod.SyncClient.connect(
        allocator,
        config.peer_host,
        config.peer_port,
        config.network_magic,
    );
    defer client.close();

    // Prefer a restored snapshot anchor when present. Otherwise resume from a
    // recent checkpoint if available, else start from genesis.
    if (runtime_snapshot) |snapshot| {
        const intersect = client.findIntersect(&[_]Point{snapshot.point}) catch {
            result.errors += 1;
            return error.IntersectFailed;
        };

        switch (intersect) {
            .intersect_found => {
                result.resumed_from_snapshot = true;
            },
            .intersect_not_found => {
                result.errors += 1;
                return error.IntersectNotFound;
            },
            else => return error.UnexpectedMessage,
        }
    } else if (resume_points.items.len > 0) {
        const candidates = try newestFirstPoints(allocator, resume_points.items);
        defer allocator.free(candidates);

        const intersect = client.findIntersect(candidates) catch blk: {
            result.errors += 1;
            resume_points.clearRetainingCapacity();
            saveResumePoints(allocator, config.db_path, resume_points.items) catch {};
            break :blk try client.findIntersectGenesis();
        };

        switch (intersect) {
            .intersect_found => {
                result.resumed_from_checkpoint = true;
            },
            .intersect_not_found => {
                resume_points.clearRetainingCapacity();
                saveResumePoints(allocator, config.db_path, resume_points.items) catch {};
                _ = try client.findIntersectGenesis();
            },
            else => {
                _ = try client.findIntersectGenesis();
            },
        }
    } else {
        _ = try client.findIntersectGenesis();
    }

    // Sync loop
    const max = if (config.max_headers == 0) std.math.maxInt(u64) else config.max_headers;

    var last_keepalive = std.time.timestamp();

    while (result.headers_synced < max) {
        if (runtime_control.stopRequested()) {
            result.stopped_by_signal = true;
            break;
        }

        // Send keep-alive every ~30s to prevent relay timeout (Haskell StServer = 60s)
        const now = std.time.timestamp();
        if (now - last_keepalive >= 30) {
            client.keepAlive() catch {};
            last_keepalive = now;
        }

        const msg = client.requestNext() catch {
            result.errors += 1;
            break;
        };

        switch (msg) {
            .roll_forward => |rf| {
                result.headers_synced += 1;

                const point = block_mod.pointFromHeader(rf.header_raw) catch {
                    result.errors += 1;
                    continue;
                };

                const block_raw = client.fetchBlock(point) catch {
                    result.errors += 1;
                    continue;
                } orelse {
                    result.errors += 1;
                    continue;
                };
                defer allocator.free(block_raw);
                result.blocks_fetched += 1;

                const block = block_mod.parseBlock(block_raw) catch {
                    result.errors += 1;
                    continue;
                };

                var switched_shelley_params = false;
                const previous_protocol_params = chain_db.getProtocolParams();
                if (pending_shelley_protocol_switch and block.era != .byron) {
                    if (deferred_shelley_protocol_params) |protocol_params| {
                        chain_db.setProtocolParams(protocol_params);
                        switched_shelley_params = true;
                    }
                    pending_shelley_protocol_switch = false;
                }

                const add_result = chain_db.addBlock(
                    block.hash(),
                    block_raw,
                    block.header.slot,
                    block.header.block_no,
                    block.header.prev_hash,
                ) catch {
                    if (switched_shelley_params) {
                        chain_db.setProtocolParams(previous_protocol_params);
                        pending_shelley_protocol_switch = true;
                    }
                    result.errors += 1;
                    continue;
                };

                switch (add_result) {
                    .added_to_current_chain => {
                        result.blocks_added_to_chain += 1;
                        try pushResumePoint(&resume_points, allocator, point);
                        saveResumePoints(allocator, config.db_path, resume_points.items) catch {};
                    },
                    .invalid => {
                        if (switched_shelley_params) {
                            chain_db.setProtocolParams(previous_protocol_params);
                            pending_shelley_protocol_switch = true;
                        }
                        result.invalid_blocks += 1;
                        result.errors += 1;
                        break;
                    },
                    else => {},
                }

                const tip = chain_db.getTip();
                result.tip_slot = tip.slot;
                result.tip_block_no = tip.block_no;
            },
            .await_reply => {
                if (runtime_control.stopRequested()) {
                    result.stopped_by_signal = true;
                    break;
                }
                // At tip — send keep-alive and wait
                client.keepAlive() catch {};
                std.Thread.sleep(1 * std.time.ns_per_s);
            },
            .roll_backward => |rb| {
                result.rollbacks += 1;
                _ = chain_db.rollbackToPoint(rb.point) catch blk: {
                    result.errors += 1;
                    break :blk 0;
                };
                truncateResumePoints(&resume_points, rb.point);
                saveResumePoints(allocator, config.db_path, resume_points.items) catch {};

                const tip = chain_db.getTip();
                result.tip_slot = tip.slot;
                result.tip_block_no = tip.block_no;
            },
            else => break,
        }
    }

    return result;
}

test "runner: initialize Byron genesis state on empty chain" {
    const allocator = std.testing.allocator;

    std.fs.cwd().deleteTree("/tmp/kassadin-test-runner-byron-genesis") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-test-runner-byron-genesis") catch {};

    var chain_db = try ChainDB.open(allocator, "/tmp/kassadin-test-runner-byron-genesis", 2160);
    defer chain_db.close();

    var result = RunResult{
        .headers_synced = 0,
        .blocks_fetched = 0,
        .blocks_added_to_chain = 0,
        .invalid_blocks = 0,
        .tip_slot = 0,
        .tip_block_no = 0,
        .rollbacks = 0,
        .errors = 0,
        .genesis_loaded = false,
        .resumed_from_checkpoint = false,
        .resumed_from_snapshot = false,
        .snapshot_anchor_used = false,
        .validation_enabled = false,
        .snapshot_tip_slot = 0,
        .snapshot_tip_block = 0,
        .base_utxos_primed = 0,
        .snapshot_reward_accounts_primed = 0,
        .snapshot_stake_deposits_primed = 0,
        .snapshot_stake_mark_pools_primed = 0,
        .snapshot_stake_set_pools_primed = 0,
        .snapshot_stake_go_pools_primed = 0,
        .local_ledger_snapshot_slot = 0,
        .immutable_blocks_replayed = 0,
        .stopped_by_signal = false,
    };

    initializeByronGenesisState(allocator, &chain_db, "byron.json", &result) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };

    try std.testing.expect(chain_db.isLedgerValidationEnabled());
    try std.testing.expect(result.validation_enabled);
    try std.testing.expect(result.base_utxos_primed > 0);
    try std.testing.expectEqual(result.base_utxos_primed, @as(u64, @intCast(chain_db.ledger.utxoCount())));
    try std.testing.expectEqual(@as(u64, 0), result.snapshot_reward_accounts_primed);
    try std.testing.expectEqual(@as(u64, 0), result.snapshot_stake_deposits_primed);
    try std.testing.expectEqual(@as(u64, 0), result.snapshot_stake_mark_pools_primed);
    try std.testing.expectEqual(@as(u64, 0), result.snapshot_stake_set_pools_primed);
    try std.testing.expectEqual(@as(u64, 0), result.snapshot_stake_go_pools_primed);
    try std.testing.expectEqual(@as(?types.SlotNo, null), chain_db.ledger.getTipSlot());
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "runner: sync 10 headers from preview" {
    const allocator = std.testing.allocator;

    std.fs.cwd().deleteTree("/tmp/kassadin-runner-test") catch {};
    defer std.fs.cwd().deleteTree("/tmp/kassadin-runner-test") catch {};

    const result = run(allocator, .{
        .network_magic = protocol.NetworkMagic.preview,
        .peer_host = "preview-node.play.dev.cardano.org",
        .peer_port = 3001,
        .db_path = "/tmp/kassadin-runner-test",
        .byron_genesis_path = null,
        .shelley_genesis_path = null,
        .max_headers = 10,
    }) catch return; // skip if no network

    try std.testing.expect(result.headers_synced >= 1);
    try std.testing.expect(result.tip_slot > 0);
}

test "runner: config defaults" {
    const preview = RunConfig.preview_defaults;
    try std.testing.expectEqual(@as(u32, 2), preview.network_magic);
    try std.testing.expectEqualStrings("db/preview", preview.db_path);
    try std.testing.expect(preview.byron_genesis_path == null);

    const preprod = RunConfig.preprod_defaults;
    try std.testing.expectEqual(@as(u32, 1), preprod.network_magic);
    try std.testing.expectEqualStrings("db/preprod", preprod.db_path);
    try std.testing.expectEqualStrings("byron.json", preprod.byron_genesis_path.?);
}

test "runner: resume checkpoint round-trip" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-runner-checkpoint";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const points = [_]Point{
        .{ .slot = 10, .hash = [_]u8{0x11} ** 32 },
        .{ .slot = 20, .hash = [_]u8{0x22} ** 32 },
    };

    try saveResumePoints(allocator, path, &points);
    const loaded = try loadResumePoints(allocator, path);
    defer allocator.free(loaded);

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqual(points[0].slot, loaded[0].slot);
    try std.testing.expectEqualSlices(u8, &points[1].hash, &loaded[1].hash);
}
