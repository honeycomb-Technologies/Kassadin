const std = @import("std");
const Ed25519 = @import("ed25519.zig").Ed25519;
const KES = @import("kes_sum.zig").KES;

/// Operational Certificate — binds a pool's cold key to a KES hot key.
pub const OperationalCert = struct {
    hot_vkey: KES.VerKey, // 32 bytes — KES verification key
    sequence_number: u64, // Monotonically increasing counter
    kes_period: u32, // Starting KES period for this cert
    cold_key_signature: Ed25519.Signature, // 64 bytes — cold key sig over payload

    /// Construct from raw parts.
    pub fn fromRawParts(
        hot_vkey: [32]u8,
        seq_no: u64,
        kes_period: u32,
        cold_sig: [64]u8,
    ) OperationalCert {
        return .{
            .hot_vkey = hot_vkey,
            .sequence_number = seq_no,
            .kes_period = kes_period,
            .cold_key_signature = cold_sig,
        };
    }

    /// Build the payload that the cold key signs:
    /// hot_vkey(32) ++ sequence_number(8 BE) ++ kes_period(8 BE)
    pub fn signedPayload(self: *const OperationalCert) [48]u8 {
        var buf: [48]u8 = undefined;
        @memcpy(buf[0..32], &self.hot_vkey);
        std.mem.writeInt(u64, buf[32..40], self.sequence_number, .big);
        std.mem.writeInt(u64, buf[40..48], @as(u64, self.kes_period), .big);
        return buf;
    }

    /// Validate that the cold key signature is correct.
    pub fn validate(self: *const OperationalCert, cold_vkey: Ed25519.VerKey) bool {
        const payload = self.signedPayload();
        return Ed25519.verify(&payload, self.cold_key_signature, cold_vkey);
    }

    /// Check if a given KES period is within the valid range for this cert.
    pub fn isKesValidAt(self: *const OperationalCert, current_kes_period: u32, max_kes_evolutions: u32) bool {
        return current_kes_period >= self.kes_period and
            current_kes_period < self.kes_period + max_kes_evolutions;
    }

    /// Create a new operational certificate (for testing / key management).
    pub fn create(
        hot_vkey: KES.VerKey,
        seq_no: u64,
        kes_period: u32,
        cold_sk: Ed25519.SignKey,
    ) !OperationalCert {
        var cert = OperationalCert{
            .hot_vkey = hot_vkey,
            .sequence_number = seq_no,
            .kes_period = kes_period,
            .cold_key_signature = undefined,
        };
        const payload = cert.signedPayload();
        cert.cold_key_signature = Ed25519.sign(&payload, cold_sk) catch return error.SignFailed;
        return cert;
    }
};

// ──────────────────────────────────── Tests ────────────────────────────────────

test "opcert: create and validate" {
    // Generate cold key
    const cold_seed = [_]u8{0x01} ** 32;
    const cold_kp = try Ed25519.keyFromSeed(cold_seed);

    // Generate KES key
    const kes_seed = [_]u8{0x02} ** 32;
    const kes_kp = try KES.generate(kes_seed);

    // Create operational certificate
    const cert = try OperationalCert.create(kes_kp.vk, 0, 100, cold_kp.sk);

    // Validate with correct cold key
    try std.testing.expect(cert.validate(cold_kp.vk));
}

test "opcert: wrong cold key fails validation" {
    const cold_seed_a = [_]u8{0x01} ** 32;
    const cold_kp_a = try Ed25519.keyFromSeed(cold_seed_a);
    const cold_seed_b = [_]u8{0x02} ** 32;
    const cold_kp_b = try Ed25519.keyFromSeed(cold_seed_b);

    const kes_seed = [_]u8{0x03} ** 32;
    const kes_kp = try KES.generate(kes_seed);

    const cert = try OperationalCert.create(kes_kp.vk, 0, 100, cold_kp_a.sk);
    try std.testing.expect(!cert.validate(cold_kp_b.vk));
}

test "opcert: tampered sequence number fails" {
    const cold_seed = [_]u8{0x04} ** 32;
    const cold_kp = try Ed25519.keyFromSeed(cold_seed);
    const kes_seed = [_]u8{0x05} ** 32;
    const kes_kp = try KES.generate(kes_seed);

    var cert = try OperationalCert.create(kes_kp.vk, 42, 0, cold_kp.sk);
    cert.sequence_number = 43; // tamper
    try std.testing.expect(!cert.validate(cold_kp.vk));
}

test "opcert: kes period range check" {
    const cert = OperationalCert.fromRawParts(
        [_]u8{0} ** 32,
        0,
        100, // starts at KES period 100
        [_]u8{0} ** 64,
    );

    // max_kes_evolutions = 62 (mainnet)
    try std.testing.expect(cert.isKesValidAt(100, 62)); // at start
    try std.testing.expect(cert.isKesValidAt(130, 62)); // mid-range
    try std.testing.expect(cert.isKesValidAt(161, 62)); // last valid
    try std.testing.expect(!cert.isKesValidAt(162, 62)); // expired
    try std.testing.expect(!cert.isKesValidAt(99, 62)); // before start
}
