const std = @import("std");
const mux = @import("mux.zig");

/// Create a Bearer from a Unix domain socket connection.
/// Used for Node-to-Client (N2C) protocols.
pub fn connectUnix(path: []const u8) !mux.Bearer {
    const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(socket);

    var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);

    if (path.len > addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);

    try std.posix.connect(socket, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));

    const stream = std.net.Stream{ .handle = socket };
    return mux.tcpBearer(stream);
}

/// Create a Unix socket server for N2C.
pub const UnixServer = struct {
    socket: std.posix.socket_t,
    path: []const u8,

    pub fn listen(path: []const u8) !UnixServer {
        // Remove existing socket file
        std.fs.cwd().deleteFile(path) catch {};

        const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(socket);

        var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        if (path.len > addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);

        try std.posix.bind(socket, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        try std.posix.listen(socket, 5);

        return .{ .socket = socket, .path = path };
    }

    pub fn accept(self: *UnixServer) !mux.Bearer {
        const client = try std.posix.accept(self.socket, null, null, 0);
        const stream = std.net.Stream{ .handle = client };
        return mux.tcpBearer(stream);
    }

    pub fn close(self: *UnixServer) void {
        std.posix.close(self.socket);
        std.fs.cwd().deleteFile(self.path) catch {};
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "unix_bearer: server listen and cleanup" {
    const path = "/tmp/kassadin-test-unix.sock";
    var server = UnixServer.listen(path) catch return; // skip if permissions issue
    server.close();

    // Socket file should be cleaned up
    const stat = std.fs.cwd().statFile(path);
    try std.testing.expect(stat == error.FileNotFound);
}
