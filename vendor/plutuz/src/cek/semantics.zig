//! Builtin semantics variant based on language/protocol version.

/// - A: V1/V2 scripts before Chang hard fork (protocol < 9)
/// - B: V1/V2 scripts after Chang hard fork (protocol >= 9)
/// - C: V3+ scripts (default)
pub const SemanticsVariant = enum {
    a,
    b,
    c,
};
