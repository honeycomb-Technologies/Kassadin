const std = @import("std");
const Allocator = std.mem.Allocator;
const std_json = std.json;
const types = @import("../types.zig");
const praos = @import("../consensus/praos.zig");
const protocol_update = @import("../ledger/protocol_update.zig");
const ledger_rules = @import("../ledger/rules.zig");
const UtxoEntry = @import("../storage/ledger.zig").UtxoEntry;
const byron_genesis_utxo = @import("byron_genesis_utxo.zig");

/// Parsed Shelley genesis configuration.
/// Contains the critical parameters needed for consensus and ledger operation.
pub const ShelleyGenesis = struct {
    active_slots_coeff: f64, // e.g., 0.05
    epoch_length: u64, // e.g., 432000
    security_param: u64, // e.g., 2160
    slot_length: u64, // e.g., 1 (seconds)
    slots_per_kes_period: u64, // e.g., 129600
    max_kes_evolutions: u32, // e.g., 62
    network_magic: u32, // e.g., 764824073
    network_id: []const u8, // "Mainnet" or "Testnet"
    system_start: []const u8, // ISO 8601 timestamp
    max_lovelace_supply: u64, // 45_000_000_000_000_000
    protocol_params: ProtocolParams,

    pub fn deinit(self: *ShelleyGenesis, allocator: Allocator) void {
        allocator.free(self.network_id);
        allocator.free(self.system_start);
    }
};

pub const ProtocolParams = struct {
    min_fee_a: u64, // fee per byte
    min_fee_b: u64, // fixed fee
    max_block_body_size: u32,
    max_tx_size: u32,
    max_block_header_size: u16,
    key_deposit: u64,
    pool_deposit: u64,
    e_max: u32, // max epoch for pool retirement
    n_opt: u16, // target number of pools
    a0: f64, // pool influence
    rho: f64, // monetary expansion
    tau: f64, // treasury growth
    min_pool_cost: u64,
    min_utxo_value: u64,
};

pub const ByronGenesisBalance = struct {
    id: []u8,
    lovelace: u64,

    pub fn deinit(self: *ByronGenesisBalance, allocator: Allocator) void {
        allocator.free(self.id);
    }
};

pub const ByronGenesis = struct {
    protocol_magic: u32,
    security_param: u64,
    start_time: u64,
    avvm_distr: []ByronGenesisBalance,
    non_avvm_balances: []ByronGenesisBalance,
    max_tx_size: u64,
    tx_fee_policy_summand: u64,
    tx_fee_policy_multiplier: u64,

    pub fn deinit(self: *ByronGenesis, allocator: Allocator) void {
        freeByronBalances(allocator, self.avvm_distr);
        freeByronBalances(allocator, self.non_avvm_balances);
    }

    pub fn totalSupply(self: *const ByronGenesis) u64 {
        var total: u64 = 0;

        for (self.avvm_distr) |entry| total += entry.lovelace;
        for (self.non_avvm_balances) |entry| total += entry.lovelace;

        return total;
    }
};

/// Parse a Shelley genesis JSON file.
/// This is a simplified parser that extracts the critical fields.
pub fn parseShelleyGenesis(allocator: Allocator, path: []const u8) !ShelleyGenesis {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024);
    defer allocator.free(content);

    // Simple JSON field extraction (not a full JSON parser)
    return .{
        .active_slots_coeff = extractFloat(content, "activeSlotsCoeff") orelse 0.05,
        .epoch_length = extractUint(content, "epochLength") orelse 432000,
        .security_param = extractUint(content, "securityParam") orelse 2160,
        .slot_length = extractUint(content, "slotLength") orelse 1,
        .slots_per_kes_period = extractUint(content, "slotsPerKESPeriod") orelse 129600,
        .max_kes_evolutions = @intCast(extractUint(content, "maxKESEvolutions") orelse 62),
        .network_magic = @intCast(extractUint(content, "networkMagic") orelse 764824073),
        .network_id = try allocator.dupe(u8, extractString(content, "networkId") orelse "Mainnet"),
        .system_start = try allocator.dupe(u8, extractString(content, "systemStart") orelse "2017-09-23T21:44:51Z"),
        .max_lovelace_supply = extractUint(content, "maxLovelaceSupply") orelse 45_000_000_000_000_000,
        .protocol_params = .{
            .min_fee_a = extractNestedUint(content, "minFeeA") orelse 44,
            .min_fee_b = extractNestedUint(content, "minFeeB") orelse 155381,
            .max_block_body_size = @intCast(extractNestedUint(content, "maxBlockBodySize") orelse 65536),
            .max_tx_size = @intCast(extractNestedUint(content, "maxTxSize") orelse 16384),
            .max_block_header_size = @intCast(extractNestedUint(content, "maxBlockHeaderSize") orelse 1100),
            .key_deposit = extractNestedUint(content, "keyDeposit") orelse 2_000_000,
            .pool_deposit = extractNestedUint(content, "poolDeposit") orelse 500_000_000,
            .e_max = @intCast(extractNestedUint(content, "eMax") orelse 18),
            .n_opt = @intCast(extractNestedUint(content, "nOpt") orelse 500),
            .a0 = extractNestedFloat(content, "a0") orelse 0.3,
            .rho = extractNestedFloat(content, "rho") orelse 0.003,
            .tau = extractNestedFloat(content, "tau") orelse 0.2,
            .min_pool_cost = extractNestedUint(content, "minPoolCost") orelse 340_000_000,
            .min_utxo_value = extractNestedUint(content, "minUTxOValue") orelse 1_000_000,
        },
    };
}

pub fn toLedgerProtocolParams(pp: ProtocolParams) ledger_rules.ProtocolParams {
    return .{
        .min_fee_a = pp.min_fee_a,
        .min_fee_b = pp.min_fee_b,
        .min_utxo_value = pp.min_utxo_value,
        .max_tx_size = pp.max_tx_size,
        .key_deposit = pp.key_deposit,
        .pool_deposit = pp.pool_deposit,
        .max_block_body_size = pp.max_block_body_size,
    };
}

pub fn toLedgerProtocolParamsByron(genesis: ByronGenesis) ledger_rules.ProtocolParams {
    return .{
        .min_fee_a = genesis.tx_fee_policy_multiplier,
        .min_fee_b = genesis.tx_fee_policy_summand,
        .min_utxo_value = 0,
        .max_tx_size = @intCast(@min(genesis.max_tx_size, std.math.maxInt(u32))),
        .key_deposit = 0,
        .pool_deposit = 0,
        .max_block_body_size = @intCast(@min(genesis.max_tx_size, std.math.maxInt(u32))),
    };
}

pub fn loadLedgerProtocolParams(allocator: Allocator, path: []const u8) !ledger_rules.ProtocolParams {
    var genesis = try parseShelleyGenesis(allocator, path);
    defer genesis.deinit(allocator);
    return toLedgerProtocolParams(genesis.protocol_params);
}

pub fn loadShelleyGovernanceConfig(allocator: Allocator, path: []const u8) !protocol_update.GovernanceConfig {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std_json.parseFromSlice(std_json.Value, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const root = valueAsObject(parsed.value);
    const gen_delegs = valueAsObject(root.get("genDelegs") orelse return error.MissingGenesisDelegates);
    const epoch_length = try valueToU64(root.get("epochLength") orelse return error.MissingEpochLength);
    const security_param = try valueToU64(root.get("securityParam") orelse return error.MissingSecurityParam);
    const active_slots_coeff = try valueToF64(root.get("activeSlotsCoeff") orelse return error.MissingActiveSlotsCoeff);
    const update_quorum = try valueToU64(root.get("updateQuorum") orelse return error.MissingUpdateQuorum);

    var delegates = try allocator.alloc(types.Hash28, gen_delegs.count());
    errdefer allocator.free(delegates);

    var iter = gen_delegs.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| : (i += 1) {
        delegates[i] = try decodeHexHash28(entry.key_ptr.*);
    }

    return .{
        .epoch_length = epoch_length,
        .stability_window = computeStabilityWindow(security_param, active_slots_coeff),
        .update_quorum = update_quorum,
        .genesis_delegate_hashes = delegates,
    };
}

pub fn loadByronLedgerProtocolParams(allocator: Allocator, path: []const u8) !ledger_rules.ProtocolParams {
    var genesis = try parseByronGenesis(allocator, path);
    defer genesis.deinit(allocator);
    return toLedgerProtocolParamsByron(genesis);
}

pub fn buildByronGenesisUtxos(allocator: Allocator, genesis: *const ByronGenesis) ![]UtxoEntry {
    var entries: std.ArrayList(UtxoEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.raw_cbor);
        entries.deinit(allocator);
    }

    try entries.ensureTotalCapacity(allocator, genesis.avvm_distr.len + genesis.non_avvm_balances.len);

    for (genesis.avvm_distr) |balance| {
        try entries.append(allocator, try byron_genesis_utxo.buildAvvmUtxoEntry(
            allocator,
            genesis.protocol_magic,
            balance.id,
            balance.lovelace,
        ));
    }
    for (genesis.non_avvm_balances) |balance| {
        try entries.append(allocator, try byron_genesis_utxo.buildNonAvvmUtxoEntry(
            allocator,
            balance.id,
            balance.lovelace,
        ));
    }

    return entries.toOwnedSlice(allocator);
}

pub fn freeGenesisUtxos(allocator: Allocator, utxos: []const UtxoEntry) void {
    for (utxos) |entry| allocator.free(entry.raw_cbor);
    allocator.free(utxos);
}

pub fn parseByronGenesis(allocator: Allocator, path: []const u8) !ByronGenesis {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std_json.parseFromSlice(std_json.Value, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const root = valueAsObject(parsed.value);
    const protocol_consts = valueAsObject(root.get("protocolConsts") orelse return error.MissingProtocolConsts);
    const block_version_data = valueAsObject(root.get("blockVersionData") orelse return error.MissingBlockVersionData);
    const tx_fee_policy = valueAsObject(block_version_data.get("txFeePolicy") orelse return error.MissingTxFeePolicy);

    const avvm_distr = try extractBalanceMap(allocator, root, "avvmDistr");
    errdefer freeByronBalances(allocator, avvm_distr);
    const non_avvm_balances = try extractBalanceMap(allocator, root, "nonAvvmBalances");
    errdefer freeByronBalances(allocator, non_avvm_balances);

    return .{
        .protocol_magic = @intCast(try valueToU64(protocol_consts.get("protocolMagic") orelse return error.MissingProtocolMagic)),
        .security_param = try valueToU64(protocol_consts.get("k") orelse return error.MissingSecurityParam),
        .start_time = try valueToU64(root.get("startTime") orelse return error.MissingStartTime),
        .avvm_distr = avvm_distr,
        .non_avvm_balances = non_avvm_balances,
        .max_tx_size = try valueToU64(block_version_data.get("maxTxSize") orelse return error.MissingMaxTxSize),
        .tx_fee_policy_summand = try valueToU64(tx_fee_policy.get("summand") orelse return error.MissingFeeSummand),
        .tx_fee_policy_multiplier = try valueToU64(tx_fee_policy.get("multiplier") orelse return error.MissingFeeMultiplier),
    };
}

fn extractUint(json: []const u8, field: []const u8) ?u64 {
    const search = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field}) catch return null;
    defer std.heap.page_allocator.free(search);
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after = json[pos + search.len ..];
    // Find the number after colon
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':' or after[i] == '\n' or after[i] == '\r')) : (i += 1) {}
    var end = i;
    while (end < after.len and after[end] >= '0' and after[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u64, after[i..end], 10) catch null;
}

fn extractFloat(json: []const u8, field: []const u8) ?f64 {
    const search = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field}) catch return null;
    defer std.heap.page_allocator.free(search);
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after = json[pos + search.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':' or after[i] == '\n')) : (i += 1) {}
    var end = i;
    while (end < after.len and (after[end] >= '0' and after[end] <= '9' or after[end] == '.' or after[end] == '-' or after[end] == 'e' or after[end] == 'E' or after[end] == '+')) : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseFloat(f64, after[i..end]) catch null;
}

fn extractString(json: []const u8, field: []const u8) ?[]const u8 {
    const search = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{field}) catch return null;
    defer std.heap.page_allocator.free(search);
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after = json[pos + search.len ..];
    var i: usize = 0;
    while (i < after.len and after[i] != '"') : (i += 1) {}
    if (i >= after.len) return null;
    i += 1;
    const start = i;
    while (i < after.len and after[i] != '"') : (i += 1) {}
    return after[start..i];
}

fn extractNestedUint(json: []const u8, field: []const u8) ?u64 {
    return extractUint(json, field);
}

fn extractNestedFloat(json: []const u8, field: []const u8) ?f64 {
    return extractFloat(json, field);
}

fn valueAsObject(value: std_json.Value) std_json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => @panic("expected JSON object"),
    };
}

fn valueToU64(value: std_json.Value) !u64 {
    return switch (value) {
        .integer => |n| blk: {
            if (n < 0) return error.NegativeGenesisValue;
            break :blk @intCast(n);
        },
        .string => |s| std.fmt.parseInt(u64, s, 10),
        .number_string => |s| std.fmt.parseInt(u64, s, 10),
        else => error.InvalidGenesisValue,
    };
}

fn valueToF64(value: std_json.Value) !f64 {
    return switch (value) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        .string => |s| std.fmt.parseFloat(f64, s),
        .number_string => |s| std.fmt.parseFloat(f64, s),
        else => error.InvalidGenesisValue,
    };
}

fn decodeHexHash28(text: []const u8) !types.Hash28 {
    if (text.len != 56) return error.InvalidGenesisHash;
    var out: types.Hash28 = undefined;
    _ = try std.fmt.hexToBytes(&out, text);
    return out;
}

fn computeStabilityWindow(security_param: u64, active_slots_coeff: f64) u64 {
    const numerator = 3.0 * @as(f64, @floatFromInt(security_param));
    return @intFromFloat(@ceil(numerator / active_slots_coeff));
}

fn extractBalanceMap(
    allocator: Allocator,
    root: std_json.ObjectMap,
    field: []const u8,
) ![]ByronGenesisBalance {
    const value = root.get(field) orelse return try allocator.alloc(ByronGenesisBalance, 0);
    const object = valueAsObject(value);

    var balances: std.ArrayList(ByronGenesisBalance) = .empty;
    defer balances.deinit(allocator);

    var iter = object.iterator();
    while (iter.next()) |entry| {
        try balances.append(allocator, .{
            .id = try allocator.dupe(u8, entry.key_ptr.*),
            .lovelace = try valueToU64(entry.value_ptr.*),
        });
    }

    return try balances.toOwnedSlice(allocator);
}

fn freeByronBalances(allocator: Allocator, balances: []ByronGenesisBalance) void {
    for (balances) |*entry| entry.deinit(allocator);
    allocator.free(balances);
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "genesis: parse real shelley genesis" {
    const allocator = std.testing.allocator;
    // Try to load a real genesis file from reference repos
    var genesis = parseShelleyGenesis(allocator, "reference-node/configuration/cardano/mainnet-shelley-genesis.json") catch |err| {
        if (err == error.FileNotFound) return; // skip if not present
        return err;
    };
    defer genesis.deinit(allocator);

    // Mainnet values
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), genesis.active_slots_coeff, 0.001);
    try std.testing.expectEqual(@as(u64, 432000), genesis.epoch_length);
    try std.testing.expectEqual(@as(u64, 2160), genesis.security_param);
    try std.testing.expectEqual(@as(u32, 764824073), genesis.network_magic);
}

test "genesis: load Shelley governance config" {
    const allocator = std.testing.allocator;

    var config = loadShelleyGovernanceConfig(allocator, "shelley.json") catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 432000), config.epoch_length);
    try std.testing.expectEqual(@as(u64, 129600), config.stability_window);
    try std.testing.expectEqual(@as(u64, 5), config.update_quorum);
    try std.testing.expect(config.genesis_delegate_hashes.len > 0);
}

test "genesis: default values when file missing" {
    // extractUint should return null for missing fields
    const result = extractUint("{}", "nonexistent");
    try std.testing.expect(result == null);
}

test "genesis: extract uint from JSON" {
    const json = "{ \"epochLength\": 432000 }";
    const val = extractUint(json, "epochLength");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(u64, 432000), val.?);
}

test "genesis: extract float from JSON" {
    const json = "{ \"activeSlotsCoeff\": 0.05 }";
    const val = extractFloat(json, "activeSlotsCoeff");
    try std.testing.expect(val != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), val.?, 0.001);
}

test "genesis: parse local byron genesis summary" {
    const allocator = std.testing.allocator;

    var genesis = parseByronGenesis(allocator, "byron.json") catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer genesis.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), genesis.protocol_magic);
    try std.testing.expectEqual(@as(u64, 2160), genesis.security_param);
    try std.testing.expect(genesis.non_avvm_balances.len > 0);
    try std.testing.expect(genesis.totalSupply() > 0);
}

test "genesis: parse official mainnet byron genesis summary" {
    const allocator = std.testing.allocator;

    var genesis = parseByronGenesis(allocator, "reference-node/configuration/cardano/mainnet-byron-genesis.json") catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer genesis.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 764824073), genesis.protocol_magic);
    try std.testing.expectEqual(@as(u64, 2160), genesis.security_param);
    try std.testing.expect(genesis.avvm_distr.len > 0);
    try std.testing.expect(genesis.totalSupply() > 0);
}

test "genesis: build local byron genesis utxos" {
    const allocator = std.testing.allocator;

    var genesis = parseByronGenesis(allocator, "byron.json") catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer genesis.deinit(allocator);

    const utxos = try buildByronGenesisUtxos(allocator, &genesis);
    defer freeGenesisUtxos(allocator, utxos);

    try std.testing.expectEqual(
        genesis.avvm_distr.len + genesis.non_avvm_balances.len,
        utxos.len,
    );

    var total: u64 = 0;
    for (utxos) |entry| {
        total += entry.value;
        try std.testing.expectEqual(@as(types.TxIx, 0), entry.tx_in.tx_ix);
        try std.testing.expect(entry.raw_cbor.len > 0);
    }
    try std.testing.expectEqual(genesis.totalSupply(), total);
}

test "genesis: build official mainnet byron genesis utxos" {
    const allocator = std.testing.allocator;

    var genesis = parseByronGenesis(allocator, "reference-node/configuration/cardano/mainnet-byron-genesis.json") catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer genesis.deinit(allocator);

    const utxos = try buildByronGenesisUtxos(allocator, &genesis);
    defer freeGenesisUtxos(allocator, utxos);

    try std.testing.expectEqual(
        genesis.avvm_distr.len + genesis.non_avvm_balances.len,
        utxos.len,
    );

    var total: u64 = 0;
    for (utxos) |entry| total += entry.value;
    try std.testing.expectEqual(genesis.totalSupply(), total);
}
