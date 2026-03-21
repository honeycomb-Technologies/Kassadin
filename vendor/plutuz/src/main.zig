const std = @import("std");
const plutuz = @import("plutuz");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    var file_path: ?[]const u8 = null;
    var pretty_print_only = false;
    var show_budget = false;

    // Parse args
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p")) {
            pretty_print_only = true;
        } else if (std.mem.eql(u8, arg, "--budget")) {
            show_budget = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            std.process.exit(1);
        } else {
            file_path = arg;
        }
    }

    const path = file_path orelse {
        std.debug.print("Error: No input file specified\n", .{});
        printUsage();
        std.process.exit(1);
    };

    const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024 * 10) catch |err| {
        std.debug.print("Error reading file '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // Step 1: Parse
    const program = plutuz.parse(allocator, source) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        std.process.exit(1);
    };

    if (pretty_print_only) {
        // Just pretty print the parsed program
        const output = plutuz.pretty(allocator, program) catch |err| {
            std.debug.print("Pretty print error: {}\n", .{err});
            std.process.exit(1);
        };
        defer allocator.free(output);

        var stdout_buf: [4096]u8 = undefined;
        var stdout_stream = std.fs.File.stdout().writer(&stdout_buf);
        try stdout_stream.interface.writeAll(output);
        try stdout_stream.interface.writeByte('\n');
        try stdout_stream.interface.flush();
    } else {
        // Full evaluation pipeline

        // Step 2: Convert to DeBruijn
        const dProgram = plutuz.nameToDeBruijn(allocator, program) catch |err| {
            std.debug.print("Conversion error: {}\n", .{err});
            std.process.exit(1);
        };

        // Step 3: Evaluate using the CEK machine directly
        const ExBudget = plutuz.cek.ExBudget;
        const initial_budget = ExBudget.unlimited;
        var machine = plutuz.DeBruijnMachine.init(allocator);
        machine.budget = initial_budget;

        const result = machine.run(dProgram.term) catch |err| {
            std.debug.print("Evaluation error: {}\n", .{err});
            std.process.exit(1);
        };

        // Step 4: Pretty print result
        const output = plutuz.prettyDeBruijnTerm(allocator, result) catch |err| {
            std.debug.print("Pretty print error: {}\n", .{err});
            std.process.exit(1);
        };
        defer allocator.free(output);

        var stdout_buf: [4096]u8 = undefined;
        var stdout_stream = std.fs.File.stdout().writer(&stdout_buf);
        try stdout_stream.interface.writeAll(output);
        try stdout_stream.interface.writeByte('\n');

        if (show_budget) {
            const consumed = machine.consumedBudget(initial_budget);
            var budget_buf: [128]u8 = undefined;
            const budget_str = std.fmt.bufPrint(&budget_buf, "({{cpu: {d}\n| mem: {d}}})", .{
                consumed.cpu, consumed.mem,
            }) catch unreachable;
            try stdout_stream.interface.writeAll(budget_str);
            try stdout_stream.interface.writeByte('\n');
        }

        try stdout_stream.interface.flush();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: plutuz [options] <file.uplc>
        \\
        \\Options:
        \\  -p          Pretty print the parsed program (skip evaluation)
        \\  --budget    Show consumed execution budget after evaluation
        \\  -h, --help  Show this help message
        \\
    , .{});
}

test "simple test" {
    // Use an arena to avoid memory leak tracking issues
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "(program 1.0.0 (con integer 42))";
    const program = try plutuz.parse(allocator, source);
    _ = program;
}
