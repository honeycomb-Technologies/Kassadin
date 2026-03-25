const std = @import("std");

const ledger_mod = @import("storage/ledger.zig");
const ledger_snapshot = @import("node/ledger_snapshot.zig");
const genesis_mod = @import("node/genesis.zig");
const rewards_mod = @import("ledger/rewards.zig");
const types = @import("types.zig");

const LedgerDB = ledger_mod.LedgerDB;
const RewardAccount = types.RewardAccount;
const Credential = types.Credential;
const Coin = types.Coin;

fn hasPrefix(hash: types.Hash28, prefix: []const u8) bool {
    return std.mem.startsWith(u8, &hash, prefix);
}

fn findCredentialByPrefix(ledger: *const LedgerDB, prefix: []const u8) ?Credential {
    var stake_it = ledger.stake_accounts.iterator();
    while (stake_it.next()) |entry| {
        if (hasPrefix(entry.key_ptr.hash, prefix)) return entry.key_ptr.*;
    }

    var reward_it = ledger.reward_balances.iterator();
    while (reward_it.next()) |entry| {
        if (hasPrefix(entry.key_ptr.credential.hash, prefix)) return entry.key_ptr.credential;
    }

    return null;
}

fn findPoolByPrefix(ledger: *const LedgerDB, prefix: []const u8) ?types.KeyHash {
    var cfg_it = ledger.pool_configs.iterator();
    while (cfg_it.next()) |entry| {
        if (hasPrefix(entry.key_ptr.*, prefix)) return entry.key_ptr.*;
    }

    const snaps = ledger.getStakeSnapshots();
    const dists = [_]?ledger_mod.StakeDistribution{ snaps.mark, snaps.set, snaps.go };
    for (dists) |maybe_dist| {
        if (maybe_dist) |dist| {
            var pool_it = dist.pools.iterator();
            while (pool_it.next()) |entry| {
                if (hasPrefix(entry.key_ptr.*, prefix)) return entry.key_ptr.*;
            }
        }
    }

    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        std.debug.assert(leaked == .ok);
    }
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const checkpoint_path = args.next() orelse "db/preprod/ledger.tip.resume";
    const shelley_genesis_path = args.next() orelse "config/preprod/shelley.json";

    const credential_prefix = [_]u8{ 0x35, 0x23, 0x22, 0x52 };
    const pool_prefix = [_]u8{ 0x8f, 0xfb, 0x4c, 0x8e };

    var ledger = try LedgerDB.init(allocator, "/tmp/kassadin-inspect");
    defer ledger.deinit();

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/meta", .{checkpoint_path});
    defer allocator.free(meta_path);
    if (fileExists(meta_path)) {
        var snapshot = ledger_snapshot.LocalLedgerSnapshot{
            .slot = try std.fmt.parseInt(types.SlotNo, std.fs.path.basename(checkpoint_path), 10),
            .path = try allocator.dupe(u8, checkpoint_path),
        };
        defer snapshot.deinit(allocator);
        _ = try ledger_snapshot.loadSnapshotIntoLedger(allocator, &ledger, snapshot, .testnet);
    } else if (!try ledger.loadCheckpoint(checkpoint_path)) {
        std.debug.print("failed to load checkpoint: {s}\n", .{checkpoint_path});
        std.process.exit(1);
    }

    const failing_cred = findCredentialByPrefix(&ledger, &credential_prefix) orelse {
        std.debug.print("no credential found with prefix {x}\n", .{credential_prefix});
        std.process.exit(1);
    };
    const failing_pool = findPoolByPrefix(&ledger, &pool_prefix) orelse {
        std.debug.print("no pool found with prefix {x}\n", .{pool_prefix});
        std.process.exit(1);
    };
    const failing_account = RewardAccount{
        .network = .testnet,
        .credential = failing_cred,
    };

    const go = ledger.getStakeSnapshots().go orelse {
        std.debug.print("checkpoint has no go snapshot\n", .{});
        std.process.exit(1);
    };
    const set = ledger.getStakeSnapshots().set;
    const mark = ledger.getStakeSnapshots().mark;

    const pool_cfg = ledger.lookupPoolConfig(failing_pool);
    const future_pool_cfg = ledger.lookupFuturePoolParams(failing_pool);
    const reward_account = ledger.lookupPoolRewardAccount(failing_pool);
    const reward_balance = ledger.lookupRewardBalance(failing_account);
    const mir_reserves = ledger.lookupMirReward(.reserves, failing_cred);
    const mir_treasury = ledger.lookupMirReward(.treasury, failing_cred);
    const prev_blocks = ledger.lookupPreviousEpochBlocksMade(failing_pool) orelse 0;
    const current_blocks = ledger.lookupCurrentEpochBlocksMade(failing_pool) orelse 0;

    var total_prev_blocks: u64 = 0;
    var prev_it = ledger.blocks_made_previous_epoch.valueIterator();
    while (prev_it.next()) |count| total_prev_blocks += count.*;
    var total_current_blocks: u64 = 0;
    var current_it = ledger.blocks_made_current_epoch.valueIterator();
    while (current_it.next()) |count| total_current_blocks += count.*;

    std.debug.print("checkpoint: {s}\n", .{checkpoint_path});
    std.debug.print("tip_slot={?} treasury={} reserves={} fees={} snapshot_fees={}\n", .{
        ledger.tip_slot,
        ledger.getTreasuryBalance(),
        ledger.getReservesBalance(),
        ledger.getFeesBalance(),
        ledger.getSnapshotFees(),
    });
    std.debug.print("cred={x} reward_balance=", .{failing_cred.hash});
    if (reward_balance) |coin| {
        std.debug.print("{}", .{coin});
    } else {
        std.debug.print("null", .{});
    }
    std.debug.print(" mir_reserves=", .{});
    if (mir_reserves) |coin| {
        std.debug.print("{}", .{coin});
    } else {
        std.debug.print("null", .{});
    }
    std.debug.print(" mir_treasury=", .{});
    if (mir_treasury) |coin| {
        std.debug.print("{}", .{coin});
    } else {
        std.debug.print("null", .{});
    }
    std.debug.print("\n", .{});
    if (ledger.stake_accounts.get(failing_cred)) |state| {
        std.debug.print(
            "stake_account: registered={} reward_balance={} deposit={} delegation=",
            .{ state.registered, state.reward_balance, state.deposit },
        );
        if (state.stake_pool_delegation) |pool| {
            std.debug.print("{x}", .{pool});
        } else {
            std.debug.print("null", .{});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("pool={x}\n", .{failing_pool});
    std.debug.print(
        "blocks_made: prev_pool={} prev_total={} current_pool={} current_total={}\n",
        .{ prev_blocks, total_prev_blocks, current_blocks, total_current_blocks },
    );
    if (reward_account) |acct| {
        std.debug.print("pool reward account={x}\n", .{acct.credential.hash});
    } else {
        std.debug.print("pool reward account=null\n", .{});
    }
    if (pool_cfg) |cfg| {
        std.debug.print(
            "pool config: pledge={} cost={} margin={}/{} vrf=",
            .{ cfg.pledge, cfg.cost, cfg.margin.numerator, cfg.margin.denominator },
        );
        if (cfg.vrf_keyhash) |vrf| {
            std.debug.print("{x}", .{vrf});
        } else {
            std.debug.print("null", .{});
        }
        std.debug.print("\n", .{});
    }
    if (future_pool_cfg) |future| {
        std.debug.print(
            "future pool config: pledge={} cost={} margin={}/{} reward_account={x} vrf=",
            .{
                future.config.pledge,
                future.config.cost,
                future.config.margin.numerator,
                future.config.margin.denominator,
                future.reward_account.credential.hash,
            },
        );
        if (future.config.vrf_keyhash) |vrf| {
            std.debug.print("{x}", .{vrf});
        } else {
            std.debug.print("null", .{});
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("future pool config: null\n", .{});
    }

    const snapshots = [_]struct {
        name: []const u8,
        dist: ?@TypeOf(go),
    }{
        .{ .name = "mark", .dist = mark },
        .{ .name = "set", .dist = set },
        .{ .name = "go", .dist = go },
    };

    for (snapshots) |entry| {
        const dist = entry.dist orelse {
            std.debug.print("{s}: null\n", .{entry.name});
            continue;
        };
        const pool = dist.getPool(failing_pool);
        const deleg = dist.getDelegatedStake(failing_cred);
        std.debug.print("{s}: total_stake={} pool?={} deleg?={}\n", .{
            entry.name,
            dist.total_stake,
            pool != null,
            deleg != null,
        });
        if (pool) |ps| {
            std.debug.print(
                "{s} pool: active={} owner_stake={} pledge={} cost={} margin={}/{} reward_account={x} is_owner={}\n",
                .{
                    entry.name,
                    ps.active_stake,
                    ps.self_delegated_owner_stake,
                    ps.pledge,
                    ps.cost,
                    ps.margin.numerator,
                    ps.margin.denominator,
                    ps.reward_account.credential.hash,
                    dist.isPoolOwner(failing_pool, failing_cred.hash),
                },
            );
        }
        if (deleg) |ds| {
            std.debug.print("{s} delegator: pool={x} active={}\n", .{
                entry.name,
                ds.pool_id,
                ds.active_stake,
            });
        }
    }

    const go_pool = go.getPool(failing_pool) orelse {
        std.debug.print("go snapshot missing failing pool\n", .{});
        return;
    };
    const go_deleg = go.getDelegatedStake(failing_cred) orelse {
        std.debug.print("go snapshot missing failing credential\n", .{});
        return;
    };

    var governance_config = try genesis_mod.loadShelleyGovernanceConfig(allocator, shelley_genesis_path);
    defer governance_config.deinit(allocator);
    const protocol_params = try genesis_mod.loadLedgerProtocolParamsWithOverride(allocator, shelley_genesis_path);
    const params = protocol_params.rewardParams(governance_config.reward_params);
    const slots_per_epoch: u64 = 432_000;
    const blocks_total = rewards_mod.calculateExpectedBlocks(slots_per_epoch, params.active_slot_coeff);
    const epoch_rewards = rewards_mod.calculateEpochRewards(
        ledger.getReservesBalance(),
        ledger.getSnapshotFees(),
        params,
        total_prev_blocks,
        blocks_total,
    );

    const total_stake_current = params.total_lovelace -| ledger.getReservesBalance();
    const total_stake_minus_treasury = total_stake_current -| ledger.getTreasuryBalance();
    const total_active_stake = go.total_stake;

    const variants = [_]struct {
        name: []const u8,
        total_stake: Coin,
        total_blocks_for_perf: u64,
    }{
        .{ .name = "current", .total_stake = total_stake_current, .total_blocks_for_perf = total_prev_blocks },
        .{ .name = "minus_treasury", .total_stake = total_stake_minus_treasury, .total_blocks_for_perf = total_prev_blocks },
        .{ .name = "active_total", .total_stake = total_active_stake, .total_blocks_for_perf = total_prev_blocks },
        .{ .name = "expected_blocks_perf", .total_stake = total_stake_current, .total_blocks_for_perf = blocks_total },
    };

    std.debug.print(
        "epoch calc: prev_blocks={} total_prev_blocks={} blocks_total={} pool_rewards={}\n",
        .{ prev_blocks, total_prev_blocks, blocks_total, epoch_rewards.pool_rewards },
    );
    for (variants) |variant| {
        const pool_reward = rewards_mod.calculatePoolReward(
            go_pool.active_stake,
            variant.total_stake,
            total_active_stake,
            epoch_rewards.pool_rewards,
            go_pool.pledge,
            params,
            prev_blocks,
            variant.total_blocks_for_perf,
        );
        const leader_reward = rewards_mod.calculatePoolLeaderReward(
            pool_reward,
            go_pool.cost,
            go_pool.margin,
            go_pool.self_delegated_owner_stake,
            go_pool.active_stake,
        );
        const member_reward = rewards_mod.calculatePoolMemberReward(
            pool_reward,
            go_pool.cost,
            go_pool.margin,
            go_deleg.active_stake,
            go_pool.active_stake,
        );
        std.debug.print(
            "{s}: pool_reward={} leader_reward={} member_reward={}\n",
            .{ variant.name, pool_reward, leader_reward, member_reward },
        );
    }
}
