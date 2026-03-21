//! Cost function types and evaluation for builtin operations.
//! Implements the cost model algebra used to calculate execution budgets.

const std = @import("std");
const DefaultFunction = @import("../ast/builtin.zig").DefaultFunction;
const ExBudget = @import("ex_budget.zig").ExBudget;

/// Saturating multiply for cost computations (clamps to maxInt on overflow).
fn satMul(a: i64, b: i64) i64 {
    return std.math.mul(i64, a, b) catch std.math.maxInt(i64);
}

/// Saturating add for cost computations (clamps to maxInt on overflow).
fn satAdd(a: i64, b: i64) i64 {
    return std.math.add(i64, a, b) catch std.math.maxInt(i64);
}

/// Linear cost function: intercept + slope * x
pub const LinearSize = struct {
    intercept: i64,
    slope: i64,

    pub fn cost(self: LinearSize, x: i64) i64 {
        return satAdd(self.intercept, satMul(self.slope, x));
    }
};

/// One-variable quadratic: c0 + c1*x + c2*x²
pub const OneVariableQuadraticFunction = struct {
    coeff_0: i64,
    coeff_1: i64,
    coeff_2: i64,

    pub fn cost(self: OneVariableQuadraticFunction, x: i64) i64 {
        return satAdd(satAdd(self.coeff_0, satMul(self.coeff_1, x)), satMul(self.coeff_2, satMul(x, x)));
    }
};

/// Two-variable quadratic with minimum:
/// max(minimum, c00 + c10*x + c01*y + c20*x² + c11*x*y + c02*y²)
pub const TwoVariableQuadraticFunction = struct {
    minimum: i64,
    coeff_00: i64,
    coeff_10: i64,
    coeff_01: i64,
    coeff_20: i64,
    coeff_11: i64,
    coeff_02: i64,

    pub fn cost(self: TwoVariableQuadraticFunction, x: i64, y: i64) i64 {
        const raw = satAdd(satAdd(satAdd(self.coeff_00, satMul(self.coeff_10, x)), satAdd(satMul(self.coeff_01, y), satMul(self.coeff_20, satMul(x, x)))), satAdd(satMul(self.coeff_11, satMul(x, y)), satMul(self.coeff_02, satMul(y, y))));
        return @max(self.minimum, raw);
    }
};

// ===== One-argument cost models =====

pub const OneArgCost = union(enum) {
    constant: i64,
    linear: LinearSize,
    quadratic: OneVariableQuadraticFunction,

    pub fn cost(self: OneArgCost, x: i64) i64 {
        return switch (self) {
            .constant => |c| c,
            .linear => |l| l.cost(x),
            .quadratic => |q| q.cost(x),
        };
    }
};

// ===== Two-argument cost models =====

pub const TwoArgCost = union(enum) {
    constant: i64,
    linear_in_x: LinearSize,
    linear_in_y: LinearSize,
    added_sizes: LinearSize,
    subtracted_sizes: SubtractedSizes,
    multiplied_sizes: LinearSize,
    min_size: LinearSize,
    max_size: LinearSize,
    linear_on_diagonal: LinearOnDiagonal,
    quadratic_in_y: OneVariableQuadraticFunction,
    const_above_diagonal: ConstAboveDiagonal,
    const_below_diagonal: ConstBelowDiagonal,
    with_interaction: WithInteraction,

    pub const SubtractedSizes = struct {
        intercept: i64,
        slope: i64,
        minimum: i64,
    };

    pub const LinearOnDiagonal = struct {
        intercept: i64,
        slope: i64,
        constant: i64,
    };

    pub const ConstAboveDiagonal = struct {
        constant: i64,
        model: TwoVariableQuadraticFunction,
    };

    pub const ConstBelowDiagonal = struct {
        constant: i64,
        model: TwoVariableQuadraticFunction,
    };

    pub const WithInteraction = struct {
        c00: i64,
        c10: i64,
        c01: i64,
        c11: i64,
    };

    pub fn cost(self: TwoArgCost, x: i64, y: i64) i64 {
        return switch (self) {
            .constant => |c| c,
            .linear_in_x => |l| l.cost(x),
            .linear_in_y => |l| l.cost(y),
            .added_sizes => |l| l.cost(satAdd(x, y)),
            .subtracted_sizes => |s| @max(s.minimum, satAdd(s.intercept, satMul(s.slope, x - y))),
            .multiplied_sizes => |l| l.cost(satMul(x, y)),
            .min_size => |l| l.cost(@min(x, y)),
            .max_size => |l| l.cost(@max(x, y)),
            .linear_on_diagonal => |d| if (x == y)
                satAdd(d.intercept, satMul(d.slope, x))
            else
                d.constant,
            .quadratic_in_y => |q| q.cost(y),
            .const_above_diagonal => |c| if (x < y)
                c.constant
            else
                c.model.cost(x, y),
            .const_below_diagonal => |c| if (x > y)
                c.constant
            else
                c.model.cost(x, y),
            .with_interaction => |w| satAdd(satAdd(w.c00, satMul(w.c10, x)), satAdd(satMul(w.c01, y), satMul(w.c11, satMul(x, y)))),
        };
    }
};

// ===== Three-argument cost models =====

pub const ThreeArgCost = union(enum) {
    constant: i64,
    linear_in_x: LinearSize,
    linear_in_y: LinearSize,
    linear_in_z: LinearSize,
    quadratic_in_z: OneVariableQuadraticFunction,
    literal_in_y_or_linear_in_z: LinearSize,
    linear_in_y_and_z: LinearInTwoSizes,
    linear_in_max_yz: LinearSize,
    exp_mod: ExpMod,

    pub const LinearInTwoSizes = struct {
        intercept: i64,
        slope_y: i64,
        slope_z: i64,
    };

    pub const ExpMod = struct {
        coeff_00: i64,
        coeff_11: i64,
        coeff_12: i64,
    };

    pub fn cost(self: ThreeArgCost, x: i64, y: i64, z: i64) i64 {
        return switch (self) {
            .constant => |c| c,
            .linear_in_x => |l| l.cost(x),
            .linear_in_y => |l| l.cost(y),
            .linear_in_z => |l| l.cost(z),
            .quadratic_in_z => |q| q.cost(z),
            .literal_in_y_or_linear_in_z => |l| @max(y, l.cost(z)),
            .linear_in_y_and_z => |l| satAdd(l.intercept, satAdd(satMul(l.slope_y, y), satMul(l.slope_z, z))),
            .linear_in_max_yz => |l| l.cost(@max(y, z)),
            .exp_mod => |e| blk: {
                const yz = satMul(y, z);
                const base = satAdd(e.coeff_00, satAdd(satMul(e.coeff_11, yz), satMul(e.coeff_12, satMul(yz, z))));
                break :blk if (x > z) satAdd(base, @divFloor(base, 2)) else base;
            },
        };
    }
};

// ===== Six-argument cost models =====

pub const SixArgCost = union(enum) {
    constant: i64,

    pub fn cost(self: SixArgCost) i64 {
        return switch (self) {
            .constant => |c| c,
        };
    }
};

// ===== CostingFun: a pair of mem and cpu cost functions =====

pub fn CostingFun(comptime T: type) type {
    return struct {
        mem: T,
        cpu: T,
    };
}

/// A builtin's cost model, parameterized by arity.
pub const BuiltinCostModel = union(enum) {
    one: CostingFun(OneArgCost),
    two: CostingFun(TwoArgCost),
    three: CostingFun(ThreeArgCost),
    six: CostingFun(SixArgCost),
};

/// Cost models for all builtins, indexed by DefaultFunction enum value.
pub const BuiltinCosts = [std.meta.fields(DefaultFunction).len]BuiltinCostModel;

/// Compute ExBudget for a 1-arg builtin.
pub fn costOne(cf: CostingFun(OneArgCost), x: i64) ExBudget {
    return .{
        .mem = cf.mem.cost(x),
        .cpu = cf.cpu.cost(x),
    };
}

/// Compute ExBudget for a 2-arg builtin.
pub fn costTwo(cf: CostingFun(TwoArgCost), x: i64, y: i64) ExBudget {
    return .{
        .mem = cf.mem.cost(x, y),
        .cpu = cf.cpu.cost(x, y),
    };
}

/// Compute ExBudget for a 3-arg builtin.
pub fn costThree(cf: CostingFun(ThreeArgCost), x: i64, y: i64, z: i64) ExBudget {
    return .{
        .mem = cf.mem.cost(x, y, z),
        .cpu = cf.cpu.cost(x, y, z),
    };
}

/// Compute ExBudget for a 6-arg builtin.
pub fn costSix(cf: CostingFun(SixArgCost)) ExBudget {
    return .{
        .mem = cf.mem.cost(),
        .cpu = cf.cpu.cost(),
    };
}

// ===== Tests =====

test "OneArgCost constant" {
    const c = OneArgCost{ .constant = 42 };
    try std.testing.expectEqual(@as(i64, 42), c.cost(100));
}

test "OneArgCost linear" {
    const c = OneArgCost{ .linear = .{ .intercept = 10, .slope = 3 } };
    try std.testing.expectEqual(@as(i64, 19), c.cost(3));
}

test "OneArgCost quadratic" {
    const c = OneArgCost{ .quadratic = .{ .coeff_0 = 100, .coeff_1 = 10, .coeff_2 = 1 } };
    // 100 + 10*5 + 1*25 = 175
    try std.testing.expectEqual(@as(i64, 175), c.cost(5));
}

test "TwoArgCost max_size" {
    const c = TwoArgCost{ .max_size = .{ .intercept = 100, .slope = 5 } };
    try std.testing.expectEqual(@as(i64, 150), c.cost(5, 10));
}

test "TwoArgCost subtracted_sizes with minimum" {
    const c = TwoArgCost{ .subtracted_sizes = .{ .intercept = 0, .slope = 1, .minimum = 0 } };
    try std.testing.expectEqual(@as(i64, 5), c.cost(10, 5));
    try std.testing.expectEqual(@as(i64, 0), c.cost(5, 10));
}

test "TwoArgCost quadratic_in_y" {
    const c = TwoArgCost{ .quadratic_in_y = .{ .coeff_0 = 1006041, .coeff_1 = 43623, .coeff_2 = 251 } };
    // y=2: 1006041 + 43623*2 + 251*4 = 1006041 + 87246 + 1004 = 1094291
    try std.testing.expectEqual(@as(i64, 1094291), c.cost(0, 2));
}

test "ThreeArgCost linear_in_y_and_z" {
    const c = ThreeArgCost{ .linear_in_y_and_z = .{ .intercept = 100, .slope_y = 2, .slope_z = 3 } };
    // 100 + 2*3 + 3*5 = 121
    try std.testing.expectEqual(@as(i64, 121), c.cost(0, 3, 5));
}
