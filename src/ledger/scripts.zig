const std = @import("std");
const Decoder = @import("../cbor/decoder.zig").Decoder;
const types = @import("../types.zig");
const Blake2b224 = @import("../crypto/hash.zig").Blake2b224;
const Blake2b256 = @import("../crypto/hash.zig").Blake2b256;

pub const KeyHash = types.KeyHash;
pub const SlotNo = types.SlotNo;
pub const Hash28 = types.Hash28;

/// Native script (Shelley multi-sig + Allegra timelock extensions).
pub const NativeScript = union(enum) {
    sig: KeyHash, // tag 0: requires signature from keyhash
    all: []const NativeScript, // tag 1: all sub-scripts must pass
    any: []const NativeScript, // tag 2: any sub-script must pass
    n_of_k: struct { n: u64, scripts: []const NativeScript }, // tag 3
    invalid_before: SlotNo, // tag 4: valid from this slot (Allegra+)
    invalid_hereafter: SlotNo, // tag 5: valid until this slot (Allegra+)
};

/// Evaluate a native script against a set of available signatures and current slot.
pub fn evaluateNativeScript(
    script: NativeScript,
    available_sigs: []const KeyHash,
    current_slot: SlotNo,
) bool {
    switch (script) {
        .sig => |required_key| {
            for (available_sigs) |sig| {
                if (std.mem.eql(u8, &sig, &required_key)) return true;
            }
            return false;
        },
        .all => |sub_scripts| {
            for (sub_scripts) |sub| {
                if (!evaluateNativeScript(sub, available_sigs, current_slot)) return false;
            }
            return true;
        },
        .any => |sub_scripts| {
            for (sub_scripts) |sub| {
                if (evaluateNativeScript(sub, available_sigs, current_slot)) return true;
            }
            return false;
        },
        .n_of_k => |nk| {
            var count: u64 = 0;
            for (nk.scripts) |sub| {
                if (evaluateNativeScript(sub, available_sigs, current_slot)) {
                    count += 1;
                    if (count >= nk.n) return true;
                }
            }
            return false;
        },
        .invalid_before => |slot| {
            return current_slot >= slot;
        },
        .invalid_hereafter => |slot| {
            return current_slot < slot;
        },
    }
}

/// Compute script hash: Blake2b-224 of (0x00 || CBOR-encoded-script) for native scripts.
pub fn nativeScriptHash(script_cbor: []const u8) Hash28 {
    var buf: [1 + 16384]u8 = undefined;
    buf[0] = 0x00; // Native script language tag
    if (script_cbor.len <= 16384) {
        @memcpy(buf[1 .. 1 + script_cbor.len], script_cbor);
        return Blake2b224.hash(buf[0 .. 1 + script_cbor.len]);
    }
    // For larger scripts, use incremental hashing
    var state = Blake2b224.State.init();
    state.update(&[_]u8{0x00});
    state.update(script_cbor);
    return state.final();
}

/// Script language tags for script hash computation.
pub const ScriptLanguage = enum(u8) {
    native = 0x00,
    plutus_v1 = 0x01,
    plutus_v2 = 0x02,
    plutus_v3 = 0x03,
};

/// Compute a Plutus script hash: Blake2b-224 of (language_tag || flat-encoded-script)
pub fn plutusScriptHash(language: ScriptLanguage, script_bytes: []const u8) Hash28 {
    var state = Blake2b224.State.init();
    state.update(&[_]u8{@intFromEnum(language)});
    state.update(script_bytes);
    return state.final();
}

// ──────────────────────────────────── Tests ────────────────────────────────────

test "scripts: sig script — key present" {
    const key = [_]u8{0xaa} ** 28;
    const script = NativeScript{ .sig = key };
    const sigs = [_]KeyHash{key};
    try std.testing.expect(evaluateNativeScript(script, &sigs, 100));
}

test "scripts: sig script — key absent" {
    const key = [_]u8{0xaa} ** 28;
    const wrong_key = [_]u8{0xbb} ** 28;
    const script = NativeScript{ .sig = key };
    const sigs = [_]KeyHash{wrong_key};
    try std.testing.expect(!evaluateNativeScript(script, &sigs, 100));
}

test "scripts: all — all present" {
    const k1 = [_]u8{0x01} ** 28;
    const k2 = [_]u8{0x02} ** 28;
    const subs = [_]NativeScript{
        .{ .sig = k1 },
        .{ .sig = k2 },
    };
    const script = NativeScript{ .all = &subs };
    const sigs = [_]KeyHash{ k1, k2 };
    try std.testing.expect(evaluateNativeScript(script, &sigs, 100));
}

test "scripts: all — one missing" {
    const k1 = [_]u8{0x01} ** 28;
    const k2 = [_]u8{0x02} ** 28;
    const subs = [_]NativeScript{
        .{ .sig = k1 },
        .{ .sig = k2 },
    };
    const script = NativeScript{ .all = &subs };
    const sigs = [_]KeyHash{k1}; // k2 missing
    try std.testing.expect(!evaluateNativeScript(script, &sigs, 100));
}

test "scripts: any — one present" {
    const k1 = [_]u8{0x01} ** 28;
    const k2 = [_]u8{0x02} ** 28;
    const subs = [_]NativeScript{
        .{ .sig = k1 },
        .{ .sig = k2 },
    };
    const script = NativeScript{ .any = &subs };
    const sigs = [_]KeyHash{k2}; // only k2
    try std.testing.expect(evaluateNativeScript(script, &sigs, 100));
}

test "scripts: n_of_k — 2 of 3" {
    const k1 = [_]u8{0x01} ** 28;
    const k2 = [_]u8{0x02} ** 28;
    const k3 = [_]u8{0x03} ** 28;
    const subs = [_]NativeScript{
        .{ .sig = k1 },
        .{ .sig = k2 },
        .{ .sig = k3 },
    };
    const script = NativeScript{ .n_of_k = .{ .n = 2, .scripts = &subs } };

    const sigs_pass = [_]KeyHash{ k1, k3 }; // 2 of 3
    try std.testing.expect(evaluateNativeScript(script, &sigs_pass, 100));

    const sigs_fail = [_]KeyHash{k2}; // 1 of 3
    try std.testing.expect(!evaluateNativeScript(script, &sigs_fail, 100));
}

test "scripts: timelock — invalid_before" {
    const script = NativeScript{ .invalid_before = 50 };
    try std.testing.expect(!evaluateNativeScript(script, &[_]KeyHash{}, 49));
    try std.testing.expect(evaluateNativeScript(script, &[_]KeyHash{}, 50));
    try std.testing.expect(evaluateNativeScript(script, &[_]KeyHash{}, 100));
}

test "scripts: timelock — invalid_hereafter" {
    const script = NativeScript{ .invalid_hereafter = 100 };
    try std.testing.expect(evaluateNativeScript(script, &[_]KeyHash{}, 99));
    try std.testing.expect(!evaluateNativeScript(script, &[_]KeyHash{}, 100));
    try std.testing.expect(!evaluateNativeScript(script, &[_]KeyHash{}, 200));
}

test "scripts: combined — sig + timelock" {
    const key = [_]u8{0xaa} ** 28;
    const subs = [_]NativeScript{
        .{ .sig = key },
        .{ .invalid_before = 50 },
        .{ .invalid_hereafter = 200 },
    };
    const script = NativeScript{ .all = &subs };

    // Valid: key present and within time window
    const sigs = [_]KeyHash{key};
    try std.testing.expect(evaluateNativeScript(script, &sigs, 100));

    // Invalid: too early
    try std.testing.expect(!evaluateNativeScript(script, &sigs, 40));

    // Invalid: too late
    try std.testing.expect(!evaluateNativeScript(script, &sigs, 200));
}

test "scripts: script hash computation" {
    const fake_script = "test script bytes";
    const hash = nativeScriptHash(fake_script);
    try std.testing.expectEqual(@as(usize, 28), hash.len);

    // Different scripts produce different hashes
    const hash2 = nativeScriptHash("different script");
    try std.testing.expect(!std.mem.eql(u8, &hash, &hash2));
}

test "scripts: plutus script hash" {
    const fake_script = "plutus flat bytes";
    const v1_hash = plutusScriptHash(.plutus_v1, fake_script);
    const v2_hash = plutusScriptHash(.plutus_v2, fake_script);
    const v3_hash = plutusScriptHash(.plutus_v3, fake_script);

    // Different language tags produce different hashes
    try std.testing.expect(!std.mem.eql(u8, &v1_hash, &v2_hash));
    try std.testing.expect(!std.mem.eql(u8, &v2_hash, &v3_hash));
}
