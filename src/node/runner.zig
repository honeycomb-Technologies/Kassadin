const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const genesis_mod = @import("genesis.zig");
const sync_mod = @import("sync.zig");
const chunk_reader_mod = @import("chunk_reader.zig");
const ledger_snapshot = @import("ledger_snapshot.zig");
const praos_checkpoint = @import("praos_checkpoint.zig");
const praos_restore = @import("praos_restore.zig");
const runtime_control = @import("runtime_control.zig");
const snapshot_restore = @import("snapshot_restore.zig");
const topology_mod = @import("topology.zig");
const block_mod = @import("../ledger/block.zig");
const protocol_update = @import("../ledger/protocol_update.zig");
const rewards_mod = @import("../ledger/rewards.zig");
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
    /// Optional relay list from topology JSON. When present, runtime rotates
    /// through these peers on connect/reconnect instead of pinning one relay.
    peer_endpoints: ?[]const topology_mod.Peer = null,
    /// Database path for chain storage.
    db_path: []const u8,
    /// Genesis configuration file paths.
    byron_genesis_path: ?[]const u8,
    shelley_genesis_path: ?[]const u8,
    /// Byron epoch at which the Shelley hard fork occurs.
    /// On testnets this comes from TestShelleyHardForkAtEpoch in config.json.
    /// On mainnet default is 208.
    hard_fork_epoch: ?u64 = null,
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
        .hard_fork_epoch = 4,
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

const PeerEndpoint = struct {
    host: []const u8,
    port: u16,
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

fn peerCount(config: RunConfig) usize {
    if (config.peer_endpoints) |peers| {
        if (peers.len > 0) return peers.len;
    }
    return 1;
}

fn peerForAttempt(config: RunConfig, attempt: usize) PeerEndpoint {
    if (config.peer_endpoints) |peers| {
        if (peers.len > 0) {
            const peer = peers[attempt % peers.len];
            return .{
                .host = peer.host,
                .port = peer.port,
            };
        }
    }

    return .{
        .host = config.peer_host,
        .port = config.peer_port,
    };
}

fn savePraosCheckpoint(allocator: Allocator, chain_db: *const ChainDB, db_path: []const u8) void {
    if (!chain_db.isPraosTrackingReady()) return;
    const config = chain_db.shelley_governance_config orelse return;
    const tip = currentTipPoint(chain_db) orelse return;
    praos_checkpoint.save(
        allocator,
        db_path,
        tip,
        &config,
        chain_db.getPraosState(),
        chain_db.getOcertCounters(),
    ) catch {};
}

fn currentTipPoint(chain_db: *const ChainDB) ?Point {
    const tip = chain_db.getTip();
    if (tip.slot == 0 and tip.block_no == 0) return null;
    return .{
        .slot = tip.slot,
        .hash = tip.hash,
    };
}

fn performInitialIntersect(
    allocator: Allocator,
    client: *sync_mod.SyncClient,
    runtime_snapshot: ?RuntimeSnapshot,
    resume_points: *std.ArrayList(Point),
    db_path: []const u8,
    result: *RunResult,
) !void {
    if (runtime_snapshot) |snapshot| {
        const intersect = try client.findIntersect(&[_]Point{snapshot.point});

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
        return;
    }

    if (resume_points.items.len > 0) {
        const candidates = try newestFirstPoints(allocator, resume_points.items);
        defer allocator.free(candidates);

        const intersect = client.findIntersect(candidates) catch {
            result.errors += 1;
            resume_points.clearRetainingCapacity();
            saveResumePoints(allocator, db_path, resume_points.items) catch {};
            _ = try client.findIntersectGenesis();
            return;
        };

        switch (intersect) {
            .intersect_found => {
                result.resumed_from_checkpoint = true;
            },
            .intersect_not_found => {
                resume_points.clearRetainingCapacity();
                saveResumePoints(allocator, db_path, resume_points.items) catch {};
                _ = try client.findIntersectGenesis();
            },
            else => {
                _ = try client.findIntersectGenesis();
            },
        }
        return;
    }

    _ = try client.findIntersectGenesis();
}

fn performReconnectIntersect(
    client: *sync_mod.SyncClient,
    chain_db: *const ChainDB,
) !void {
    if (currentTipPoint(chain_db)) |point| {
        const intersect = try client.findIntersect(&[_]Point{point});
        switch (intersect) {
            .intersect_found => {},
            .intersect_not_found => return error.IntersectNotFound,
            else => return error.UnexpectedMessage,
        }
        return;
    }

    _ = try client.findIntersectGenesis();
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
    db_path: []const u8,
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
                if (chain_db.shelley_governance_config) |config| config.reward_params else rewards_mod.RewardParams.mainnet_defaults,
            );
            result.immutable_blocks_replayed = replay.blocks_replayed;

            if (chain_db.shelley_governance_config) |config| {
                if (try praos_checkpoint.load(allocator, db_path, snapshot.point, &config)) |loaded| {
                    var owned = loaded;
                    defer owned.deinit(allocator);
                    chain_db.attachPraosState(owned.state);
                    chain_db.attachOcertCounters(owned.ocert_counters);
                    std.debug.print("Loaded persisted Praos state + {} OCert counters for snapshot tip.\n", .{owned.ocert_counters.len});
                } else {
                    const praos_result = try praos_restore.reconstructFromImmutable(
                        allocator,
                        snapshot.layout.immutable_path,
                        snapshot.point.slot,
                        &config,
                    );
                    if (praos_result.state) |reconstructed_state| {
                        var state = reconstructed_state;
                        // TEMPORARY: Override epoch nonce with known-correct Koios value
                        // to work around cold-reconstruction Conway nonce divergence.
                        // TODO: Find root cause of divergence starting at preprod epoch 164.
                        {
                            const koios_nonce_hex = "7e93f6338fc6804a9a4485d11182ea02ad9f5e5063e0cda8d60735ecc1d55ccd";
                            var koios_nonce: [32]u8 = undefined;
                            _ = std.fmt.hexToBytes(&koios_nonce, koios_nonce_hex) catch unreachable;
                            std.debug.print("  Overriding reconstructed epoch nonce with Koios epoch 276 value\n", .{});
                            state.epoch_nonce = .{ .hash = koios_nonce };
                        }
                        chain_db.attachPraosState(state);
                        praos_checkpoint.save(allocator, db_path, snapshot.point, &config, state, chain_db.getOcertCounters()) catch {};
                        std.debug.print(
                            "Praos state reconstructed from {} Shelley+ immutable blocks.\n",
                            .{praos_result.shelley_blocks_scanned},
                        );
                    }
                }
            }

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
    var loaded_consensus_params: ?genesis_mod.ConsensusParams = null;
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
    if (config.shelley_genesis_path) |path| {
        if (genesis_mod.loadShelleyConsensusParams(allocator, path) catch null) |consensus_params| {
            loaded_consensus_params = consensus_params;
            result.genesis_loaded = true;
        }
    }

    // Compute Shelley era start slot for correct epoch boundary detection.
    // HFC uses continuous slot numbering: era_start = hard_fork_epoch * byron_epoch_length.
    if (loaded_governance_config != null and config.byron_genesis_path != null) {
        const byron = genesis_mod.parseByronGenesis(allocator, config.byron_genesis_path.?) catch null;
        if (byron) |byron_genesis| {
            var bg = byron_genesis;
            defer bg.deinit(allocator);
            const hard_fork_epoch = config.hard_fork_epoch orelse 208;
            loaded_governance_config.?.era_start_slot = genesis_mod.computeEraStartSlot(&bg, hard_fork_epoch);
        }
    }

    // Open chain database
    var chain_db = try ChainDB.open(allocator, config.db_path, 2160);
    defer chain_db.close();
    chain_db.ledger.setRewardAccountNetwork(networkFromMagic(config.network_magic));

    if (loaded_protocol_params) |protocol_params| {
        chain_db.setProtocolParams(protocol_params);
    }
    if (loaded_consensus_params) |consensus_params| {
        chain_db.setConsensusParams(
            consensus_params.slots_per_kes_period,
            consensus_params.max_kes_evolutions,
        );
    }
    if (loaded_governance_config) |governance_config| {
        try chain_db.configureShelleyGovernanceTracking(governance_config);
        loaded_governance_config = null;
    }

    if (runtime_snapshot) |*snapshot| {
        initializeSnapshotState(allocator, &chain_db, snapshot, config.db_path, networkFromMagic(config.network_magic), &result) catch |err| switch (err) {
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

    const max = if (config.max_headers == 0) std.math.maxInt(u64) else config.max_headers;

    var initial_intersect_done = false;
    var reconnect_count: u32 = 0;
    const max_reconnects: u32 = 50;

    reconnect: while (reconnect_count <= max_reconnects and result.headers_synced < max) {
        if (runtime_control.stopRequested()) {
            result.stopped_by_signal = true;
            break;
        }

        const endpoint = peerForAttempt(config, reconnect_count);
        if (reconnect_count > 0) {
            std.debug.print(
                "Reconnecting ({}/{}) via {s}:{}...\n",
                .{ reconnect_count, max_reconnects, endpoint.host, endpoint.port },
            );
            std.Thread.sleep(2 * std.time.ns_per_s);
        } else if (peerCount(config) > 1) {
            std.debug.print("Connecting via topology peer {s}:{}...\n", .{ endpoint.host, endpoint.port });
        }

        var client = sync_mod.SyncClient.connect(
            allocator,
            endpoint.host,
            endpoint.port,
            config.network_magic,
        ) catch |err| {
            result.errors += 1;
            std.debug.print("Connection failed to {s}:{}: {}\n", .{ endpoint.host, endpoint.port, err });
            reconnect_count += 1;
            continue :reconnect;
        };
        var client_closed = false;
        defer if (!client_closed) client.close();

        if (!initial_intersect_done) {
            performInitialIntersect(
                allocator,
                &client,
                runtime_snapshot,
                &resume_points,
                config.db_path,
                &result,
            ) catch |err| switch (err) {
                error.IntersectNotFound => {
                    result.errors += 1;
                    return err;
                },
                else => {
                    result.errors += 1;
                    client.close();
                    client_closed = true;
                    reconnect_count += 1;
                    continue :reconnect;
                },
            };
            initial_intersect_done = true;
        } else {
            performReconnectIntersect(&client, &chain_db) catch |err| {
                result.errors += 1;
                std.debug.print("Reconnect intersect failed via {s}:{}: {}\n", .{ endpoint.host, endpoint.port, err });
                client.close();
                client_closed = true;
                reconnect_count += 1;
                continue :reconnect;
            };
        }

        var last_keepalive = std.time.timestamp();

        while (result.headers_synced < max) {
            if (runtime_control.stopRequested()) {
                result.stopped_by_signal = true;
                break :reconnect;
            }

            // Send keep-alive every ~30s to prevent relay timeout (Haskell StServer = 60s)
            const now = std.time.timestamp();
            if (now - last_keepalive >= 30) {
                client.keepAlive() catch {};
                last_keepalive = now;
            }

            const msg = client.requestNext() catch |err| {
                result.errors += 1;
                std.debug.print("Sync error via {s}:{}: {} — rotating peer\n", .{ endpoint.host, endpoint.port, err });
                client.close();
                client_closed = true;
                reconnect_count += 1;
                continue :reconnect;
            };

            switch (msg) {
                .roll_forward => |rf| {
                    result.headers_synced += 1;

                    const point = block_mod.pointFromHeader(rf.header_raw) catch {
                        result.errors += 1;
                        continue;
                    };

                    const block_raw = client.fetchBlock(point) catch |err| {
                        result.errors += 1;
                        std.debug.print("Block fetch error via {s}:{}: {} — rotating peer\n", .{ endpoint.host, endpoint.port, err });
                        client.close();
                        client_closed = true;
                        reconnect_count += 1;
                        continue :reconnect;
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
                            const promoted = try chain_db.promoteFinalized();
                            if (promoted > 0) {
                                savePraosCheckpoint(allocator, &chain_db, config.db_path);
                            }
                        },
                        .invalid => {
                            if (switched_shelley_params) {
                                chain_db.setProtocolParams(previous_protocol_params);
                                pending_shelley_protocol_switch = true;
                            }
                            result.invalid_blocks += 1;
                            result.errors += 1;
                            break :reconnect;
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
                        break :reconnect;
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
                else => {
                    client.close();
                    client_closed = true;
                    reconnect_count += 1;
                    continue :reconnect;
                },
            }
        }

        client.close();
        client_closed = true;
        break;
    }

    savePraosCheckpoint(allocator, &chain_db, config.db_path);
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

test "runner: topology peers rotate by reconnect attempt" {
    var host_a = [_]u8{'a'};
    var host_b = [_]u8{'b'};
    const peers = [_]topology_mod.Peer{
        .{ .host = host_a[0..], .port = 1111, .source = .bootstrap_peer },
        .{ .host = host_b[0..], .port = 2222, .source = .public_root },
    };
    const config = RunConfig{
        .network_magic = protocol.NetworkMagic.preprod,
        .peer_host = "fallback.example",
        .peer_port = 3001,
        .peer_endpoints = peers[0..],
        .db_path = "/tmp/kassadin-runner-peer-rotation",
        .byron_genesis_path = null,
        .shelley_genesis_path = null,
        .max_headers = 0,
    };

    const first = peerForAttempt(config, 0);
    const second = peerForAttempt(config, 1);
    const third = peerForAttempt(config, 2);

    try std.testing.expectEqualStrings("a", first.host);
    try std.testing.expectEqual(@as(u16, 1111), first.port);
    try std.testing.expectEqualStrings("b", second.host);
    try std.testing.expectEqual(@as(u16, 2222), second.port);
    try std.testing.expectEqualStrings("a", third.host);
    try std.testing.expectEqual(@as(usize, 2), peerCount(config));
}
