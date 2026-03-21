//! Machine state - the current step in CEK evaluation.

const Term = @import("../ast/term.zig").Term;
const value = @import("value.zig");
const Value = value.Value;
const Env = value.Env;
const Context = @import("context.zig").Context;

/// Machine state for the CEK machine.
pub fn MachineState(comptime Binder: type) type {
    const TermType = Term(Binder);
    const ValueType = Value(Binder);
    const EnvType = Env(Binder);
    const ContextType = Context(Binder);

    return union(enum) {
        /// Compute state: evaluate a term in an environment.
        compute: struct {
            ctx: *const ContextType,
            env: *const EnvType,
            term: *const TermType,
        },

        /// Return state: handle a computed value.
        @"return": struct {
            ctx: *const ContextType,
            value: *const ValueType,
        },

        /// Done state: evaluation complete.
        done: *const TermType,
    };
}
