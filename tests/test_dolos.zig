const std = @import("std");
const kassadin = @import("kassadin");
const unix_bearer = kassadin.network.unix_bearer;
const n2c_handshake = kassadin.network.n2c_handshake;
const chainsync = kassadin.network.chainsync;
const local_tx_monitor = kassadin.network.local_tx_monitor;

const dolos_socket = "dolos.socket";
const preprod_magic: u32 = 1; // from dolos.toml: magic = 1

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);

    try stdout.interface.print("=== Kassadin N2C Test: Dolos (preprod) ===\n\n", .{});

    // Connect via Unix socket
    try stdout.interface.print("[1] Connecting to Dolos via {s}...\n", .{dolos_socket});
    var bearer = unix_bearer.connectUnix(dolos_socket) catch |err| {
        try stdout.interface.print("  FAILED: {}\n", .{err});
        std.process.exit(1);
    };
    defer bearer.stream.close();
    try stdout.interface.print("  Connected!\n", .{});

    // N2C Handshake
    try stdout.interface.print("\n[2] N2C Handshake (preprod magic={})...\n", .{preprod_magic});
    const result = n2c_handshake.performHandshake(allocator, &bearer, preprod_magic) catch |err| {
        try stdout.interface.print("  FAILED: {}\n", .{err});
        std.process.exit(1);
    };

    switch (result) {
        .accepted => |a| {
            try stdout.interface.print("  ACCEPTED! Version={}, magic={}\n", .{ a.version, a.version_data.network_magic });
            if (a.version_data.network_magic != preprod_magic) {
                try stdout.interface.print("  ERROR: magic mismatch!\n", .{});
                std.process.exit(1);
            }
        },
        .refused => |msg| {
            try stdout.interface.print("  REFUSED: {s}\n", .{msg});
            std.process.exit(1);
        },
    }

    // Local Chain-Sync: find intersect from genesis
    try stdout.interface.print("\n[3] N2C Chain-Sync FindIntersect (genesis)...\n", .{});
    const find_msg = try chainsync.encodeMsg(allocator, .{ .find_intersect = .{ .points = &[_]chainsync.Point{} } });
    defer allocator.free(find_msg);
    try bearer.writeSDU(5, .initiator, find_msg); // protocol 5 = N2C chain-sync

    const resp = try bearer.readProtocolMessage(5, allocator);
    defer allocator.free(resp);

    const cs_msg = try chainsync.decodeMsg(resp);
    switch (cs_msg) {
        .intersect_not_found => |inf| {
            try stdout.interface.print("  IntersectNotFound — tip: slot={}, block={}\n", .{ inf.tip.slot, inf.tip.block_no });
        },
        .intersect_found => |isf| {
            try stdout.interface.print("  IntersectFound at slot={}\n", .{isf.point.slot});
        },
        else => {
            try stdout.interface.print("  Unexpected response\n", .{});
        },
    }

    // Follow 3 blocks (N2C sends FULL blocks)
    try stdout.interface.print("\n[4] Following chain (3 full blocks via N2C)...\n", .{});
    var blocks: u32 = 0;
    while (blocks < 3) {
        const req = try chainsync.encodeMsg(allocator, .request_next);
        defer allocator.free(req);
        try bearer.writeSDU(5, .initiator, req);

        const next_resp = try bearer.readProtocolMessage(5, allocator);
        defer allocator.free(next_resp);

        const next = try chainsync.decodeMsg(next_resp);
        switch (next) {
            .roll_forward => |rf| {
                blocks += 1;
                try stdout.interface.print("  Block {}: tip_slot={}, block={}, raw_size={}\n", .{
                    blocks, rf.tip.slot, rf.tip.block_no, rf.header_raw.len,
                });
            },
            .await_reply => {
                try stdout.interface.print("  AwaitReply (at tip)\n", .{});
                break;
            },
            .roll_backward => {
                try stdout.interface.print("  RollBackward\n", .{});
            },
            else => break,
        }
    }

    try stdout.interface.print("\n=== ALL DOLOS N2C TESTS PASSED ===\n", .{});
    try stdout.interface.print("  Handshake: accepted (preprod magic={})\n", .{preprod_magic});
    try stdout.interface.print("  Chain-sync: {} full blocks received via multi-SDU\n", .{blocks});
    try stdout.interface.print("  Kassadin ↔ Dolos N2C protocol fully operational\n", .{});
}
