const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");

pub const KeyHash = types.KeyHash;
pub const Coin = types.Coin;
pub const EpochNo = types.EpochNo;
pub const Credential = types.Credential;
pub const RewardAccount = types.RewardAccount;
pub const UnitInterval = types.UnitInterval;
pub const PoolOwnerMembership = types.PoolOwnerMembership;

pub const DelegatedStake = struct {
    credential: Credential,
    pool_id: KeyHash,
    active_stake: Coin,
};

/// Individual pool's stake information.
pub const PoolStake = struct {
    pool_id: KeyHash,
    active_stake: Coin,
    self_delegated_owner_stake: Coin,
    pledge: Coin,
    cost: Coin,
    margin: UnitInterval,
    reward_account: RewardAccount,
    total_stake: Coin, // total active stake across all pools (for relative calc)

    /// Relative stake: pool_stake / total_active_stake
    pub fn relativeStake(self: *const PoolStake) f64 {
        if (self.total_stake == 0) return 0;
        return @as(f64, @floatFromInt(self.active_stake)) / @as(f64, @floatFromInt(self.total_stake));
    }
};

/// Stake distribution snapshot used for leader election.
pub const StakeDistribution = struct {
    allocator: Allocator,
    pools: std.AutoHashMap(KeyHash, PoolStake),
    delegators: std.AutoHashMap(Credential, DelegatedStake),
    owner_memberships: std.AutoHashMap(PoolOwnerMembership, void),
    total_stake: Coin,
    epoch: EpochNo,

    pub fn init(allocator: Allocator, epoch: EpochNo) StakeDistribution {
        return .{
            .allocator = allocator,
            .pools = std.AutoHashMap(KeyHash, PoolStake).init(allocator),
            .delegators = std.AutoHashMap(Credential, DelegatedStake).init(allocator),
            .owner_memberships = std.AutoHashMap(PoolOwnerMembership, void).init(allocator),
            .total_stake = 0,
            .epoch = epoch,
        };
    }

    pub fn deinit(self: *StakeDistribution) void {
        self.pools.deinit();
        self.delegators.deinit();
        self.owner_memberships.deinit();
    }

    /// Register a pool's stake.
    pub fn setPoolStake(
        self: *StakeDistribution,
        pool_id: KeyHash,
        active_stake: Coin,
        self_delegated_owner_stake: Coin,
        pledge: Coin,
        cost: Coin,
        margin: UnitInterval,
        reward_account: RewardAccount,
    ) !void {
        try self.pools.put(pool_id, .{
            .pool_id = pool_id,
            .active_stake = active_stake,
            .self_delegated_owner_stake = self_delegated_owner_stake,
            .pledge = pledge,
            .cost = cost,
            .margin = margin,
            .reward_account = reward_account,
            .total_stake = 0, // updated in finalize
        });
    }

    pub fn setPoolOwnerMembership(
        self: *StakeDistribution,
        pool_id: KeyHash,
        owner: KeyHash,
    ) !void {
        try self.owner_memberships.put(.{
            .pool = pool_id,
            .owner = owner,
        }, {});
    }

    pub fn isPoolOwner(
        self: *const StakeDistribution,
        pool_id: KeyHash,
        owner: KeyHash,
    ) bool {
        return self.owner_memberships.contains(.{
            .pool = pool_id,
            .owner = owner,
        });
    }

    pub fn setDelegatedStake(
        self: *StakeDistribution,
        credential: Credential,
        pool_id: KeyHash,
        active_stake: Coin,
    ) !void {
        try self.delegators.put(credential, .{
            .credential = credential,
            .pool_id = pool_id,
            .active_stake = active_stake,
        });
    }

    /// Finalize the distribution (compute total stake, set relative values).
    pub fn finalize(self: *StakeDistribution) void {
        var total: Coin = 0;
        var it = self.pools.valueIterator();
        while (it.next()) |pool| {
            total += pool.active_stake;
        }
        self.total_stake = total;

        // Update total_stake in each pool entry
        var it2 = self.pools.valueIterator();
        while (it2.next()) |pool| {
            pool.total_stake = total;
        }
    }

    /// Lookup a pool's stake info.
    pub fn getPool(self: *const StakeDistribution, pool_id: KeyHash) ?*const PoolStake {
        return self.pools.getPtr(pool_id);
    }

    pub fn getDelegatedStake(self: *const StakeDistribution, credential: Credential) ?*const DelegatedStake {
        return self.delegators.getPtr(credential);
    }

    /// Number of pools.
    pub fn poolCount(self: *const StakeDistribution) usize {
        return self.pools.count();
    }

    pub fn delegatorCount(self: *const StakeDistribution) usize {
        return self.delegators.count();
    }
};

/// Stake snapshot pipeline: mark → set → go.
/// The stake distribution used for leader election in epoch N comes from 2 epochs prior.
pub const StakeSnapshots = struct {
    allocator: Allocator,
    mark: ?StakeDistribution, // Current epoch's snapshot (being built)
    set: ?StakeDistribution, // Previous epoch's snapshot
    go: ?StakeDistribution, // Two epochs ago (used for leader election)
    current_epoch: EpochNo,

    pub fn init(allocator: Allocator) StakeSnapshots {
        return .{
            .allocator = allocator,
            .mark = null,
            .set = null,
            .go = null,
            .current_epoch = 0,
        };
    }

    pub fn deinit(self: *StakeSnapshots) void {
        if (self.mark) |*m| m.deinit();
        if (self.set) |*s| s.deinit();
        if (self.go) |*g| g.deinit();
    }

    /// Rotate snapshots at epoch boundary.
    /// go = old set, set = old mark, mark = new empty snapshot
    pub fn onEpochBoundary(self: *StakeSnapshots, new_epoch: EpochNo) void {
        // Free the old "go" snapshot
        if (self.go) |*g| g.deinit();

        // Rotate: go ← set ← mark
        self.go = self.set;
        self.set = self.mark;
        self.mark = StakeDistribution.init(self.allocator, new_epoch);
        self.current_epoch = new_epoch;
    }

    /// Get the active stake distribution for leader election (the "go" snapshot).
    pub fn getActiveDistribution(self: *const StakeSnapshots) ?*const StakeDistribution {
        if (self.go) |*g| return g;
        return null;
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "stake: pool relative stake" {
    const pool = PoolStake{
        .pool_id = [_]u8{0x01} ** 28,
        .active_stake = 1_000_000_000, // 1000 ADA
        .self_delegated_owner_stake = 0,
        .pledge = 500_000_000,
        .cost = 340_000_000,
        .margin = .{ .numerator = 0, .denominator = 1 },
        .reward_account = .{
            .network = .testnet,
            .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0x04} ** 28 },
        },
        .total_stake = 20_000_000_000, // 20000 ADA total
    };
    const rel = pool.relativeStake();
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), rel, 1e-10); // 1000/20000 = 0.05
}

test "stake: distribution finalize" {
    const allocator = std.testing.allocator;
    var dist = StakeDistribution.init(allocator, 100);
    defer dist.deinit();

    const reward_account = RewardAccount{
        .network = .testnet,
        .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0x04} ** 28 },
    };
    try dist.setPoolStake([_]u8{0x01} ** 28, 1_000_000, 0, 500_000, 340_000, .{ .numerator = 0, .denominator = 1 }, reward_account);
    try dist.setPoolStake([_]u8{0x02} ** 28, 2_000_000, 0, 1_000_000, 340_000, .{ .numerator = 0, .denominator = 1 }, reward_account);
    try dist.setPoolStake([_]u8{0x03} ** 28, 3_000_000, 0, 1_500_000, 340_000, .{ .numerator = 0, .denominator = 1 }, reward_account);

    dist.finalize();

    try std.testing.expectEqual(@as(Coin, 6_000_000), dist.total_stake);
    try std.testing.expectEqual(@as(usize, 3), dist.poolCount());

    const pool = dist.getPool([_]u8{0x01} ** 28).?;
    try std.testing.expectEqual(@as(Coin, 6_000_000), pool.total_stake);
}

test "stake: snapshot rotation" {
    const allocator = std.testing.allocator;
    var snaps = StakeSnapshots.init(allocator);
    defer snaps.deinit();

    // Initially no active distribution
    try std.testing.expect(snaps.getActiveDistribution() == null);

    // Epoch 0 boundary: mark = new, set = null, go = null
    snaps.onEpochBoundary(0);
    try std.testing.expect(snaps.mark != null);
    try std.testing.expect(snaps.getActiveDistribution() == null);

    // Epoch 1 boundary: go = null, set = old mark, mark = new
    snaps.onEpochBoundary(1);
    try std.testing.expect(snaps.set != null);
    try std.testing.expect(snaps.getActiveDistribution() == null);

    // Epoch 2 boundary: go = old set (epoch 0), set = old mark (epoch 1), mark = new
    snaps.onEpochBoundary(2);
    try std.testing.expect(snaps.getActiveDistribution() != null);
    try std.testing.expectEqual(@as(EpochNo, 0), snaps.go.?.epoch);
}

test "stake: 2-epoch delay" {
    const allocator = std.testing.allocator;
    var snaps = StakeSnapshots.init(allocator);
    defer snaps.deinit();

    // Build up through 3 epoch boundaries
    snaps.onEpochBoundary(0);
    if (snaps.mark) |*m| {
        try m.setPoolStake(
            [_]u8{0xaa} ** 28,
            10_000_000,
            0,
            5_000_000,
            340_000,
            .{ .numerator = 0, .denominator = 1 },
            .{ .network = .testnet, .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0x0a} ** 28 } },
        );
        m.finalize();
    }

    snaps.onEpochBoundary(1);
    if (snaps.mark) |*m| {
        try m.setPoolStake(
            [_]u8{0xbb} ** 28,
            20_000_000,
            0,
            10_000_000,
            340_000,
            .{ .numerator = 0, .denominator = 1 },
            .{ .network = .testnet, .credential = .{ .cred_type = .key_hash, .hash = [_]u8{0x0b} ** 28 } },
        );
        m.finalize();
    }

    snaps.onEpochBoundary(2);

    // The "go" distribution should be the one from epoch 0 (2 epochs ago)
    const active = snaps.getActiveDistribution().?;
    try std.testing.expectEqual(@as(EpochNo, 0), active.epoch);
    try std.testing.expect(active.getPool([_]u8{0xaa} ** 28) != null);
    try std.testing.expect(active.getPool([_]u8{0xbb} ** 28) == null); // was in epoch 1
}
