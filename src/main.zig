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

    if (args.len > 1 and std.mem.eql(u8, args[1], "sync")) {
        // kassadin sync [--network preview|preprod] [--max-headers N]
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

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--network")) {
                if (i + 1 >= args.len) {
                    fatal("Missing value after --network\n", .{});
                }

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
                if (i + 1 >= args.len) {
                    fatal("Missing value after --max-headers\n", .{});
                }
                config.max_headers = std.fmt.parseInt(u64, args[i + 1], 10) catch {
                    fatal("Invalid --max-headers value: {s}\n", .{args[i + 1]});
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--shelley-genesis")) {
                if (i + 1 >= args.len) {
                    fatal("Missing value after --shelley-genesis\n", .{});
                }
                config.shelley_genesis_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--byron-genesis")) {
                if (i + 1 >= args.len) {
                    fatal("Missing value after --byron-genesis\n", .{});
                }
                config.byron_genesis_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--config")) {
                if (i + 1 >= args.len) {
                    fatal("Missing value after --config\n", .{});
                }
                config_file_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--topology")) {
                if (i + 1 >= args.len) {
                    fatal("Missing value after --topology\n", .{});
                }
                topology_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--db-path")) {
                if (i + 1 >= args.len) {
                    fatal("Missing value after --db-path\n", .{});
                }
                db_path_override = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--socket-path")) {
                if (i + 1 >= args.len) {
                    fatal("Missing value after --socket-path\n", .{});
                }
                socket_path = args[i + 1];
                i += 1;
            } else {
                fatal("Unknown sync argument: {s}\n", .{args[i]});
            }
        }

        if (config_file_path) |path| {
            var parsed = node.config.parseCardanoNodeConfig(std.heap.page_allocator, path) catch |err| {
                fatal("Config parse failed: {}\n", .{err});
            };
            defer parsed.deinit(std.heap.page_allocator);

            if (parsed.byron_genesis_path) |genesis_path| {
                config.byron_genesis_path = std.heap.page_allocator.dupe(u8, genesis_path) catch {
                    fatal("Failed to copy Byron genesis path from config\n", .{});
                };
            }
            if (parsed.shelley_genesis_path) |genesis_path| {
                config.shelley_genesis_path = std.heap.page_allocator.dupe(u8, genesis_path) catch {
                    fatal("Failed to copy Shelley genesis path from config\n", .{});
                };
            }
            config.hard_fork_epoch = parsed.shelley_hard_fork_epoch;
        }

        if (topology_path) |path| {
            parsed_topology = node.topology.parseTopology(std.heap.page_allocator, path) catch |err| {
                fatal("Topology parse failed: {}\n", .{err});
            };
            config.peer_endpoints = parsed_topology.?.peers;
        }

        if (db_path_override) |path| {
            config.db_path = path;
        }
        config.socket_path = socket_path;

        std.debug.print("Syncing from {s} network...\n\n", .{network_name});
        node.runtime_control.resetStopRequested();
        node.runtime_control.installSignalHandlers();

        const result = node.runner.run(std.heap.page_allocator, config) catch |err| {
            fatal("Sync error: {}\n", .{err});
        };

        std.debug.print("Sync complete:\n", .{});
        std.debug.print("  Headers synced: {}\n", .{result.headers_synced});
        std.debug.print("  Blocks fetched: {}\n", .{result.blocks_fetched});
        std.debug.print("  Blocks added: {}\n", .{result.blocks_added_to_chain});
        std.debug.print("  Invalid blocks: {}\n", .{result.invalid_blocks});
        if (result.vrf_threshold_warnings > 0) {
            std.debug.print("  VRF threshold warnings: {} (stake snapshot stale)\n", .{result.vrf_threshold_warnings});
        }
        std.debug.print("  Tip slot: {}\n", .{result.tip_slot});
        std.debug.print("  Tip block: {}\n", .{result.tip_block_no});
        std.debug.print("  Rollbacks: {}\n", .{result.rollbacks});
        std.debug.print("  Resumed from checkpoint: {}\n", .{result.resumed_from_checkpoint});
        std.debug.print("  Resumed from snapshot: {}\n", .{result.resumed_from_snapshot});
        std.debug.print("  Snapshot anchor used: {}\n", .{result.snapshot_anchor_used});
        std.debug.print("  Validation enabled: {}\n", .{result.validation_enabled});
        std.debug.print("  Snapshot tip: block={}, slot={}\n", .{ result.snapshot_tip_block, result.snapshot_tip_slot });
        std.debug.print("  Base UTxOs primed: {}\n", .{result.base_utxos_primed});
        std.debug.print("  Snapshot reward accounts primed: {}\n", .{result.snapshot_reward_accounts_primed});
        std.debug.print("  Snapshot stake deposits primed: {}\n", .{result.snapshot_stake_deposits_primed});
        std.debug.print(
            "  Snapshot stake pools (mark/set/go): {}/{}/{}\n",
            .{
                result.snapshot_stake_mark_pools_primed,
                result.snapshot_stake_set_pools_primed,
                result.snapshot_stake_go_pools_primed,
            },
        );
        std.debug.print("  Local ledger snapshot slot: {}\n", .{result.local_ledger_snapshot_slot});
        std.debug.print("  Immutable blocks replayed: {}\n", .{result.immutable_blocks_replayed});
        std.debug.print("  Stopped by signal: {}\n", .{result.stopped_by_signal});
    } else if (args.len > 1 and std.mem.eql(u8, args[1], "bootstrap")) {
        std.debug.print("Kassadin — Mithril Bootstrap\n", .{});
        std.debug.print("Fetching latest preprod snapshot info...\n\n", .{});

        const info = node.mithril.fetchLatestSnapshot(
            std.heap.page_allocator,
            node.mithril.aggregator_urls.preprod,
        ) catch |err| {
            fatal("Failed to fetch snapshot: {}\n", .{err});
        };
        defer info.deinit(std.heap.page_allocator);

        std.debug.print("Latest snapshot:\n", .{});
        std.debug.print("  Epoch: {}\n", .{info.epoch});
        std.debug.print("  Immutable file: {}\n", .{info.immutable_file_number});
        std.debug.print("  Size: {} MB\n", .{info.size / 1024 / 1024});
        if (info.ancillary_download_url != null) {
            std.debug.print("  Ancillary size: {} MB\n", .{info.ancillary_size / 1024 / 1024});
        }
        std.debug.print("\nTo download and restore, run:\n", .{});
        std.debug.print("  kassadin bootstrap --download\n", .{});

        if (args.len > 2 and std.mem.eql(u8, args[2], "--download")) {
            std.debug.print("\nDownloading and extracting...\n", .{});
            node.mithril.downloadAndExtract(
                std.heap.page_allocator,
                info,
                "db/preprod",
            ) catch |err| {
                fatal("Bootstrap failed: {}\n", .{err});
            };
            std.debug.print("Bootstrap complete! Run 'kassadin bootstrap-sync' to continue from tip.\n", .{});
        }
    } else if (args.len > 1 and std.mem.eql(u8, args[1], "bootstrap-sync")) {
        // Sync forward from Mithril snapshot tip
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
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--validate-dolos")) {
                validation_endpoint = "127.0.0.1:50051";
            } else if (std.mem.eql(u8, args[i], "--dolos-grpc")) {
                if (i + 1 >= args.len) {
                    fatal("Missing endpoint after --dolos-grpc\n", .{});
                }
                validation_endpoint = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--shelley-genesis")) {
                if (i + 1 >= args.len) {
                    fatal("Missing path after --shelley-genesis\n", .{});
                }
                shelley_genesis_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--config")) {
                if (i + 1 >= args.len) {
                    fatal("Missing path after --config\n", .{});
                }
                config_file_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--max-blocks")) {
                if (i + 1 >= args.len) {
                    fatal("Missing value after --max-blocks\n", .{});
                }
                max_blocks = std.fmt.parseInt(u64, args[i + 1], 10) catch {
                    fatal("Invalid --max-blocks value: {s}\n", .{args[i + 1]});
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--topology")) {
                if (i + 1 >= args.len) {
                    fatal("Missing value after --topology\n", .{});
                }
                topology_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--db-path")) {
                if (i + 1 >= args.len) {
                    fatal("Missing value after --db-path\n", .{});
                }
                db_path = args[i + 1];
                i += 1;
            } else {
                fatal("Unknown bootstrap-sync argument: {s}\n", .{args[i]});
            }
        }

        if (config_file_path) |path| {
            var parsed = node.config.parseCardanoNodeConfig(std.heap.page_allocator, path) catch |err| {
                fatal("Config parse failed: {}\n", .{err});
            };
            defer parsed.deinit(std.heap.page_allocator);

            if (parsed.shelley_genesis_path) |genesis_path| {
                shelley_genesis_path = std.heap.page_allocator.dupe(u8, genesis_path) catch {
                    fatal("Failed to copy Shelley genesis path from config\n", .{});
                };
            }
        }

        if (topology_path) |path| {
            parsed_topology = node.topology.parseTopology(std.heap.page_allocator, path) catch |err| {
                fatal("Topology parse failed: {}\n", .{err});
            };
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
        ) catch |err| {
            fatal("Bootstrap sync failed: {}\n", .{err});
        };

        std.debug.print("\nBootstrap sync complete:\n", .{});
        std.debug.print("  Snapshot tip: block={}, slot={}\n", .{ result.snapshot_tip_block, result.snapshot_tip_slot });
        std.debug.print("  Headers synced forward: {}\n", .{result.headers_synced_forward});
        std.debug.print("  Blocks parsed: {}\n", .{result.blocks_parsed});
        std.debug.print("  Blocks added to chain: {}\n", .{result.blocks_added_to_chain});
        std.debug.print("  Transactions parsed: {}\n", .{result.txs_parsed});
        std.debug.print("  Validation enabled: {}\n", .{result.validation_enabled});
        std.debug.print("  Base UTxOs primed: {}\n", .{result.base_utxos_primed});
        std.debug.print("  Snapshot reward accounts primed: {}\n", .{result.snapshot_reward_accounts_primed});
        std.debug.print("  Snapshot stake deposits primed: {}\n", .{result.snapshot_stake_deposits_primed});
        std.debug.print(
            "  Snapshot stake pools (mark/set/go): {}/{}/{}\n",
            .{
                result.snapshot_stake_mark_pools_primed,
                result.snapshot_stake_set_pools_primed,
                result.snapshot_stake_go_pools_primed,
            },
        );
        std.debug.print("  Local ledger snapshot slot: {}\n", .{result.local_ledger_snapshot_slot});
        std.debug.print("  Immutable blocks replayed: {}\n", .{result.immutable_blocks_replayed});
        std.debug.print("  Invalid blocks: {}\n", .{result.invalid_blocks});
        std.debug.print("  Network tip: block={}, slot={}\n", .{ result.network_tip_block, result.network_tip_slot });
        std.debug.print("  Rollbacks: {}\n", .{result.rollbacks});
        std.debug.print("  Stopped by signal: {}\n", .{result.stopped_by_signal});
    } else if (args.len > 1 and std.mem.eql(u8, args[1], "dolos-tip")) {
        var endpoint: []const u8 = "127.0.0.1:50051";

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--dolos-grpc")) {
                if (i + 1 >= args.len) {
                    fatal("Missing endpoint after --dolos-grpc\n", .{});
                }
                endpoint = args[i + 1];
                i += 1;
            } else {
                fatal("Unknown dolos-tip argument: {s}\n", .{args[i]});
            }
        }

        std.debug.print("Kassadin — Dolos Tip\n\n", .{});
        var client = network.dolos_grpc_client.Client.init(std.heap.page_allocator, endpoint) catch |err| {
            fatal("Failed to initialize Dolos gRPC client: {}\n", .{err});
        };
        defer client.deinit();

        const tip = client.readTip() catch |err| {
            fatal("Failed to read Dolos tip: {}\n", .{err});
        };

        std.debug.print("Dolos tip:\n", .{});
        std.debug.print("  Slot: {}\n", .{tip.slot});
        std.debug.print("  Height: {}\n", .{tip.height});
        std.debug.print(
            "  Hash: {x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n",
            .{
                tip.hash[0], tip.hash[1], tip.hash[2], tip.hash[3],
                tip.hash[4], tip.hash[5], tip.hash[6], tip.hash[7],
                tip.hash[8], tip.hash[9], tip.hash[10], tip.hash[11],
                tip.hash[12], tip.hash[13], tip.hash[14], tip.hash[15],
                tip.hash[16], tip.hash[17], tip.hash[18], tip.hash[19],
                tip.hash[20], tip.hash[21], tip.hash[22], tip.hash[23],
                tip.hash[24], tip.hash[25], tip.hash[26], tip.hash[27],
                tip.hash[28], tip.hash[29], tip.hash[30], tip.hash[31],
            },
        );
    } else {
        std.debug.print("Kassadin — Cardano Node in Zig\n", .{});
        std.debug.print("Version: 0.1.0\n", .{});
        std.debug.print("\nUsage:\n", .{});
        std.debug.print("  kassadin bootstrap           Show latest Mithril snapshot info\n", .{});
        std.debug.print("  kassadin bootstrap --download Download and restore snapshot\n", .{});
        std.debug.print("  kassadin bootstrap-sync [--db-path path] [--config config.json] [--topology topology.json] [--shelley-genesis path] [--max-blocks N] [--validate-dolos] [--dolos-grpc host:port]\n", .{});
        std.debug.print("  kassadin sync [--network preview|preprod] [--db-path path] [--max-headers N] [--config config.json] [--topology topology.json] [--byron-genesis path] [--shelley-genesis path] [--socket-path path]\n", .{});
        std.debug.print("  kassadin dolos-tip [--dolos-grpc host:port]\n", .{});
        std.debug.print("  kassadin                      Show this help\n", .{});
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
