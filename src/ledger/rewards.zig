const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const stake_mod = @import("stake.zig");

pub const KeyHash = types.KeyHash;
pub const Coin = types.Coin;
pub const EpochNo = types.EpochNo;
pub const Credential = types.Credential;
pub const UnitInterval = types.UnitInterval;

/// Protocol parameters relevant to reward calculation.
pub const RewardParams = struct {
    rho: UnitInterval, // monetary expansion rate
    tau: UnitInterval, // treasury growth rate
    a0: UnitInterval, // pool influence factor (pledge)
    n_opt: u16, // target number of pools
    total_lovelace: Coin, // max lovelace supply (45 billion ADA)

    pub const mainnet_defaults = RewardParams{
        .rho = .{ .numerator = 3, .denominator = 1000 }, // 0.003
        .tau = .{ .numerator = 2, .denominator = 10 }, // 0.20
        .a0 = .{ .numerator = 3, .denominator = 10 }, // 0.30
        .n_opt = 500,
        .total_lovelace = 45_000_000_000_000_000,
    };
};

/// Reward pot calculation for an epoch.
pub const EpochRewards = struct {
    total_rewards: Coin, // monetary expansion + fees
    treasury_cut: Coin, // tau * total_rewards
    pool_rewards: Coin, // total_rewards - treasury_cut
    fees_collected: Coin, // transaction fees from this epoch
};

/// Calculate the epoch reward pot.
/// rewards = rho * reserve + fees
/// treasury = tau * rewards
/// pool_pot = rewards - treasury
pub fn calculateEpochRewards(
    reserve: Coin,
    fees: Coin,
    params: RewardParams,
) EpochRewards {
    // Monetary expansion: rho * reserve
    const expansion = @as(Coin, @intCast(
        (@as(u128, reserve) * params.rho.numerator) / params.rho.denominator,
    ));

    const total = expansion + fees;

    // Treasury cut
    const treasury = @as(Coin, @intCast(
        (@as(u128, total) * params.tau.numerator) / params.tau.denominator,
    ));

    return .{
        .total_rewards = total,
        .treasury_cut = treasury,
        .pool_rewards = total - treasury,
        .fees_collected = fees,
    };
}

/// Calculate reward for a single pool.
/// Uses a simplified version of the Shelley reward formula.
pub fn calculatePoolReward(
    pool_stake: Coin,
    total_active_stake: Coin,
    pool_rewards_pot: Coin,
    pool_cost: Coin,
    pool_margin: UnitInterval,
    blocks_produced: u64,
    expected_blocks: u64,
) Coin {
    if (total_active_stake == 0 or expected_blocks == 0) return 0;

    // Performance: blocks_produced / expected_blocks
    // Cap at 1.0 to avoid over-rewarding
    const performance = @min(
        (@as(u128, blocks_produced) * 1_000_000) / expected_blocks,
        1_000_000,
    );

    // Proportional share: pool_stake / total_active_stake
    const share = (@as(u128, pool_stake) * 1_000_000) / total_active_stake;

    // Raw pool reward: pool_rewards_pot * share * performance
    const raw_reward = @as(Coin, @intCast(
        (@as(u128, pool_rewards_pot) * share * performance) / (1_000_000 * 1_000_000),
    ));

    if (raw_reward <= pool_cost) return 0;
    const net_reward = raw_reward - pool_cost;

    // Leader reward: pool_cost + margin * net_reward
    const margin_cut = @as(Coin, @intCast(
        (@as(u128, net_reward) * pool_margin.numerator) / pool_margin.denominator,
    ));

    _ = margin_cut; // leader gets cost + margin_cut
    // member rewards = net_reward - margin_cut (distributed proportionally)

    return raw_reward;
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "rewards: epoch reward calculation" {
    const params = RewardParams.mainnet_defaults;

    // Reserve: 14 billion ADA (in lovelace)
    const reserve: Coin = 14_000_000_000_000_000;
    const fees: Coin = 50_000_000_000; // 50,000 ADA in fees

    const result = calculateEpochRewards(reserve, fees, params);

    // Expansion: 0.003 * 14B ADA = 42M ADA
    try std.testing.expect(result.total_rewards > 0);
    try std.testing.expect(result.treasury_cut > 0);
    try std.testing.expect(result.pool_rewards > 0);
    try std.testing.expect(result.pool_rewards < result.total_rewards);

    // Treasury should be ~20% of total
    const treasury_pct = (@as(u128, result.treasury_cut) * 100) / result.total_rewards;
    try std.testing.expect(treasury_pct >= 19 and treasury_pct <= 21);
}

test "rewards: zero reserve produces only fee rewards" {
    const params = RewardParams.mainnet_defaults;
    const fees: Coin = 10_000_000; // 10 ADA

    const result = calculateEpochRewards(0, fees, params);

    try std.testing.expectEqual(fees, result.total_rewards);
    try std.testing.expect(result.treasury_cut > 0);
}

test "rewards: pool reward calculation" {
    const pool_reward = calculatePoolReward(
        10_000_000_000_000, // 10M ADA stake
        200_000_000_000_000, // 200M ADA total
        42_000_000_000_000, // 42M ADA reward pot
        340_000_000, // 340 ADA cost
        .{ .numerator = 5, .denominator = 100 }, // 5% margin
        100, // blocks produced
        100, // expected blocks (100% performance)
    );

    // Should get approximately 5% of reward pot (10M/200M = 5%)
    try std.testing.expect(pool_reward > 0);
}

test "rewards: mainnet default parameters" {
    const p = RewardParams.mainnet_defaults;
    try std.testing.expectEqual(@as(u16, 500), p.n_opt);
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), p.rho.toFloat(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), p.tau.toFloat(), 1e-6);
}
