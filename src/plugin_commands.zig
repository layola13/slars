const std = @import("std");
const sio = @import("sio");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const source_expand = @import("source_expand.zig");
const sci_bridge = @import("sci_bridge");
const plugin_api = @import("plugin_api");

const plugin_cli = @import("plugin_cli.zig");
const plugin_sab_paths = @import("plugin_sab_paths.zig");
const plugin_imports = @import("plugin_imports.zig");
const host_paths = @import("host_paths.zig");
const plugin_import_expand = @import("plugin_import_expand.zig");
const plugin_module_table = @import("plugin_module_table.zig");
const plugin_compile = @import("plugin_compile.zig");
const slars_frontend = @import("slars_frontend.zig");
const plugin_compile_options = @import("plugin_compile_options.zig");

const ResolvedImport = plugin_imports.ResolvedImport;
const SlaModuleTable = plugin_module_table.SlaModuleTable;
const SlaResolvedImportGroup = plugin_module_table.SlaResolvedImportGroup;
const appendDefaultJobsAuto = plugin_cli.appendDefaultJobsAuto;
const appendCompiledSaTestPassthrough = plugin_cli.appendCompiledSaTestPassthrough;
const resolveSaExecutable = host_paths.resolveSaExecutable;
const appendSabWorkspacePassthrough = plugin_sab_paths.appendSabWorkspacePassthrough;
const compileSlaFileToSab = plugin_compile.compileSlaFileToSab;
const compileSlaFileToSabWithOptions = plugin_compile.compileSlaFileToSabWithOptions;
const compileSlaSaTestInput = plugin_compile.compileSlaSaTestInput;
const compileSlaSabTestInput = plugin_compile.compileSlaSabTestInput;
const compileSlaToSaString = plugin_compile.compileSlaToSaString;
const defaultOutputPath = plugin_sab_paths.defaultOutputPath;
const expandSlaImportsWithModuleTable = plugin_import_expand.expandSlaImportsWithModuleTable;
const hasEmitSabArg = plugin_sab_paths.hasEmitSabArg;
const isHelpArg = plugin_cli.isHelpArg;
const loadImportedContractsFromResolvedImports = plugin_import_expand.loadImportedContractsFromResolvedImports;
const managedSabPath = plugin_sab_paths.managedSabPath;
const parseOutFileArg = plugin_sab_paths.parseOutFileArg;
const parseSabOutFileArg = plugin_sab_paths.parseSabOutFileArg;
const parseSlaCliOptions = plugin_cli.parseSlaCliOptions;
const parseSlaCliOptionsFrom = plugin_cli.parseSlaCliOptionsFrom;
const parseTestBackendFromArgs = plugin_cli.parseTestBackendFromArgs;
const registerImportedFunctionAliasesFromResolvedImports = plugin_import_expand.registerImportedFunctionAliasesFromResolvedImports;
const resolveSlaInputFile = plugin_compile.resolveSlaInputFile;
const resolveWorkspaceSourcePath = plugin_compile.resolveWorkspaceSourcePath;
const runSlaInitCommand = plugin_cli.runSlaInitCommand;
const runSlaSkillsCommand = plugin_cli.runSlaSkillsCommand;
const runSlaStabilityCommand = plugin_cli.runSlaStabilityCommand;
const saTestFilterFromArgs = plugin_cli.saTestFilterFromArgs;
const testFilterSelectsNoTests = plugin_compile.testFilterSelectsNoTests;
const writeCommandHelp = plugin_cli.writeCommandHelp;
const writeEmptyTestResult = plugin_compile_options.writeEmptyTestResult;
const writeManagedSab = plugin_sab_paths.writeManagedSab;
const writeSabFile = plugin_sab_paths.writeSabFile;

fn buildExeCompileOptions() plugin_compile_options.SlaCompileOptions {
    // Keep the full typed program for executable SAB generation. Entry-point
    // pruning can discard associated constructors that direct lowerers resolve
    // by type (for example `RwLock::new` and `mpsc::channel`).
    return .{
        .load_reachable_imported_bodies_from_registry = true,
    };
}

fn writeSiblingSabFromBytes(
    allocator: std.mem.Allocator,
    file: []const u8,
    sab_bytes: []const u8,
    stderr: *std.Io.Writer,
) !bool {
    const sab_out = try defaultOutputPath(allocator, file, ".sla", ".sab");
    return try writeSabFile(allocator, sab_out, sab_bytes, stderr);
}

fn runSabBuildCommand(
    args: []const []const u8,
    option_start: usize,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const options = parseSlaCliOptionsFrom(args, "sab build", option_start) catch {
        try writeCommandHelp(stderr, "sab build");
        return 1;
    };
    if (options.help_requested) {
        try writeCommandHelp(stderr, "sab build");
        return 0;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;
    const managed_out = try managedSabPath(allocator, file);
    const sab_bytes = (try compileSlaFileToSab(allocator, file, managed_out, stderr)) orelse return 1;
    const managed_path = (try writeManagedSab(allocator, file, sab_bytes, stderr)) orelse return 1;

    if (parseOutFileArg(args, option_start)) |final_out| {
        if (!try writeSabFile(allocator, final_out, sab_bytes, stderr)) return 1;
        try stdout.print("Sla Compiler: Successfully compiled {s} to SAB {s} (managed cache {s}).\n", .{ file, final_out, managed_path });
    } else {
        try stdout.print("Sla Compiler: Successfully compiled {s} to managed SAB {s}.\n", .{ file, managed_path });
    }
    return 0;
}

fn runSabWorkspaceCommand(
    args: []const []const u8,
    option_start: usize,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    _ = stdout;
    const options = parseSlaCliOptionsFrom(args, "sab workspace", option_start) catch {
        try writeCommandHelp(stderr, "sab workspace");
        return 1;
    };
    if (options.help_requested) {
        try writeCommandHelp(stderr, "sab workspace");
        return 0;
    }
    if (options.source_file != null) {
        try stderr.writeAll("Error: sla sab workspace does not accept a source file argument; run it from a workspace root or member directory\n");
        return 1;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file = (try resolveWorkspaceSourcePath(allocator, stderr, options.package_name)) orelse return 1;
    const extra_args = args[options.passthrough_start..];
    const managed_out = try managedSabPath(allocator, file);
    const sab_bytes = (try compileSlaFileToSabWithOptions(allocator, file, managed_out, stderr, buildExeCompileOptions())) orelse return 1;
    const managed_path = (try writeManagedSab(allocator, file, sab_bytes, stderr)) orelse return 1;

    if (parseSabOutFileArg(args, option_start)) |sab_out| {
        if (!try writeSabFile(allocator, sab_out, sab_bytes, stderr)) return 1;
    }
    if (options.emit_sab_file or hasEmitSabArg(args, option_start)) {
        if (!try writeSiblingSabFromBytes(allocator, file, sab_bytes, stderr)) return 1;
    }

    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.append(resolveSaExecutable(allocator));
    try argv.append("build-exe");
    try argv.append(managed_path);
    try appendSabWorkspacePassthrough(&argv, extra_args);

    var child = sio.Child.init(argv.items, allocator);
    const term = child.spawnAndWait() catch |err| {
        try stderr.print("Error: failed to run 'sa build-exe' for SAB workspace output: {}\n", .{err});
        return 1;
    };
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn runSabDisasmCommand(
    args: []const []const u8,
    option_start: usize,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (option_start >= args.len or isHelpArg(args[option_start])) {
        try writeCommandHelp(stderr, "sab disasm");
        return if (option_start < args.len) 0 else 1;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file = args[option_start];
    const out_file = parseOutFileArg(args, option_start + 1);

    const sab_bytes = sio.cwd().readFileAlloc(allocator, file, 16 * 1024 * 1024) catch |err| {
        try stderr.print("SAB Error: failed to read {s}: {}\n", .{ file, err });
        return 1;
    };

    const text = sci_bridge.disasmSabAlloc(allocator, sab_bytes) catch |err| {
        try stderr.print("SAB Error: failed to disassemble {s}: {}\n", .{ file, err });
        return 1;
    };

    if (out_file) |path| {
        sio.cwd().writeFile(.{ .sub_path = path, .data = text }) catch |err| {
            try stderr.print("File Error: failed to write {s}: {}\n", .{ path, err });
            return 1;
        };
        try stdout.print("Disassembled {s} to {s}\n", .{ file, path });
    } else {
        try stdout.writeAll(text);
    }
    return 0;
}

fn runSabCommand(
    args: []const []const u8,
    subcommand_index: usize,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (subcommand_index >= args.len or isHelpArg(args[subcommand_index])) {
        try writeCommandHelp(stderr, "sab");
        return if (subcommand_index < args.len) 0 else 1;
    }
    const subcmd = args[subcommand_index];
    const option_start = subcommand_index + 1;
    if (std.mem.eql(u8, subcmd, "build")) return try runSabBuildCommand(args, option_start, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "workspace")) return try runSabWorkspaceCommand(args, option_start, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "disasm")) return try runSabDisasmCommand(args, option_start, stdout, stderr);
    try stderr.print("Unknown sla sab command: {s}\n", .{subcmd});
    try writeCommandHelp(stderr, "sab");
    return 1;
}

pub fn runSlaCommandImpl(
    ctx: *const plugin_api.Context,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !?u8 {
    if (args.len < 2) return null;
    if (std.mem.eql(u8, args[1], "slab")) {
        return try runSabCommand(args, 2, stdout, stderr);
    }
    if (!std.mem.eql(u8, args[1], "slars") and !std.mem.eql(u8, args[1], "sla")) return null;
    if (args.len < 3) {
        try stderr.writeAll("usage: sa sla <command> [options]\n");
        return 1;
    }
    const cmd = args[2];
    if (std.mem.eql(u8, cmd, "help")) {
        try stderr.writeAll("usage: sla <command> [options]\n");
        try stderr.writeAll("       sa sla <command> [options]\n\n");
        try stderr.writeAll("Commands:\n");
        try stderr.writeAll("  init       [path]\n");
        try stderr.writeAll("  skills     [--json]\n");
        try stderr.writeAll("  stability  schema|verify ...\n");
        try stderr.writeAll("  build      [file] [-p <package>] [--out <file>]\n");
        try stderr.writeAll("  build-workspace [-p <package>] [sa-build-exe args]\n");
        try stderr.writeAll("  build-exe  [file] [-p <package>] [sa-build-exe args]\n");
        try stderr.writeAll("  build-wasm [file] [-p <package>] [sa-build-wasm args]\n");
        try stderr.writeAll("  build-js   [file] [-p <package>] [sa-build-js args]\n");
        try stderr.writeAll("  build-c    [file] [-p <package>] [sa-build-c args]\n");
        try stderr.writeAll("  sab build  [file] [-p <package>] [--out <file.sab>]\n");
        try stderr.writeAll("  sab workspace [-p <package>] [--sab-out <file.sab>] [sa-build-exe args]\n");
        try stderr.writeAll("  sab disasm <file.sab> [--out <file.sa>]\n");
        try stderr.writeAll("  slab build|workspace|disasm ...    Short alias\n");
        try stderr.writeAll("  check      [file] [-p <package>]\n");
        try stderr.writeAll("  test       [file] [-p <package>] [--test-backend auto|sab|sa] [sa-test args]\n");
        return 0;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        return try runSlaInitCommand(arena.allocator(), args, 3, stdout, stderr);
    }
    if (std.mem.eql(u8, cmd, "skills")) {
        return try runSlaSkillsCommand(args, 3, stdout, stderr, ctx.json_mode);
    }
    if (std.mem.eql(u8, cmd, "stability")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        return try runSlaStabilityCommand(arena.allocator(), args, 3, stdout, stderr, ctx.json_mode);
    }
    if (std.mem.eql(u8, cmd, "sab")) {
        return try runSabCommand(args, 3, stdout, stderr);
    }
    if (std.mem.eql(u8, cmd, "build")) {
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;

        var out_file: ?[]const u8 = null;
        var idx: usize = options.passthrough_start;
        while (idx < args.len) : (idx += 1) {
            if (std.mem.eql(u8, args[idx], "--out") or std.mem.eql(u8, args[idx], "-o")) {
                if (idx + 1 < args.len) {
                    out_file = args[idx + 1];
                    idx += 1;
                }
            }
        }

        const final_out = out_file orelse blk: {
            if (std.mem.endsWith(u8, file, ".sla")) {
                const base = file[0 .. file.len - 4];
                break :blk try std.fmt.allocPrint(allocator, "{s}.sa", .{base});
            } else {
                break :blk try std.fmt.allocPrint(allocator, "{s}.sa", .{file});
            }
        };

        const sa_code = (try compileSlaToSaString(allocator, file, final_out, stderr)) orelse return 1;

        sio.cwd().writeFile(.{ .sub_path = final_out, .data = sa_code }) catch |err| {
            try stderr.print("File Error: failed to write output {s}: {}\n", .{ final_out, err });
            return 1;
        };

        try stdout.print("Sla Compiler: Successfully compiled {s} to {s}.\n", .{ file, final_out });
        return 0;
    } else if (std.mem.eql(u8, cmd, "build-exe")) {
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;
        const extra_args = args[options.passthrough_start..];

        const sab_out = try managedSabPath(allocator, file);
        const sab_bytes = (try compileSlaFileToSabWithOptions(allocator, file, sab_out, stderr, buildExeCompileOptions())) orelse return 1;
        if (!try writeSabFile(allocator, sab_out, sab_bytes, stderr)) return 1;
        if (options.emit_sab_file) {
            if (!try writeSiblingSabFromBytes(allocator, file, sab_bytes, stderr)) return 1;
        }

        var argv = std.array_list.Managed([]const u8).init(allocator);
        try argv.append(resolveSaExecutable(allocator));
        try argv.append("build-exe");
        try argv.append(sab_out);
        for (extra_args) |a| try argv.append(a);
        try appendDefaultJobsAuto(&argv, extra_args);

        var child = sio.Child.init(argv.items, allocator);
        const term = child.spawnAndWait() catch |err| {
            try stderr.print("Error: failed to run 'sa build-exe': {}\n", .{err});
            return 1;
        };
        return switch (term) {
            .exited => |code| code,
            else => 1,
        };
    } else if (std.mem.eql(u8, cmd, "build-wasm") or std.mem.eql(u8, cmd, "build-js") or std.mem.eql(u8, cmd, "build-c")) {
        const sa_sub = if (std.mem.eql(u8, cmd, "build-wasm"))
            "build-wasm"
        else if (std.mem.eql(u8, cmd, "build-js"))
            "build-js"
        else
            "build-c";
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;
        const extra_args = args[options.passthrough_start..];

        const sab_out = try managedSabPath(allocator, file);
        const sab_bytes = (try compileSlaFileToSabWithOptions(allocator, file, sab_out, stderr, buildExeCompileOptions())) orelse return 1;
        if (!try writeSabFile(allocator, sab_out, sab_bytes, stderr)) return 1;
        if (options.emit_sab_file) {
            if (!try writeSiblingSabFromBytes(allocator, file, sab_bytes, stderr)) return 1;
        }

        var argv = std.array_list.Managed([]const u8).init(allocator);
        try argv.append(resolveSaExecutable(allocator));
        try argv.append(sa_sub);
        try argv.append(sab_out);
        for (extra_args) |a| try argv.append(a);
        try appendDefaultJobsAuto(&argv, extra_args);

        var child = sio.Child.init(argv.items, allocator);
        const term = child.spawnAndWait() catch |err| {
            try stderr.print("Error: failed to run 'sa {s}': {}\n", .{ sa_sub, err });
            return 1;
        };
        return switch (term) {
            .exited => |code| code,
            else => 1,
        };
    } else if (std.mem.eql(u8, cmd, "build-workspace")) {
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        if (options.source_file != null) {
            try stderr.writeAll("Error: sla build-workspace does not accept a source file argument; run it from a workspace root or member directory\n");
            return 1;
        }

        const file = (try resolveWorkspaceSourcePath(allocator, stderr, options.package_name)) orelse return 1;
        const extra_args = args[options.passthrough_start..];

        const sab_out = try managedSabPath(allocator, file);
        const sab_bytes = (try compileSlaFileToSabWithOptions(allocator, file, sab_out, stderr, buildExeCompileOptions())) orelse return 1;
        if (!try writeSabFile(allocator, sab_out, sab_bytes, stderr)) return 1;
        if (options.emit_sab_file) {
            if (!try writeSiblingSabFromBytes(allocator, file, sab_bytes, stderr)) return 1;
        }

        var argv = std.array_list.Managed([]const u8).init(allocator);
        try argv.append(resolveSaExecutable(allocator));
        try argv.append("build-exe");
        try argv.append(sab_out);
        for (extra_args) |a| try argv.append(a);
        try appendDefaultJobsAuto(&argv, extra_args);

        var child = sio.Child.init(argv.items, allocator);
        const term = child.spawnAndWait() catch |err| {
            try stderr.print("Error: failed to run 'sa build-exe': {}\n", .{err});
            return 1;
        };
        return switch (term) {
            .exited => |code| code,
            else => 1,
        };
    } else if (std.mem.eql(u8, cmd, "check")) {
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;
        const profile = plugin_compile_options.slaProfileEnabled(allocator);
        var stage_start = sio.nanoTimestamp();

        const content = sio.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch |err| {
            try stderr.print("Error: failed to read file {s}: {}\n", .{ file, err });
            return 1;
        };
        plugin_compile_options.slaProfileStage(stderr, profile, "check read source", stage_start);

        // [slars] The check command runs its own inline frontend pipeline
        // (it does not go through plugin_compile.runSlaFrontend), so the
        // root-file gate is applied here as well.
        if (std.mem.endsWith(u8, file, ".slars") and !slarsStrictDisabledHere(allocator)) {
            if (!slars_frontend.checkSource(allocator, content, file, stderr)) {
                return 1;
            }
        }

        stage_start = sio.nanoTimestamp();
        const expanded_content = source_expand.expandForModulePath(allocator, file, content) catch |err| {
            try stderr.print("Macro Expansion Error: failed to expand tuple templates in {s}: {}\n", .{ file, err });
            return 1;
        };
        plugin_compile_options.slaProfileStage(stderr, profile, "check source expand", stage_start);

        stage_start = sio.nanoTimestamp();
        const sla_base_dir = std.fs.path.dirname(file) orelse ".";
        var p = parser_mod.Parser.initWithDirAndOptions(allocator, expanded_content, sla_base_dir, .{
            .parse_test_bodies = false,
        });
        const prog = p.parseProgram() catch |err| {
            try p.printDiagnostic(stderr, file, err);
            return 1;
        };
        plugin_compile_options.slaProfileStage(stderr, profile, "check parse", stage_start);

        stage_start = sio.nanoTimestamp();
        var primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
        var import_modules = SlaModuleTable.initWithParserOptions(allocator, .{
            .parse_function_bodies = false,
            .parse_test_bodies = false,
            .prescan_sla_import_types = false,
        });
        // Check include_all never materializes imported bodies; skip span capture.
        import_modules.capture_body_spans = false;
        defer import_modules.deinit();
        var root_import_groups = std.array_list.Managed(SlaResolvedImportGroup).init(allocator);
        defer root_import_groups.deinit();
        var contract_imports = std.array_list.Managed(ResolvedImport).init(allocator);
        defer contract_imports.deinit();
        const expanded_prog = expandSlaImportsWithModuleTable(allocator, prog, file, &primary_decls, .{
            .imported_bodies_decl_only = true,
            .include_all_imported_decls = true,
        }, &import_modules, &root_import_groups, &contract_imports) catch |err| {
            try stderr.print("Import Error: failed to expand @import SLA sources: {}\n", .{err});
            return 1;
        };
        plugin_compile_options.slaProfileStage(stderr, profile, "check import expand", stage_start);

        stage_start = sio.nanoTimestamp();
        var mono = monomorphizer_mod.Monomorphizer.init(allocator);
        defer mono.deinit();
        var specialized_primary_decls = std.AutoHashMap(*const ast.Node, void).init(allocator);
        const specialized_prog = mono.monomorphize(expanded_prog, &primary_decls, &specialized_primary_decls) catch |err| {
            if (err == error.TemplateNotFound) {
                if (mono.missingTemplateName()) |name| {
                    try stderr.print("Monomorphization Error: failed to specialize generics: {}: {s}\n", .{ err, name });
                } else {
                    try stderr.print("Monomorphization Error: failed to specialize generics: {}\n", .{err});
                }
            } else {
                try stderr.print("Monomorphization Error: failed to specialize generics: {}\n", .{err});
            }
            return 1;
        };
        plugin_compile_options.slaProfileStage(stderr, profile, "check monomorphize", stage_start);

        stage_start = sio.nanoTimestamp();
        var tc = type_checker_mod.TypeChecker.init(allocator);
        defer tc.deinit();

        loadImportedContractsFromResolvedImports(&tc, allocator, contract_imports.items) catch |err| {
            try stderr.print("Import Error: failed to load @import contracts: {}\n", .{err});
            return 1;
        };
        plugin_compile_options.slaProfileStage(stderr, profile, "check load contracts", stage_start);

        stage_start = sio.nanoTimestamp();
        registerImportedFunctionAliasesFromResolvedImports(&tc, allocator, root_import_groups.items, &import_modules) catch |err| {
            try stderr.print("Import Error: failed to register @import function aliases: {}\n", .{err});
            return 1;
        };
        plugin_compile_options.slaProfileStage(stderr, profile, "check import aliases", stage_start);

        stage_start = sio.nanoTimestamp();
        tc.checkProgram(specialized_prog) catch |err| {
            try stderr.print("Type Check Error: failed to verify types: {s} ({})\n", .{ tc.last_error, err });
            return 1;
        };
        plugin_compile_options.slaProfileStage(stderr, profile, "check type check", stage_start);

        try stdout.print("Sla Compiler: Successfully parsed and verified syntax and types of {s}.\n", .{file});
        return 0;
    } else if (std.mem.eql(u8, cmd, "test")) {
        const options = parseSlaCliOptions(args, cmd) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };
        if (options.help_requested) {
            try writeCommandHelp(stderr, cmd);
            return 0;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const file = (try resolveSlaInputFile(allocator, stderr, options)) orelse return 1;
        const extra_args = args[options.passthrough_start..];
        const backend = parseTestBackendFromArgs(extra_args, options.test_backend) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };

        const test_filter = saTestFilterFromArgs(extra_args);
        if ((try testFilterSelectsNoTests(allocator, file, test_filter, stderr)) orelse false) {
            try writeEmptyTestResult(stdout);
            return 0;
        }

        const test_input = switch (backend) {
            .auto, .sab => (try compileSlaSabTestInput(allocator, file, stderr, extra_args, options.emit_sab_file)) orelse return 1,
            .sa => (try compileSlaSaTestInput(allocator, file, stderr, extra_args, options.emit_sab_file)) orelse return 1,
        };
        defer {
            if (test_input.delete_after) sio.cwd().deleteFile(test_input.path) catch {};
        }

        var argv = std.array_list.Managed([]const u8).init(allocator);
        try argv.append(resolveSaExecutable(allocator));
        try argv.append("test");
        try argv.append(test_input.path);
        appendCompiledSaTestPassthrough(&argv, extra_args) catch {
            try writeCommandHelp(stderr, cmd);
            return 1;
        };

        var child = sio.Child.init(argv.items, allocator);
        const term = child.spawnAndWait() catch |err| {
            try stderr.print("Error: failed to run 'sa test': {}\n", .{err});
            return 1;
        };
        return switch (term) {
            .exited => |code| code,
            else => 1,
        };
    } else {
        try stderr.print("Unknown sla command: {s}\n", .{cmd});
        return 1;
    }
}

fn slarsStrictDisabledHere(allocator: std.mem.Allocator) bool {
    const value = sio.getEnvVarOwned(allocator, "SLARS_DISABLE_STRICT") catch return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
}
