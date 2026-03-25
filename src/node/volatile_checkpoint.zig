const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../types.zig");

pub const SlotNo = types.SlotNo;
pub const BlockNo = types.BlockNo;
pub const HeaderHash = types.HeaderHash;
pub const Point = types.Point;

const checkpoint_version: u32 = 1;
const max_blocks: u32 = 8192;
const max_file_size: usize = 512 * 1024 * 1024;

pub const AnchorPoint = struct {
    point: Point,
    block_no: BlockNo,
};

pub const Anchor = union(enum) {
    origin: void,
    point: AnchorPoint,
};

pub const SaveBlock = struct {
    hash: HeaderHash,
    slot: SlotNo,
    block_no: BlockNo,
    prev_hash: ?HeaderHash,
    data: []const u8,
};

pub const StoredBlock = struct {
    hash: HeaderHash,
    slot: SlotNo,
    block_no: BlockNo,
    prev_hash: ?HeaderHash,
    data: []u8,
};

pub const LoadResult = struct {
    anchor: Anchor,
    blocks: []StoredBlock,

    pub fn deinit(self: *LoadResult, allocator: Allocator) void {
        for (self.blocks) |block| allocator.free(block.data);
        allocator.free(self.blocks);
    }
};

fn checkpointPath(allocator: Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/volatile.resume", .{db_path});
}

pub fn delete(allocator: Allocator, db_path: []const u8) !void {
    const path = try checkpointPath(allocator, db_path);
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn anchorEql(a: Anchor, b: Anchor) bool {
    return switch (a) {
        .origin => switch (b) {
            .origin => true,
            .point => false,
        },
        .point => |a_point| switch (b) {
            .origin => false,
            .point => |b_point| a_point.block_no == b_point.block_no and Point.eql(a_point.point, b_point.point),
        },
    };
}

fn writeAnchor(writer: anytype, anchor: Anchor) !void {
    switch (anchor) {
        .origin => try writer.writeByte(0),
        .point => |point| {
            try writer.writeByte(1);
            try writer.writeInt(u64, point.point.slot, .big);
            try writer.writeAll(&point.point.hash);
            try writer.writeInt(u64, point.block_no, .big);
        },
    }
}

fn readAnchor(reader: anytype) !Anchor {
    return switch (try reader.readByte()) {
        0 => .{ .origin = {} },
        1 => .{ .point = .{
            .point = .{
                .slot = try reader.readInt(u64, .big),
                .hash = blk: {
                    var hash: HeaderHash = undefined;
                    try reader.readNoEof(&hash);
                    break :blk hash;
                },
            },
            .block_no = try reader.readInt(u64, .big),
        } },
        else => error.InvalidCheckpoint,
    };
}

pub fn save(
    allocator: Allocator,
    db_path: []const u8,
    anchor: Anchor,
    blocks: []const SaveBlock,
) !void {
    const path = try checkpointPath(allocator, db_path);
    defer allocator.free(path);

    if (blocks.len == 0) {
        std.fs.cwd().deleteFile(path) catch {};
        return;
    }

    std.fs.cwd().makePath(db_path) catch {};

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.ensureTotalCapacity(allocator, 64 + blocks.len * 128);
    const writer = bytes.writer(allocator);

    try writer.writeInt(u32, checkpoint_version, .big);
    try writeAnchor(writer, anchor);
    try writer.writeInt(u32, @intCast(blocks.len), .big);

    for (blocks) |block| {
        try writer.writeInt(u64, block.slot, .big);
        try writer.writeInt(u64, block.block_no, .big);
        try writer.writeAll(&block.hash);
        if (block.prev_hash) |prev_hash| {
            try writer.writeByte(1);
            try writer.writeAll(&prev_hash);
        } else {
            try writer.writeByte(0);
        }
        try writer.writeInt(u32, @intCast(block.data.len), .big);
        try writer.writeAll(block.data);
    }

    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = bytes.items,
    });
}

pub fn load(
    allocator: Allocator,
    db_path: []const u8,
    expected_anchor: Anchor,
) !?LoadResult {
    const path = try checkpointPath(allocator, db_path);
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, max_file_size) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(data);

    var stream = std.io.fixedBufferStream(data);
    const reader = stream.reader();

    const version = try reader.readInt(u32, .big);
    if (version != checkpoint_version) return null;

    const anchor = try readAnchor(reader);
    if (!anchorEql(anchor, expected_anchor)) return null;

    const count = try reader.readInt(u32, .big);
    if (count > max_blocks) return error.InvalidCheckpoint;

    const block_count: usize = count;
    const blocks = try allocator.alloc(StoredBlock, block_count);
    var loaded_count: usize = 0;
    errdefer {
        for (blocks[0..loaded_count]) |block| allocator.free(block.data);
        allocator.free(blocks);
    }

    while (loaded_count < block_count) : (loaded_count += 1) {
        const slot = try reader.readInt(u64, .big);
        const block_no = try reader.readInt(u64, .big);
        var hash: HeaderHash = undefined;
        try reader.readNoEof(&hash);
        const has_prev = try reader.readByte();
        const prev_hash = switch (has_prev) {
            0 => null,
            1 => blk: {
                var prev: HeaderHash = undefined;
                try reader.readNoEof(&prev);
                break :blk prev;
            },
            else => return error.InvalidCheckpoint,
        };
        const data_len = try reader.readInt(u32, .big);
        const block_data = try allocator.alloc(u8, data_len);
        reader.readNoEof(block_data) catch |err| {
            allocator.free(block_data);
            return err;
        };
        blocks[loaded_count] = .{
            .hash = hash,
            .slot = slot,
            .block_no = block_no,
            .prev_hash = prev_hash,
            .data = block_data,
        };
    }

    return .{
        .anchor = anchor,
        .blocks = blocks,
    };
}

test "volatile checkpoint: round trip with anchored blocks" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-volatile-checkpoint";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const blocks = [_]SaveBlock{
        .{
            .hash = [_]u8{0x11} ** 32,
            .slot = 101,
            .block_no = 51,
            .prev_hash = [_]u8{0x10} ** 32,
            .data = "block-1",
        },
        .{
            .hash = [_]u8{0x22} ** 32,
            .slot = 102,
            .block_no = 52,
            .prev_hash = [_]u8{0x11} ** 32,
            .data = "block-2",
        },
    };
    const anchor: Anchor = .{ .point = .{
        .point = .{ .slot = 100, .hash = [_]u8{0xaa} ** 32 },
        .block_no = 50,
    } };

    try save(allocator, path, anchor, &blocks);
    var loaded = (try load(allocator, path, anchor)).?;
    defer loaded.deinit(allocator);

    try std.testing.expect(anchorEql(anchor, loaded.anchor));
    try std.testing.expectEqual(@as(usize, 2), loaded.blocks.len);
    try std.testing.expectEqual(@as(u64, 52), loaded.blocks[1].block_no);
    try std.testing.expectEqualSlices(u8, "block-2", loaded.blocks[1].data);
}

test "volatile checkpoint: anchor mismatch returns null" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-volatile-checkpoint-mismatch";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const anchor: Anchor = .{ .point = .{
        .point = .{ .slot = 100, .hash = [_]u8{0xaa} ** 32 },
        .block_no = 50,
    } };
    const blocks = [_]SaveBlock{.{
        .hash = [_]u8{0x11} ** 32,
        .slot = 101,
        .block_no = 51,
        .prev_hash = [_]u8{0xaa} ** 32,
        .data = "block-1",
    }};

    try save(allocator, path, anchor, &blocks);

    const other_anchor: Anchor = .{ .origin = {} };
    const loaded = try load(allocator, path, other_anchor);
    try std.testing.expect(loaded == null);
}

test "volatile checkpoint: empty save removes file" {
    const allocator = std.testing.allocator;
    const path = "/tmp/kassadin-volatile-checkpoint-empty";

    std.fs.cwd().deleteTree(path) catch {};
    defer std.fs.cwd().deleteTree(path) catch {};

    const anchor: Anchor = .{ .origin = {} };
    const blocks = [_]SaveBlock{.{
        .hash = [_]u8{0x11} ** 32,
        .slot = 1,
        .block_no = 1,
        .prev_hash = null,
        .data = "block",
    }};

    try save(allocator, path, anchor, &blocks);
    try save(allocator, path, anchor, &.{});
    const loaded = try load(allocator, path, anchor);
    try std.testing.expect(loaded == null);
}
