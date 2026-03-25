const std = @import("std");

pub const crypto = struct {
    pub const hash = @import("crypto/hash.zig");
    pub const ed25519 = @import("crypto/ed25519.zig");
    pub const vrf = @import("crypto/vrf.zig");
    pub const kes = @import("crypto/kes_sum.zig");
    pub const compact_kes = @import("crypto/kes.zig");
    pub const opcert = @import("crypto/opcert.zig");
    pub const bech32 = @import("crypto/bech32.zig");
};

pub const cbor = @import("cbor/cbor.zig");
pub const types = @import("types.zig");

pub const network = struct {
    pub const protocol = @import("network/protocol.zig");
    pub const mux = @import("network/mux.zig");
    pub const handshake = @import("network/handshake.zig");
    pub const chainsync = @import("network/chainsync.zig");
    pub const blockfetch = @import("network/blockfetch.zig");
    pub const txsubmission = @import("network/txsubmission.zig");
    pub const keepalive = @import("network/keepalive.zig");
    pub const peersharing = @import("network/peersharing.zig");
    pub const peer = @import("network/peer.zig");
    pub const unix_bearer = @import("network/unix_bearer.zig");
    pub const n2c_handshake = @import("network/n2c_handshake.zig");
    pub const local_tx_submission = @import("network/local_tx_submission.zig");
    pub const local_tx_monitor = @import("network/local_tx_monitor.zig");
    pub const local_state_query = @import("network/local_state_query.zig");
    pub const local_state_query_client = @import("network/local_state_query_client.zig");
    pub const dolos_grpc_client = @import("network/dolos_grpc_client.zig");
};

pub const storage = struct {
    pub const immutable = @import("storage/immutable.zig");
    pub const volatile_db = @import("storage/volatile.zig");
    pub const ledger = @import("storage/ledger.zig");
    pub const chaindb = @import("storage/chaindb.zig");
};

pub const ledger = struct {
    pub const block = @import("ledger/block.zig");
    pub const transaction = @import("ledger/transaction.zig");
    pub const rules = @import("ledger/rules.zig");
    pub const multiasset = @import("ledger/multiasset.zig");
    pub const certificates = @import("ledger/certificates.zig");
    pub const scripts = @import("ledger/scripts.zig");
    pub const plutus = @import("ledger/plutus.zig");
    pub const script_context = @import("ledger/script_context.zig");
    pub const stake = @import("ledger/stake.zig");
    pub const apply = @import("ledger/apply.zig");
    pub const rewards = @import("ledger/rewards.zig");
    pub const witness = @import("ledger/witness.zig");
    pub const golden_tests = @import("ledger/golden_tests.zig");
};

pub const consensus = struct {
    pub const praos = @import("consensus/praos.zig");
    pub const leader = @import("consensus/leader.zig");
    pub const header_validation = @import("consensus/header_validation.zig");
};

pub const mempool = @import("mempool/mempool.zig");
pub const app = @import("app/root.zig");
pub const node = struct {
    pub const node_mod = @import("node/node.zig");
    pub const config = @import("node/config.zig");
    pub const keys = @import("node/keys.zig");
    pub const genesis = @import("node/genesis.zig");
    pub const sync = @import("node/sync.zig");
    pub const runner = @import("node/runner.zig");
    pub const mithril = @import("node/mithril.zig");
    pub const snapshot_restore = @import("node/snapshot_restore.zig");
    pub const chunk_reader = @import("node/chunk_reader.zig");
    pub const ledger_snapshot = @import("node/ledger_snapshot.zig");
    pub const bootstrap_sync = @import("node/bootstrap_sync.zig");
    pub const runtime_control = @import("node/runtime_control.zig");
    pub const topology = @import("node/topology.zig");
    pub const n2c_server = @import("node/n2c_server.zig");
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len == 1) {
        try runManagedRoot();
        return;
    }

    if (std.mem.eql(u8, args[1], "init")) {
        try runManagedInit(args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "status")) {
        try printManagedStatus(true);
        return;
    }
    if (std.mem.eql(u8, args[1], "bootstrap")) {
        try runManagedBootstrap();
        return;
    }
    if (std.mem.eql(u8, args[1], "daemon")) {
        try runManagedDaemon(args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "debug")) {
        try runDebug(args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "sync")) {
        try runLegacySync(args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "bootstrap-sync")) {
        try runLegacyBootstrapSync(args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "dolos-tip")) {
        try runLegacyDolosTip(args[2..]);
        return;
    }

    printHelp();
}

fn runManagedRoot() !void {
    var layout = try app.home.resolve(std.heap.page_allocator);
    defer layout.deinit(std.heap.page_allocator);

    var loaded = try app.state.load(std.heap.page_allocator, &layout);
    if (loaded == null) {
        try runManagedInit(&.{});
        return;
    }
    defer loaded.?.deinit();
    try printManagedStatus(true);
}

fn runManagedInit(args: []const [:0]u8) !void {
    var layout = try app.home.resolve(std.heap.page_allocator);
    defer layout.deinit(std.heap.page_allocator);

    var result: app.wizard.Result = undefined;
    var owned_custom_relays: ?[]app.state.CustomRelay = null;
    defer if (owned_custom_relays) |relays| app.state.deinitRelayList(std.heap.page_allocator, relays);
    var db_path_override: ?[]u8 = null;
    defer if (db_path_override) |path| std.heap.page_allocator.free(path);
    var socket_path_override: ?[]u8 = null;
    defer if (socket_path_override) |path| std.heap.page_allocator.free(path);

    var non_interactive = false;
    var bootstrap_now = true;
    var start_daemon = false;
    var options = app.state.InitOptions{
        .service_backend = app.service.detectDefaultBackend(),
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--non-interactive")) {
            non_interactive = true;
        } else if (std.mem.eql(u8, args[i], "--network")) {
            if (i + 1 >= args.len) fatal("Missing value after --network\n", .{});
            options.network = app.network.parseId(args[i + 1]) orelse fatal("Unsupported network: {s}\n", .{args[i + 1]});
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--relay-mode")) {
            if (i + 1 >= args.len) fatal("Missing value after --relay-mode\n", .{});
            if (std.mem.eql(u8, args[i + 1], "official-only")) {
                options.relay_mode = .official_only;
            } else if (std.mem.eql(u8, args[i + 1], "official-plus-custom")) {
                options.relay_mode = .official_plus_custom;
            } else if (std.mem.eql(u8, args[i + 1], "custom-only")) {
                options.relay_mode = .custom_only;
            } else {
                fatal("Unsupported relay mode: {s}\n", .{args[i + 1]});
            }
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--custom-relay")) {
            if (i + 1 >= args.len) fatal("Missing value after --custom-relay\n", .{});
            if (owned_custom_relays) |existing| {
                app.state.deinitRelayList(std.heap.page_allocator, existing);
            }
            owned_custom_relays = try app.state.parseRelayList(std.heap.page_allocator, args[i + 1]);
            options.custom_relays = owned_custom_relays.?;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--bootstrap-strategy")) {
            if (i + 1 >= args.len) fatal("Missing value after --bootstrap-strategy\n", .{});
            if (std.mem.eql(u8, args[i + 1], "mithril")) {
                options.bootstrap_strategy = .mithril;
            } else if (std.mem.eql(u8, args[i + 1], "genesis-only")) {
                options.bootstrap_strategy = .genesis_only;
            } else {
                fatal("Unsupported bootstrap strategy: {s}\n", .{args[i + 1]});
            }
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--db-path")) {
            if (i + 1 >= args.len) fatal("Missing value after --db-path\n", .{});
            db_path_override = try std.heap.page_allocator.dupe(u8, args[i + 1]);
            options.db_path = db_path_override.?;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--socket-path")) {
            if (i + 1 >= args.len) fatal("Missing value after --socket-path\n", .{});
            socket_path_override = try std.heap.page_allocator.dupe(u8, args[i + 1]);
            options.socket_path = socket_path_override.?;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-service")) {
            options.service_backend = .none;
        } else if (std.mem.eql(u8, args[i], "--skip-bootstrap")) {
            bootstrap_now = false;
        } else if (std.mem.eql(u8, args[i], "--start-daemon")) {
            start_daemon = true;
        } else {
            fatal("Unknown init argument: {s}\n", .{args[i]});
        }
    }

    if (non_interactive) {
        result = .{
            .options = options,
            .bootstrap_now = bootstrap_now,
            .start_daemon = start_daemon,
        };
    } else {
        result = try app.wizard.run(std.heap.page_allocator, &layout);
    }

    if (app.network.get(result.options.network).availability != .active) {
        fatal("Network {s} is coming soon. Preprod is the only active startup path in v1.\n", .{@tagName(result.options.network)});
    }
    if (result.options.relay_mode == .custom_only and result.options.custom_relays.len == 0) {
        fatal("Custom-only relay mode requires at least one custom relay.\n", .{});
    }

    var state = try app.state.createDefault(std.heap.page_allocator, &layout, result.options);
    defer app.state.deinitOwned(std.heap.page_allocator, &state);

    try app.state.save(&layout, &state);
    try app.bundle.ensureProfileBundle(std.heap.page_allocator, &state.profiles[0]);

    if (state.profiles[0].service_backend != .none) {
        state.profiles[0].service_backend = try app.service.install(std.heap.page_allocator, &layout, &state.profiles[0]);
        state.profiles[0].service_installed = state.profiles[0].service_backend != .none;
        try app.state.save(&layout, &state);
    }

    if (result.bootstrap_now) {
        _ = try app.runtime.ensureBootstrap(std.heap.page_allocator, &state.profiles[0]);
        const snapshot_state = try node.snapshot_restore.scanSnapshotDir(std.heap.page_allocator, state.profiles[0].db_path);
        state.profiles[0].bootstrap_completed = snapshot_state.immutable_file_count > 0;
        try app.state.save(&layout, &state);
    }

    std.debug.print("Kassadin initialized under {s}\n", .{layout.root});
    if (result.start_daemon) {
        if (state.profiles[0].service_installed) {
            try app.service.start(std.heap.page_allocator, state.profiles[0].service_backend);
            std.debug.print("Daemon started through the managed service.\n", .{});
        } else {
            try app.runtime.runProfile(std.heap.page_allocator, &state.profiles[0]);
        }
    } else {
        std.debug.print("Run 'kassadin daemon install' or 'kassadin daemon run' next.\n", .{});
    }
}

fn runManagedBootstrap() !void {
    var layout = try app.home.resolve(std.heap.page_allocator);
    defer layout.deinit(std.heap.page_allocator);

    var loaded = try app.state.load(std.heap.page_allocator, &layout) orelse fatal("Kassadin is not initialized. Run 'kassadin' or 'kassadin init' first.\n", .{});
    defer loaded.deinit();

    var state = try app.state.clone(std.heap.page_allocator, loaded.value());
    defer app.state.deinitOwned(std.heap.page_allocator, &state);

    const profile = findMutableDefaultProfile(&state) orelse fatal("Default profile missing from managed state\n", .{});
    _ = try app.runtime.ensureBootstrap(std.heap.page_allocator, profile);
    const snapshot_state = try node.snapshot_restore.scanSnapshotDir(std.heap.page_allocator, profile.db_path);
    profile.bootstrap_completed = snapshot_state.immutable_file_count > 0;
    try app.state.save(&layout, &state);
    std.debug.print("Bootstrap state updated. Snapshot present: {}\n", .{profile.bootstrap_completed});
}

fn runManagedDaemon(args: []const [:0]u8) !void {
    if (args.len == 0) {
        try printManagedStatus(false);
        return;
    }

    const profile_id = parseManagedProfileArg(args[1..]);
    if (!std.mem.eql(u8, profile_id, app.state.default_profile_id)) {
        fatal("Only the default managed profile is supported in v1.\n", .{});
    }
    if (std.mem.eql(u8, args[0], "status")) {
        try printManagedStatus(false);
        return;
    }

    var layout = try app.home.resolve(std.heap.page_allocator);
    defer layout.deinit(std.heap.page_allocator);
    var loaded = try app.state.load(std.heap.page_allocator, &layout) orelse fatal("Kassadin is not initialized. Run 'kassadin' or 'kassadin init' first.\n", .{});
    defer loaded.deinit();

    const default_profile = loaded.defaultProfile() orelse fatal("Default profile missing from managed state\n", .{});

    if (std.mem.eql(u8, args[0], "logs")) {
        const log_path = try app.home.defaultLogPath(std.heap.page_allocator, &layout);
        defer std.heap.page_allocator.free(log_path);
        try app.service.streamLogs(std.heap.page_allocator, default_profile.service_backend, log_path);
        return;
    }

    var state = try app.state.clone(std.heap.page_allocator, loaded.value());
    defer app.state.deinitOwned(std.heap.page_allocator, &state);
    const profile = findMutableDefaultProfile(&state) orelse fatal("Default profile missing from managed state\n", .{});

    if (std.mem.eql(u8, args[0], "install")) {
        profile.service_backend = try app.service.install(std.heap.page_allocator, &layout, profile);
        profile.service_installed = profile.service_backend != .none;
        try app.state.save(&layout, &state);
        std.debug.print("Managed daemon installed with backend {s}\n", .{@tagName(profile.service_backend)});
        return;
    }
    if (std.mem.eql(u8, args[0], "uninstall")) {
        try app.service.uninstall(std.heap.page_allocator, profile.service_backend);
        profile.service_installed = false;
        try app.state.save(&layout, &state);
        std.debug.print("Managed daemon uninstalled.\n", .{});
        return;
    }
    if (std.mem.eql(u8, args[0], "start")) {
        if (!profile.service_installed) fatal("Managed service is not installed. Run 'kassadin daemon install' first.\n", .{});
        try app.service.start(std.heap.page_allocator, profile.service_backend);
        return;
    }
    if (std.mem.eql(u8, args[0], "stop")) {
        if (!profile.service_installed) fatal("Managed service is not installed.\n", .{});
        try app.service.stop(std.heap.page_allocator, profile.service_backend);
        return;
    }
    if (std.mem.eql(u8, args[0], "restart")) {
        if (!profile.service_installed) fatal("Managed service is not installed.\n", .{});
        try app.service.restart(std.heap.page_allocator, profile.service_backend);
        return;
    }
    if (std.mem.eql(u8, args[0], "run")) {
        _ = try app.runtime.ensureBootstrap(std.heap.page_allocator, profile);
        const snapshot_state = try node.snapshot_restore.scanSnapshotDir(std.heap.page_allocator, profile.db_path);
        profile.bootstrap_completed = snapshot_state.immutable_file_count > 0;
        try app.state.save(&layout, &state);
        try app.runtime.runProfile(std.heap.page_allocator, profile);
        return;
    }

    fatal("Unknown daemon argument: {s}\n", .{args[0]});
}

fn parseManagedProfileArg(args: []const [:0]u8) []const u8 {
    var profile_id: []const u8 = app.state.default_profile_id;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--profile")) {
            if (i + 1 >= args.len) fatal("Missing value after --profile\n", .{});
            profile_id = args[i + 1];
            i += 1;
            continue;
        }
        fatal("Unknown daemon argument: {s}\n", .{args[i]});
    }
    return profile_id;
}

fn runDebug(args: []const [:0]u8) !void {
    if (args.len == 0) fatal("Usage: kassadin debug <sync|bootstrap|bootstrap-sync|dolos-tip> ...\n", .{});
    if (std.mem.eql(u8, args[0], "sync")) return runLegacySync(args[1..]);
    if (std.mem.eql(u8, args[0], "bootstrap")) return runLegacyBootstrapInfo(args[1..]);
    if (std.mem.eql(u8, args[0], "bootstrap-sync")) return runLegacyBootstrapSync(args[1..]);
    if (std.mem.eql(u8, args[0], "dolos-tip")) return runLegacyDolosTip(args[1..]);
    fatal("Unknown debug command: {s}\n", .{args[0]});
}

fn printManagedStatus(include_hints: bool) !void {
    var layout = try app.home.resolve(std.heap.page_allocator);
    defer layout.deinit(std.heap.page_allocator);

    var loaded = try app.state.load(std.heap.page_allocator, &layout);
    if (loaded == null) {
        std.debug.print("Kassadin is not initialized.\n", .{});
        if (include_hints) std.debug.print("Run 'kassadin' or 'kassadin init' to create the managed profile.\n", .{});
        return;
    }
    defer loaded.?.deinit();

    const profile = loaded.?.defaultProfile() orelse fatal("Default profile missing from managed state\n", .{});
    const daemon_status = try app.service.status(std.heap.page_allocator, profile.service_backend, profile.service_installed);
    const tip = try app.runtime.lastKnownTip(std.heap.page_allocator, profile.db_path);
    const log_path = try app.home.defaultLogPath(std.heap.page_allocator, &layout);
    defer std.heap.page_allocator.free(log_path);

    std.debug.print("Kassadin\n", .{});
    std.debug.print("  Root: {s}\n", .{layout.root});
    std.debug.print("  Profile: {s}\n", .{profile.id});
    std.debug.print("  Network: {s}\n", .{@tagName(profile.network)});
    std.debug.print("  Availability: {s}\n", .{@tagName(profile.availability)});
    std.debug.print("  Relay mode: {s}\n", .{@tagName(profile.relay_mode)});
    std.debug.print("  Bootstrap: {s} (completed: {})\n", .{ @tagName(profile.bootstrap_strategy), profile.bootstrap_completed });
    std.debug.print("  Service backend: {s}\n", .{@tagName(profile.service_backend)});
    std.debug.print("  Service status: {s}\n", .{@tagName(daemon_status)});
    std.debug.print("  DB path: {s}\n", .{profile.db_path});
    std.debug.print("  Socket path: {s}\n", .{profile.socket_path});
    std.debug.print("  Config: {s}\n", .{profile.config_path});
    std.debug.print("  Topology: {s}\n", .{profile.topology_path});
    std.debug.print("  Log file: {s}\n", .{log_path});
    if (tip) |known| {
        std.debug.print("  Last known tip: block={}, slot={}\n", .{ known.block_no, known.slot });
    } else {
        std.debug.print("  Last known tip: unavailable\n", .{});
    }
    if (include_hints) {
        std.debug.print("\nNext:\n", .{});
        std.debug.print("  kassadin bootstrap\n", .{});
        std.debug.print("  kassadin daemon install\n", .{});
        std.debug.print("  kassadin daemon run\n", .{});
    }
}

fn findMutableDefaultProfile(state: *app.state.ManagedState) ?*app.state.ManagedProfile {
    for (state.profiles) |*profile| {
        if (std.mem.eql(u8, profile.id, state.default_profile)) return profile;
    }
    return null;
}

fn runLegacySync(args: []const [:0]u8) !void {
    std.debug.print("Kassadin — Cardano Node in Zig\n", .{});
    var config = node.runner.RunConfig.preview_defaults;
    config.max_headers = 0;
    var network_name: []const u8 = "preview";
    var config_file_path: ?[]const u8 = null;
    var topology_path: ?[]const u8 = null;
    var db_path_override: ?[]const u8 = null;
    var socket_path: ?[]const u8 = null;
    var parsed_topology: ?node.topology.Topology = null;
    defer {
        if (parsed_topology) |*topology| topology.deinit(std.heap.page_allocator);
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--network")) {
            if (i + 1 >= args.len) fatal("Missing value after --network\n", .{});
            if (std.mem.eql(u8, args[i + 1], "preview")) {
                config = node.runner.RunConfig.preview_defaults;
                network_name = "preview";
            } else if (std.mem.eql(u8, args[i + 1], "preprod")) {
                config = node.runner.RunConfig.preprod_defaults;
                network_name = "preprod";
            } else {
                fatal("Unsupported network: {s}\n", .{args[i + 1]});
            }
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--max-headers")) {
            if (i + 1 >= args.len) fatal("Missing value after --max-headers\n", .{});
            config.max_headers = std.fmt.parseInt(u64, args[i + 1], 10) catch fatal("Invalid --max-headers value: {s}\n", .{args[i + 1]});
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--shelley-genesis")) {
            if (i + 1 >= args.len) fatal("Missing value after --shelley-genesis\n", .{});
            config.shelley_genesis_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--byron-genesis")) {
            if (i + 1 >= args.len) fatal("Missing value after --byron-genesis\n", .{});
            config.byron_genesis_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--config")) {
            if (i + 1 >= args.len) fatal("Missing value after --config\n", .{});
            config_file_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--topology")) {
            if (i + 1 >= args.len) fatal("Missing value after --topology\n", .{});
            topology_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--db-path")) {
            if (i + 1 >= args.len) fatal("Missing value after --db-path\n", .{});
            db_path_override = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--socket-path")) {
            if (i + 1 >= args.len) fatal("Missing value after --socket-path\n", .{});
            socket_path = args[i + 1];
            i += 1;
        } else {
            fatal("Unknown sync argument: {s}\n", .{args[i]});
        }
    }

    if (config_file_path) |path| {
        var parsed = node.config.parseCardanoNodeConfig(std.heap.page_allocator, path) catch |err| fatal("Config parse failed: {}\n", .{err});
        defer parsed.deinit(std.heap.page_allocator);
        if (parsed.byron_genesis_path) |genesis_path| {
            config.byron_genesis_path = std.heap.page_allocator.dupe(u8, genesis_path) catch fatal("Failed to copy Byron genesis path from config\n", .{});
        }
        if (parsed.shelley_genesis_path) |genesis_path| {
            config.shelley_genesis_path = std.heap.page_allocator.dupe(u8, genesis_path) catch fatal("Failed to copy Shelley genesis path from config\n", .{});
        }
        config.hard_fork_epoch = parsed.shelley_hard_fork_epoch;
    }

    if (topology_path) |path| {
        parsed_topology = node.topology.parseTopology(std.heap.page_allocator, path) catch |err| fatal("Topology parse failed: {}\n", .{err});
        config.peer_endpoints = parsed_topology.?.peers;
    }

    if (db_path_override) |path| config.db_path = path;
    config.socket_path = socket_path;

    std.debug.print("Syncing from {s} network...\n\n", .{network_name});
    node.runtime_control.resetStopRequested();
    node.runtime_control.installSignalHandlers();
    const result = node.runner.run(std.heap.page_allocator, config) catch |err| fatal("Sync error: {}\n", .{err});

    std.debug.print("Sync complete:\n", .{});
    std.debug.print("  Headers synced: {}\n", .{result.headers_synced});
    std.debug.print("  Blocks fetched: {}\n", .{result.blocks_fetched});
    std.debug.print("  Blocks added: {}\n", .{result.blocks_added_to_chain});
    std.debug.print("  Invalid blocks: {}\n", .{result.invalid_blocks});
    std.debug.print("  Tip slot: {}\n", .{result.tip_slot});
    std.debug.print("  Tip block: {}\n", .{result.tip_block_no});
    std.debug.print("  Stopped by signal: {}\n", .{result.stopped_by_signal});
}

fn runLegacyBootstrapInfo(args: []const [:0]u8) !void {
    std.debug.print("Kassadin — Mithril Bootstrap\n", .{});
    std.debug.print("Fetching latest preprod snapshot info...\n\n", .{});

    const info = node.mithril.fetchLatestSnapshot(std.heap.page_allocator, node.mithril.aggregator_urls.preprod) catch |err| fatal("Failed to fetch snapshot: {}\n", .{err});
    defer info.deinit(std.heap.page_allocator);

    std.debug.print("Latest snapshot:\n", .{});
    std.debug.print("  Epoch: {}\n", .{info.epoch});
    std.debug.print("  Immutable file: {}\n", .{info.immutable_file_number});
    std.debug.print("  Size: {} MB\n", .{info.size / 1024 / 1024});
    if (info.ancillary_download_url != null) std.debug.print("  Ancillary size: {} MB\n", .{info.ancillary_size / 1024 / 1024});
    std.debug.print("\nTo download and restore, run:\n", .{});
    std.debug.print("  kassadin debug bootstrap --download\n", .{});

    if (args.len > 0 and std.mem.eql(u8, args[0], "--download")) {
        std.debug.print("\nDownloading and extracting...\n", .{});
        node.mithril.downloadAndExtract(std.heap.page_allocator, info, "db/preprod") catch |err| fatal("Bootstrap failed: {}\n", .{err});
        std.debug.print("Bootstrap complete! Run 'kassadin bootstrap-sync' to continue from tip.\n", .{});
    }
}

fn runLegacyBootstrapSync(args: []const [:0]u8) !void {
    std.debug.print("Kassadin — Bootstrap Sync (preprod)\n\n", .{});

    var validation_endpoint: ?[]const u8 = null;
    var shelley_genesis_path: ?[]const u8 = "config/preprod/shelley.json";
    var config_file_path: ?[]const u8 = null;
    var topology_path: ?[]const u8 = null;
    var max_blocks: u64 = 0;
    const peer_host: []const u8 = "preprod-node.play.dev.cardano.org";
    const peer_port: u16 = 3001;
    var db_path: []const u8 = "db/preprod";
    var parsed_topology: ?node.topology.Topology = null;
    defer {
        if (parsed_topology) |*topology| topology.deinit(std.heap.page_allocator);
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--validate-dolos")) {
            validation_endpoint = "127.0.0.1:50051";
        } else if (std.mem.eql(u8, args[i], "--dolos-grpc")) {
            if (i + 1 >= args.len) fatal("Missing endpoint after --dolos-grpc\n", .{});
            validation_endpoint = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--shelley-genesis")) {
            if (i + 1 >= args.len) fatal("Missing path after --shelley-genesis\n", .{});
            shelley_genesis_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--config")) {
            if (i + 1 >= args.len) fatal("Missing path after --config\n", .{});
            config_file_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--max-blocks")) {
            if (i + 1 >= args.len) fatal("Missing value after --max-blocks\n", .{});
            max_blocks = std.fmt.parseInt(u64, args[i + 1], 10) catch fatal("Invalid --max-blocks value: {s}\n", .{args[i + 1]});
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--topology")) {
            if (i + 1 >= args.len) fatal("Missing value after --topology\n", .{});
            topology_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--db-path")) {
            if (i + 1 >= args.len) fatal("Missing value after --db-path\n", .{});
            db_path = args[i + 1];
            i += 1;
        } else {
            fatal("Unknown bootstrap-sync argument: {s}\n", .{args[i]});
        }
    }

    if (config_file_path) |path| {
        var parsed = node.config.parseCardanoNodeConfig(std.heap.page_allocator, path) catch |err| fatal("Config parse failed: {}\n", .{err});
        defer parsed.deinit(std.heap.page_allocator);
        if (parsed.shelley_genesis_path) |genesis_path| {
            shelley_genesis_path = std.heap.page_allocator.dupe(u8, genesis_path) catch fatal("Failed to copy Shelley genesis path from config\n", .{});
        }
    }

    if (topology_path) |path| {
        parsed_topology = node.topology.parseTopology(std.heap.page_allocator, path) catch |err| fatal("Topology parse failed: {}\n", .{err});
    }
    node.runtime_control.resetStopRequested();
    node.runtime_control.installSignalHandlers();

    const result = node.bootstrap_sync.bootstrapSync(
        std.heap.page_allocator,
        db_path,
        peer_host,
        peer_port,
        if (parsed_topology) |topology| topology.peers else null,
        network.protocol.NetworkMagic.preprod,
        max_blocks,
        shelley_genesis_path,
        validation_endpoint,
    ) catch |err| fatal("Bootstrap sync failed: {}\n", .{err});

    std.debug.print("\nBootstrap sync complete:\n", .{});
    std.debug.print("  Snapshot tip: block={}, slot={}\n", .{ result.snapshot_tip_block, result.snapshot_tip_slot });
    std.debug.print("  Headers synced forward: {}\n", .{result.headers_synced_forward});
    std.debug.print("  Blocks parsed: {}\n", .{result.blocks_parsed});
    std.debug.print("  Blocks added to chain: {}\n", .{result.blocks_added_to_chain});
    std.debug.print("  Invalid blocks: {}\n", .{result.invalid_blocks});
    std.debug.print("  Stopped by signal: {}\n", .{result.stopped_by_signal});
}

fn runLegacyDolosTip(args: []const [:0]u8) !void {
    var endpoint: []const u8 = "127.0.0.1:50051";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dolos-grpc")) {
            if (i + 1 >= args.len) fatal("Missing endpoint after --dolos-grpc\n", .{});
            endpoint = args[i + 1];
            i += 1;
        } else {
            fatal("Unknown dolos-tip argument: {s}\n", .{args[i]});
        }
    }

    std.debug.print("Kassadin — Dolos Tip\n\n", .{});
    var client = network.dolos_grpc_client.Client.init(std.heap.page_allocator, endpoint) catch |err| fatal("Failed to initialize Dolos gRPC client: {}\n", .{err});
    defer client.deinit();
    const tip = client.readTip() catch |err| fatal("Failed to read Dolos tip: {}\n", .{err});

    std.debug.print("Dolos tip:\n", .{});
    std.debug.print("  Slot: {}\n", .{tip.slot});
    std.debug.print("  Height: {}\n", .{tip.height});
}

fn printHelp() void {
    std.debug.print("Kassadin\n", .{});
    std.debug.print("Version: 0.1.0\n", .{});
    std.debug.print("\nUsage:\n", .{});
    std.debug.print("  kassadin                     Launch setup wizard or show managed status\n", .{});
    std.debug.print("  kassadin init [--non-interactive ...]\n", .{});
    std.debug.print("  kassadin status\n", .{});
    std.debug.print("  kassadin bootstrap\n", .{});
    std.debug.print("  kassadin daemon <install|start|stop|restart|status|logs|run|uninstall>\n", .{});
    std.debug.print("  kassadin debug <sync|bootstrap|bootstrap-sync|dolos-tip> ...\n", .{});
    std.debug.print("  kassadin sync ...            Legacy compatibility path\n", .{});
    std.debug.print("  kassadin bootstrap-sync ...  Legacy compatibility path\n", .{});
    std.debug.print("  kassadin dolos-tip ...       Legacy compatibility path\n", .{});
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
