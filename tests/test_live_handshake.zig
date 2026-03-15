const std = @import("std");
const kassadin = @import("kassadin");
const mux = kassadin.network.mux;
const handshake = kassadin.network.handshake;
const chainsync = kassadin.network.chainsync;
const keepalive = kassadin.network.keepalive;
const protocol = kassadin.network.protocol;
const peer_mod = kassadin.network.peer;

const preview_host = "preview-node.play.dev.cardano.org";
const preview_port = 3001;
const preview_magic = protocol.NetworkMagic.preview;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    try stdout.interface.print("=== Kassadin Phase 1 Live Validation ===\n\n", .{});

    // ── Test 1: Handshake ──
    try stdout.interface.print("[Test 1] Handshake with preview node...\n", .{});
    var p = peer_mod.Peer.connect(allocator, preview_host, preview_port, preview_magic) catch |err| {
        try stdout.interface.print("  FAILED: {}\n", .{err});
        std.process.exit(1);
    };
    defer p.close();

    try stdout.interface.print("  PASSED: Handshake accepted, version {}\n", .{p.negotiated_version.?});

    // ── Test 2: Chain-Sync — find intersect from genesis ──
    try stdout.interface.print("\n[Test 2] Chain-Sync FindIntersect (genesis)...\n", .{});
    const intersect_result = p.chainSyncFindIntersect(&[_]chainsync.Point{}) catch |err| {
        try stdout.interface.print("  FAILED: {}\n", .{err});
        std.process.exit(1);
    };

    switch (intersect_result) {
        .intersect_not_found => |inf| {
            try stdout.interface.print("  PASSED: IntersectNotFound (expected for genesis)\n", .{});
            try stdout.interface.print("  Tip: slot={}, block_no={}\n", .{ inf.tip.slot, inf.tip.block_no });
        },
        .intersect_found => |isf| {
            try stdout.interface.print("  PASSED: IntersectFound at slot={}\n", .{isf.point.slot});
        },
        else => {
            try stdout.interface.print("  FAILED: unexpected response\n", .{});
            std.process.exit(1);
        },
    }

    // ── Test 3: Chain-Sync — follow 10 headers ──
    try stdout.interface.print("\n[Test 3] Chain-Sync RequestNext x10...\n", .{});
    var prev_slot: u64 = 0;
    var headers_received: u32 = 0;

    while (headers_received < 10) {
        const next = p.chainSyncRequestNext() catch |err| {
            try stdout.interface.print("  FAILED at header {}: {}\n", .{ headers_received, err });
            std.process.exit(1);
        };

        switch (next) {
            .roll_forward => |rf| {
                headers_received += 1;
                if (rf.tip.slot < prev_slot and !rf.tip.is_genesis) {
                    try stdout.interface.print("  FAILED: slot decreased! {} < {}\n", .{ rf.tip.slot, prev_slot });
                    std.process.exit(1);
                }
                prev_slot = rf.tip.slot;
                if (headers_received <= 3 or headers_received == 10) {
                    try stdout.interface.print("  Header {}: tip_slot={}, tip_block={}\n", .{
                        headers_received, rf.tip.slot, rf.tip.block_no,
                    });
                }
            },
            .await_reply => {
                try stdout.interface.print("  AwaitReply (caught up to tip, retrying)...\n", .{});
                std.Thread.sleep(1 * std.time.ns_per_s);
            },
            .roll_backward => {
                try stdout.interface.print("  RollBackward (rollback event)\n", .{});
            },
            else => {
                try stdout.interface.print("  FAILED: unexpected message\n", .{});
                std.process.exit(1);
            },
        }
    }
    try stdout.interface.print("  PASSED: {} headers received, slots non-decreasing\n", .{headers_received});

    // ── Test 4: Keep-Alive ──
    try stdout.interface.print("\n[Test 4] Keep-Alive ping (cookie=42)...\n", .{});
    const response_cookie = p.keepAlivePing(42) catch |err| {
        try stdout.interface.print("  FAILED: {}\n", .{err});
        std.process.exit(1);
    };

    if (response_cookie == 42) {
        try stdout.interface.print("  PASSED: Response cookie=42 matches\n", .{});
    } else {
        try stdout.interface.print("  FAILED: Expected cookie=42, got {}\n", .{response_cookie});
        std.process.exit(1);
    }

    // ── Summary ──
    try stdout.interface.print("\n=== ALL LIVE TESTS PASSED ===\n", .{});
    try stdout.interface.print("  Handshake: v{} with magic={}\n", .{ p.negotiated_version.?, preview_magic });
    try stdout.interface.print("  Chain-Sync: {} headers followed\n", .{headers_received});
    try stdout.interface.print("  Keep-Alive: cookie round-trip verified\n", .{});
    try stdout.interface.print("\nPhase 1 networking is validated against the real Cardano preview network.\n", .{});
}
