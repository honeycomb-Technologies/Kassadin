const std = @import("std");

// Import from the main kassadin module
const kassadin = @import("kassadin");
const mux = kassadin.network.mux;
const handshake = kassadin.network.handshake;
const protocol = kassadin.network.protocol;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Connecting to preview-node.play.dev.cardano.org:3001...\n", .{});

    const stream = std.net.tcpConnectToHost(allocator, "preview-node.play.dev.cardano.org", 3001) catch |err| {
        try stdout.print("Connection failed: {}\n", .{err});
        return;
    };
    defer stream.close();

    try stdout.print("Connected. Performing N2N handshake (preview magic=2)...\n", .{});

    var bearer = mux.tcpBearer(stream);

    const result = handshake.performHandshake(allocator, &bearer, protocol.NetworkMagic.preview) catch |err| {
        try stdout.print("Handshake error: {}\n", .{err});
        return;
    };

    switch (result) {
        .accepted => |a| {
            try stdout.print("HANDSHAKE ACCEPTED!\n", .{});
            try stdout.print("  Version: {}\n", .{a.version});
            try stdout.print("  Magic: {}\n", .{a.version_data.network_magic});
            try stdout.print("  Initiator only: {}\n", .{a.version_data.initiator_only});
            try stdout.print("  Peer sharing: {}\n", .{@intFromEnum(a.version_data.peer_sharing)});

            if (a.version_data.network_magic != protocol.NetworkMagic.preview) {
                try stdout.print("ERROR: Wrong magic! Expected 2, got {}\n", .{a.version_data.network_magic});
                std.process.exit(1);
            }
            try stdout.print("\nPhase 1 live validation: HANDSHAKE PASSED\n", .{});
        },
        .refused => |r| {
            switch (r) {
                .version_mismatch => try stdout.print("REFUSED: Version mismatch\n", .{}),
                .decode_error => |msg| try stdout.print("REFUSED: Decode error: {s}\n", .{msg}),
                .refused => |msg| try stdout.print("REFUSED: {s}\n", .{msg}),
            }
            std.process.exit(1);
        },
    }
}
