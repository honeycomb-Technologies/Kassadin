//! Execution budget for CPU and memory.

const std = @import("std");

pub const ExBudget = struct {
    cpu: i64,
    mem: i64,

    pub const unlimited: ExBudget = .{
        .cpu = std.math.maxInt(i64),
        .mem = std.math.maxInt(i64),
    };

    pub fn sub(self: ExBudget, other: ExBudget) ExBudget {
        return .{
            .cpu = self.cpu - other.cpu,
            .mem = self.mem - other.mem,
        };
    }

    pub fn add(self: ExBudget, other: ExBudget) ExBudget {
        return .{
            .cpu = self.cpu + other.cpu,
            .mem = self.mem + other.mem,
        };
    }

    pub fn occurrences(self: ExBudget, n: i64) ExBudget {
        return .{
            .cpu = self.cpu * n,
            .mem = self.mem * n,
        };
    }
};
