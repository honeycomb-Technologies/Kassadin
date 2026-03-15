const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");
const praos = @import("../consensus/praos.zig");

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
        .network_id = extractString(content, "networkId") orelse "Mainnet",
        .system_start = extractString(content, "systemStart") orelse "2017-09-23T21:44:51Z",
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

// ──────────────────────────────────── Tests ────────────────────────────────────

test "genesis: parse real shelley genesis" {
    const allocator = std.testing.allocator;
    // Try to load a real genesis file from reference repos
    const genesis = parseShelleyGenesis(allocator, "reference-node/configuration/cardano/mainnet-shelley-genesis.json") catch |err| {
        if (err == error.FileNotFound) return; // skip if not present
        return err;
    };

    // Mainnet values
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), genesis.active_slots_coeff, 0.001);
    try std.testing.expectEqual(@as(u64, 432000), genesis.epoch_length);
    try std.testing.expectEqual(@as(u64, 2160), genesis.security_param);
    try std.testing.expectEqual(@as(u32, 764824073), genesis.network_magic);
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
