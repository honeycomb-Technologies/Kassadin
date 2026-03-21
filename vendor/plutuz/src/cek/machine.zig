//! CEK abstract machine for UPLC evaluation.
//! Implements the Control-Environment-Kontinuation machine.
//!
//! The CEK machine is a small-step operational semantics for evaluating functional programs.
//! It maintains three components:
//! - Control (C): the current term being evaluated
//! - Environment (E): mapping from variables to values
//! - Kontinuation (K): represents the evaluation context/stack
//!
//! The algorithm proceeds by repeatedly transitioning between three states:
//! - Compute: evaluate the current term in the current environment and context
//! - Return: handle a computed value in the current context
//! - Done: evaluation complete, return the final result

const std = @import("std");
const Term = @import("../ast/term.zig").Term;
const Program = @import("../ast/program.zig").Program;
const Constant = @import("../ast/constant.zig").Constant;
const DefaultFunction = @import("../ast/builtin.zig").DefaultFunction;
const DeBruijn = @import("../binder/debruijn.zig").DeBruijn;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Env = value_mod.Env;
const builtins = @import("builtins.zig");
const error_mod = @import("error.zig");
const cost_model_mod = @import("cost_model.zig");
pub const StepKind = cost_model_mod.StepKind;
pub const CostModel = cost_model_mod.CostModel;
const costing = @import("costing.zig");
pub const Context = @import("context.zig").Context;
pub const MachineState = @import("state.zig").MachineState;
pub const ExBudget = @import("ex_budget.zig").ExBudget;
pub const SemanticsVariant = @import("semantics.zig").SemanticsVariant;

pub const MachineError = error_mod.MachineError;

/// CEK Machine.
pub fn Machine(comptime Binder: type) type {
    return struct {
        allocator: std.mem.Allocator,
        budget: ExBudget,
        costs: CostModel,
        logs: std.ArrayListUnmanaged([]const u8),
        semantics: SemanticsVariant,
        unbudgeted_steps: [StepKind.count + 1]u8,
        slippage: u8,
        restricting: bool,

        const Self = @This();
        const TermType = Term(Binder);
        const ValueType = Value(Binder);
        const EnvType = Env(Binder);
        const ContextType = Context(Binder);
        const StateType = MachineState(Binder);

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .budget = ExBudget.unlimited,
                .costs = CostModel.default,
                .logs = .{},
                .semantics = .c, // Default to V3+ semantics
                .unbudgeted_steps = .{0} ** (StepKind.count + 1),
                .slippage = 200,
                .restricting = false,
            };
        }

        /// Subtract cost from budget. In restricting mode, returns OutOfBudget if
        /// either dimension goes negative. In counting mode (default), budget can
        /// go negative — this matches the Haskell/Plutigo reference behavior for
        /// unlimited-budget evaluation.
        pub fn spendBudget(self: *Self, cost: ExBudget) MachineError!void {
            self.budget.cpu = std.math.sub(i64, self.budget.cpu, cost.cpu) catch std.math.minInt(i64);
            self.budget.mem = std.math.sub(i64, self.budget.mem, cost.mem) catch std.math.minInt(i64);
            if (self.restricting and (self.budget.cpu < 0 or self.budget.mem < 0)) {
                return error.OutOfBudget;
            }
        }

        /// Track a machine step, flushing accumulated costs when the slippage threshold is reached.
        fn stepAndMaybeSpend(self: *Self, kind: StepKind) MachineError!void {
            self.unbudgeted_steps[@intFromEnum(kind)] += 1;
            self.unbudgeted_steps[StepKind.count] += 1;
            if (self.unbudgeted_steps[StepKind.count] >= self.slippage) {
                try self.spendUnbudgetedSteps();
            }
        }

        /// Flush all accumulated step costs into the budget.
        fn spendUnbudgetedSteps(self: *Self) MachineError!void {
            var total = ExBudget{ .cpu = 0, .mem = 0 };
            inline for (0..StepKind.count) |i| {
                const n = self.unbudgeted_steps[i];
                if (n > 0) {
                    const step_cost = self.costs.machine_costs.get(@enumFromInt(i));
                    total = total.add(step_cost.occurrences(@intCast(n)));
                    self.unbudgeted_steps[i] = 0;
                }
            }
            self.unbudgeted_steps[StepKind.count] = 0;
            try self.spendBudget(total);
        }

        /// Spend budget for a builtin call using the cost model.
        pub fn spendBuiltinCost(self: *Self, func: DefaultFunction, args: []const i64) MachineError!void {
            const model = self.costs.builtin_costs[@intFromEnum(func)];
            const cost = switch (model) {
                .one => |cf| costing.costOne(cf, if (args.len > 0) args[0] else 0),
                .two => |cf| costing.costTwo(cf, if (args.len > 0) args[0] else 0, if (args.len > 1) args[1] else 0),
                .three => |cf| costing.costThree(cf, if (args.len > 0) args[0] else 0, if (args.len > 1) args[1] else 0, if (args.len > 2) args[2] else 0),
                .six => |cf| costing.costSix(cf),
            };
            try self.spendBudget(cost);
        }

        /// Run the machine on a term.
        /// Main CEK evaluation loop: continue until we reach Done state.
        pub fn run(self: *Self, term: *const TermType) MachineError!*const TermType {
            // Spend startup cost
            try self.spendBudget(self.costs.machine_costs.startup);

            // Initialize with a Compute state: evaluate the input term with empty environment
            // and no continuation context (NoFrame)
            const no_frame = self.allocator.create(ContextType) catch return error.OutOfMemory;
            no_frame.* = .no_frame;

            var state: StateType = .{
                .compute = .{
                    .ctx = no_frame,
                    .env = &EnvType.empty,
                    .term = term,
                },
            };

            // Main loop
            while (true) {
                switch (state) {
                    .compute => |comp| {
                        state = try self.compute(comp.ctx, comp.env, comp.term);
                    },
                    .@"return" => |ret| {
                        state = try self.returnCompute(ret.ctx, ret.value);
                    },
                    .done => |result| {
                        // Flush any remaining unbudgeted steps
                        try self.spendUnbudgetedSteps();
                        return result;
                    },
                }
            }
        }

        /// Compute state handler: evaluate a term in an environment.
        fn compute(
            self: *Self,
            context: *const ContextType,
            env: *const EnvType,
            term: *const TermType,
        ) MachineError!StateType {
            switch (term.*) {
                .var_ => |binder| {
                    try self.stepAndMaybeSpend(.var_);
                    // Variable lookup: retrieve value from environment
                    const val = env.lookup(binder.index) orelse return error.OpenTermEvaluated;

                    // Transition to Return state with the looked-up value
                    return StateType{ .@"return" = .{ .ctx = context, .value = val } };
                },
                .delay => |body| {
                    try self.stepAndMaybeSpend(.delay);
                    // Delay creates a suspended computation
                    const val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                    val.* = .{ .delay = .{ .body = body, .env = env } };

                    return StateType{ .@"return" = .{ .ctx = context, .value = val } };
                },
                .lambda => |lam| {
                    try self.stepAndMaybeSpend(.lambda);
                    // Lambda creates a closure capturing the current environment
                    const val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                    val.* = .{ .lambda = .{
                        .parameter = lam.parameter,
                        .body = lam.body,
                        .env = env,
                    } };

                    return StateType{ .@"return" = .{ .ctx = context, .value = val } };
                },
                .apply => |app| {
                    try self.stepAndMaybeSpend(.apply);
                    // Application: evaluate function term first, then argument
                    // Uses FrameAwaitFunTerm to remember argument for later evaluation
                    const frame = self.allocator.create(ContextType) catch return error.OutOfMemory;
                    frame.* = .{ .frame_await_fun_term = .{
                        .env = env,
                        .term = app.argument,
                        .ctx = context,
                    } };

                    return StateType{ .compute = .{
                        .ctx = frame,
                        .env = env,
                        .term = app.function,
                    } };
                },
                .constant => |c| {
                    try self.stepAndMaybeSpend(.constant);
                    // Constants are already evaluated values
                    const val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                    val.* = .{ .constant = c };

                    return StateType{ .@"return" = .{ .ctx = context, .value = val } };
                },
                .force => |inner| {
                    try self.stepAndMaybeSpend(.force);
                    // Force triggers evaluation of a delayed computation
                    const frame = self.allocator.create(ContextType) catch return error.OutOfMemory;
                    frame.* = .{ .frame_force = .{ .ctx = context } };

                    return StateType{ .compute = .{
                        .ctx = frame,
                        .env = env,
                        .term = inner,
                    } };
                },
                .err => {
                    return error.BuiltinError;
                },
                .builtin => |b| {
                    try self.stepAndMaybeSpend(.builtin);
                    // Builtin functions are treated as values
                    const val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                    val.* = .{ .builtin = .{
                        .func = b,
                        .forces = 0,
                        .args = .{},
                    } };

                    return StateType{ .@"return" = .{ .ctx = context, .value = val } };
                },
                .constr => |c| {
                    try self.stepAndMaybeSpend(.constr);
                    // Constructor: evaluate all fields sequentially
                    if (c.fields.len == 0) {
                        // No fields to evaluate
                        const val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                        val.* = .{ .constr = .{ .tag = c.tag, .fields = &.{} } };

                        return StateType{ .@"return" = .{ .ctx = context, .value = val } };
                    } else {
                        // Evaluate fields sequentially using FrameConstr
                        const frame = self.allocator.create(ContextType) catch return error.OutOfMemory;
                        var resolved = std.ArrayListUnmanaged(*const ValueType){};
                        resolved.ensureTotalCapacity(self.allocator, c.fields.len) catch return error.OutOfMemory;

                        frame.* = .{ .frame_constr = .{
                            .env = env,
                            .tag = c.tag,
                            .fields = c.fields[1..],
                            .resolved_fields = resolved,
                            .ctx = context,
                        } };

                        return StateType{ .compute = .{
                            .ctx = frame,
                            .env = env,
                            .term = c.fields[0],
                        } };
                    }
                },
                .case => |c| {
                    try self.stepAndMaybeSpend(.case);
                    // Case expression: evaluate scrutinee, then match against branches
                    const frame = self.allocator.create(ContextType) catch return error.OutOfMemory;
                    frame.* = .{ .frame_cases = .{
                        .env = env,
                        .branches = c.branches,
                        .ctx = context,
                    } };

                    return StateType{ .compute = .{
                        .ctx = frame,
                        .env = env,
                        .term = c.constr,
                    } };
                },
            }
        }

        /// Return state handler: handle a computed value in the current context.
        fn returnCompute(
            self: *Self,
            context: *const ContextType,
            value: *const ValueType,
        ) MachineError!StateType {
            switch (context.*) {
                .frame_await_arg => |frame| {
                    // Function term evaluated, now apply to argument value
                    return self.applyEvaluate(frame.ctx, frame.value, value);
                },
                .frame_await_fun_term => |frame| {
                    // Function evaluated to a value, now evaluate argument term
                    const new_ctx = self.allocator.create(ContextType) catch return error.OutOfMemory;
                    new_ctx.* = .{ .frame_await_arg = .{
                        .ctx = frame.ctx,
                        .value = value,
                    } };

                    return StateType{ .compute = .{
                        .ctx = new_ctx,
                        .env = frame.env,
                        .term = frame.term,
                    } };
                },
                .frame_await_fun_value => |frame| {
                    // Argument evaluated to a value, now apply to function value
                    return self.applyEvaluate(frame.ctx, value, frame.value);
                },
                .frame_force => |frame| {
                    // Handle forcing of delayed computations
                    return self.forceEvaluate(frame.ctx, value);
                },
                .frame_constr => |frame| {
                    // Accumulate evaluated constructor fields
                    var resolved = frame.resolved_fields;
                    resolved.append(self.allocator, value) catch return error.OutOfMemory;

                    if (frame.fields.len == 0) {
                        // All fields evaluated, create constructor value
                        const val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                        const fields_slice = self.allocator.alloc(*const ValueType, resolved.items.len) catch return error.OutOfMemory;
                        @memcpy(fields_slice, resolved.items);
                        val.* = .{ .constr = .{ .tag = frame.tag, .fields = fields_slice } };

                        return StateType{ .@"return" = .{ .ctx = frame.ctx, .value = val } };
                    } else {
                        // More fields to evaluate
                        const new_ctx = self.allocator.create(ContextType) catch return error.OutOfMemory;
                        new_ctx.* = .{ .frame_constr = .{
                            .env = frame.env,
                            .tag = frame.tag,
                            .fields = frame.fields[1..],
                            .resolved_fields = resolved,
                            .ctx = frame.ctx,
                        } };

                        return StateType{ .compute = .{
                            .ctx = new_ctx,
                            .env = frame.env,
                            .term = frame.fields[0],
                        } };
                    }
                },
                .frame_cases => |frame| {
                    // Pattern match on constructor value
                    switch (value.*) {
                        .constr => |constr_val| {
                            if (constr_val.tag >= frame.branches.len) {
                                return error.MissingCaseBranch;
                            }

                            // Transfer constructor fields to arg stack
                            const ctx = self.transferArgStack(constr_val.fields, frame.ctx);

                            return StateType{ .compute = .{
                                .ctx = ctx,
                                .env = frame.env,
                                .term = frame.branches[constr_val.tag],
                            } };
                        },
                        .constant => |con| {
                            return self.caseOnConstant(con, frame) catch return error.NonConstrScrutinee;
                        },
                        else => return error.NonConstrScrutinee,
                    }
                },
                .no_frame => {
                    // No more continuations - evaluation complete
                    const result = try self.dischargeValue(value);
                    return StateType{ .done = result };
                },
            }
        }

        /// Force evaluation: handle forcing of delayed computations or builtin applications.
        fn forceEvaluate(
            self: *Self,
            context: *const ContextType,
            value: *const ValueType,
        ) MachineError!StateType {
            switch (value.*) {
                .delay => |d| {
                    // Force a delayed computation: evaluate body in captured environment
                    return StateType{ .compute = .{
                        .ctx = context,
                        .env = d.env,
                        .term = d.body,
                    } };
                },
                .builtin => |b| {
                    // Force a builtin function application
                    if (b.func.forceCount() > b.forces) {
                        // Consume one force
                        const new_val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                        new_val.* = .{ .builtin = .{
                            .func = b.func,
                            .forces = b.forces + 1,
                            .args = b.args,
                        } };

                        // Check if builtin is ready
                        const resolved = try self.tryCallBuiltin(new_val);

                        return StateType{ .@"return" = .{ .ctx = context, .value = resolved } };
                    } else {
                        return error.BuiltinTermArgumentExpected;
                    }
                },
                else => return error.NonPolymorphicInstantiation,
            }
        }

        /// Apply evaluation: handle function application.
        fn applyEvaluate(
            self: *Self,
            context: *const ContextType,
            function: *const ValueType,
            arg: *const ValueType,
        ) MachineError!StateType {
            switch (function.*) {
                .lambda => |lam| {
                    // Apply lambda: extend environment and evaluate body
                    const new_env = lam.env.extend(self.allocator, arg) catch return error.OutOfMemory;

                    return StateType{ .compute = .{
                        .ctx = context,
                        .env = new_env,
                        .term = lam.body,
                    } };
                },
                .builtin => |b| {
                    // Apply builtin function
                    if (b.func.forceCount() <= b.forces and b.func.arity() > b.args.items.len) {
                        var new_args = b.args.clone(self.allocator) catch return error.OutOfMemory;
                        new_args.append(self.allocator, arg) catch return error.OutOfMemory;

                        const new_val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                        new_val.* = .{ .builtin = .{
                            .func = b.func,
                            .forces = b.forces,
                            .args = new_args,
                        } };

                        const resolved = try self.tryCallBuiltin(new_val);

                        return StateType{ .@"return" = .{ .ctx = context, .value = resolved } };
                    } else {
                        return error.UnexpectedBuiltinTermArgument;
                    }
                },
                else => return error.NonFunctionalApplication,
            }
        }

        /// Transfer constructor fields to argument stack for case branches.
        /// Handle case expressions on constant values (bools, units, integers, lists).
        fn caseOnConstant(
            self: *Self,
            con: *const Constant,
            frame: anytype,
        ) MachineError!StateType {
            switch (con.*) {
                .boolean => |b| {
                    // Bool: exactly 1 or 2 branches allowed
                    if (frame.branches.len < 1 or frame.branches.len > 2) return error.MissingCaseBranch;
                    const tag: usize = if (b) 1 else 0;
                    if (tag >= frame.branches.len) return error.MissingCaseBranch;
                    return StateType{ .compute = .{
                        .ctx = frame.ctx,
                        .env = frame.env,
                        .term = frame.branches[tag],
                    } };
                },
                .unit => {
                    // Unit: exactly 1 branch allowed
                    if (frame.branches.len != 1) return error.MissingCaseBranch;
                    return StateType{ .compute = .{
                        .ctx = frame.ctx,
                        .env = frame.env,
                        .term = frame.branches[0],
                    } };
                },
                .integer => |*int_val| {
                    const tag = int_val.toConst().toInt(usize) catch return error.MissingCaseBranch;
                    if (tag >= frame.branches.len) return error.MissingCaseBranch;
                    return StateType{ .compute = .{
                        .ctx = frame.ctx,
                        .env = frame.env,
                        .term = frame.branches[tag],
                    } };
                },
                .proto_list => |list| {
                    if (list.values.len > 0) {
                        // Non-empty list: branch 0, with head and tail as arguments
                        if (frame.branches.len < 1) return error.MissingCaseBranch;

                        // Build head value
                        const head_val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                        head_val.* = .{ .constant = list.values[0] };

                        // Build tail value (remaining list)
                        const tail_const = self.allocator.create(Constant) catch return error.OutOfMemory;
                        tail_const.* = .{ .proto_list = .{ .typ = list.typ, .values = list.values[1..] } };
                        const tail_val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                        tail_val.* = .{ .constant = tail_const };

                        // Push tail then head as arguments (reverse order for stack)
                        const fields = self.allocator.alloc(*const ValueType, 2) catch return error.OutOfMemory;
                        fields[0] = head_val;
                        fields[1] = tail_val;
                        const ctx = self.transferArgStack(fields, frame.ctx);

                        return StateType{ .compute = .{
                            .ctx = ctx,
                            .env = frame.env,
                            .term = frame.branches[0],
                        } };
                    } else {
                        // Empty list: branch 1 (if 2 branches), branch 0 (if 1 branch with error semantics)
                        if (frame.branches.len >= 2) {
                            return StateType{ .compute = .{
                                .ctx = frame.ctx,
                                .env = frame.env,
                                .term = frame.branches[1],
                            } };
                        }
                        return error.MissingCaseBranch;
                    }
                },
                .proto_pair => |pair| {
                    // Pair: exactly 1 branch with fst and snd as arguments
                    if (frame.branches.len != 1) return error.MissingCaseBranch;

                    const fst_val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                    fst_val.* = .{ .constant = pair.fst };
                    const snd_val = self.allocator.create(ValueType) catch return error.OutOfMemory;
                    snd_val.* = .{ .constant = pair.snd };

                    const fields = self.allocator.alloc(*const ValueType, 2) catch return error.OutOfMemory;
                    fields[0] = fst_val;
                    fields[1] = snd_val;
                    const ctx = self.transferArgStack(fields, frame.ctx);

                    return StateType{ .compute = .{
                        .ctx = ctx,
                        .env = frame.env,
                        .term = frame.branches[0],
                    } };
                },
                else => return error.NonConstrScrutinee,
            }
        }

        fn transferArgStack(
            self: *Self,
            fields: []const *const ValueType,
            ctx: *const ContextType,
        ) *const ContextType {
            var c = ctx;

            // Process fields in reverse order
            var i: usize = fields.len;
            while (i > 0) {
                i -= 1;
                const frame = self.allocator.create(ContextType) catch return c;
                frame.* = .{ .frame_await_fun_value = .{
                    .ctx = c,
                    .value = fields[i],
                } };
                c = frame;
            }

            return c;
        }

        /// Try to call a builtin if it's fully saturated.
        fn tryCallBuiltin(self: *Self, val: *const ValueType) MachineError!*const ValueType {
            const b = val.builtin;
            const arity = b.func.arity();
            const force_count = b.func.forceCount();

            if (b.args.items.len == arity and b.forces == force_count) {
                return self.callBuiltin(b.func, b.args.items);
            }
            return val;
        }

        /// Call a builtin function with arguments.
        fn callBuiltin(self: *Self, func: DefaultFunction, args: []const *const ValueType) MachineError!*const ValueType {
            return builtins.evalBuiltin(Binder, self, func, args) catch |err| switch (err) {
                error.TypeMismatch => error.TypeMismatch,
                error.OutOfMemory => error.OutOfMemory,
                error.OutOfBudget => error.OutOfBudget,
                error.DivisionByZero => error.BuiltinError,
                error.OutOfRange => error.BuiltinError,
                error.DecodeError => error.BuiltinError,
                error.EvaluationFailure => error.BuiltinError,
            };
        }

        /// Discharge a value back to a term.
        /// This is the inverse operation of evaluation.
        fn dischargeValue(self: *Self, value: *const ValueType) MachineError!*const TermType {
            const term = self.allocator.create(TermType) catch return error.OutOfMemory;

            switch (value.*) {
                .constant => |c| {
                    term.* = .{ .constant = c };
                },
                .builtin => |b| {
                    // Reconstruct the term that represents this builtin application
                    var forced_term: *const TermType = undefined;

                    const builtin_term = self.allocator.create(TermType) catch return error.OutOfMemory;
                    builtin_term.* = .{ .builtin = b.func };
                    forced_term = builtin_term;

                    // Add forces for polymorphic instantiation
                    var forces: usize = 0;
                    while (forces < b.forces) : (forces += 1) {
                        const force_term = self.allocator.create(TermType) catch return error.OutOfMemory;
                        force_term.* = .{ .force = forced_term };
                        forced_term = force_term;
                    }

                    // Add applications for each argument
                    for (b.args.items) |arg| {
                        const arg_term = try self.dischargeValue(arg);
                        const app_term = self.allocator.create(TermType) catch return error.OutOfMemory;
                        app_term.* = .{ .apply = .{
                            .function = forced_term,
                            .argument = arg_term,
                        } };
                        forced_term = app_term;
                    }

                    return forced_term;
                },
                .delay => |d| {
                    // Discharge delayed computation with environment
                    const body = try self.withEnv(0, d.env, d.body);
                    term.* = .{ .delay = body };
                },
                .lambda => |lam| {
                    // Discharge lambda with environment (lam_cnt=1 to account for parameter)
                    const body = try self.withEnv(1, lam.env, lam.body);
                    term.* = .{ .lambda = .{
                        .parameter = lam.parameter,
                        .body = body,
                    } };
                },
                .constr => |c| {
                    // Recursively discharge all constructor fields
                    const fields = self.allocator.alloc(*const TermType, c.fields.len) catch return error.OutOfMemory;
                    for (c.fields, 0..) |field, i| {
                        fields[i] = try self.dischargeValue(field);
                    }
                    term.* = .{ .constr = .{ .tag = c.tag, .fields = fields } };
                },
            }

            return term;
        }

        /// Discharge a term while substituting values from an environment.
        /// This implements lexical scoping by replacing free variables with their
        /// bound values from the evaluation environment.
        fn withEnv(
            self: *Self,
            lam_cnt: usize,
            env: *const EnvType,
            term: *const TermType,
        ) MachineError!*const TermType {
            const result = self.allocator.create(TermType) catch return error.OutOfMemory;

            switch (term.*) {
                .var_ => |binder| {
                    // Variable resolution with de Bruijn index adjustment
                    if (lam_cnt >= binder.index) {
                        // Variable is bound by a lambda we haven't discharged yet
                        result.* = term.*;
                    } else if (env.lookup(binder.index - lam_cnt)) |val| {
                        // Variable found in environment, discharge its value
                        return self.dischargeValue(val);
                    } else {
                        // Free variable (shouldn't happen in well-formed terms)
                        result.* = term.*;
                    }
                },
                .lambda => |lam| {
                    // Lambda: increase lambda count for body processing
                    const body = try self.withEnv(lam_cnt + 1, env, lam.body);
                    result.* = .{ .lambda = .{
                        .parameter = lam.parameter,
                        .body = body,
                    } };
                },
                .apply => |app| {
                    // Application: process both function and argument
                    const func = try self.withEnv(lam_cnt, env, app.function);
                    const arg = try self.withEnv(lam_cnt, env, app.argument);
                    result.* = .{ .apply = .{
                        .function = func,
                        .argument = arg,
                    } };
                },
                .delay => |inner| {
                    // Delay: process delayed term
                    const body = try self.withEnv(lam_cnt, env, inner);
                    result.* = .{ .delay = body };
                },
                .force => |inner| {
                    // Force: process term to be forced
                    const body = try self.withEnv(lam_cnt, env, inner);
                    result.* = .{ .force = body };
                },
                .constr => |c| {
                    // Constructor: recursively process all fields
                    const fields = self.allocator.alloc(*const TermType, c.fields.len) catch return error.OutOfMemory;
                    for (c.fields, 0..) |field, i| {
                        fields[i] = try self.withEnv(lam_cnt, env, field);
                    }
                    result.* = .{ .constr = .{ .tag = c.tag, .fields = fields } };
                },
                .case => |c| {
                    // Case expression: process scrutinee and all branches
                    const constr = try self.withEnv(lam_cnt, env, c.constr);
                    const branches = self.allocator.alloc(*const TermType, c.branches.len) catch return error.OutOfMemory;
                    for (c.branches, 0..) |branch, i| {
                        branches[i] = try self.withEnv(lam_cnt, env, branch);
                    }
                    result.* = .{ .case = .{ .constr = constr, .branches = branches } };
                },
                // Constants, builtins, errors: no environment processing needed
                .constant, .builtin, .err => {
                    result.* = term.*;
                },
            }

            return result;
        }

        /// Get consumed budget (initial - remaining), clamped to maxInt on overflow.
        pub fn consumedBudget(self: *const Self, initial: ExBudget) ExBudget {
            return .{
                .cpu = std.math.sub(i64, initial.cpu, self.budget.cpu) catch std.math.maxInt(i64),
                .mem = std.math.sub(i64, initial.mem, self.budget.mem) catch std.math.maxInt(i64),
            };
        }
    };
}
