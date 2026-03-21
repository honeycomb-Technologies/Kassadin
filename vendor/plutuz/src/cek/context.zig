//! Continuation frames - the "K" in CEK.
//! These represent what to do after computing the current term.

const std = @import("std");
const Term = @import("../ast/term.zig").Term;
const value = @import("value.zig");
const Value = value.Value;
const Env = value.Env;

/// Continuation frames for the CEK machine.
pub fn Context(comptime Binder: type) type {
    const TermType = Term(Binder);
    const ValueType = Value(Binder);
    const EnvType = Env(Binder);

    return union(enum) {
        /// No more continuations - evaluation complete.
        no_frame,

        /// Evaluated function, waiting for argument value.
        /// Used after function is evaluated in an application.
        frame_await_arg: struct {
            value: *const ValueType,
            ctx: *const Context(Binder),
        },

        /// Evaluated function to value, now need to evaluate argument term.
        frame_await_fun_term: struct {
            env: *const EnvType,
            term: *const TermType,
            ctx: *const Context(Binder),
        },

        /// Have function value, waiting to apply to argument value.
        frame_await_fun_value: struct {
            value: *const ValueType,
            ctx: *const Context(Binder),
        },

        /// Forcing a delayed computation.
        frame_force: struct {
            ctx: *const Context(Binder),
        },

        /// Evaluating constructor fields sequentially.
        frame_constr: struct {
            env: *const EnvType,
            tag: usize,
            fields: []const *const TermType,
            resolved_fields: std.ArrayListUnmanaged(*const ValueType),
            ctx: *const Context(Binder),
        },

        /// Pattern matching on constructor.
        frame_cases: struct {
            env: *const EnvType,
            branches: []const *const TermType,
            ctx: *const Context(Binder),
        },
    };
}
