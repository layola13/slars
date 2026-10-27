const std = @import("std");
const plugin_freshness = @import("plugin_freshness.zig");
const sio = @import("sio");
const plugin_api = @import("plugin_api");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const codegen_mod = @import("codegen.zig");
const sab_codegen_mod = @import("sab_codegen.zig");
const stability_metadata = @import("stability_metadata.zig");
const source_expand = @import("source_expand.zig");
const sla_workspace = @import("workspace.zig");
const lowering_rules = @import("lowering_rules.zig");
const sci_bridge = @import("sci_bridge");
pub const handler_bridge = @import("handler_bridge.zig");
const plugin_handler = @import("plugin_handler.zig");
const plugin_skills = @import("plugin_skills.zig");
const plugin_cli = @import("plugin_cli.zig");
const plugin_sab_paths = @import("plugin_sab_paths.zig");

pub const SlaHandlerStateFieldAbi = plugin_handler.SlaHandlerStateFieldAbi;
pub const SlaCompileHandlerOptionsAbi = plugin_handler.SlaCompileHandlerOptionsAbi;
pub const SlaCompileHandlerResultAbi = plugin_handler.SlaCompileHandlerResultAbi;
pub const sla_compile_handler = plugin_handler.sla_compile_handler;
pub const sla_compile_handler_result_free = plugin_handler.sla_compile_handler_result_free;
const TestBackend = plugin_cli.TestBackend;
const SlaCliOptions = plugin_cli.SlaCliOptions;
const isHelpArg = plugin_cli.isHelpArg;
const parseTestBackendFromArgs = plugin_cli.parseTestBackendFromArgs;
const appendSaTestPassthrough = plugin_cli.appendSaTestPassthrough;
const appendDefaultJobsAuto = plugin_cli.appendDefaultJobsAuto;
const runSlaSkillsCommand = plugin_cli.runSlaSkillsCommand;
const runSlaInitCommand = plugin_cli.runSlaInitCommand;
const runSlaStabilityCommand = plugin_cli.runSlaStabilityCommand;
const writeCommandHelp = plugin_cli.writeCommandHelp;
const parseSlaCliOptionsFrom = plugin_cli.parseSlaCliOptionsFrom;
const parseSlaCliOptions = plugin_cli.parseSlaCliOptions;
const saTestFilterFromArgs = plugin_cli.saTestFilterFromArgs;
const defaultOutputPath = plugin_sab_paths.defaultOutputPath;
const managedSabPath = plugin_sab_paths.managedSabPath;
const managedSabTestPath = plugin_sab_paths.managedSabTestPath;
const writeSabFile = plugin_sab_paths.writeSabFile;
const writeManagedSab = plugin_sab_paths.writeManagedSab;
const parseOutFileArg = plugin_sab_paths.parseOutFileArg;
const parseSabOutFileArg = plugin_sab_paths.parseSabOutFileArg;
const hasEmitSabArg = plugin_sab_paths.hasEmitSabArg;
const appendSabWorkspacePassthrough = plugin_sab_paths.appendSabWorkspacePassthrough;
const virtualSaPathForSabOutput = plugin_sab_paths.virtualSaPathForSabOutput;
const sabSaStdRoot = plugin_sab_paths.sabSaStdRoot;
const sabProjectRoot = plugin_sab_paths.sabProjectRoot;

const plugin_imports = @import("plugin_imports.zig");

const max_import_bytes = plugin_imports.max_import_bytes;
const ResolvedImport = plugin_imports.ResolvedImport;
const ResolvedModuleImport = plugin_imports.ResolvedModuleImport;
const moduleNamespaceFromImportPath = plugin_imports.moduleNamespaceFromImportPath;
const moduleNamespaceMatchesImportPath = plugin_imports.moduleNamespaceMatchesImportPath;
const ImportedMangledSymbol = plugin_imports.ImportedMangledSymbol;
const splitImportedMangledSymbol = plugin_imports.splitImportedMangledSymbol;
const stringSliceLessThan = plugin_imports.stringSliceLessThan;
const resolvedImportLessThan = plugin_imports.resolvedImportLessThan;
const isGlobImportPath = plugin_imports.isGlobImportPath;
const globNameMatches = plugin_imports.globNameMatches;
const isSaStdImport = plugin_imports.isSaStdImport;
const isSlaStdImport = plugin_imports.isSlaStdImport;
const readImportFileIfExistsWithOutputPath = plugin_imports.readImportFileIfExistsWithOutputPath;
const readImportFileIfExists = plugin_imports.readImportFileIfExists;
const readImportFromRoot = plugin_imports.readImportFromRoot;
const resolveSaStdImport = plugin_imports.resolveSaStdImport;
const resolveSlaStdImport = plugin_imports.resolveSlaStdImport;
const resolveImportFile = plugin_imports.resolveImportFile;
const appendResolvedImportFiles = plugin_imports.appendResolvedImportFiles;
const resolveImportFiles = plugin_imports.resolveImportFiles;
const importPathFromLine = plugin_imports.importPathFromLine;
const expandedSourceMayContainImports = plugin_imports.expandedSourceMayContainImports;

const plugin_import_expand = @import("plugin_import_expand.zig");

const appendModuleDeclsSelective = plugin_import_expand.appendModuleDeclsSelective;
const expandSlaImports = plugin_import_expand.expandSlaImports;
const expandSlaImportsWithModuleTable = plugin_import_expand.expandSlaImportsWithModuleTable;
const loadImportedContracts = plugin_import_expand.loadImportedContracts;
const loadImportedContractsFromResolvedImports = plugin_import_expand.loadImportedContractsFromResolvedImports;
const registerImportedFunctionAliases = plugin_import_expand.registerImportedFunctionAliases;
const registerImportedFunctionAliasesFromResolvedImports = plugin_import_expand.registerImportedFunctionAliasesFromResolvedImports;

const plugin_imported_macros = @import("plugin_imported_macros.zig");

const expandedSourceMayContainImportedMacros = plugin_imported_macros.expandedSourceMayContainImportedMacros;
const macroParamName = plugin_imported_macros.macroParamName;
const isLeadingOutputMacroParam = plugin_imported_macros.isLeadingOutputMacroParam;
const macroParamIndex = plugin_imported_macros.macroParamIndex;
const markBorrowedParam = plugin_imported_macros.markBorrowedParam;
const markDirectBorrowedMacroParams = plugin_imported_macros.markDirectBorrowedMacroParams;
const markDirectAddressSlotMacroParams = plugin_imported_macros.markDirectAddressSlotMacroParams;
const markExpandedImportedMacroParamMasks = plugin_imported_macros.markExpandedImportedMacroParamMasks;
const importedMacroCalleeName = plugin_imported_macros.importedMacroCalleeName;
const appendUniqueDirectCallee = plugin_imported_macros.appendUniqueDirectCallee;
const collectDirectSlaMacroCallees = plugin_imported_macros.collectDirectSlaMacroCallees;
const appendExpandedImportedMacroDirectCallees = plugin_imported_macros.appendExpandedImportedMacroDirectCallees;
const loadImportedMacrosFromExpandedSource = plugin_imported_macros.loadImportedMacrosFromExpandedSource;
const loadImportedMacros = plugin_imported_macros.loadImportedMacros;

const plugin_module_table = @import("plugin_module_table.zig");

const SlaModuleExports = plugin_module_table.SlaModuleExports;
const SlaModule = plugin_module_table.SlaModule;
const SlaImportExpansionOptions = plugin_module_table.SlaImportExpansionOptions;
const SlaResolvedImportGroup = plugin_module_table.SlaResolvedImportGroup;
const SlaModuleTable = plugin_module_table.SlaModuleTable;

const plugin_reachability = @import("plugin_reachability.zig");

const SlaCallableIndex = plugin_reachability.SlaCallableIndex;

const SyntacticFactSet = plugin_reachability.SyntacticFactSet;
const fieldFactKeyMatchesName = plugin_reachability.fieldFactKeyMatchesName;

const FunctionSyntacticFacts = plugin_reachability.FunctionSyntacticFacts;
const ReachabilityAnalysis = plugin_reachability.ReachabilityAnalysis;

const literalHasNoImportKeyword = plugin_reachability.literalHasNoImportKeyword;
const nodeIsNoImportSource = plugin_reachability.nodeIsNoImportSource;
const nodeIsZeroImportScan = plugin_reachability.nodeIsZeroImportScan;
const evalSyntacticInt = plugin_reachability.evalSyntacticInt;
const evalSyntacticBool = plugin_reachability.evalSyntacticBool;

const buildCallFactsForDecl = plugin_reachability.buildCallFactsForDecl;
const syntacticFuncDeclForCall = plugin_reachability.syntacticFuncDeclForCall;
const moduleQualifiedCallableForCaller = plugin_reachability.moduleQualifiedCallableForCaller;
const syntacticFuncDeclForCallFromCaller = plugin_reachability.syntacticFuncDeclForCallFromCaller;
const singleReturnValue = plugin_reachability.singleReturnValue;
const recordKnownFieldsFromStructLiteral = plugin_reachability.recordKnownFieldsFromStructLiteral;
const recordKnownFieldsFromCall = plugin_reachability.recordKnownFieldsFromCall;
const recordKnownFieldsFromExpr = plugin_reachability.recordKnownFieldsFromExpr;
const syntacticConcreteTypeNameFromExpr = plugin_reachability.syntacticConcreteTypeNameFromExpr;
const updateFactsForLetBinding = plugin_reachability.updateFactsForLetBinding;
const pruneKnownFalseBranchesInBlock = plugin_reachability.pruneKnownFalseBranchesInBlock;
const pruneKnownFalseBranchesInExpr = plugin_reachability.pruneKnownFalseBranchesInExpr;

const reachabilityNodeBindsIdentifier = plugin_reachability.reachabilityNodeBindsIdentifier;
const reachabilityClosureShadowsIdentifier = plugin_reachability.reachabilityClosureShadowsIdentifier;
const reachabilityBlockUsesIdentifier = plugin_reachability.reachabilityBlockUsesIdentifier;
const reachabilityNodeUsesIdentifier = plugin_reachability.reachabilityNodeUsesIdentifier;
const pruneDeadZeroImportScanLetsInBlock = plugin_reachability.pruneDeadZeroImportScanLetsInBlock;

const plugin_project_shortcuts = @import("plugin_project_shortcuts.zig");

const rewriteProjectSnapshotTestShortcuts = plugin_project_shortcuts.rewriteProjectSnapshotTestShortcuts;
const isProjectShortcutRetainedHelperName = plugin_project_shortcuts.isProjectShortcutRetainedHelperName;

const pruneKnownFalseBranchesInReachableDecls = plugin_reachability.pruneKnownFalseBranchesInReachableDecls;
const scanReferencedSymbolRoots = plugin_reachability.scanReferencedSymbolRoots;
const buildReachableSymbols = plugin_reachability.buildReachableSymbols;
const collectReachableModuleBodyNames = plugin_reachability.collectReachableModuleBodyNames;
const materializeReachableImportedModuleBodies = plugin_reachability.materializeReachableImportedModuleBodies;
const testMatchesFilter = plugin_reachability.testMatchesFilter;
const recordReferencedType = plugin_reachability.recordReferencedType;
const markSyntacticReachableFunc = plugin_reachability.markSyntacticReachableFunc;
const collectSyntacticReachableExpr = plugin_reachability.collectSyntacticReachableExpr;
const collectSyntacticReachableBlock = plugin_reachability.collectSyntacticReachableBlock;

const plugin_output_paths = @import("plugin_output_paths.zig");

const rewriteProgramImportsForOutput = plugin_output_paths.rewriteProgramImportsForOutput;

const plugin_compile_options = @import("plugin_compile_options.zig");

const SlaCompileOptions = plugin_compile_options.SlaCompileOptions;
const defaultSlaCompileOptions = plugin_compile_options.defaultSlaCompileOptions;
const slaProfileEnabled = plugin_compile_options.slaProfileEnabled;
const slaProfileStage = plugin_compile_options.slaProfileStage;
const writeEmptyTestResult = plugin_compile_options.writeEmptyTestResult;

const plugin_compile = @import("plugin_compile.zig");

const compileSlaFileToSab = plugin_compile.compileSlaFileToSab;
const compileSlaFileToSabOrSa = plugin_compile.compileSlaFileToSabOrSa;
const compileSlaFileToSabWithOptions = plugin_compile.compileSlaFileToSabWithOptions;
const compileSlaSaTestInput = plugin_compile.compileSlaSaTestInput;
const compileSlaSabTestInput = plugin_compile.compileSlaSabTestInput;
const compileSlaToSaString = plugin_compile.compileSlaToSaString;
const compileSlaToSaStringWithOptions = plugin_compile.compileSlaToSaStringWithOptions;
const maybeWriteSiblingSab = plugin_compile.maybeWriteSiblingSab;
const pruneTestsByFilter = plugin_compile.pruneTestsByFilter;
const pruneUnreachableTestFunctionDeclsBeforeTypeCheck = plugin_compile.pruneUnreachableTestFunctionDeclsBeforeTypeCheck;
const resolveSlaInputFile = plugin_compile.resolveSlaInputFile;
const resolveWorkspaceSourcePath = plugin_compile.resolveWorkspaceSourcePath;
const testFilterSelectsNoTests = plugin_compile.testFilterSelectsNoTests;

const plugin_emit_reachability = @import("plugin_emit_reachability.zig");

const collectReachableExpr = plugin_emit_reachability.collectReachableExpr;
const collectReachableBlock = plugin_emit_reachability.collectReachableBlock;
const collectNeededTraitImplsExpr = plugin_emit_reachability.collectNeededTraitImplsExpr;
const collectNeededTraitImplsBlock = plugin_emit_reachability.collectNeededTraitImplsBlock;

const plugin_commands = @import("plugin_commands.zig");

pub const runSlaCommandImpl = plugin_commands.runSlaCommandImpl;

const HostStreamSink = struct {
    stream: plugin_api.HostStream,

    pub fn writeAll(self: HostStreamSink, bytes: []const u8) !void {
        const wa = self.stream.write_all orelse return error.WriteFailed;
        if (wa(self.stream.ctx, bytes.ptr, bytes.len) != @intFromEnum(plugin_api.AbiStatus.ok)) return error.WriteFailed;
    }
};

fn runSlaCommandAbi(
    ctx: *const plugin_api.Context,
    argv: [*]const [*:0]const u8,
    argv_len: usize,
    stdout: plugin_api.HostStream,
    stderr: plugin_api.HostStream,
    out_code: *u8,
) callconv(.c) u32 {
    out_code.* = 0;
    const allocator = std.heap.page_allocator;
    var local_ctx = ctx.*;
    local_ctx.allocator = allocator;
    plugin_freshness.host_ctx = &local_ctx;

    const args = allocator.alloc([]const u8, argv_len) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer allocator.free(args);
    for (0..argv_len) |i| {
        args[i] = std.mem.span(argv[i]);
    }

    var out_fw = sio.ForwardWriter(HostStreamSink).init(.{ .stream = stdout });
    var err_fw = sio.ForwardWriter(HostStreamSink).init(.{ .stream = stderr });
    const stdout_writer = out_fw.writer();
    const stderr_writer = err_fw.writer();

    const result = runSlaCommandImpl(&local_ctx, args, stdout_writer, stderr_writer) catch {
        stdout_writer.flush() catch {};
        stderr_writer.flush() catch {};
        return @intFromEnum(plugin_api.AbiStatus.failed);
    };
    stdout_writer.flush() catch {};
    stderr_writer.flush() catch {};
    if (result) |code| {
        out_code.* = code;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    }
    return @intFromEnum(plugin_api.AbiStatus.unknown_command);
}

const descriptor = plugin_api.PluginDescriptor{
    .abi_version = plugin_api.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin_api.PluginDescriptor))),
    .name = "slars",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = runSlaCommandAbi,
    .skills_ptr = plugin_skills.skills[0..].ptr,
    .skills_len = plugin_skills.skills.len,
};

pub export const saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = descriptor;
pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin_api.PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}

test {
    _ = @import("plugin_tests.zig");
}
