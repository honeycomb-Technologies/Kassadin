const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RequiresNetworkMagic = enum {
    requires_magic,
    requires_no_magic,
};

pub const CardanoNodeConfig = struct {
    protocol: []u8,
    requires_network_magic: RequiresNetworkMagic,
    byron_genesis_path: ?[]u8,
    shelley_genesis_path: ?[]u8,
    alonzo_genesis_path: ?[]u8,
    conway_genesis_path: ?[]u8,
    database_path: ?[]u8,
    socket_path: ?[]u8,
    shelley_hard_fork_epoch: ?u64 = null,

    pub fn deinit(self: *CardanoNodeConfig, allocator: Allocator) void {
        allocator.free(self.protocol);
        if (self.byron_genesis_path) |path| allocator.free(path);
        if (self.shelley_genesis_path) |path| allocator.free(path);
        if (self.alonzo_genesis_path) |path| allocator.free(path);
        if (self.conway_genesis_path) |path| allocator.free(path);
        if (self.database_path) |path| allocator.free(path);
        if (self.socket_path) |path| allocator.free(path);
    }
};

pub fn parseCardanoNodeConfig(allocator: Allocator, path: []const u8) !CardanoNodeConfig {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
    defer allocator.free(content);

    const protocol = try allocator.dupe(u8, extractString(content, "Protocol") orelse return error.MissingProtocol);
    errdefer allocator.free(protocol);

    if (!std.mem.eql(u8, protocol, "Cardano")) {
        return error.UnsupportedProtocol;
    }

    return .{
        .protocol = protocol,
        .requires_network_magic = parseRequiresNetworkMagic(
            extractString(content, "RequiresNetworkMagic") orelse "RequiresMagic",
        ) orelse return error.InvalidRequiresNetworkMagic,
        .byron_genesis_path = try extractResolvedPath(allocator, path, content, "ByronGenesisFile"),
        .shelley_genesis_path = try extractResolvedPath(allocator, path, content, "ShelleyGenesisFile"),
        .alonzo_genesis_path = try extractResolvedPath(allocator, path, content, "AlonzoGenesisFile"),
        .conway_genesis_path = try extractResolvedPath(allocator, path, content, "ConwayGenesisFile"),
        .database_path = try extractResolvedPath(allocator, path, content, "DatabasePath"),
        .socket_path = try extractResolvedPath(allocator, path, content, "SocketPath"),
        .shelley_hard_fork_epoch = extractUint(content, "TestShelleyHardForkAtEpoch"),
    };
}

fn parseRequiresNetworkMagic(raw: []const u8) ?RequiresNetworkMagic {
    if (std.mem.eql(u8, raw, "RequiresMagic")) return .requires_magic;
    if (std.mem.eql(u8, raw, "RequiresNoMagic")) return .requires_no_magic;
    return null;
}

fn extractResolvedPath(
    allocator: Allocator,
    config_path: []const u8,
    json: []const u8,
    field: []const u8,
) !?[]u8 {
    const raw = extractString(json, field) orelse return null;
    return try resolveRelativePath(allocator, config_path, raw);
}

fn resolveRelativePath(allocator: Allocator, config_path: []const u8, raw_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) {
        return allocator.dupe(u8, raw_path);
    }

    const config_dir = std.fs.path.dirname(config_path) orelse ".";
    return std.fs.path.join(allocator, &.{ config_dir, raw_path });
}

fn extractUint(json: []const u8, field: []const u8) ?u64 {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch return null;
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after = json[pos + search.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':' or after[i] == '\n' or after[i] == '\r')) : (i += 1) {}
    var end = i;
    while (end < after.len and after[end] >= '0' and after[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u64, after[i..end], 10) catch null;
}

fn extractString(json: []const u8, field: []const u8) ?[]const u8 {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch return null;
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after = json[pos + search.len ..];

    var i: usize = 0;
    while (i < after.len and after[i] != '"') : (i += 1) {}
    if (i >= after.len) return null;

    i += 1;
    const start = i;
    while (i < after.len and after[i] != '"') : (i += 1) {}
    if (i > after.len) return null;

    return after[start..i];
}

test "config: parse official mainnet config and resolve genesis paths" {
    const allocator = std.testing.allocator;

    var cfg = parseCardanoNodeConfig(
        allocator,
        "reference-node/configuration/cardano/mainnet-config.json",
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(RequiresNetworkMagic.requires_no_magic, cfg.requires_network_magic);
    try std.testing.expect(cfg.shelley_genesis_path != null);
    try std.testing.expectEqualStrings(
        "reference-node/configuration/cardano/mainnet-shelley-genesis.json",
        cfg.shelley_genesis_path.?,
    );
    try std.testing.expect(cfg.byron_genesis_path != null);
}

test "config: parse test config with relative paths" {
    const allocator = std.testing.allocator;

    var cfg = parseCardanoNodeConfig(
        allocator,
        "reference-ouroboros-consensus/ouroboros-consensus-cardano/test/tools-test/disk/config/config.json",
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(RequiresNetworkMagic.requires_magic, cfg.requires_network_magic);
    try std.testing.expectEqualStrings(
        "reference-ouroboros-consensus/ouroboros-consensus-cardano/test/tools-test/disk/config/shelley-genesis.json",
        cfg.shelley_genesis_path.?,
    );
    try std.testing.expect(cfg.alonzo_genesis_path != null);
    try std.testing.expect(cfg.conway_genesis_path != null);
}
