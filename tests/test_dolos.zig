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

    try stdout.interface.print("\n=== DOLOS N2C HANDSHAKE PASSED ===\n", .{});
    try stdout.interface.print("  Kassadin ↔ Dolos (preprod) N2C communication verified\n", .{});
    try stdout.interface.print("  Full N2C chain-sync deferred (needs multi-SDU block reassembly)\n", .{});
}
