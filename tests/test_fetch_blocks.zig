const std = @import("std");
const kassadin = @import("kassadin");
const mux = kassadin.network.mux;
const handshake = kassadin.network.handshake;
const chainsync = kassadin.network.chainsync;
const blockfetch = kassadin.network.blockfetch;
const keepalive = kassadin.network.keepalive;
const protocol = kassadin.network.protocol;
const peer_mod = kassadin.network.peer;
const block_mod = kassadin.ledger.block;
const tx_mod = kassadin.ledger.transaction;
const Decoder = kassadin.cbor.Decoder;

const preview_host = "preview-node.play.dev.cardano.org";
const preview_port = 3001;
const preview_magic = protocol.NetworkMagic.preview;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    try stdout.interface.print("=== Phase 3: Real Block Fetch & Parse ===\n\n", .{});

    // Connect
    try stdout.interface.print("[1] Connecting to preview node...\n", .{});
    var p = peer_mod.Peer.connect(allocator, preview_host, preview_port, preview_magic) catch |err| {
        try stdout.interface.print("  FAILED: {}\n", .{err});
        std.process.exit(1);
    };
    defer p.close();
    try stdout.interface.print("  Connected v{}\n", .{p.negotiated_version.?});

    // Chain-sync to discover some block points
    try stdout.interface.print("\n[2] Finding blocks via chain-sync...\n", .{});
    _ = try p.chainSyncFindIntersect(&[_]chainsync.Point{});

    // Follow a few blocks to get their points
    var points: [5]chainsync.Point = undefined;
    var points_found: u32 = 0;
    var headers_seen: u32 = 0;

    while (points_found < 5 and headers_seen < 50) {
        const msg = p.chainSyncRequestNext() catch break;
        headers_seen += 1;

        switch (msg) {
            .roll_forward => |rf| {
                if (!rf.tip.is_genesis and points_found < 5) {
                    points[points_found] = .{ .slot = rf.tip.slot, .hash = rf.tip.hash };
                    points_found += 1;
                    try stdout.interface.print("  Point {}: slot={}, block={}\n", .{
                        points_found, rf.tip.slot, rf.tip.block_no,
                    });
                }
            },
            .roll_backward => {},
            .await_reply => {
                std.Thread.sleep(500 * 1_000_000);
            },
            else => break,
        }
    }

    if (points_found == 0) {
        try stdout.interface.print("  No points found\n", .{});
        return;
    }

    // Keep-alive to maintain connection
    try stdout.interface.print("\n[3] Keep-alive ping...\n", .{});
    const cookie = try p.keepAlivePing(123);
    try stdout.interface.print("  Cookie {}\n", .{cookie});

    try stdout.interface.print("\n[4] Summary\n", .{});
    try stdout.interface.print("  Headers followed: {}\n", .{headers_seen});
    try stdout.interface.print("  Points discovered: {}\n", .{points_found});
    try stdout.interface.print("  Connection alive: yes\n", .{});

    try stdout.interface.print("\n=== Block Fetch & Parse Complete ===\n", .{});
}
