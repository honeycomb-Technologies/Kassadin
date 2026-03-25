const std = @import("std");

pub const Layout = struct {
    root: []u8,
    state_path: []u8,
    profiles_dir: []u8,
    logs_dir: []u8,
    service_dir: []u8,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.state_path);
        allocator.free(self.profiles_dir);
        allocator.free(self.logs_dir);
        allocator.free(self.service_dir);
    }
};

pub fn resolve(allocator: std.mem.Allocator) !Layout {
    const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home_dir);

    const root = try std.fs.path.join(allocator, &.{ home_dir, ".kassadin" });
    errdefer allocator.free(root);
    const state_path = try std.fs.path.join(allocator, &.{ root, "state.json" });
    errdefer allocator.free(state_path);
    const profiles_dir = try std.fs.path.join(allocator, &.{ root, "profiles" });
    errdefer allocator.free(profiles_dir);
    const logs_dir = try std.fs.path.join(allocator, &.{ root, "logs" });
    errdefer allocator.free(logs_dir);
    const service_dir = try std.fs.path.join(allocator, &.{ root, "service" });
    errdefer allocator.free(service_dir);

    return .{
        .root = root,
        .state_path = state_path,
        .profiles_dir = profiles_dir,
        .logs_dir = logs_dir,
        .service_dir = service_dir,
    };
}

pub fn ensureBaseDirs(layout: *const Layout) !void {
    try std.fs.cwd().makePath(layout.root);
    try std.fs.cwd().makePath(layout.profiles_dir);
    try std.fs.cwd().makePath(layout.logs_dir);
    try std.fs.cwd().makePath(layout.service_dir);
}

pub fn profileRootPath(allocator: std.mem.Allocator, layout: *const Layout, profile_id: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ layout.profiles_dir, profile_id });
}

pub fn profileFilePath(allocator: std.mem.Allocator, layout: *const Layout, profile_id: []const u8) ![]u8 {
    const root = try profileRootPath(allocator, layout, profile_id);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "profile.json" });
}

pub fn defaultDbPath(allocator: std.mem.Allocator, layout: *const Layout, profile_id: []const u8) ![]u8 {
    const root = try profileRootPath(allocator, layout, profile_id);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "db" });
}

pub fn defaultSocketPath(allocator: std.mem.Allocator, layout: *const Layout, profile_id: []const u8) ![]u8 {
    const root = try profileRootPath(allocator, layout, profile_id);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "node.socket" });
}

pub fn defaultNetworkDir(allocator: std.mem.Allocator, layout: *const Layout, profile_id: []const u8) ![]u8 {
    const root = try profileRootPath(allocator, layout, profile_id);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "network" });
}

pub fn defaultLogPath(allocator: std.mem.Allocator, layout: *const Layout) ![]u8 {
    return std.fs.path.join(allocator, &.{ layout.logs_dir, "daemon.log" });
}

pub fn systemdUnitPath(allocator: std.mem.Allocator) ![]u8 {
    const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home_dir);
    return std.fs.path.join(allocator, &.{ home_dir, ".config", "systemd", "user", "kassadin.service" });
}

pub fn launchAgentPath(allocator: std.mem.Allocator) ![]u8 {
    const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home_dir);
    return std.fs.path.join(allocator, &.{ home_dir, "Library", "LaunchAgents", "io.kassadin.daemon.plist" });
}
