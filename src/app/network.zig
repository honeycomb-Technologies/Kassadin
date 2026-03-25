const protocol = @import("../network/protocol.zig");
const mithril = @import("../node/mithril.zig");

pub const NetworkId = enum {
    preprod,
    preview,
    mainnet,
};

pub const Availability = enum {
    active,
    coming_soon,
};

pub const NetworkInfo = struct {
    id: NetworkId,
    display_name: []const u8,
    availability: Availability,
    network_magic: u32,
    mithril_aggregator_url: ?[]const u8,
    bundle_base_url: []const u8,
    default_peer_host: []const u8,
    default_peer_port: u16,
};

pub const preprod = NetworkInfo{
    .id = .preprod,
    .display_name = "Preprod",
    .availability = .active,
    .network_magic = protocol.NetworkMagic.preprod,
    .mithril_aggregator_url = mithril.aggregator_urls.preprod,
    .bundle_base_url = "https://book.play.dev.cardano.org/environments/preprod",
    .default_peer_host = "preprod-node.play.dev.cardano.org",
    .default_peer_port = 3001,
};

pub const preview = NetworkInfo{
    .id = .preview,
    .display_name = "Preview",
    .availability = .coming_soon,
    .network_magic = protocol.NetworkMagic.preview,
    .mithril_aggregator_url = mithril.aggregator_urls.preview,
    .bundle_base_url = "https://book.play.dev.cardano.org/environments/preview",
    .default_peer_host = "preview-node.play.dev.cardano.org",
    .default_peer_port = 3001,
};

pub const mainnet = NetworkInfo{
    .id = .mainnet,
    .display_name = "Mainnet",
    .availability = .coming_soon,
    .network_magic = protocol.NetworkMagic.mainnet,
    .mithril_aggregator_url = mithril.aggregator_urls.mainnet,
    .bundle_base_url = "https://book.world.dev.cardano.org/environments/mainnet",
    .default_peer_host = "backbone.cardano.iog.io",
    .default_peer_port = 3001,
};

pub fn all() []const NetworkInfo {
    return &.{ preprod, preview, mainnet };
}

pub fn get(id: NetworkId) *const NetworkInfo {
    return switch (id) {
        .preprod => &preprod,
        .preview => &preview,
        .mainnet => &mainnet,
    };
}

pub fn parseId(raw: []const u8) ?NetworkId {
    if (std.mem.eql(u8, raw, "preprod")) return .preprod;
    if (std.mem.eql(u8, raw, "preview")) return .preview;
    if (std.mem.eql(u8, raw, "mainnet")) return .mainnet;
    return null;
}

const std = @import("std");
