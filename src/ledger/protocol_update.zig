const std = @import("std");
const Allocator = std.mem.Allocator;
const Decoder = @import("../cbor/decoder.zig").Decoder;
const rewards_mod = @import("rewards.zig");
const rules = @import("rules.zig");
const types = @import("../types.zig");

pub const EpochNo = types.EpochNo;
pub const Hash28 = types.Hash28;

pub const SupportedProtocolParamUpdate = struct {
    min_fee_a: ?u64 = null,
    min_fee_b: ?u64 = null,
    min_utxo_value: ?u64 = null,
    max_tx_size: ?u32 = null,
    key_deposit: ?u64 = null,
    pool_deposit: ?u64 = null,
    max_block_body_size: ?u32 = null,
};

pub const UpdateVote = struct {
    proposer: Hash28,
    raw_update: []const u8,
    update: SupportedProtocolParamUpdate,
};

pub const TxProtocolUpdate = struct {
    target_epoch: EpochNo,
    votes: []const UpdateVote,

    pub fn deinit(self: *TxProtocolUpdate, allocator: Allocator) void {
        allocator.free(self.votes);
    }
};

pub const OwnedVote = struct {
    proposer: Hash28,
    raw_update: []u8,
    update: SupportedProtocolParamUpdate,
};

pub const GovernanceConfig = struct {
    epoch_length: u64,
    stability_window: u64,
    update_quorum: u64,
    reward_params: rewards_mod.RewardParams,
    genesis_delegate_hashes: []Hash28,

    pub fn deinit(self: *GovernanceConfig, allocator: Allocator) void {
        allocator.free(self.genesis_delegate_hashes);
    }
};

pub const GovernanceSnapshot = struct {
    current_epoch: EpochNo,
    active_params: rules.ProtocolParams,
    current_proposals: []OwnedVote,
    future_proposals: []OwnedVote,
    future_params: ?rules.ProtocolParams,

    pub fn deinit(self: *GovernanceSnapshot, allocator: Allocator) void {
        freeOwnedVotes(allocator, self.current_proposals);
        freeOwnedVotes(allocator, self.future_proposals);
    }
};

pub const GovernanceState = struct {
    current_epoch: EpochNo = 0,
    current_proposals: std.ArrayList(OwnedVote) = .empty,
    future_proposals: std.ArrayList(OwnedVote) = .empty,
    future_params: ?rules.ProtocolParams = null,

    pub fn deinit(self: *GovernanceState, allocator: Allocator) void {
        freeOwnedVoteList(allocator, &self.current_proposals);
        freeOwnedVoteList(allocator, &self.future_proposals);
    }

    pub fn setCurrentEpoch(self: *GovernanceState, epoch: EpochNo) void {
        self.current_epoch = epoch;
    }

    pub fn cloneSnapshot(
        self: *const GovernanceState,
        allocator: Allocator,
        active_params: rules.ProtocolParams,
    ) !GovernanceSnapshot {
        return .{
            .current_epoch = self.current_epoch,
            .active_params = active_params,
            .current_proposals = try cloneOwnedVotes(allocator, self.current_proposals.items),
            .future_proposals = try cloneOwnedVotes(allocator, self.future_proposals.items),
            .future_params = self.future_params,
        };
    }

    pub fn restoreSnapshot(
        self: *GovernanceState,
        allocator: Allocator,
        snapshot: *const GovernanceSnapshot,
    ) !void {
        freeOwnedVoteList(allocator, &self.current_proposals);
        freeOwnedVoteList(allocator, &self.future_proposals);

        self.current_epoch = snapshot.current_epoch;
        self.current_proposals = .empty;
        self.future_proposals = .empty;

        try cloneVotesIntoList(allocator, &self.current_proposals, snapshot.current_proposals);
        try cloneVotesIntoList(allocator, &self.future_proposals, snapshot.future_proposals);
        self.future_params = snapshot.future_params;
    }
};

pub const GovernanceError = error{
    NonGenesisUpdate,
    WrongEpoch,
};

pub fn parseTxUpdate(allocator: Allocator, data: []const u8) !TxProtocolUpdate {
    var dec = Decoder.init(data);
    const arr_len = (try dec.decodeArrayLen()) orelse return error.InvalidCbor;
    if (arr_len != 2) return error.InvalidCbor;

    var votes: std.ArrayList(UpdateVote) = .empty;
    defer votes.deinit(allocator);

    const map_len = try dec.decodeMapLen();
    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            try appendVote(allocator, &votes, &dec);
        }
    } else {
        while (!dec.isBreak()) {
            try appendVote(allocator, &votes, &dec);
        }
        try dec.decodeBreak();
    }

    return .{
        .target_epoch = try dec.decodeUint(),
        .votes = try votes.toOwnedSlice(allocator),
    };
}

pub fn cloneBorrowedTxUpdate(
    allocator: Allocator,
    tx_update: *const TxProtocolUpdate,
) !TxProtocolUpdate {
    return .{
        .target_epoch = tx_update.target_epoch,
        .votes = try allocator.dupe(UpdateVote, tx_update.votes),
    };
}

pub fn freeTxUpdates(allocator: Allocator, updates: []TxProtocolUpdate) void {
    for (updates) |*update| {
        update.deinit(allocator);
    }
    allocator.free(updates);
}

pub fn applySupportedUpdate(
    base: rules.ProtocolParams,
    update: SupportedProtocolParamUpdate,
) rules.ProtocolParams {
    var next = base;
    if (update.min_fee_a) |value| next.min_fee_a = value;
    if (update.min_fee_b) |value| next.min_fee_b = value;
    if (update.min_utxo_value) |value| next.min_utxo_value = value;
    if (update.max_tx_size) |value| next.max_tx_size = value;
    if (update.key_deposit) |value| next.key_deposit = value;
    if (update.pool_deposit) |value| next.pool_deposit = value;
    if (update.max_block_body_size) |value| next.max_block_body_size = value;
    return next;
}

pub fn stageTxUpdate(
    allocator: Allocator,
    config: *const GovernanceConfig,
    state: *GovernanceState,
    active_params: rules.ProtocolParams,
    slot: u64,
    tx_update: *const TxProtocolUpdate,
) !void {
    const current_epoch = types.slotToEpoch(slot, config.epoch_length);
    const point_of_no_return = epochBoundaryPointOfNoReturn(config, current_epoch);
    const target_epoch = if (slot < point_of_no_return) current_epoch else current_epoch + 1;
    if (tx_update.target_epoch != target_epoch) return error.WrongEpoch;

    const proposals = if (slot < point_of_no_return) &state.current_proposals else &state.future_proposals;
    for (tx_update.votes) |vote| {
        if (!isGenesisDelegate(config, vote.proposer)) return error.NonGenesisUpdate;
        try putOwnedVote(allocator, proposals, vote);
    }

    if (slot < point_of_no_return) {
        state.future_params = votedFutureParams(active_params, state.current_proposals.items, config.update_quorum);
    }
}

pub fn advanceToSlot(
    allocator: Allocator,
    config: *const GovernanceConfig,
    state: *GovernanceState,
    active_params: *rules.ProtocolParams,
    slot: u64,
) !void {
    const block_epoch = types.slotToEpoch(slot, config.epoch_length);
    while (state.current_epoch < block_epoch) {
        if (state.future_params) |next| {
            active_params.* = next;
        }

        freeOwnedVoteList(allocator, &state.current_proposals);
        state.current_proposals = .empty;
        try cloneVotesIntoList(allocator, &state.current_proposals, state.future_proposals.items);

        freeOwnedVoteList(allocator, &state.future_proposals);
        state.future_proposals = .empty;

        state.current_epoch += 1;
        state.future_params = votedFutureParams(active_params.*, state.current_proposals.items, config.update_quorum);
    }
}

pub fn setCurrentEpochFromSlot(
    config: *const GovernanceConfig,
    state: *GovernanceState,
    slot: u64,
) void {
    state.current_epoch = types.slotToEpoch(slot, config.epoch_length);
}

pub fn loadOwnedVotesForTesting(
    allocator: Allocator,
    votes: []const UpdateVote,
) ![]OwnedVote {
    return cloneBorrowedVotes(allocator, votes);
}

fn appendVote(
    allocator: Allocator,
    votes: *std.ArrayList(UpdateVote),
    dec: *Decoder,
) !void {
    const proposer_bytes = try dec.decodeBytes();
    if (proposer_bytes.len != 28) return error.InvalidCbor;

    var proposer: Hash28 = undefined;
    @memcpy(&proposer, proposer_bytes);

    const raw_update = try dec.sliceOfNextValue();
    try votes.append(allocator, .{
        .proposer = proposer,
        .raw_update = raw_update,
        .update = try parseSupportedUpdate(raw_update),
    });
}

fn parseSupportedUpdate(data: []const u8) !SupportedProtocolParamUpdate {
    var dec = Decoder.init(data);
    const map_len = try dec.decodeMapLen();
    var update = SupportedProtocolParamUpdate{};

    if (map_len) |count| {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            try decodeUpdateField(&dec, &update);
        }
    } else {
        while (!dec.isBreak()) {
            try decodeUpdateField(&dec, &update);
        }
        try dec.decodeBreak();
    }

    return update;
}

fn decodeUpdateField(dec: *Decoder, update: *SupportedProtocolParamUpdate) !void {
    const key = try dec.decodeUint();
    switch (key) {
        0 => update.min_fee_a = try dec.decodeUint(),
        1 => update.min_fee_b = try dec.decodeUint(),
        2 => update.max_block_body_size = try decodeUint32(dec),
        3 => update.max_tx_size = try decodeUint32(dec),
        5 => update.key_deposit = try dec.decodeUint(),
        6 => update.pool_deposit = try dec.decodeUint(),
        15 => update.min_utxo_value = try dec.decodeUint(),
        else => try dec.skipValue(),
    }
}

fn decodeUint32(dec: *Decoder) !u32 {
    const value = try dec.decodeUint();
    if (value > std.math.maxInt(u32)) return error.Overflow;
    return @intCast(value);
}

fn epochBoundaryPointOfNoReturn(config: *const GovernanceConfig, epoch: EpochNo) u64 {
    const next_epoch_first_slot = types.epochFirstSlot(epoch + 1, config.epoch_length);
    return next_epoch_first_slot -| (2 * config.stability_window);
}

fn isGenesisDelegate(config: *const GovernanceConfig, proposer: Hash28) bool {
    for (config.genesis_delegate_hashes) |key_hash| {
        if (std.mem.eql(u8, &key_hash, &proposer)) return true;
    }
    return false;
}

fn votedFutureParams(
    base: rules.ProtocolParams,
    proposals: []const OwnedVote,
    quorum: u64,
) ?rules.ProtocolParams {
    if (proposals.len == 0 or quorum == 0) return null;

    var i: usize = 0;
    while (i < proposals.len) : (i += 1) {
        var count: u64 = 1;
        var j: usize = i + 1;
        while (j < proposals.len) : (j += 1) {
            if (std.mem.eql(u8, proposals[i].raw_update, proposals[j].raw_update)) {
                count += 1;
            }
        }

        if (count >= quorum) {
            return applySupportedUpdate(base, proposals[i].update);
        }
    }

    return null;
}

fn putOwnedVote(
    allocator: Allocator,
    proposals: *std.ArrayList(OwnedVote),
    vote: UpdateVote,
) !void {
    for (proposals.items) |*existing| {
        if (std.mem.eql(u8, &existing.proposer, &vote.proposer)) {
            allocator.free(existing.raw_update);
            existing.* = .{
                .proposer = vote.proposer,
                .raw_update = try allocator.dupe(u8, vote.raw_update),
                .update = vote.update,
            };
            return;
        }
    }

    try proposals.append(allocator, .{
        .proposer = vote.proposer,
        .raw_update = try allocator.dupe(u8, vote.raw_update),
        .update = vote.update,
    });
}

fn cloneOwnedVotes(allocator: Allocator, votes: []const OwnedVote) ![]OwnedVote {
    var cloned = try allocator.alloc(OwnedVote, votes.len);
    var cloned_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < cloned_count) : (i += 1) {
            allocator.free(cloned[i].raw_update);
        }
        allocator.free(cloned);
    }
    for (votes, 0..) |vote, i| {
        cloned[i] = .{
            .proposer = vote.proposer,
            .raw_update = try allocator.dupe(u8, vote.raw_update),
            .update = vote.update,
        };
        cloned_count += 1;
    }

    return cloned;
}

fn cloneBorrowedVotes(allocator: Allocator, votes: []const UpdateVote) ![]OwnedVote {
    var cloned = try allocator.alloc(OwnedVote, votes.len);
    var cloned_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < cloned_count) : (i += 1) {
            allocator.free(cloned[i].raw_update);
        }
        allocator.free(cloned);
    }

    for (votes, 0..) |vote, i| {
        cloned[i] = .{
            .proposer = vote.proposer,
            .raw_update = try allocator.dupe(u8, vote.raw_update),
            .update = vote.update,
        };
        cloned_count += 1;
    }

    return cloned;
}

fn cloneVotesIntoList(
    allocator: Allocator,
    list: *std.ArrayList(OwnedVote),
    votes: []const OwnedVote,
) !void {
    try list.ensureTotalCapacity(allocator, votes.len);
    for (votes) |vote| {
        try list.append(allocator, .{
            .proposer = vote.proposer,
            .raw_update = try allocator.dupe(u8, vote.raw_update),
            .update = vote.update,
        });
    }
}

pub fn freeOwnedVotes(allocator: Allocator, votes: []const OwnedVote) void {
    for (votes) |vote| {
        allocator.free(vote.raw_update);
    }
    allocator.free(votes);
}

fn freeOwnedVoteList(allocator: Allocator, votes: *std.ArrayList(OwnedVote)) void {
    for (votes.items) |vote| {
        allocator.free(vote.raw_update);
    }
    votes.deinit(allocator);
}

test "protocol update: parse tx update with supported fields" {
    const allocator = std.testing.allocator;
    const Encoder = @import("../cbor/encoder.zig").Encoder;

    var enc = Encoder.init(allocator);
    defer enc.deinit();

    try enc.encodeArrayLen(2);
    try enc.encodeMapLen(1);
    try enc.encodeBytes(&([_]u8{0x11} ** 28));
    try enc.encodeMapLen(2);
    try enc.encodeUint(0);
    try enc.encodeUint(77);
    try enc.encodeUint(3);
    try enc.encodeUint(16390);
    try enc.encodeUint(9);

    const raw = try enc.toOwnedSlice();
    defer allocator.free(raw);

    var update = try parseTxUpdate(allocator, raw);
    defer update.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 9), update.target_epoch);
    try std.testing.expectEqual(@as(usize, 1), update.votes.len);
    try std.testing.expectEqual(@as(u64, 77), update.votes[0].update.min_fee_a.?);
    try std.testing.expectEqual(@as(u32, 16390), update.votes[0].update.max_tx_size.?);
}

test "protocol update: stage and adopt updates across epoch boundary" {
    const allocator = std.testing.allocator;

    const delegates = try allocator.alloc(Hash28, 2);
    defer allocator.free(delegates);
    delegates[0] = [_]u8{0xaa} ** 28;
    delegates[1] = [_]u8{0xbb} ** 28;

    const config = GovernanceConfig{
        .epoch_length = 100,
        .stability_window = 10,
        .update_quorum = 2,
        .reward_params = rewards_mod.RewardParams.mainnet_defaults,
        .genesis_delegate_hashes = delegates,
    };

    var state = GovernanceState{};
    defer state.deinit(allocator);
    setCurrentEpochFromSlot(&config, &state, 5);

    const borrowed_votes = [_]UpdateVote{
        .{
            .proposer = delegates[0],
            .raw_update = &[_]u8{ 0xa1, 0x00, 0x18, 0x2c },
            .update = .{ .min_fee_a = 44 },
        },
        .{
            .proposer = delegates[1],
            .raw_update = &[_]u8{ 0xa1, 0x00, 0x18, 0x2c },
            .update = .{ .min_fee_a = 44 },
        },
    };
    var tx_update = TxProtocolUpdate{
        .target_epoch = 0,
        .votes = borrowed_votes[0..],
    };

    var active = rules.ProtocolParams.compatibility_defaults;
    try stageTxUpdate(allocator, &config, &state, active, 5, &tx_update);
    try std.testing.expect(state.future_params != null);
    try std.testing.expectEqual(@as(u64, 44), state.future_params.?.min_fee_a);

    try advanceToSlot(allocator, &config, &state, &active, 100);
    try std.testing.expectEqual(@as(u64, 44), active.min_fee_a);
    try std.testing.expectEqual(@as(u64, 1), state.current_epoch);
}

test "protocol update: reject non-genesis proposer" {
    const allocator = std.testing.allocator;

    const delegates = try allocator.alloc(Hash28, 1);
    defer allocator.free(delegates);
    delegates[0] = [_]u8{0xaa} ** 28;

    const config = GovernanceConfig{
        .epoch_length = 100,
        .stability_window = 10,
        .update_quorum = 1,
        .reward_params = rewards_mod.RewardParams.mainnet_defaults,
        .genesis_delegate_hashes = delegates,
    };

    var state = GovernanceState{};
    defer state.deinit(allocator);
    setCurrentEpochFromSlot(&config, &state, 5);

    const borrowed_votes = [_]UpdateVote{
        .{
            .proposer = [_]u8{0xbb} ** 28,
            .raw_update = &[_]u8{ 0xa1, 0x00, 0x18, 0x2c },
            .update = .{ .min_fee_a = 44 },
        },
    };
    var tx_update = TxProtocolUpdate{
        .target_epoch = 0,
        .votes = borrowed_votes[0..],
    };

    try std.testing.expectError(
        error.NonGenesisUpdate,
        stageTxUpdate(allocator, &config, &state, rules.ProtocolParams.compatibility_defaults, 5, &tx_update),
    );
}
