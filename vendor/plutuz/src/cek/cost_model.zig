//! Cost model types for the CEK machine.
//! Defines machine step costs and the overall cost model structure.

const std = @import("std");
const ExBudget = @import("ex_budget.zig").ExBudget;
const costing = @import("costing.zig");

/// The kind of CEK machine step, used for step costing.
pub const StepKind = enum(u4) {
    constant = 0,
    var_ = 1,
    lambda = 2,
    apply = 3,
    delay = 4,
    force = 5,
    builtin = 6,
    constr = 7,
    case = 8,

    pub const count: usize = 9;
};

/// Costs for each machine step kind.
pub const MachineCosts = struct {
    startup: ExBudget,
    constant: ExBudget,
    var_: ExBudget,
    lambda: ExBudget,
    apply: ExBudget,
    delay: ExBudget,
    force: ExBudget,
    builtin: ExBudget,
    constr: ExBudget,
    case: ExBudget,

    pub fn get(self: MachineCosts, kind: StepKind) ExBudget {
        return switch (kind) {
            .constant => self.constant,
            .var_ => self.var_,
            .lambda => self.lambda,
            .apply => self.apply,
            .delay => self.delay,
            .force => self.force,
            .builtin => self.builtin,
            .constr => self.constr,
            .case => self.case,
        };
    }
};

/// Default machine costs (matching Haskell/Rust/Go reference implementations).
pub const default_machine_costs = MachineCosts{
    .startup = .{ .mem = 100, .cpu = 100 },
    .constant = .{ .mem = 100, .cpu = 16000 },
    .var_ = .{ .mem = 100, .cpu = 16000 },
    .lambda = .{ .mem = 100, .cpu = 16000 },
    .apply = .{ .mem = 100, .cpu = 16000 },
    .delay = .{ .mem = 100, .cpu = 16000 },
    .force = .{ .mem = 100, .cpu = 16000 },
    .builtin = .{ .mem = 100, .cpu = 16000 },
    .constr = .{ .mem = 100, .cpu = 16000 },
    .case = .{ .mem = 100, .cpu = 16000 },
};

/// Complete cost model: machine step costs + builtin costs.
pub const CostModel = struct {
    machine_costs: MachineCosts,
    builtin_costs: costing.BuiltinCosts,

    pub const default = CostModel{
        .machine_costs = default_machine_costs,
        .builtin_costs = @import("cost_model_defaults.zig").default_builtin_costs,
    };
};
