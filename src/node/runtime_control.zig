const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

var stop_requested = std.atomic.Value(bool).init(false);

pub fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) return;

    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleStopSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO,
    };

    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

pub fn resetStopRequested() void {
    stop_requested.store(false, .seq_cst);
}

pub fn requestStop() void {
    stop_requested.store(true, .seq_cst);
}

pub fn stopRequested() bool {
    return stop_requested.load(.seq_cst);
}

fn handleStopSignal(sig: i32, info: *const posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    _ = info;
    _ = ctx_ptr;

    if (sig == posix.SIG.INT or sig == posix.SIG.TERM) {
        requestStop();
    }
}

test "runtime_control: stop flag round-trip" {
    resetStopRequested();
    try std.testing.expect(!stopRequested());
    requestStop();
    try std.testing.expect(stopRequested());
    resetStopRequested();
    try std.testing.expect(!stopRequested());
}
