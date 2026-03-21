//! CEK machine values.
//! Runtime values produced during evaluation.

const std = @import("std");
const Term = @import("../ast/term.zig").Term;
const Constant = @import("../ast/constant.zig").Constant;
const DefaultFunction = @import("../ast/builtin.zig").DefaultFunction;

/// CEK machine value - the result of evaluating a term.
pub fn Value(comptime Binder: type) type {
    return union(enum) {
        /// A constant value
        constant: *const Constant,
        /// A delayed computation (thunk)
        delay: struct {
            body: *const Term(Binder),
            env: *const Env(Binder),
        },
        /// A lambda closure
        lambda: struct {
            parameter: *const Binder,
            body: *const Term(Binder),
            env: *const Env(Binder),
        },
        /// A partially applied builtin
        builtin: struct {
            func: DefaultFunction,
            forces: usize,
            args: std.ArrayListUnmanaged(*const Value(Binder)),
        },
        /// A constructor value
        constr: struct {
            tag: usize,
            fields: []const *const Value(Binder),
        },
    };
}

/// Environment - a linked list of values for variable lookup.
pub fn Env(comptime Binder: type) type {
    return struct {
        data: ?*const Value(Binder),
        next: ?*const Env(Binder),

        const Self = @This();

        pub const empty: Self = .{ .data = null, .next = null };

        pub fn extend(self: *const Self, allocator: std.mem.Allocator, value: *const Value(Binder)) !*const Self {
            const new_env = try allocator.create(Self);
            new_env.* = .{
                .data = value,
                .next = self,
            };
            return new_env;
        }

        pub fn lookup(self: *const Self, index: usize) ?*const Value(Binder) {
            if (index == 0) return null;

            var current: ?*const Self = self;
            var remaining = index - 1;

            while (remaining > 0) : (remaining -= 1) {
                if (current) |env| {
                    current = env.next;
                } else {
                    return null;
                }
            }

            if (current) |env| {
                return env.data;
            }
            return null;
        }
    };
}
