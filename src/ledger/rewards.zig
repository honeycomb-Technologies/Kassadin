const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const stake_mod = @import("stake.zig");
const RationalInt = u512;
const WideInt = u1024;

pub const KeyHash = types.KeyHash;
pub const Coin = types.Coin;
pub const DeltaCoin = types.DeltaCoin;
pub const EpochNo = types.EpochNo;
pub const Credential = types.Credential;
pub const UnitInterval = types.UnitInterval;

/// Protocol parameters relevant to reward calculation.
pub const RewardParams = struct {
    rho: UnitInterval, // monetary expansion rate
    tau: UnitInterval, // treasury growth rate
    a0: UnitInterval, // pool influence factor (pledge)
    active_slot_coeff: UnitInterval, // active slot coefficient (d)
    n_opt: u16, // target number of pools
    total_lovelace: Coin, // max lovelace supply (45 billion ADA)

    pub const mainnet_defaults = RewardParams{
        .rho = .{ .numerator = 3, .denominator = 1000 }, // 0.003
        .tau = .{ .numerator = 2, .denominator = 10 }, // 0.20
        .a0 = .{ .numerator = 3, .denominator = 10 }, // 0.30
        .active_slot_coeff = .{ .numerator = 1, .denominator = 20 }, // 0.05
        .n_opt = 500,
        .total_lovelace = 45_000_000_000_000_000,
    };
};

/// Reward pot calculation for an epoch.
pub const EpochRewards = struct {
    expansion: Coin, // eta * rho * reserves
    total_rewards: Coin, // monetary expansion + fees
    treasury_cut: Coin, // tau * total_rewards
    pool_rewards: Coin, // total_rewards - treasury_cut
    fees_collected: Coin, // transaction fees from this epoch
};

/// Haskell-shaped epoch balance-sheet update.
pub const RewardUpdate = struct {
    deltaT: DeltaCoin,
    deltaR: DeltaCoin,
    deltaF: DeltaCoin,
    distributed_rewards: Coin,

    pub fn isBalanced(self: RewardUpdate) bool {
        const distributed = std.math.cast(DeltaCoin, self.distributed_rewards) orelse return false;
        const total: i128 =
            @as(i128, self.deltaT) +
            @as(i128, self.deltaR) +
            @as(i128, distributed) +
            @as(i128, self.deltaF);
        return total == 0;
    }
};

pub const PoolRewardSplit = struct {
    leader_reward: Coin,
    member_rewards: Coin,
};

const Rational = struct {
    numerator: RationalInt,
    denominator: RationalInt,

    fn init(numerator: u128, denominator: u128) Rational {
        return initWide(numerator, denominator);
    }

    fn initWide(numerator: WideInt, denominator: WideInt) Rational {
        std.debug.assert(denominator != 0);
        if (numerator == 0) {
            return .{ .numerator = 0, .denominator = 1 };
        }
        const divisor = gcdInt(WideInt, numerator, denominator);
        const reduced_numerator = numerator / divisor;
        const reduced_denominator = denominator / divisor;
        std.debug.assert(reduced_numerator <= std.math.maxInt(RationalInt));
        std.debug.assert(reduced_denominator <= std.math.maxInt(RationalInt));
        return .{
            .numerator = @intCast(reduced_numerator),
            .denominator = @intCast(reduced_denominator),
        };
    }

    fn fromUnitInterval(value: UnitInterval) Rational {
        return init(value.numerator, value.denominator);
    }

    fn add(a: Rational, b: Rational) Rational {
        return initWide(
            (@as(WideInt, a.numerator) * @as(WideInt, b.denominator)) + (@as(WideInt, b.numerator) * @as(WideInt, a.denominator)),
            @as(WideInt, a.denominator) * @as(WideInt, b.denominator),
        );
    }

    fn sub(a: Rational, b: Rational) Rational {
        std.debug.assert(compare(a, b) != .lt);
        return initWide(
            (@as(WideInt, a.numerator) * @as(WideInt, b.denominator)) - (@as(WideInt, b.numerator) * @as(WideInt, a.denominator)),
            @as(WideInt, a.denominator) * @as(WideInt, b.denominator),
        );
    }

    fn mul(a: Rational, b: Rational) Rational {
        return initWide(
            @as(WideInt, a.numerator) * @as(WideInt, b.numerator),
            @as(WideInt, a.denominator) * @as(WideInt, b.denominator),
        );
    }

    fn div(a: Rational, b: Rational) Rational {
        std.debug.assert(b.numerator != 0);
        return initWide(
            @as(WideInt, a.numerator) * @as(WideInt, b.denominator),
            @as(WideInt, a.denominator) * @as(WideInt, b.numerator),
        );
    }

    fn min(a: Rational, b: Rational) Rational {
        return switch (compare(a, b)) {
            .lt, .eq => a,
            .gt => b,
        };
    }

    fn compare(a: Rational, b: Rational) std.math.Order {
        const left = @as(WideInt, a.numerator) * @as(WideInt, b.denominator);
        const right = @as(WideInt, b.numerator) * @as(WideInt, a.denominator);
        if (left < right) return .lt;
        if (left > right) return .gt;
        return .eq;
    }
};

fn gcdInt(comptime T: type, a: T, b: T) T {
    var x = a;
    var y = b;
    while (y != 0) {
        const rem = x % y;
        x = y;
        y = rem;
    }
    return x;
}

fn floorRationalProduct(
    amount: Coin,
    numerator: RationalInt,
    denominator: RationalInt,
) Coin {
    if (amount == 0 or numerator == 0 or denominator == 0) return 0;
    const result = (@as(WideInt, amount) * @as(WideInt, numerator)) / @as(WideInt, denominator);
    std.debug.assert(result <= std.math.maxInt(Coin));
    return @intCast(result);
}

pub fn calculateExpectedBlocks(
    slots_per_epoch: u64,
    active_slot_coeff: UnitInterval,
) u64 {
    return @intCast((@as(u128, slots_per_epoch) * active_slot_coeff.numerator) / active_slot_coeff.denominator);
}

fn calculateEta(
    active_slot_coeff: UnitInterval,
    blocks_made: u64,
    blocks_total: u64,
) Rational {
    const d = Rational.fromUnitInterval(active_slot_coeff);
    const threshold = Rational.init(4, 5);
    if (Rational.compare(d, threshold) != .lt) {
        return Rational.init(1, 1);
    }
    if (blocks_made == 0 or blocks_total == 0) {
        return Rational.init(0, 1);
    }
    return Rational.init(@min(blocks_made, blocks_total), blocks_total);
}

fn coinToDeltaCoin(value: Coin) !DeltaCoin {
    return std.math.cast(DeltaCoin, value) orelse error.InvalidRewardAccounting;
}

fn calculateApparentPerformance(
    active_slot_coeff: UnitInterval,
    pool_active_stake: Coin,
    total_active_stake: Coin,
    blocks_produced: u64,
    total_blocks_produced: u64,
) Rational {
    if (pool_active_stake == 0 or total_active_stake == 0 or blocks_produced == 0) {
        return Rational.init(0, 1);
    }

    const sigma_a = Rational.init(pool_active_stake, total_active_stake);
    const d = Rational.fromUnitInterval(active_slot_coeff);
    const threshold = Rational.init(4, 5);
    if (Rational.compare(d, threshold) != .lt) {
        return Rational.init(1, 1);
    }

    // Haskell's β is the fraction of all blocks actually produced in the epoch,
    // not the expected non-overlay slot count.
    const beta = Rational.init(blocks_produced, @max(total_blocks_produced, 1));
    return Rational.div(beta, sigma_a);
}

/// Calculate the epoch reward pot.
/// rewards = rho * reserve + fees
/// treasury = tau * rewards
/// pool_pot = rewards - treasury
pub fn calculateEpochRewards(
    reserve: Coin,
    fees: Coin,
    params: RewardParams,
    blocks_made: u64,
    blocks_total: u64,
) EpochRewards {
    const eta = calculateEta(params.active_slot_coeff, blocks_made, blocks_total);
    const expansion_factor = Rational.mul(eta, Rational.fromUnitInterval(params.rho));
    const expansion = floorRationalProduct(
        reserve,
        expansion_factor.numerator,
        expansion_factor.denominator,
    );

    const total = expansion + fees;

    // Treasury cut
    const treasury = @as(Coin, @intCast(
        (@as(u128, total) * params.tau.numerator) / params.tau.denominator,
    ));

    return .{
        .expansion = expansion,
        .total_rewards = total,
        .treasury_cut = treasury,
        .pool_rewards = total - treasury,
        .fees_collected = fees,
    };
}

pub fn calculateRewardUpdate(
    epoch_rewards: EpochRewards,
    distributed_rewards: Coin,
) !RewardUpdate {
    if (distributed_rewards > epoch_rewards.pool_rewards) {
        return error.InvalidRewardAccounting;
    }

    const delta_r1 = try coinToDeltaCoin(epoch_rewards.expansion);
    const delta_r2 = try coinToDeltaCoin(epoch_rewards.pool_rewards - distributed_rewards);

    return .{
        .deltaT = try coinToDeltaCoin(epoch_rewards.treasury_cut),
        .deltaR = -delta_r1 + delta_r2,
        .deltaF = -(try coinToDeltaCoin(epoch_rewards.fees_collected)),
        .distributed_rewards = distributed_rewards,
    };
}

/// Calculate reward for a single pool.
/// Uses Shelley `maxPool'` with apparent performance derived from `BlocksMade`.
pub fn calculatePoolReward(
    pool_stake: Coin,
    total_stake: Coin,
    total_active_stake: Coin,
    pool_rewards_pot: Coin,
    pool_pledge: Coin,
    params: RewardParams,
    blocks_produced: u64,
    total_blocks_produced: u64,
) Coin {
    if (pool_rewards_pot == 0 or total_stake == 0 or total_active_stake == 0 or params.n_opt == 0 or blocks_produced == 0) {
        return 0;
    }

    const sigma = Rational.init(pool_stake, total_stake);
    const pledge_ratio = Rational.init(pool_pledge, total_stake);
    const z0 = Rational.init(1, params.n_opt);
    const sigma_prime = Rational.min(sigma, z0);
    const pledge_prime = Rational.min(pledge_ratio, z0);
    const a0 = Rational.fromUnitInterval(params.a0);
    const one = Rational.init(1, 1);

    const factor1 = Rational.div(one, Rational.add(one, a0));
    const factor4 = Rational.div(Rational.sub(z0, sigma_prime), z0);
    const factor3 = Rational.div(
        Rational.sub(sigma_prime, Rational.mul(pledge_prime, factor4)),
        z0,
    );
    const factor2 = Rational.add(
        sigma_prime,
        Rational.mul(Rational.mul(pledge_prime, a0), factor3),
    );

    const max_pool_reward = floorRationalProduct(
        pool_rewards_pot,
        Rational.mul(factor1, factor2).numerator,
        Rational.mul(factor1, factor2).denominator,
    );

    const app_perf = calculateApparentPerformance(
        params.active_slot_coeff,
        pool_stake,
        total_active_stake,
        blocks_produced,
        total_blocks_produced,
    );
    return floorRationalProduct(max_pool_reward, app_perf.numerator, app_perf.denominator);
}

pub fn splitPoolReward(
    raw_reward: Coin,
    pool_cost: Coin,
    pool_margin: UnitInterval,
) PoolRewardSplit {
    if (raw_reward == 0) {
        return .{ .leader_reward = 0, .member_rewards = 0 };
    }
    if (raw_reward <= pool_cost) {
        return .{ .leader_reward = raw_reward, .member_rewards = 0 };
    }

    const net_reward = raw_reward - pool_cost;
    const margin_cut = @as(Coin, @intCast(
        (@as(u128, net_reward) * pool_margin.numerator) / pool_margin.denominator,
    ));
    const leader_reward = pool_cost + margin_cut;

    return .{
        .leader_reward = leader_reward,
        .member_rewards = raw_reward - leader_reward,
    };
}

pub fn calculatePoolLeaderReward(
    raw_reward: Coin,
    pool_cost: Coin,
    pool_margin: UnitInterval,
    owner_stake: Coin,
    pool_stake: Coin,
) Coin {
    if (raw_reward == 0) return 0;
    if (raw_reward <= pool_cost or pool_stake == 0) return raw_reward;

    const net_reward = raw_reward - pool_cost;
    const margin_den = @as(u128, pool_margin.denominator);
    const factor_num = (@as(u128, pool_margin.numerator) * @as(u128, pool_stake)) +
        ((margin_den - @as(u128, pool_margin.numerator)) * @as(u128, owner_stake));
    const factor_den = margin_den * @as(u128, pool_stake);

    return pool_cost + floorRationalProduct(net_reward, factor_num, factor_den);
}

pub fn calculatePoolMemberReward(
    raw_reward: Coin,
    pool_cost: Coin,
    pool_margin: UnitInterval,
    member_stake: Coin,
    pool_stake: Coin,
) Coin {
    if (raw_reward == 0 or raw_reward <= pool_cost or pool_stake == 0 or member_stake == 0) return 0;

    const net_reward = raw_reward - pool_cost;
    const factor_num = (@as(u128, pool_margin.denominator) - @as(u128, pool_margin.numerator)) * @as(u128, member_stake);
    const factor_den = @as(u128, pool_margin.denominator) * @as(u128, pool_stake);
    return floorRationalProduct(net_reward, factor_num, factor_den);
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "rewards: epoch reward calculation" {
    const params = RewardParams.mainnet_defaults;
    const blocks_total = calculateExpectedBlocks(432_000, params.active_slot_coeff);

    // Reserve: 14 billion ADA (in lovelace)
    const reserve: Coin = 14_000_000_000_000_000;
    const fees: Coin = 50_000_000_000; // 50,000 ADA in fees

    const result = calculateEpochRewards(reserve, fees, params, blocks_total, blocks_total);

    // Expansion: 0.003 * 14B ADA = 42M ADA
    try std.testing.expect(result.expansion > 0);
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

    const result = calculateEpochRewards(
        0,
        fees,
        params,
        0,
        calculateExpectedBlocks(432_000, params.active_slot_coeff),
    );

    try std.testing.expectEqual(fees, result.total_rewards);
    try std.testing.expect(result.treasury_cut > 0);
}

test "rewards: no blocks means no reserve expansion when d < 0.8" {
    const params = RewardParams.mainnet_defaults;
    const result = calculateEpochRewards(
        14_000_000_000_000_000,
        10_000_000,
        params,
        0,
        calculateExpectedBlocks(432_000, params.active_slot_coeff),
    );

    try std.testing.expectEqual(@as(Coin, 0), result.expansion);
    try std.testing.expectEqual(@as(Coin, 10_000_000), result.total_rewards);
}

test "rewards: reward update preserves balance sheet" {
    const params = RewardParams.mainnet_defaults;
    const blocks_total = calculateExpectedBlocks(432_000, params.active_slot_coeff);
    const epoch_rewards = calculateEpochRewards(
        14_000_000_000_000_000,
        50_000_000_000,
        params,
        blocks_total,
        blocks_total,
    );

    const update = try calculateRewardUpdate(epoch_rewards, epoch_rewards.pool_rewards - 123_456);

    try std.testing.expect(update.isBalanced());
    try std.testing.expectEqual(-@as(DeltaCoin, @intCast(epoch_rewards.fees_collected)), update.deltaF);
}

test "rewards: rational compare handles large cross products" {
    const large_denominator: u128 = (@as(u128, 1) << 80) + 7;
    const larger = Rational.init(large_denominator - 1, large_denominator);
    const smaller = Rational.init(large_denominator - 2, large_denominator);

    try std.testing.expectEqual(std.math.Order.gt, Rational.compare(larger, smaller));

    const diff = Rational.sub(larger, smaller);
    try std.testing.expectEqual(@as(RationalInt, 1), diff.numerator);
    try std.testing.expectEqual(@as(RationalInt, large_denominator), diff.denominator);
}

test "rewards: undistributed fee pot returns to reserves" {
    const params = RewardParams.mainnet_defaults;
    const epoch_rewards = calculateEpochRewards(
        0,
        10_000_000,
        params,
        0,
        calculateExpectedBlocks(432_000, params.active_slot_coeff),
    );
    const update = try calculateRewardUpdate(epoch_rewards, 0);

    try std.testing.expect(update.isBalanced());
    try std.testing.expectEqual(@as(DeltaCoin, 2_000_000), update.deltaT);
    try std.testing.expectEqual(@as(DeltaCoin, 8_000_000), update.deltaR);
    try std.testing.expectEqual(@as(DeltaCoin, -10_000_000), update.deltaF);
}

test "rewards: pool reward calculation" {
    const pool_reward = calculatePoolReward(
        10_000_000_000_000, // 10M ADA stake
        31_000_000_000_000_000, // circulating stake
        200_000_000_000_000, // 200M ADA total
        42_000_000_000_000, // 42M ADA reward pot
        5_000_000_000_000, // 5M ADA pledge
        RewardParams.mainnet_defaults,
        2, // blocks produced
        2, // expected blocks
    );

    try std.testing.expect(pool_reward > 0);
}

test "rewards: pool reward handles large realistic stake ratios" {
    const reward = calculatePoolReward(
        30_000_000_000_000,
        31_824_132_237_660_190,
        548_348_261_056_515,
        23_582_964_964_583,
        20_000_000_000_000,
        RewardParams.mainnet_defaults,
        35,
        21_600,
    );

    try std.testing.expect(reward > 0);
}

test "rewards: higher pledge increases pool reward" {
    const lower_pledge = calculatePoolReward(
        10_000_000_000_000,
        31_000_000_000_000_000,
        200_000_000_000_000,
        42_000_000_000_000,
        100_000_000_000,
        RewardParams.mainnet_defaults,
        2,
        2,
    );
    const higher_pledge = calculatePoolReward(
        10_000_000_000_000,
        31_000_000_000_000_000,
        200_000_000_000_000,
        42_000_000_000_000,
        300_000_000_000,
        RewardParams.mainnet_defaults,
        2,
        2,
    );

    try std.testing.expect(higher_pledge > lower_pledge);
}

test "rewards: better performance increases pool reward" {
    const underperforming = calculatePoolReward(
        10_000_000_000_000,
        31_000_000_000_000_000,
        200_000_000_000_000,
        42_000_000_000_000,
        300_000_000_000,
        RewardParams.mainnet_defaults,
        1,
        2,
    );
    const at_target = calculatePoolReward(
        10_000_000_000_000,
        31_000_000_000_000_000,
        200_000_000_000_000,
        42_000_000_000_000,
        300_000_000_000,
        RewardParams.mainnet_defaults,
        2,
        2,
    );

    try std.testing.expect(at_target > underperforming);
}

test "rewards: sparser produced epochs increase apparent performance" {
    const dense_epoch = calculatePoolReward(
        10_000_000_000_000,
        31_000_000_000_000_000,
        200_000_000_000_000,
        42_000_000_000_000,
        300_000_000_000,
        RewardParams.mainnet_defaults,
        100,
        21_600,
    );
    const sparse_epoch = calculatePoolReward(
        10_000_000_000_000,
        31_000_000_000_000_000,
        200_000_000_000_000,
        42_000_000_000_000,
        300_000_000_000,
        RewardParams.mainnet_defaults,
        100,
        16_100,
    );

    try std.testing.expect(sparse_epoch > dense_epoch);
}

test "rewards: split pool reward into leader and member shares" {
    const split = splitPoolReward(
        1_000_000_000,
        340_000_000,
        .{ .numerator = 5, .denominator = 100 },
    );

    try std.testing.expectEqual(@as(Coin, 373_000_000), split.leader_reward);
    try std.testing.expectEqual(@as(Coin, 627_000_000), split.member_rewards);
}

test "rewards: owner stake increases leader reward" {
    const without_owner = calculatePoolLeaderReward(
        1_000_000_000,
        340_000_000,
        .{ .numerator = 5, .denominator = 100 },
        0,
        1_000_000_000,
    );
    const with_owner = calculatePoolLeaderReward(
        1_000_000_000,
        340_000_000,
        .{ .numerator = 5, .denominator = 100 },
        400_000_000,
        1_000_000_000,
    );

    try std.testing.expect(with_owner > without_owner);
}

test "rewards: member reward excludes operator share" {
    const member_reward = calculatePoolMemberReward(
        1_000_000_000,
        340_000_000,
        .{ .numerator = 5, .denominator = 100 },
        200_000_000,
        1_000_000_000,
    );

    try std.testing.expect(member_reward > 0);
    try std.testing.expect(member_reward < 200_000_000);
}

test "rewards: mainnet default parameters" {
    const p = RewardParams.mainnet_defaults;
    try std.testing.expectEqual(@as(u16, 500), p.n_opt);
    try std.testing.expectApproxEqAbs(@as(f64, 0.003), p.rho.toFloat(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), p.tau.toFloat(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), p.active_slot_coeff.toFloat(), 1e-6);
}
