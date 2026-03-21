//! Name to DeBruijn conversion.
//! Converts named variables to DeBruijn indices.

const std = @import("std");
const Name = @import("../binder/name.zig").Name;
const DeBruijn = @import("../binder/debruijn.zig").DeBruijn;
const Term = @import("../ast/term.zig").Term;
const Program = @import("../ast/program.zig").Program;

pub const ConvertError = error{
    FreeVariable,
    OutOfMemory,
};

/// Convert a program with Name binders to DeBruijn indices.
pub fn convert(
    allocator: std.mem.Allocator,
    program: *const Program(Name),
) ConvertError!*const Program(DeBruijn) {
    var converter = Converter.init(allocator);
    return converter.convertProgram(program);
}

/// Bidirectional map for unique <-> level lookups
const BiMap = struct {
    unique_to_level: std.AutoHashMapUnmanaged(usize, usize),
    level_to_unique: std.AutoHashMapUnmanaged(usize, usize),

    fn init() BiMap {
        return .{
            .unique_to_level = .{},
            .level_to_unique = .{},
        };
    }

    fn deinit(self: *BiMap, allocator: std.mem.Allocator) void {
        self.unique_to_level.deinit(allocator);
        self.level_to_unique.deinit(allocator);
    }

    fn insert(self: *BiMap, allocator: std.mem.Allocator, unique: usize, level: usize) void {
        self.unique_to_level.put(allocator, unique, level) catch {};
        self.level_to_unique.put(allocator, level, unique) catch {};
    }

    fn remove(self: *BiMap, allocator: std.mem.Allocator, unique: usize, level: usize) void {
        _ = self.unique_to_level.remove(unique);
        _ = self.level_to_unique.remove(level);
        _ = allocator;
    }

    fn getByUnique(self: *const BiMap, unique: usize) ?usize {
        return self.unique_to_level.get(unique);
    }
};

const Converter = struct {
    allocator: std.mem.Allocator,
    current_level: usize,
    /// Stack of scopes (bimap per scope level)
    levels: std.ArrayListUnmanaged(BiMap),

    fn init(allocator: std.mem.Allocator) Converter {
        var converter = Converter{
            .allocator = allocator,
            .current_level = 0,
            .levels = .{},
        };
        // Start with one scope at level 0 (matching Go)
        converter.levels.append(allocator, BiMap.init()) catch {};
        return converter;
    }

    fn convertProgram(self: *Converter, program: *const Program(Name)) ConvertError!*const Program(DeBruijn) {
        const term = try self.convertTerm(program.term);
        const result = self.allocator.create(Program(DeBruijn)) catch return error.OutOfMemory;
        result.* = .{
            .version = program.version,
            .term = term,
        };
        return result;
    }

    fn convertTerm(self: *Converter, term: *const Term(Name)) ConvertError!*const Term(DeBruijn) {
        const result = self.allocator.create(Term(DeBruijn)) catch return error.OutOfMemory;

        switch (term.*) {
            .var_ => |name| {
                const index = self.getIndex(name.unique) orelse return error.FreeVariable;
                const binder = self.allocator.create(DeBruijn) catch return error.OutOfMemory;
                binder.* = .{ .index = index };
                result.* = .{ .var_ = binder };
            },
            .lambda => |lam| {
                // 1. Declare unique at current level (BEFORE starting new scope)
                self.declareUnique(lam.parameter.unique);

                // 2. Get the index for the parameter name
                const param_index = self.getIndex(lam.parameter.unique) orelse return error.FreeVariable;

                // 3. Start new scope
                self.startScope();

                // 4. Convert body
                const body = try self.convertTerm(lam.body);

                // 5. End scope
                self.endScope();

                // 6. Remove the unique
                self.removeUnique(lam.parameter.unique);

                const binder = self.allocator.create(DeBruijn) catch return error.OutOfMemory;
                binder.* = .{ .index = param_index };
                result.* = .{ .lambda = .{ .parameter = binder, .body = body } };
            },
            .apply => |app| {
                const func = try self.convertTerm(app.function);
                const arg = try self.convertTerm(app.argument);
                result.* = .{ .apply = .{ .function = func, .argument = arg } };
            },
            .delay => |inner| {
                result.* = .{ .delay = try self.convertTerm(inner) };
            },
            .force => |inner| {
                result.* = .{ .force = try self.convertTerm(inner) };
            },
            .constant => |c| {
                result.* = .{ .constant = c };
            },
            .builtin => |b| {
                result.* = .{ .builtin = b };
            },
            .err => {
                result.* = .err;
            },
            .case => |c| {
                const constr = try self.convertTerm(c.constr);
                const branches = self.allocator.alloc(*const Term(DeBruijn), c.branches.len) catch return error.OutOfMemory;
                for (c.branches, 0..) |branch, i| {
                    branches[i] = try self.convertTerm(branch);
                }
                result.* = .{ .case = .{ .constr = constr, .branches = branches } };
            },
            .constr => |c| {
                const fields = self.allocator.alloc(*const Term(DeBruijn), c.fields.len) catch return error.OutOfMemory;
                for (c.fields, 0..) |field, i| {
                    fields[i] = try self.convertTerm(field);
                }
                result.* = .{ .constr = .{ .tag = c.tag, .fields = fields } };
            },
        }

        return result;
    }

    /// Get the DeBruijn index for a unique identifier
    fn getIndex(self: *Converter, unique: usize) ?usize {
        // Search scopes from innermost to outermost
        var i: usize = self.levels.items.len;
        while (i > 0) {
            i -= 1;
            if (self.levels.items[i].getByUnique(unique)) |found_level| {
                return self.current_level - found_level;
            }
        }
        return null;
    }

    /// Declare a unique at the current level
    fn declareUnique(self: *Converter, unique: usize) void {
        if (self.current_level < self.levels.items.len) {
            self.levels.items[self.current_level].insert(self.allocator, unique, self.current_level);
        }
    }

    /// Remove a unique from the current level
    fn removeUnique(self: *Converter, unique: usize) void {
        if (self.current_level < self.levels.items.len) {
            self.levels.items[self.current_level].remove(self.allocator, unique, self.current_level);
        }
    }

    /// Start a new scope
    fn startScope(self: *Converter) void {
        self.current_level += 1;
        self.levels.append(self.allocator, BiMap.init()) catch {};
    }

    /// End the current scope
    fn endScope(self: *Converter) void {
        if (self.current_level > 0) {
            self.current_level -= 1;
        }
        if (self.levels.pop()) |scope| {
            var mutable_scope = scope;
            mutable_scope.deinit(self.allocator);
        }
    }
};

test "convert simple lambda" {
    // (lam x x) should convert to (lam i0 i1)
    // TODO: Add tests
}
