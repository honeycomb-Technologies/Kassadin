//! Term AST for Untyped Plutus Core.
//! The Term type is generic over the binder type, allowing different
//! representations (Name, DeBruijn, NamedDeBruijn).

const std = @import("std");
const Constant = @import("constant.zig").Constant;
const DefaultFunction = @import("builtin.zig").DefaultFunction;

/// A generic term in Untyped Plutus Core.
/// The Binder type parameter determines how variables are represented.
pub fn Term(comptime Binder: type) type {
    return union(enum) {
        /// Variable reference
        var_: *const Binder,
        /// Lambda abstraction
        lambda: struct {
            parameter: *const Binder,
            body: *const Term(Binder),
        },
        /// Function application
        apply: struct {
            function: *const Term(Binder),
            argument: *const Term(Binder),
        },
        /// Delayed computation (thunk)
        delay: *const Term(Binder),
        /// Force evaluation of a delayed computation
        force: *const Term(Binder),
        /// Case expression for pattern matching on constructors
        case: struct {
            constr: *const Term(Binder),
            branches: []const *const Term(Binder),
        },
        /// Constructor application
        constr: struct {
            tag: usize,
            fields: []const *const Term(Binder),
        },
        /// Constant value
        constant: *const Constant,
        /// Builtin function reference
        builtin: DefaultFunction,
        /// Error term
        err,

        const Self = @This();

        /// Create a variable term.
        pub fn variable(allocator: std.mem.Allocator, binder: *const Binder) !*const Self {
            const t = try allocator.create(Self);
            t.* = .{ .var_ = binder };
            return t;
        }

        /// Create a lambda term.
        pub fn lam(allocator: std.mem.Allocator, param: *const Binder, body: *const Self) !*const Self {
            const t = try allocator.create(Self);
            t.* = .{ .lambda = .{ .parameter = param, .body = body } };
            return t;
        }

        /// Create an application term.
        pub fn app(allocator: std.mem.Allocator, function: *const Self, argument: *const Self) !*const Self {
            const t = try allocator.create(Self);
            t.* = .{ .apply = .{ .function = function, .argument = argument } };
            return t;
        }

        /// Create a delay term.
        pub fn del(allocator: std.mem.Allocator, term: *const Self) !*const Self {
            const t = try allocator.create(Self);
            t.* = .{ .delay = term };
            return t;
        }

        /// Create a force term.
        pub fn frc(allocator: std.mem.Allocator, term: *const Self) !*const Self {
            const t = try allocator.create(Self);
            t.* = .{ .force = term };
            return t;
        }

        /// Create a case term.
        pub fn caseOf(allocator: std.mem.Allocator, scrutinee: *const Self, branches: []const *const Self) !*const Self {
            const t = try allocator.create(Self);
            t.* = .{ .case = .{ .constr = scrutinee, .branches = branches } };
            return t;
        }

        /// Create a constructor term.
        pub fn constrOf(allocator: std.mem.Allocator, tag: usize, fields: []const *const Self) !*const Self {
            const t = try allocator.create(Self);
            t.* = .{ .constr = .{ .tag = tag, .fields = fields } };
            return t;
        }

        /// Create a constant term.
        pub fn con(allocator: std.mem.Allocator, constant: *const Constant) !*const Self {
            const t = try allocator.create(Self);
            t.* = .{ .constant = constant };
            return t;
        }

        /// Create a builtin term.
        pub fn builtinOf(allocator: std.mem.Allocator, fun: DefaultFunction) !*const Self {
            const t = try allocator.create(Self);
            t.* = .{ .builtin = fun };
            return t;
        }

        /// Create an error term.
        pub fn errorTerm(allocator: std.mem.Allocator) !*const Self {
            const t = try allocator.create(Self);
            t.* = .err;
            return t;
        }

        /// Apply this term to an argument (chainable).
        pub fn apply_(self: *const Self, allocator: std.mem.Allocator, argument: *const Self) !*const Self {
            return app(allocator, self, argument);
        }

        /// Force this term (chainable).
        pub fn force_(self: *const Self, allocator: std.mem.Allocator) !*const Self {
            return frc(allocator, self);
        }
    };
}

test "term creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Name = @import("../binder/name.zig").Name;

    const NameTerm = Term(Name);

    // Create a simple variable
    const name = try Name.create(allocator, "x", 0);
    defer allocator.destroy(name);

    const var_term = try NameTerm.variable(allocator, name);
    defer allocator.destroy(var_term);

    try testing.expect(var_term.* == .var_);
}

test "lambda application" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Name = @import("../binder/name.zig").Name;

    const NameTerm = Term(Name);

    // Create (lam x x)
    const name = try Name.create(allocator, "x", 0);
    defer allocator.destroy(name);

    const var_term = try NameTerm.variable(allocator, name);
    defer allocator.destroy(var_term);

    const lam_term = try NameTerm.lam(allocator, name, var_term);
    defer allocator.destroy(lam_term);

    try testing.expect(lam_term.* == .lambda);
    try testing.expect(lam_term.lambda.body.* == .var_);
}

test "builtin term" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Name = @import("../binder/name.zig").Name;

    const NameTerm = Term(Name);

    const builtin_term = try NameTerm.builtinOf(allocator, .add_integer);
    defer allocator.destroy(builtin_term);

    try testing.expect(builtin_term.* == .builtin);
    try testing.expectEqual(DefaultFunction.add_integer, builtin_term.builtin);
}
