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
const volatile_checkpoint = @import("volatile_checkpoint.zig");
const topology_mod = @import("topology.zig");
const block_mod = @import("../ledger/block.zig");
const praos = @import("../consensus/praos.zig");
const protocol_update = @import("../ledger/protocol_update.zig");
const rewards_mod = @import("../ledger/rewards.zig");
const ledger_rules = @import("../ledger/rules.zig");
const ChainDB = @import("../storage/chaindb.zig").ChainDB;
const AddBlockResult = @import("../storage/chaindb.zig").AddBlockResult;
const BaseTip = @import("../storage/chaindb.zig").BaseTip;
const VolatileDB = @import("../storage/volatile.zig").VolatileDB;
const protocol = @import("../network/protocol.zig");
const N2CServer = @import("n2c_server.zig").N2CServer;

const Point = types.Point;
const checkpoint_version: u32 = 1;
// Bump when resume semantics change so stale on-disk checkpoints are ignored.
const ledger_checkpoint_anchor_version: u32 = 4;
const max_resume_points: usize = 8;
const min_tip_checkpoint_blocks: usize = 512;

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
    /// Optional N2C Unix socket path for local queries (e.g., cardano-cli).
    socket_path: ?[]const u8 = null,

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
        .byron_genesis_path = "config/preprod/byron.json",
        .shelley_genesis_path = "config/preprod/shelley.json",
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
    vrf_threshold_warnings: u64,
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
    /// Last chunk number in the Mithril snapshot (boundary for write isolation).
    last_chunk: u32,

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

fn ledgerCheckpointPath(allocator: Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/ledger.resume", .{db_path});
}

fn ledgerCheckpointAnchorPath(allocator: Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/ledger.resume.anchor", .{db_path});
}

fn tipLedgerCheckpointPath(allocator: Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/ledger.tip.resume", .{db_path});
}

fn tipLedgerCheckpointAnchorPath(allocator: Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/ledger.tip.resume.anchor", .{db_path});
}

fn tipPraosCheckpointPath(allocator: Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/praos.tip.resume", .{db_path});
}

fn deleteLedgerCheckpoint(allocator: Allocator, db_path: []const u8) void {
    const checkpoint_path = ledgerCheckpointPath(allocator, db_path) catch return;
    defer allocator.free(checkpoint_path);
    const anchor_path = ledgerCheckpointAnchorPath(allocator, db_path) catch return;
    defer allocator.free(anchor_path);

    std.fs.cwd().deleteFile(checkpoint_path) catch {};
    std.fs.cwd().deleteFile(anchor_path) catch {};
}

fn deleteTipLedgerCheckpoint(allocator: Allocator, db_path: []const u8) void {
    const checkpoint_path = tipLedgerCheckpointPath(allocator, db_path) catch return;
    defer allocator.free(checkpoint_path);
    const anchor_path = tipLedgerCheckpointAnchorPath(allocator, db_path) catch return;
    defer allocator.free(anchor_path);
    const praos_path = tipPraosCheckpointPath(allocator, db_path) catch return;
    defer allocator.free(praos_path);

    std.fs.cwd().deleteFile(checkpoint_path) catch {};
    std.fs.cwd().deleteFile(anchor_path) catch {};
    std.fs.cwd().deleteFile(praos_path) catch {};
}

fn saveLedgerCheckpointAnchor(allocator: Allocator, db_path: []const u8, base: BaseTip) !void {
    const path = try ledgerCheckpointAnchorPath(allocator, db_path);
    defer allocator.free(path);

    return saveCheckpointAnchor(path, db_path, base);
}

fn saveTipLedgerCheckpointAnchor(allocator: Allocator, db_path: []const u8, base: BaseTip) !void {
    const path = try tipLedgerCheckpointAnchorPath(allocator, db_path);
    defer allocator.free(path);

    return saveCheckpointAnchor(path, db_path, base);
}

fn saveCheckpointAnchor(path: []const u8, db_path: []const u8, base: BaseTip) !void {
    std.fs.cwd().makePath(db_path) catch {};

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buf: [8]u8 = undefined;
    var version_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &version_buf, ledger_checkpoint_anchor_version, .big);
    try file.writeAll(&version_buf);
    std.mem.writeInt(u64, &buf, base.point.slot, .big);
    try file.writeAll(&buf);
    try file.writeAll(&base.point.hash);
    std.mem.writeInt(u64, &buf, base.block_no, .big);
    try file.writeAll(&buf);
}

fn loadLedgerCheckpointAnchor(allocator: Allocator, db_path: []const u8) !?BaseTip {
    const path = try ledgerCheckpointAnchorPath(allocator, db_path);
    defer allocator.free(path);

    return loadCheckpointAnchor(path, allocator);
}

fn loadTipLedgerCheckpointAnchor(allocator: Allocator, db_path: []const u8) !?BaseTip {
    const path = try tipLedgerCheckpointAnchorPath(allocator, db_path);
    defer allocator.free(path);

    return loadCheckpointAnchor(path, allocator);
}

fn loadCheckpointAnchor(path: []const u8, allocator: Allocator) !?BaseTip {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 52) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(data);

    if (data.len != 52) return null;
    if (std.mem.readInt(u32, data[0..4], .big) != ledger_checkpoint_anchor_version) return null;

    return .{
        .point = .{
            .slot = std.mem.readInt(u64, data[4..12], .big),
            .hash = data[12..44].*,
        },
        .block_no = std.mem.readInt(u64, data[44..52], .big),
    };
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
    const checkpoint_point = if (chain_db.getBaseTip()) |base| base.point else currentTipPoint(chain_db) orelse return;
    const checkpoint_state = if (chain_db.getBasePraosState()) |base_state| base_state else chain_db.getPraosState();
    praos_checkpoint.save(
        allocator,
        db_path,
        checkpoint_point,
        &config,
        checkpoint_state,
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

fn populateLedgerPrimingResult(chain_db: *const ChainDB, result: *RunResult) void {
    result.base_utxos_primed = chain_db.ledger.utxoCount();
    result.snapshot_reward_accounts_primed = chain_db.ledger.nonZeroRewardAccountCount();
    result.snapshot_stake_deposits_primed = chain_db.ledger.stakeDepositCount();
    const snapshots = chain_db.ledger.getStakeSnapshots();
    result.snapshot_stake_mark_pools_primed = if (snapshots.mark) |dist| dist.poolCount() else 0;
    result.snapshot_stake_set_pools_primed = if (snapshots.set) |dist| dist.poolCount() else 0;
    result.snapshot_stake_go_pools_primed = if (snapshots.go) |dist| dist.poolCount() else 0;
    result.local_ledger_snapshot_slot = chain_db.ledger.getTipSlot() orelse 0;
}

fn restorePraosForAnchor(
    allocator: Allocator,
    chain_db: *ChainDB,
    db_path: []const u8,
    immutable_path: []const u8,
    raw_cbor_boundary: ?u32,
    anchor: Point,
) !void {
    if (chain_db.shelley_governance_config) |config| {
        if (try praos_checkpoint.load(allocator, db_path, anchor, &config)) |loaded| {
            var owned = loaded;
            defer owned.deinit(allocator);
            chain_db.attachPraosState(owned.state);
            chain_db.attachOcertCounters(owned.ocert_counters);
            std.debug.print("Loaded persisted Praos state + {} OCert counters for resume anchor.\n", .{owned.ocert_counters.len});
        } else {
            const praos_result = try praos_restore.reconstructFromImmutable(
                allocator,
                immutable_path,
                anchor.slot,
                raw_cbor_boundary,
                &config,
            );
            if (praos_result.state) |reconstructed_state| {
                const state = reconstructed_state;
                chain_db.attachPraosState(state);
                praos_checkpoint.save(allocator, db_path, anchor, &config, state, chain_db.getOcertCounters()) catch {};
                std.debug.print(
                    "Praos state reconstructed from {} Shelley+ immutable blocks.\n",
                    .{praos_result.shelley_blocks_scanned},
                );
            }
        }
    }
}

fn saveBaseLedgerCheckpoint(allocator: Allocator, chain_db: *const ChainDB, db_path: []const u8) void {
    if (!chain_db.isLedgerValidationEnabled()) return;
    if (chain_db.currentChainBlockCount() != 0) return;
    const base = chain_db.getBaseTip() orelse return;

    const path = ledgerCheckpointPath(allocator, db_path) catch return;
    defer allocator.free(path);

    chain_db.ledger.saveCheckpoint(path) catch return;
    saveLedgerCheckpointAnchor(allocator, db_path, base) catch {};
}

fn saveBaseLedgerCheckpointForShutdown(allocator: Allocator, chain_db: *ChainDB, db_path: []const u8) void {
    if (!chain_db.isLedgerValidationEnabled()) return;
    if (chain_db.getBaseTip() == null) return;

    if (chain_db.currentChainBlockCount() > 0) {
        _ = chain_db.rollbackToPoint(chain_db.getBaseTip().?.point) catch return;
    }

    saveBaseLedgerCheckpoint(allocator, chain_db, db_path);
}

fn loadBaseLedgerCheckpoint(
    allocator: Allocator,
    chain_db: *ChainDB,
    snapshot: *const RuntimeSnapshot,
    db_path: []const u8,
    result: *RunResult,
) !bool {
    const base = chain_db.getBaseTip() orelse return false;
    const anchor = try loadLedgerCheckpointAnchor(allocator, db_path) orelse return false;
    if (anchor.block_no > base.block_no or anchor.point.slot > base.point.slot) {
        deleteLedgerCheckpoint(allocator, db_path);
        return false;
    }
    if (anchor.block_no == base.block_no and !Point.eql(anchor.point, base.point)) {
        deleteLedgerCheckpoint(allocator, db_path);
        return false;
    }

    const path = try ledgerCheckpointPath(allocator, db_path);
    defer allocator.free(path);

    const loaded = chain_db.ledger.loadCheckpoint(path) catch {
        deleteLedgerCheckpoint(allocator, db_path);
        return false;
    };
    if (!loaded) {
        deleteLedgerCheckpoint(allocator, db_path);
        return false;
    }

    var immutable_blocks_replayed: u64 = 0;
    if (!Point.eql(anchor.point, base.point) or anchor.block_no != base.block_no) {
        const reward_params = if (chain_db.shelley_governance_config) |config|
            chain_db.getProtocolParams().rewardParams(config.reward_params)
        else
            rewards_mod.RewardParams.mainnet_defaults;
        const replay = ledger_snapshot.replayImmutableFromSlot(
            allocator,
            &chain_db.ledger,
            snapshot.layout.immutable_path,
            anchor.point.slot,
            snapshot.last_chunk,
            chain_db.getProtocolParams(),
            if (chain_db.shelley_governance_config) |config| config.epoch_length else null,
            reward_params,
            if (chain_db.shelley_governance_config) |config| config.era_start_epoch else 0,
            if (chain_db.shelley_governance_config) |config| config.era_start_slot else 0,
        ) catch {
            deleteLedgerCheckpoint(allocator, db_path);
            return false;
        };
        if (replay.blocks_replayed == 0 or chain_db.ledger.getTipSlot() != base.point.slot) {
            deleteLedgerCheckpoint(allocator, db_path);
            return false;
        }
        immutable_blocks_replayed = replay.blocks_replayed;
    }

    try restorePraosForAnchor(
        allocator,
        chain_db,
        db_path,
        snapshot.layout.immutable_path,
        snapshot.last_chunk,
        base.point,
    );
    try chain_db.enableLedgerValidation();
    result.validation_enabled = true;
    result.immutable_blocks_replayed = immutable_blocks_replayed;
    if (immutable_blocks_replayed > 0) {
        saveBaseLedgerCheckpoint(allocator, chain_db, db_path);
    }
    populateLedgerPrimingResult(chain_db, result);
    if (immutable_blocks_replayed > 0) {
        std.debug.print(
            "Loaded local ledger checkpoint at slot {} and replayed {} immutable blocks to slot {}.\n",
            .{ anchor.point.slot, immutable_blocks_replayed, base.point.slot },
        );
    } else {
        std.debug.print(
            "Loaded local ledger checkpoint at slot {} with {} UTxOs.\n",
            .{ base.point.slot, result.base_utxos_primed },
        );
    }
    return true;
}

fn loadRuntimeSnapshotBaseline(
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

    const loaded_base_checkpoint = try loadBaseLedgerCheckpoint(
        allocator,
        chain_db,
        snapshot,
        db_path,
        result,
    );
    if (loaded_base_checkpoint) return;

    try initializeSnapshotState(
        allocator,
        chain_db,
        snapshot,
        db_path,
        network,
        result,
    );
    saveBaseLedgerCheckpoint(allocator, chain_db, db_path);
}

fn persistTipLedgerCheckpoint(allocator: Allocator, chain_db: *const ChainDB, db_path: []const u8) void {
    const tip = currentTipPoint(chain_db) orelse return;
    const base = chain_db.getBaseTip() orelse return;
    if (Point.eql(base.point, tip) and base.block_no == chain_db.getTip().block_no) {
        deleteTipLedgerCheckpoint(allocator, db_path);
        return;
    }
    const config = chain_db.shelley_governance_config orelse return;

    const ledger_path = tipLedgerCheckpointPath(allocator, db_path) catch return;
    defer allocator.free(ledger_path);
    const praos_path = tipPraosCheckpointPath(allocator, db_path) catch return;
    defer allocator.free(praos_path);

    chain_db.ledger.saveCheckpoint(ledger_path) catch return;
    saveTipLedgerCheckpointAnchor(allocator, db_path, .{
        .point = tip,
        .block_no = chain_db.getTip().block_no,
    }) catch {
        deleteTipLedgerCheckpoint(allocator, db_path);
        return;
    };
    praos_checkpoint.saveAtPath(
        allocator,
        praos_path,
        tip,
        &config,
        chain_db.getPraosState(),
        chain_db.getOcertCounters(),
    ) catch {
        deleteTipLedgerCheckpoint(allocator, db_path);
    };
}

fn saveTipLedgerCheckpoint(allocator: Allocator, chain_db: *const ChainDB, db_path: []const u8) void {
    if (!chain_db.isLedgerValidationEnabled()) return;
    if (chain_db.currentChainBlockCount() < min_tip_checkpoint_blocks) {
        return;
    }
    persistTipLedgerCheckpoint(allocator, chain_db, db_path);
}

fn loadTipLedgerCheckpoint(
    allocator: Allocator,
    chain_db: *ChainDB,
    db_path: []const u8,
    tip_checkpoint: BaseTip,
    result: *RunResult,
) !bool {
    const ledger_path = try tipLedgerCheckpointPath(allocator, db_path);
    defer allocator.free(ledger_path);

    const loaded = chain_db.ledger.loadCheckpoint(ledger_path) catch {
        deleteTipLedgerCheckpoint(allocator, db_path);
        return false;
    };
    if (!loaded) {
        deleteTipLedgerCheckpoint(allocator, db_path);
        return false;
    }

    if (chain_db.shelley_governance_config) |config| {
        const praos_path = try tipPraosCheckpointPath(allocator, db_path);
        defer allocator.free(praos_path);
        var tip_praos = (try praos_checkpoint.loadAtPath(allocator, praos_path, tip_checkpoint.point, &config)) orelse {
            deleteTipLedgerCheckpoint(allocator, db_path);
            return false;
        };
        defer tip_praos.deinit(allocator);
        chain_db.ocert_counters.clearRetainingCapacity();
        chain_db.attachPraosState(tip_praos.state);
        chain_db.attachOcertCounters(tip_praos.ocert_counters);
    }

    chain_db.tip_slot = tip_checkpoint.point.slot;
    chain_db.tip_hash = tip_checkpoint.point.hash;
    chain_db.tip_block_no = tip_checkpoint.block_no;
    chain_db.base_tip = tip_checkpoint;
    try chain_db.enableLedgerValidation();
    result.validation_enabled = true;
    result.immutable_blocks_replayed = 0;
    populateLedgerPrimingResult(chain_db, result);
    std.debug.print(
        "Loaded local tip checkpoint at slot {} with {} UTxOs.\n",
        .{ tip_checkpoint.point.slot, result.base_utxos_primed },
    );
    return true;
}

fn resetRuntimeResumeState(chain_db: *ChainDB) void {
    for (chain_db.current_chain.items) |*entry| {
        if (entry.governance_snapshot) |*snapshot| snapshot.deinit(chain_db.allocator);
    }
    chain_db.current_chain.clearRetainingCapacity();
    chain_db.@"volatile".deinit();
    chain_db.@"volatile" = VolatileDB.init(chain_db.allocator);
    chain_db.ocert_counters.clearRetainingCapacity();
    chain_db.tip_slot = 0;
    chain_db.tip_hash = [_]u8{0} ** 32;
    chain_db.tip_block_no = 0;
    chain_db.base_tip = null;
    chain_db.base_praos_state = null;
    chain_db.praos_state = praos.PraosState.initWithNonce(chain_db.praos_initial_nonce);
    chain_db.praos_tracking_ready = false;
    chain_db.ledger_validation_enabled = false;
    chain_db.ledger_ready = false;
    chain_db.governance_state.deinit(chain_db.allocator);
    chain_db.governance_state = .{};
}

fn restoreBaseResumeState(
    allocator: Allocator,
    chain_db: *ChainDB,
    snapshot: *const RuntimeSnapshot,
    db_path: []const u8,
) !bool {
    const base = try loadLedgerCheckpointAnchor(allocator, db_path) orelse return false;
    const ledger_path = try ledgerCheckpointPath(allocator, db_path);
    defer allocator.free(ledger_path);

    resetRuntimeResumeState(chain_db);

    const loaded = chain_db.ledger.loadCheckpoint(ledger_path) catch return false;
    if (!loaded) return false;

    chain_db.tip_slot = base.point.slot;
    chain_db.tip_hash = base.point.hash;
    chain_db.tip_block_no = base.block_no;
    chain_db.base_tip = base;
    if (chain_db.shelley_governance_config) |*config| {
        protocol_update.setCurrentEpochFromSlot(config, &chain_db.governance_state, base.point.slot);
    }
    try restorePraosForAnchor(
        allocator,
        chain_db,
        db_path,
        snapshot.layout.immutable_path,
        snapshot.last_chunk,
        base.point,
    );
    try chain_db.enableLedgerValidation();
    return true;
}

fn shouldFallbackFromTipCheckpoint(tip_checkpoint: BaseTip, rollback_point: ?Point) bool {
    const point = rollback_point orelse return true;
    return !Point.eql(point, tip_checkpoint.point) and point.slot <= tip_checkpoint.point.slot;
}

fn checkpointAnchor(chain_db: *const ChainDB) volatile_checkpoint.Anchor {
    if (chain_db.getBaseTip()) |base| {
        return .{ .point = .{
            .point = base.point,
            .block_no = base.block_no,
        } };
    }
    return .{ .origin = {} };
}

fn rollbackToBaseAnchor(chain_db: *ChainDB) void {
    const rollback_point = if (chain_db.getBaseTip()) |base| base.point else null;
    _ = chain_db.rollbackToPoint(rollback_point) catch {};
}

fn syncVolatileCheckpoint(allocator: Allocator, chain_db: *const ChainDB, db_path: []const u8) void {
    const count = chain_db.currentChainBlockCount();
    if (count == 0) {
        volatile_checkpoint.delete(allocator, db_path) catch {};
        return;
    }

    const blocks = allocator.alloc(volatile_checkpoint.SaveBlock, count) catch return;
    defer allocator.free(blocks);

    for (blocks, 0..) |*out, idx| {
        const block = chain_db.getCurrentChainBlock(idx) catch return;
        out.* = .{
            .hash = block.point.hash,
            .slot = block.point.slot,
            .block_no = block.block_no,
            .prev_hash = block.prev_hash,
            .data = block.data,
        };
    }

    volatile_checkpoint.save(allocator, db_path, checkpointAnchor(chain_db), blocks) catch {};
}

fn loadVolatileCheckpoint(allocator: Allocator, chain_db: *ChainDB, db_path: []const u8) !u32 {
    var loaded = volatile_checkpoint.load(allocator, db_path, checkpointAnchor(chain_db)) catch |err| switch (err) {
        error.InvalidCheckpoint => {
            volatile_checkpoint.delete(allocator, db_path) catch {};
            return 0;
        },
        else => return err,
    } orelse return 0;
    defer loaded.deinit(allocator);

    errdefer {
        rollbackToBaseAnchor(chain_db);
        volatile_checkpoint.delete(allocator, db_path) catch {};
    }

    var replayed: u32 = 0;
    for (loaded.blocks) |block| {
        const add_result = try chain_db.addBlock(
            block.hash,
            block.data,
            block.slot,
            block.block_no,
            block.prev_hash,
        );
        if (add_result != .added_to_current_chain) return error.InvalidCheckpoint;
        replayed += 1;
    }

    return replayed;
}

fn ensureVolatileCheckpointLoaded(
    allocator: Allocator,
    chain_db: *ChainDB,
    db_path: []const u8,
    loaded_once: *bool,
) !u32 {
    if (loaded_once.*) return 0;

    const replayed = try loadVolatileCheckpoint(allocator, chain_db, db_path);
    loaded_once.* = true;
    return replayed;
}

fn performInitialIntersect(
    allocator: Allocator,
    client: *sync_mod.SyncClient,
    chain_db: *ChainDB,
    runtime_snapshot: ?RuntimeSnapshot,
    network: types.Network,
    tip_checkpoint: ?BaseTip,
    tip_checkpoint_preloaded: bool,
    resume_points: *std.ArrayList(Point),
    db_path: []const u8,
    result: *RunResult,
    tip_checkpoint_active: *bool,
    volatile_checkpoint_loaded: *bool,
) !void {
    if (tip_checkpoint) |candidate| {
        const intersect = try client.findIntersect(&[_]Point{candidate.point});
        switch (intersect) {
            .intersect_found => {
                if (tip_checkpoint_preloaded or
                    try loadTipLedgerCheckpoint(allocator, chain_db, db_path, candidate, result))
                {
                    const replayed_current_chain = try ensureVolatileCheckpointLoaded(
                        allocator,
                        chain_db,
                        db_path,
                        volatile_checkpoint_loaded,
                    );
                    if (replayed_current_chain > 0) {
                        std.debug.print("Replayed {} current-chain blocks from volatile checkpoint.\n", .{replayed_current_chain});
                    }

                    const resumed_tip_point = currentTipPoint(chain_db) orelse candidate.point;
                    const resumed_intersect = try client.findIntersect(&[_]Point{resumed_tip_point});
                    switch (resumed_intersect) {
                        .intersect_found => {},
                        .intersect_not_found => {
                            if (replayed_current_chain > 0) {
                                rollbackToBaseAnchor(chain_db);
                                volatile_checkpoint.delete(allocator, db_path) catch {};
                                const base_tip = chain_db.getTip();
                                result.tip_slot = base_tip.slot;
                                result.tip_block_no = base_tip.block_no;
                            } else {
                                deleteTipLedgerCheckpoint(allocator, db_path);
                                return error.IntersectNotFound;
                            }
                        },
                        else => return error.UnexpectedMessage,
                    }

                    tip_checkpoint_active.* = true;
                    result.resumed_from_checkpoint = true;
                    const tip = chain_db.getTip();
                    result.tip_slot = tip.slot;
                    result.tip_block_no = tip.block_no;
                    return;
                }
            },
            .intersect_not_found => {
                deleteTipLedgerCheckpoint(allocator, db_path);
                if (tip_checkpoint_preloaded) {
                    resetRuntimeResumeState(chain_db);
                    if (runtime_snapshot) |snapshot| {
                        try loadRuntimeSnapshotBaseline(
                            allocator,
                            chain_db,
                            &snapshot,
                            db_path,
                            network,
                            result,
                        );
                    }
                }
            },
            else => return error.UnexpectedMessage,
        }
    }

    const replayed_current_chain = try ensureVolatileCheckpointLoaded(
        allocator,
        chain_db,
        db_path,
        volatile_checkpoint_loaded,
    );
    if (replayed_current_chain > 0) {
        std.debug.print("Replayed {} current-chain blocks from volatile checkpoint.\n", .{replayed_current_chain});
    }
    const restored_tip = chain_db.getTip();
    result.tip_slot = restored_tip.slot;
    result.tip_block_no = restored_tip.block_no;

    if (chain_db.currentChainBlockCount() > 0) {
        const tip_point = currentTipPoint(chain_db) orelse return error.InvalidCheckpoint;
        const intersect = try client.findIntersect(&[_]Point{tip_point});
        switch (intersect) {
            .intersect_found => {
                result.resumed_from_checkpoint = true;
                return;
            },
            .intersect_not_found => {
                rollbackToBaseAnchor(chain_db);
                volatile_checkpoint.delete(allocator, db_path) catch {};
                const tip = chain_db.getTip();
                result.tip_slot = tip.slot;
                result.tip_block_no = tip.block_no;
            },
            else => return error.UnexpectedMessage,
        }
    }

    if (runtime_snapshot) |snapshot| {
        if (currentTipPoint(chain_db)) |tip_point| {
            if (!Point.eql(tip_point, snapshot.point)) {
                const intersect = try client.findIntersect(&[_]Point{tip_point});
                switch (intersect) {
                    .intersect_found => {
                        result.resumed_from_checkpoint = true;
                        return;
                    },
                    .intersect_not_found => {},
                    else => return error.UnexpectedMessage,
                }
            }
        }

        const snapshot_intersect = try client.findIntersect(&[_]Point{snapshot.point});
        switch (snapshot_intersect) {
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

    const reader = chunk_reader_mod.ChunkReader.init(layout.immutable_path) catch {
        layout.deinit(allocator);
        return null;
    };

    const tip_result = reader.readTipWithChunk(allocator) catch {
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
        .last_chunk = tip_result.chunk_no,
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
    const RecoveredTip = struct {
        slot: types.SlotNo,
        hash: types.HeaderHash,
        block_no: types.BlockNo,
    };

    result.snapshot_anchor_used = true;
    result.snapshot_tip_slot = snapshot.point.slot;
    result.snapshot_tip_block = snapshot.block_no;

    const current_tip = chain_db.getTip();
    const recovered_tip = if ((current_tip.block_no != 0 or current_tip.slot != 0) and
        !(current_tip.slot == snapshot.point.slot and
            current_tip.block_no == snapshot.block_no and
            std.mem.eql(u8, &current_tip.hash, &snapshot.point.hash)))
        RecoveredTip{
            .slot = current_tip.slot,
            .hash = current_tip.hash,
            .block_no = current_tip.block_no,
        }
    else
        null;
    if (current_tip.block_no == 0 and current_tip.slot == 0) {
        try chain_db.attachSnapshotTip(snapshot.point, snapshot.block_no);
    } else if (current_tip.slot == snapshot.point.slot and
        current_tip.block_no == snapshot.block_no and
        std.mem.eql(u8, &current_tip.hash, &snapshot.point.hash))
    {
        // Tip already matches snapshot — no action needed
    } else {
        // Start from the Mithril anchor while we rebuild the ledger from the
        // local snapshot plus immutable tail. If we successfully replay a
        // later local immutable tip below, we'll restore that tip afterwards.
        std.debug.print("Resetting chain tip from slot {} to snapshot tip slot {}.\n", .{ current_tip.slot, snapshot.point.slot });
        chain_db.tip_slot = snapshot.point.slot;
        chain_db.tip_hash = snapshot.point.hash;
        chain_db.tip_block_no = snapshot.block_no;
        chain_db.base_tip = .{ .point = snapshot.point, .block_no = snapshot.block_no };
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
                snapshot.last_chunk,
                chain_db.getProtocolParams(),
                if (chain_db.shelley_governance_config) |config| config.epoch_length else null,
                if (chain_db.shelley_governance_config) |config|
                    chain_db.getProtocolParams().rewardParams(config.reward_params)
                else
                    rewards_mod.RewardParams.mainnet_defaults,
                if (chain_db.shelley_governance_config) |config| config.era_start_epoch else 0,
                if (chain_db.shelley_governance_config) |config| config.era_start_slot else 0,
            );
            result.immutable_blocks_replayed = replay.blocks_replayed;

            const praos_anchor = if (recovered_tip) |tip|
                if (tip.slot > snapshot.point.slot or
                    (tip.slot == snapshot.point.slot and tip.block_no >= snapshot.block_no))
                    Point{ .slot = tip.slot, .hash = tip.hash }
                else
                    snapshot.point
            else
                snapshot.point;
            const praos_anchor_block_no = if (recovered_tip) |tip|
                if (tip.slot > snapshot.point.slot or
                    (tip.slot == snapshot.point.slot and tip.block_no >= snapshot.block_no))
                    tip.block_no
                else
                    snapshot.block_no
            else
                snapshot.block_no;

            if (!Point.eql(praos_anchor, snapshot.point)) {
                chain_db.tip_slot = praos_anchor.slot;
                chain_db.tip_hash = praos_anchor.hash;
                chain_db.tip_block_no = praos_anchor_block_no;
                chain_db.base_tip = .{ .point = praos_anchor, .block_no = praos_anchor_block_no };
                std.debug.print(
                    "Recovered local immutable tip at slot {} block {} after snapshot replay.\n",
                    .{ praos_anchor.slot, praos_anchor_block_no },
                );
            }

            if (chain_db.shelley_governance_config) |config| {
                if (try praos_checkpoint.load(allocator, db_path, praos_anchor, &config)) |loaded| {
                    var owned = loaded;
                    defer owned.deinit(allocator);
                    chain_db.attachPraosState(owned.state);
                    chain_db.attachOcertCounters(owned.ocert_counters);
                    std.debug.print("Loaded persisted Praos state + {} OCert counters for resume anchor.\n", .{owned.ocert_counters.len});
                } else {
                    const praos_result = try praos_restore.reconstructFromImmutable(
                        allocator,
                        snapshot.layout.immutable_path,
                        praos_anchor.slot,
                        snapshot.last_chunk,
                        &config,
                    );
                    if (praos_result.state) |reconstructed_state| {
                        const state = reconstructed_state;
                        chain_db.attachPraosState(state);
                        praos_checkpoint.save(allocator, db_path, praos_anchor, &config, state, chain_db.getOcertCounters()) catch {};
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

/// N2C server loop — accepts connections and serves queries until stopped.
fn n2cServerLoop(server: *N2CServer, tip: *const N2CServer.TipState) void {
    _ = tip;
    while (!runtime_control.stopRequested()) {
        server.serveOne() catch |err| {
            if (runtime_control.stopRequested()) return;
            std.debug.print("N2C client error: {}\n", .{err});
        };
    }
}

/// Run the node: load config, optionally restore from snapshot, connect, sync.
pub fn run(allocator: Allocator, config: RunConfig) !RunResult {
    var result = RunResult{
        .headers_synced = 0,
        .blocks_fetched = 0,
        .blocks_added_to_chain = 0,
        .invalid_blocks = 0,
        .vrf_threshold_warnings = 0,
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
            if (genesis_mod.loadLedgerProtocolParamsWithOverride(allocator, path) catch null) |protocol_params| {
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
            if (genesis_mod.loadLedgerProtocolParamsWithOverride(allocator, shelley_path) catch null) |protocol_params| {
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
        if (genesis_mod.loadLedgerProtocolParamsWithOverride(allocator, path) catch null) |protocol_params| {
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
            const hard_fork_epoch = config.hard_fork_epoch orelse switch (config.network_magic) {
                1 => @as(u64, 4), // preprod
                2 => @as(u64, 0), // preview (Shelley from genesis)
                else => @as(u64, 208), // mainnet
            };
            loaded_governance_config.?.era_start_epoch = hard_fork_epoch;
            loaded_governance_config.?.era_start_slot = genesis_mod.computeEraStartSlot(&bg, hard_fork_epoch);
        }
    }

    // Open chain database
    var chain_db = try ChainDB.openWithMithrilBoundary(
        allocator,
        config.db_path,
        2160,
        if (runtime_snapshot) |snapshot| snapshot.last_chunk else null,
    );
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
        const network = networkFromMagic(config.network_magic);
        var startup_tip_checkpoint = try loadTipLedgerCheckpointAnchor(allocator, config.db_path);
        var tip_checkpoint_preloaded = false;

        if (startup_tip_checkpoint) |candidate| {
            tip_checkpoint_preloaded = try loadTipLedgerCheckpoint(
                allocator,
                &chain_db,
                config.db_path,
                candidate,
                &result,
            );
            if (!tip_checkpoint_preloaded) startup_tip_checkpoint = null;
        }

        if (!tip_checkpoint_preloaded) {
            loadRuntimeSnapshotBaseline(
                allocator,
                &chain_db,
                snapshot,
                config.db_path,
                network,
                &result,
            ) catch |err| switch (err) {
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
        } else {
            result.snapshot_anchor_used = true;
            result.snapshot_tip_slot = snapshot.point.slot;
            result.snapshot_tip_block = snapshot.block_no;
        }
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
    const initial_tip_checkpoint = if (runtime_snapshot != null)
        try loadTipLedgerCheckpointAnchor(allocator, config.db_path)
    else
        null;
    const initial_tip_checkpoint_preloaded = if (initial_tip_checkpoint) |candidate|
        if (chain_db.isLedgerValidationEnabled())
            if (chain_db.getBaseTip()) |base|
                Point.eql(base.point, candidate.point) and base.block_no == candidate.block_no and
                    currentTipPoint(&chain_db) != null and Point.eql(currentTipPoint(&chain_db).?, candidate.point) and
                    chain_db.getTip().block_no == candidate.block_no
            else
                false
        else
            false
    else
        false;

    // Shared tip state for the N2C server thread.
    var n2c_tip = N2CServer.TipState{
        .slot = chain_db.tip_slot,
        .hash = chain_db.tip_hash,
        .block_no = chain_db.tip_block_no,
        .network_magic = config.network_magic,
    };

    // Start N2C server in a background thread if socket path configured.
    var n2c_thread: ?std.Thread = null;
    var n2c_server: ?N2CServer = null;
    if (config.socket_path) |socket_path| {
        n2c_server = N2CServer.init(allocator, socket_path, &n2c_tip) catch |err| blk: {
            std.debug.print("N2C server failed to start on {s}: {}\n", .{ socket_path, err });
            break :blk null;
        };
        if (n2c_server != null) {
            n2c_thread = std.Thread.spawn(.{}, n2cServerLoop, .{ &n2c_server.?, &n2c_tip }) catch |err| blk: {
                std.debug.print("N2C server thread failed to start: {}\n", .{err});
                n2c_server.?.deinit();
                n2c_server = null;
                break :blk null;
            };
        }
    }
    defer {
        if (n2c_server) |*server| server.deinit();
    }

    var initial_intersect_done = false;
    var tip_checkpoint_active = false;
    var tip_checkpoint_base: ?BaseTip = null;
    var volatile_checkpoint_loaded = false;
    var reconnect_count: u32 = 0;
    var batch_start_time = std.time.timestamp();
    var batch_block_count: u64 = 0;
    var last_log_epoch: u64 = if (chain_db.shelley_governance_config) |cfg|
        cfg.slotToEpoch(chain_db.tip_slot)
    else
        0;

    reconnect: while (result.headers_synced < max) {
        if (runtime_control.stopRequested()) {
            result.stopped_by_signal = true;
            break;
        }

        const endpoint = peerForAttempt(config, reconnect_count);
        if (reconnect_count > 0) {
            // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, 60s max
            const backoff_secs: u64 = @min(60, @as(u64, 1) << @intCast(@min(reconnect_count, 6)));
            std.debug.print(
                "Reconnecting (attempt {}) via {s}:{} (backoff {}s)...\n",
                .{ reconnect_count, endpoint.host, endpoint.port, backoff_secs },
            );
            std.Thread.sleep(backoff_secs * std.time.ns_per_s);
        } else {
            std.debug.print("Connecting to {s}:{}...\n", .{ endpoint.host, endpoint.port });
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
                &chain_db,
                runtime_snapshot,
                networkFromMagic(config.network_magic),
                initial_tip_checkpoint,
                initial_tip_checkpoint_preloaded,
                &resume_points,
                config.db_path,
                &result,
                &tip_checkpoint_active,
                &volatile_checkpoint_loaded,
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
            if (tip_checkpoint_active) {
                tip_checkpoint_base = chain_db.getBaseTip();
            }
            std.debug.print("Intersect found, syncing forward from slot {}...\n", .{result.tip_slot});
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
                            reconnect_count = 0; // reset backoff on progress
                            try pushResumePoint(&resume_points, allocator, point);
                            saveResumePoints(allocator, config.db_path, resume_points.items) catch {};
                            const promoted = try chain_db.promoteFinalized();
                            if (promoted > 0 and !tip_checkpoint_active) {
                                savePraosCheckpoint(allocator, &chain_db, config.db_path);
                                saveBaseLedgerCheckpoint(allocator, &chain_db, config.db_path);
                            }
                            if (!tip_checkpoint_active) {
                                syncVolatileCheckpoint(allocator, &chain_db, config.db_path);
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

                    // Update N2C shared tip state
                    n2c_tip.slot = tip.slot;
                    n2c_tip.hash = tip.hash;
                    n2c_tip.block_no = tip.block_no;

                    // Epoch boundary marker
                    if (chain_db.shelley_governance_config) |cfg| {
                        const block_epoch = cfg.slotToEpoch(block.header.slot);
                        if (block_epoch > last_log_epoch) {
                            std.debug.print(
                                "══ Epoch {} boundary at slot {} ══\n",
                                .{ block_epoch, cfg.epochFirstSlot(block_epoch) },
                            );
                            last_log_epoch = block_epoch;
                        }
                    }

                    // Per-block log
                    std.debug.print("Block {} slot {} era={s}", .{
                        block.header.block_no,
                        block.header.slot,
                        @tagName(block.era),
                    });
                    if (add_result == .added_to_current_chain) {
                        std.debug.print(" +chain", .{});
                    }
                    std.debug.print("\n", .{});

                    // Periodic summary every 100 blocks
                    batch_block_count += 1;
                    if (batch_block_count % 100 == 0) {
                        const batch_now = std.time.timestamp();
                        const elapsed = batch_now - batch_start_time;
                        const rate = if (elapsed > 0) @divTrunc(@as(i64, @intCast(batch_block_count)), elapsed) else 0;
                        std.debug.print(
                            "=== {d} blocks in {d}s ({d}/s) | tip: slot {d} block {d} | volatile: {d} | rollbacks: {d} ===\n",
                            .{
                                batch_block_count,
                                elapsed,
                                rate,
                                result.tip_slot,
                                result.tip_block_no,
                                chain_db.@"volatile".count(),
                                result.rollbacks,
                            },
                        );
                    }
                },
                .await_reply => {
                    if (runtime_control.stopRequested()) {
                        result.stopped_by_signal = true;
                        break :reconnect;
                    }
                    // At tip — send keep-alive and wait
                    if (batch_block_count > 0) {
                        std.debug.print("At tip — slot {} block {} ({} blocks synced). Waiting for new blocks...\n", .{
                            result.tip_slot, result.tip_block_no, batch_block_count,
                        });
                        batch_block_count = 0;
                        batch_start_time = std.time.timestamp();
                    }
                    client.keepAlive() catch {};
                    std.Thread.sleep(1 * std.time.ns_per_s);
                },
                .roll_backward => |rb| {
                    result.rollbacks += 1;
                    if (rb.point) |p| {
                        std.debug.print("Rollback to slot {} (total rollbacks: {})\n", .{ p.slot, result.rollbacks });
                    } else {
                        std.debug.print("Rollback to genesis (total rollbacks: {})\n", .{result.rollbacks});
                    }
                    if (tip_checkpoint_active and tip_checkpoint_base != null and shouldFallbackFromTipCheckpoint(tip_checkpoint_base.?, rb.point)) {
                        std.debug.print("Rollback below cached tip; restoring base + volatile resume state.\n", .{});
                        const snapshot = runtime_snapshot orelse unreachable;
                        if (!(try restoreBaseResumeState(allocator, &chain_db, &snapshot, config.db_path))) {
                            result.errors += 1;
                            break :reconnect;
                        }
                        _ = try loadVolatileCheckpoint(allocator, &chain_db, config.db_path);
                        _ = chain_db.rollbackToPoint(rb.point) catch blk: {
                            result.errors += 1;
                            break :blk 0;
                        };
                        tip_checkpoint_active = false;
                        tip_checkpoint_base = null;
                        deleteTipLedgerCheckpoint(allocator, config.db_path);
                        truncateResumePoints(&resume_points, rb.point);
                        saveResumePoints(allocator, config.db_path, resume_points.items) catch {};
                        const recovered_tip = chain_db.getTip();
                        result.tip_slot = recovered_tip.slot;
                        result.tip_block_no = recovered_tip.block_no;
                        continue;
                    }
                    _ = chain_db.rollbackToPoint(rb.point) catch blk: {
                        result.errors += 1;
                        break :blk 0;
                    };
                    truncateResumePoints(&resume_points, rb.point);
                    saveResumePoints(allocator, config.db_path, resume_points.items) catch {};
                    if (!tip_checkpoint_active) {
                        syncVolatileCheckpoint(allocator, &chain_db, config.db_path);
                    }

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

    saveTipLedgerCheckpoint(allocator, &chain_db, config.db_path);
    syncVolatileCheckpoint(allocator, &chain_db, config.db_path);
    saveBaseLedgerCheckpointForShutdown(allocator, &chain_db, config.db_path);
    savePraosCheckpoint(allocator, &chain_db, config.db_path);
    result.vrf_threshold_warnings = chain_db.vrf_threshold_warnings;
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
        .vrf_threshold_warnings = 0,
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

    initializeByronGenesisState(allocator, &chain_db, "config/preprod/byron.json", &result) catch |err| {
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
    try std.testing.expectEqualStrings("config/preprod/byron.json", preprod.byron_genesis_path.?);
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

test "runner: volatile checkpoint replays current chain from origin" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-runner-volatile-origin";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    {
        var db = try ChainDB.open(allocator, path, 2160);
        defer db.close();

        const hash0 = [_]u8{0x10} ** 32;
        const hash1 = [_]u8{0x11} ** 32;
        try std.testing.expectEqual(
            AddBlockResult.added_to_current_chain,
            try db.addBlock(hash0, "block0", 10, 0, null),
        );
        try std.testing.expectEqual(
            AddBlockResult.added_to_current_chain,
            try db.addBlock(hash1, "block1", 20, 1, hash0),
        );

        syncVolatileCheckpoint(allocator, &db, path);
    }

    var reopened = try ChainDB.open(allocator, path, 2160);
    defer reopened.close();

    try std.testing.expectEqual(@as(u32, 2), try loadVolatileCheckpoint(allocator, &reopened, path));
    try std.testing.expectEqual(@as(usize, 2), reopened.currentChainBlockCount());
    try std.testing.expectEqual(@as(u64, 20), reopened.getTip().slot);
    try std.testing.expectEqual([_]u8{0x11} ** 32, reopened.getTip().hash);
}

test "runner: volatile checkpoint replays anchored current chain" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-runner-volatile-anchor";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const anchor_hash = [_]u8{0xaa} ** 32;
    const child_hash = [_]u8{0xbb} ** 32;
    const grandchild_hash = [_]u8{0xcc} ** 32;

    {
        var db = try ChainDB.open(allocator, path, 2160);
        defer db.close();

        try db.attachSnapshotTip(.{ .slot = 100, .hash = anchor_hash }, 50);
        try std.testing.expectEqual(
            AddBlockResult.added_to_current_chain,
            try db.addBlock(child_hash, "child", 110, 51, anchor_hash),
        );
        try std.testing.expectEqual(
            AddBlockResult.added_to_current_chain,
            try db.addBlock(grandchild_hash, "grandchild", 120, 52, child_hash),
        );

        syncVolatileCheckpoint(allocator, &db, path);
    }

    var reopened = try ChainDB.open(allocator, path, 2160);
    defer reopened.close();
    try reopened.attachSnapshotTip(.{ .slot = 100, .hash = anchor_hash }, 50);

    try std.testing.expectEqual(@as(u32, 2), try loadVolatileCheckpoint(allocator, &reopened, path));
    try std.testing.expectEqual(@as(usize, 2), reopened.currentChainBlockCount());
    try std.testing.expectEqual(@as(u64, 52), reopened.getTip().block_no);
    try std.testing.expectEqual(grandchild_hash, reopened.getTip().hash);
}

test "runner: volatile checkpoint only replays once per startup attempt" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-runner-volatile-once";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    {
        var db = try ChainDB.open(allocator, path, 2160);
        defer db.close();

        const hash0 = [_]u8{0x31} ** 32;
        const hash1 = [_]u8{0x32} ** 32;
        try std.testing.expectEqual(
            AddBlockResult.added_to_current_chain,
            try db.addBlock(hash0, "block0", 10, 0, null),
        );
        try std.testing.expectEqual(
            AddBlockResult.added_to_current_chain,
            try db.addBlock(hash1, "block1", 20, 1, hash0),
        );

        syncVolatileCheckpoint(allocator, &db, path);
    }

    var reopened = try ChainDB.open(allocator, path, 2160);
    defer reopened.close();

    var loaded_once = false;
    try std.testing.expectEqual(@as(u32, 2), try ensureVolatileCheckpointLoaded(allocator, &reopened, path, &loaded_once));
    try std.testing.expectEqual(@as(usize, 2), reopened.currentChainBlockCount());
    try std.testing.expect(loaded_once);

    try std.testing.expectEqual(@as(u32, 0), try ensureVolatileCheckpointLoaded(allocator, &reopened, path, &loaded_once));
    try std.testing.expectEqual(@as(usize, 2), reopened.currentChainBlockCount());
    try std.testing.expectEqual(@as(u64, 20), reopened.getTip().slot);
}

test "runner: shutdown refresh saves base checkpoint from non-empty current chain" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-runner-base-checkpoint-shutdown";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const base_hash = [_]u8{0xa7} ** 32;
    const child_hash = [_]u8{0xb8} ** 32;
    const tip_hash = [_]u8{0xc9} ** 32;
    const reward_account = types.RewardAccount{
        .network = .testnet,
        .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0xda} ** 28 },
    };

    {
        var db = try ChainDB.open(allocator, path, 2160);
        defer db.close();

        db.ledger.setRewardAccountNetwork(.testnet);
        try db.attachSnapshotTip(.{ .slot = 100, .hash = base_hash }, 50);
        try db.ledger.importRewardBalance(reward_account, 7_000);
        db.ledger.setTipSlot(100);

        try std.testing.expectEqual(
            AddBlockResult.added_to_current_chain,
            try db.addBlock(child_hash, "child", 110, 51, base_hash),
        );
        try std.testing.expectEqual(
            AddBlockResult.added_to_current_chain,
            try db.addBlock(tip_hash, "tip", 120, 52, child_hash),
        );

        db.ledger_validation_enabled = true;
        db.ledger_ready = true;
        saveBaseLedgerCheckpointForShutdown(allocator, &db, path);

        try std.testing.expectEqual(@as(usize, 0), db.currentChainBlockCount());
        try std.testing.expectEqual(@as(u64, 100), db.getTip().slot);
    }

    const anchor = (try loadLedgerCheckpointAnchor(allocator, path)).?;
    try std.testing.expectEqual(@as(u64, 100), anchor.point.slot);
    try std.testing.expectEqual(base_hash, anchor.point.hash);
    try std.testing.expectEqual(@as(u64, 50), anchor.block_no);

    var reopened = try ChainDB.open(allocator, path, 2160);
    defer reopened.close();
    reopened.ledger.setRewardAccountNetwork(.testnet);

    const checkpoint_path = try ledgerCheckpointPath(allocator, path);
    defer allocator.free(checkpoint_path);
    try std.testing.expect(try reopened.ledger.loadCheckpoint(checkpoint_path));
    try std.testing.expectEqual(@as(?types.Coin, 7_000), reopened.ledger.lookupRewardBalance(reward_account));
}

test "runner: tip checkpoint round-trip restores exact tip state" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-runner-tip-checkpoint";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const anchor_hash = [_]u8{0xa1} ** 32;
    const tip_hash = [_]u8{0xb2} ** 32;
    const reward_account = types.RewardAccount{
        .network = .testnet,
        .credential = .{
            .cred_type = .key_hash,
            .hash = [_]u8{0xc3} ** 28,
        },
    };

    {
        var db = try ChainDB.open(allocator, path, 2160);
        defer db.close();

        const governance_config = protocol_update.GovernanceConfig{
            .epoch_length = 100,
            .stability_window = 10,
            .update_quorum = 1,
            .initial_nonce = .{ .hash = [_]u8{0x11} ** 32 },
            .extra_entropy = .neutral,
            .decentralization_param = .{ .numerator = 0, .denominator = 1 },
            .reward_params = rewards_mod.RewardParams.mainnet_defaults,
            .initial_genesis_delegations = try allocator.alloc(protocol_update.GenesisDelegation, 0),
        };
        try db.configureShelleyGovernanceTracking(governance_config);

        try db.attachSnapshotTip(.{ .slot = 100, .hash = anchor_hash }, 50);
        _ = try db.primeBaseUtxos(&[_]@import("../storage/ledger.zig").UtxoEntry{
            .{
                .tx_in = .{ .tx_id = [_]u8{0xd4} ** 32, .tx_ix = 0 },
                .value = 5_000_000,
                .raw_cbor = &.{},
            },
        });
        try db.enableLedgerValidation();
        try db.ledger.importRewardBalance(reward_account, 7_000);
        db.ledger.setTipSlot(120);
        db.tip_slot = 120;
        db.tip_hash = tip_hash;
        db.tip_block_no = 52;
        db.attachPraosState(.{
            .flavor = .praos,
            .evolving_nonce = .{ .hash = [_]u8{0x21} ** 32 },
            .candidate_nonce = .{ .hash = [_]u8{0x22} ** 32 },
            .epoch_nonce = .{ .hash = [_]u8{0x23} ** 32 },
            .previous_epoch_nonce = .{ .hash = [_]u8{0x24} ** 32 },
            .last_epoch_block_nonce = .{ .hash = [_]u8{0x25} ** 32 },
            .lab_nonce = .{ .hash = [_]u8{0x26} ** 32 },
        });
        try db.ocert_counters.put([_]u8{0xe5} ** 28, 9);

        persistTipLedgerCheckpoint(allocator, &db, path);
    }

    var reopened = try ChainDB.open(allocator, path, 2160);
    defer reopened.close();
    reopened.ledger.setRewardAccountNetwork(.testnet);
    const governance_config = protocol_update.GovernanceConfig{
        .epoch_length = 100,
        .stability_window = 10,
        .update_quorum = 1,
        .initial_nonce = .{ .hash = [_]u8{0x11} ** 32 },
        .extra_entropy = .neutral,
        .decentralization_param = .{ .numerator = 0, .denominator = 1 },
        .reward_params = rewards_mod.RewardParams.mainnet_defaults,
        .initial_genesis_delegations = try allocator.alloc(protocol_update.GenesisDelegation, 0),
    };
    try reopened.configureShelleyGovernanceTracking(governance_config);

    const tip_checkpoint = (try loadTipLedgerCheckpointAnchor(allocator, path)).?;
    var result: RunResult = std.mem.zeroInit(RunResult, .{});
    try std.testing.expect(try loadTipLedgerCheckpoint(allocator, &reopened, path, tip_checkpoint, &result));
    try std.testing.expectEqual(@as(u64, 120), reopened.getTip().slot);
    try std.testing.expectEqual(@as(u64, 52), reopened.getTip().block_no);
    try std.testing.expectEqual(tip_hash, reopened.getTip().hash);
    try std.testing.expectEqual(@as(usize, 1), reopened.ledger.utxoCount());
    try std.testing.expectEqual(@as(?types.Coin, 7_000), reopened.ledger.lookupRewardBalance(reward_account));
    try std.testing.expectEqual(@as(u64, 1), result.snapshot_reward_accounts_primed);
    try std.testing.expectEqual(@as(?u64, 9), reopened.ocert_counters.get([_]u8{0xe5} ** 28));
}

test "runner: old checkpoint anchors are ignored" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-runner-old-anchor";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};
    try std.fs.cwd().makePath(path);

    const anchor_path = try tipLedgerCheckpointAnchorPath(allocator, path);
    defer allocator.free(anchor_path);

    var file = try std.fs.cwd().createFile(anchor_path, .{ .truncate = true });
    defer file.close();

    var version_buf: [4]u8 = undefined;
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, &version_buf, ledger_checkpoint_anchor_version - 1, .big);
    try file.writeAll(&version_buf);
    std.mem.writeInt(u64, &buf, 123, .big);
    try file.writeAll(&buf);
    try file.writeAll(&([_]u8{0xee} ** 32));
    std.mem.writeInt(u64, &buf, 456, .big);
    try file.writeAll(&buf);

    try std.testing.expectEqual(@as(?BaseTip, null), try loadTipLedgerCheckpointAnchor(allocator, path));
}

fn buildSignedShelleyRunnerTestBlock(
    allocator: Allocator,
    tx_bodies_raw: []const u8,
    block_no: u64,
    slot: u64,
    prev_hash: ?[32]u8,
    issuer_seed: [32]u8,
    kes_seed: [32]u8,
    vrf_seed: [32]u8,
    opcert_sequence_no: u64,
    body_hash: [32]u8,
) ![]u8 {
    const Encoder = @import("../cbor/encoder.zig").Encoder;
    const Ed25519 = @import("../crypto/ed25519.zig").Ed25519;
    const LiveKES = @import("../crypto/kes_sum.zig").KES;
    const VRF = @import("../crypto/vrf.zig").VRF;
    const opcert_mod = @import("../crypto/opcert.zig");
    const leader = @import("../consensus/leader.zig");

    const cold_kp = try Ed25519.keyFromSeed(issuer_seed);
    const kes_kp = try LiveKES.generate(kes_seed);
    const vrf_kp = try VRF.keyFromSeed(vrf_seed);
    const current_kes_period: u32 = @intCast(slot / types.mainnet.slots_per_kes_period);
    const vrf_result = try VRF.prove(&leader.makeInputVRF(slot, praos.initialNonce()), vrf_kp.sk);
    const opcert = try opcert_mod.OperationalCert.create(
        kes_kp.vk,
        opcert_sequence_no,
        current_kes_period,
        cold_kp.sk,
    );

    var header_body_enc = Encoder.init(allocator);
    defer header_body_enc.deinit();
    try header_body_enc.encodeArrayLen(10);
    try header_body_enc.encodeUint(block_no);
    try header_body_enc.encodeUint(slot);
    if (prev_hash) |hash| {
        try header_body_enc.encodeBytes(&hash);
    } else {
        try header_body_enc.encodeNull();
    }
    try header_body_enc.encodeBytes(&cold_kp.vk);
    try header_body_enc.encodeBytes(&vrf_kp.vk);
    try header_body_enc.encodeArrayLen(2);
    try header_body_enc.encodeBytes(&vrf_result.output);
    try header_body_enc.encodeBytes(&vrf_result.proof);
    try header_body_enc.encodeUint(tx_bodies_raw.len);
    try header_body_enc.encodeBytes(&body_hash);
    try header_body_enc.encodeArrayLen(4);
    try header_body_enc.encodeBytes(&opcert.hot_vkey);
    try header_body_enc.encodeUint(opcert.sequence_number);
    try header_body_enc.encodeUint(opcert.kes_period);
    try header_body_enc.encodeBytes(&opcert.cold_key_signature);
    try header_body_enc.encodeArrayLen(2);
    try header_body_enc.encodeUint(1);
    try header_body_enc.encodeUint(0);
    const header_body_raw = try header_body_enc.toOwnedSlice();
    defer allocator.free(header_body_raw);

    const kes_sig = try LiveKES.sign(current_kes_period, header_body_raw, &kes_kp.sk);

    var header_enc = Encoder.init(allocator);
    defer header_enc.deinit();
    try header_enc.encodeArrayLen(2);
    try header_enc.writeRaw(header_body_raw);
    try header_enc.encodeBytes(&kes_sig);
    const header_raw = try header_enc.toOwnedSlice();
    defer allocator.free(header_raw);

    var block_enc = Encoder.init(allocator);
    defer block_enc.deinit();
    try block_enc.encodeArrayLen(4);
    try block_enc.writeRaw(header_raw);
    try block_enc.writeRaw(tx_bodies_raw);
    try block_enc.encodeArrayLen(0);
    try block_enc.encodeMapLen(0);
    return block_enc.toOwnedSlice();
}

test "runner: stale base checkpoint replays immutable tail and refreshes anchor" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-runner-stale-base-checkpoint";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const snapshot_hash = [_]u8{0x71} ** 32;
    const reward_account = types.RewardAccount{
        .network = .testnet,
        .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0x72} ** 28 },
    };
    const empty_tx_bodies = [_]u8{0x80};
    const tx_body_hash = @import("../crypto/hash.zig").Blake2b256.hash(&empty_tx_bodies);

    var block1_hash: [32]u8 = undefined;

    {
        var db = try ChainDB.openWithMithrilBoundary(allocator, path, 1, 0);
        defer db.close();

        db.ledger.setRewardAccountNetwork(.testnet);
        try db.attachSnapshotTip(.{ .slot = 100, .hash = snapshot_hash }, 50);
        db.ledger.setTipSlot(100);
        db.ledger_validation_enabled = true;
        db.ledger_ready = true;
        try db.ledger.importRewardBalance(reward_account, 7_000);
        saveBaseLedgerCheckpoint(allocator, &db, path);
        db.ledger_validation_enabled = false;
        db.ledger_ready = false;
        const boundary_chunk_path = try std.fmt.allocPrint(allocator, "{s}/immutable/00000.chunk", .{path});
        defer allocator.free(boundary_chunk_path);
        var boundary_chunk = try std.fs.cwd().createFile(boundary_chunk_path, .{ .truncate = false });
        boundary_chunk.close();

        const block1_data = try buildSignedShelleyRunnerTestBlock(
            allocator,
            &empty_tx_bodies,
            51,
            110,
            snapshot_hash,
            [_]u8{0x81} ** 32,
            [_]u8{0x82} ** 32,
            [_]u8{0x83} ** 32,
            0,
            tx_body_hash,
        );
        defer allocator.free(block1_data);
        const block1 = try block_mod.parseBlock(block1_data);
        block1_hash = block1.hash();

        const block2_data = try buildSignedShelleyRunnerTestBlock(
            allocator,
            &empty_tx_bodies,
            52,
            120,
            block1_hash,
            [_]u8{0x84} ** 32,
            [_]u8{0x85} ** 32,
            [_]u8{0x86} ** 32,
            1,
            tx_body_hash,
        );
        defer allocator.free(block2_data);
        const block2 = try block_mod.parseBlock(block2_data);
        const block2_hash = block2.hash();

        try std.testing.expectEqual(
            AddBlockResult.added_to_current_chain,
            try db.addBlock(block1_hash, block1_data, block1.header.slot, block1.header.block_no, block1.header.prev_hash),
        );
        try std.testing.expectEqual(
            AddBlockResult.added_to_current_chain,
            try db.addBlock(block2_hash, block2_data, block2.header.slot, block2.header.block_no, block2.header.prev_hash),
        );
        try std.testing.expectEqual(@as(u32, 1), try db.promoteFinalized());
        try std.testing.expectEqual(@as(u64, 110), db.getBaseTip().?.point.slot);
        try std.testing.expectEqual(@as(usize, 1), db.currentChainBlockCount());
    }

    var reopened = try ChainDB.openWithMithrilBoundary(allocator, path, 1, 0);
    defer reopened.close();
    reopened.ledger.setRewardAccountNetwork(.testnet);

    var snapshot = RuntimeSnapshot{
        .layout = .{
            .root_path = try allocator.dupe(u8, path),
            .immutable_path = try std.fmt.allocPrint(allocator, "{s}/immutable", .{path}),
            .ledger_path = null,
        },
        .point = .{ .slot = 100, .hash = snapshot_hash },
        .block_no = 50,
        .last_chunk = 0,
    };
    defer snapshot.deinit(allocator);

    var result: RunResult = std.mem.zeroInit(RunResult, .{});
    try std.testing.expect(try loadBaseLedgerCheckpoint(allocator, &reopened, &snapshot, path, &result));
    try std.testing.expectEqual(@as(u64, 110), reopened.getTip().slot);
    try std.testing.expectEqual(@as(u64, 51), reopened.getTip().block_no);
    try std.testing.expectEqual(block1_hash, reopened.getTip().hash);
    try std.testing.expectEqual(@as(u64, 1), result.immutable_blocks_replayed);
    try std.testing.expectEqual(@as(?types.Coin, 7_000), reopened.ledger.lookupRewardBalance(reward_account));

    const refreshed_anchor = (try loadLedgerCheckpointAnchor(allocator, path)).?;
    try std.testing.expectEqual(@as(u64, 110), refreshed_anchor.point.slot);
    try std.testing.expectEqual(block1_hash, refreshed_anchor.point.hash);
    try std.testing.expectEqual(@as(u64, 51), refreshed_anchor.block_no);
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
