const std = @import("std");
const sio = @import("sio");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const lowering_rules = @import("lowering_rules.zig");
const source_expand = @import("source_expand.zig");
const host_paths = @import("host_paths.zig");
const slars_frontend = @import("slars_frontend.zig");

pub const ParserError = error{
    SyntaxError,
    InlineStructNotAllowed,
    InlineImplNotAllowed,
    InlineMacroNotAllowed,
    ExternBlockRequiresExtern,
    ExpectedDeclaration,
    UnexpectedToken,
    UnexpectedInfixToken,
    InvalidCallTarget,
    UnexpectedTypeToken,
    OutOfMemory,
    Overflow,
    InvalidCharacter,
};

pub const ImportTypeSurface = struct {
    types: []const []const u8,
    enums: []const []const u8,
    source: []const u8,
    expanded_source: []const u8,
    complete: bool,
};

pub const ImportTypeScanCache = std.StringHashMap(ImportTypeSurface);

pub const Parser = struct {
    pub const Options = struct {
        parse_function_bodies: bool = true,
        function_body_names: ?*const std.StringHashMap(void) = null,
        parse_macro_bodies: bool = true,
        macro_body_names: ?*const std.StringHashMap(void) = null,
        parse_test_bodies: bool = true,
        prescan_sla_import_types: bool = true,
    };

    allocator: std.mem.Allocator,
    lex: lexer.Lexer,
    tok: lexer.Token,
    last_expected: ?[]const u8,
    known_types: std.array_list.Managed([]const u8),
    known_enums: std.array_list.Managed([]const u8),
    known_modules: std.array_list.Managed([]const u8),
    current_impl_target: ?*ast.Type,
    base_dir: []const u8,
    import_scan_depth: usize,
    /// Canonical `.sla` paths already visited by recursive type prescanning.
    /// Nested parsers copy this map state and return the updated state to their
    /// parent, so diamond imports and cycles are scanned once per root Parser.
    import_type_scan_cache: ImportTypeScanCache,
    import_type_scan_cache_hits: usize,
    options: Options,
    /// Counter for parser-synthesized temporaries (`?.` desugar). Fresh per
    /// Parser so nested/chained chains never collide with each other.
    synth_counter: usize,
    /// Exact `{ ... }` source slices for function bodies that were skipped
    /// during the current parse. Keys are the created `func_decl` nodes and
    /// values point into the parser buffer / expanded module source.
    function_body_spans: std.AutoHashMap(*ast.Node, []const u8),

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) Parser {
        return initWithDir(allocator, buffer, ".");
    }

    pub fn initWithDir(allocator: std.mem.Allocator, buffer: []const u8, base_dir: []const u8) Parser {
        return initWithDirAndOptions(allocator, buffer, base_dir, .{});
    }

    pub fn initWithDirAndOptions(allocator: std.mem.Allocator, buffer: []const u8, base_dir: []const u8, options: Options) Parser {
        var p = Parser{
            .allocator = allocator,
            .lex = lexer.Lexer.init(slars_frontend.transformSource(allocator, buffer)),
            .tok = undefined,
            .last_expected = null,
            .known_types = std.array_list.Managed([]const u8).init(allocator),
            .known_enums = std.array_list.Managed([]const u8).init(allocator),
            .known_modules = std.array_list.Managed([]const u8).init(allocator),
            .current_impl_target = null,
            .base_dir = base_dir,
            .import_scan_depth = 0,
            .import_type_scan_cache = ImportTypeScanCache.init(allocator),
            .import_type_scan_cache_hits = 0,
            .options = options,
            .synth_counter = 0,
            .function_body_spans = std.AutoHashMap(*ast.Node, []const u8).init(allocator),
        };
        p.tok = p.lex.next();
        return p;
    }

    pub fn knownTypeNames(self: *const Parser) []const []const u8 {
        return self.known_types.items;
    }

    pub fn knownEnumNames(self: *const Parser) []const []const u8 {
        return self.known_enums.items;
    }

    pub fn prescannedImportPathCount(self: *const Parser) usize {
        return self.import_type_scan_cache.count();
    }

    pub fn seedImportTypeScanCache(self: *Parser, cache: ImportTypeScanCache) void {
        self.import_type_scan_cache = cache;
    }

    pub fn importTypeScanCache(self: *const Parser) ImportTypeScanCache {
        return self.import_type_scan_cache;
    }

    pub fn importTypeScanCacheHitCount(self: *const Parser) usize {
        return self.import_type_scan_cache_hits;
    }

    pub fn seedKnownTypeNames(self: *Parser, type_names: []const []const u8, enum_names: []const []const u8) !void {
        try self.known_types.appendSlice(type_names);
        try self.known_enums.appendSlice(enum_names);
    }

    pub fn functionBodySpanFor(self: *const Parser, node: *ast.Node) ?[]const u8 {
        return self.function_body_spans.get(node);
    }

    /// Parse a previously captured `{ ... }` function-body span with the
    /// caller's known type/enum surface, without recursive import prescanning.
    pub fn parseFunctionBodySpan(
        allocator: std.mem.Allocator,
        body_source: []const u8,
        type_names: []const []const u8,
        enum_names: []const []const u8,
    ) ParserError![]const *ast.Node {
        var parser = initWithDirAndOptions(allocator, body_source, ".", .{
            .parse_function_bodies = true,
            .parse_macro_bodies = true,
            .parse_test_bodies = true,
            .prescan_sla_import_types = false,
        });
        try parser.seedKnownTypeNames(type_names, enum_names);
        return try parser.parseBlock();
    }

    fn advance(self: *Parser) void {
        self.tok = self.lex.next();
    }

    fn peek(self: *Parser) lexer.Token.Tag {
        return self.tok.tag;
    }

    fn match(self: *Parser, tag: lexer.Token.Tag) bool {
        if (self.tok.tag == tag) {
            self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, tag: lexer.Token.Tag) ParserError!void {
        if (self.tok.tag != tag) {
            self.last_expected = @tagName(tag);
            return ParserError.SyntaxError;
        }
        self.advance();
    }

    fn expectGenericClose(self: *Parser) ParserError!void {
        switch (self.tok.tag) {
            .greater_than => self.advance(),
            .greater_greater => {
                self.tok = lexer.Token{
                    .tag = .greater_than,
                    .loc = .{
                        .start = self.tok.loc.start + 1,
                        .end = self.tok.loc.end,
                    },
                };
            },
            else => {
                self.last_expected = "generic close token '>'";
                return ParserError.SyntaxError;
            },
        }
    }

    const SourcePos = struct {
        line: usize,
        column: usize,
        line_start: usize,
        line_end: usize,
    };

    fn sourcePos(self: *Parser, byte_index: usize) SourcePos {
        var line: usize = 1;
        var column: usize = 1;
        var line_start: usize = 0;
        var i: usize = 0;
        const limit = @min(byte_index, self.lex.buffer.len);
        while (i < limit) : (i += 1) {
            if (self.lex.buffer[i] == '\n') {
                line += 1;
                column = 1;
                line_start = i + 1;
            } else {
                column += 1;
            }
        }
        var line_end = line_start;
        while (line_end < self.lex.buffer.len and self.lex.buffer[line_end] != '\n' and self.lex.buffer[line_end] != '\r') : (line_end += 1) {}
        return .{ .line = line, .column = column, .line_start = line_start, .line_end = line_end };
    }

    fn lineStartForLine(self: *Parser, target_line: usize) usize {
        if (target_line <= 1) return 0;
        var line: usize = 1;
        var i: usize = 0;
        while (i < self.lex.buffer.len) : (i += 1) {
            if (self.lex.buffer[i] == '\n') {
                line += 1;
                if (line == target_line) return i + 1;
            }
        }
        return self.lex.buffer.len;
    }

    fn lineEndFromStart(self: *Parser, start: usize) usize {
        var end = start;
        while (end < self.lex.buffer.len and self.lex.buffer[end] != '\n' and self.lex.buffer[end] != '\r') : (end += 1) {}
        return end;
    }

    fn expectedDescription(self: *Parser, err: ParserError) []const u8 {
        if (self.last_expected) |expected| return expected;
        return switch (err) {
            ParserError.ExpectedDeclaration => "function, struct, enum, trait, impl, const, macro, extern block, module, or annotation declaration",
            ParserError.UnexpectedToken => "valid expression or statement token",
            ParserError.UnexpectedInfixToken => "valid infix operator or expression continuation",
            ParserError.UnexpectedTypeToken => "valid type expression",
            ParserError.InvalidCallTarget => "callable function, method, module function, or associated function target",
            ParserError.InlineStructNotAllowed => "non-inline struct declaration",
            ParserError.InlineImplNotAllowed => "non-inline impl declaration",
            ParserError.InlineMacroNotAllowed => "non-inline macro declaration",
            ParserError.ExternBlockRequiresExtern => "extern block declaration",
            ParserError.SyntaxError => "valid Sla syntax",
            ParserError.InvalidCharacter => "valid character or literal",
            ParserError.Overflow => "literal within supported range",
            ParserError.OutOfMemory => "available parser memory",
        };
    }

    fn tokenDisplay(self: *Parser) []const u8 {
        if (self.tok.tag == .eof) return "end of file";
        const text = self.lexeme(self.tok.loc);
        if (text.len == 0) return @tagName(self.tok.tag);
        return text;
    }

    fn findBraceNote(self: *Parser, loc_start: usize) ?SourcePos {
        if (self.tok.tag == .r_brace) {
            var depth: usize = 0;
            var l = lexer.Lexer.init(self.lex.buffer[0..loc_start]);
            while (true) {
                const t = l.next();
                switch (t.tag) {
                    .eof => break,
                    .l_brace => depth += 1,
                    .r_brace => {
                        if (depth == 0) return self.sourcePos(t.loc.start);
                        depth -= 1;
                    },
                    else => {},
                }
            }
            if (depth == 0) return self.sourcePos(loc_start);
        } else if (self.tok.tag == .eof) {
            var depth: usize = 0;
            var last_open: ?usize = null;
            var l = lexer.Lexer.init(self.lex.buffer);
            while (true) {
                const t = l.next();
                switch (t.tag) {
                    .eof => break,
                    .l_brace => {
                        depth += 1;
                        last_open = t.loc.start;
                    },
                    .r_brace => {
                        if (depth > 0) depth -= 1;
                    },
                    else => {},
                }
            }
            if (depth > 0 and last_open != null) return self.sourcePos(last_open.?);
        }
        return null;
    }

    pub fn printDiagnostic(self: *Parser, writer: anytype, file: []const u8, err: ParserError) !void {
        const pos = self.sourcePos(self.tok.loc.start);
        const expected = self.expectedDescription(err);
        const found = self.tokenDisplay();
        try writer.print("Syntax Error: failed to parse {s}:{}:{}: {}\n", .{ file, pos.line, pos.column, err });
        try writer.print("  |\n", .{});
        const first_line = if (pos.line > 2) pos.line - 2 else 1;
        var line_no = first_line;
        while (line_no <= pos.line + 2) : (line_no += 1) {
            const start = self.lineStartForLine(line_no);
            if (start >= self.lex.buffer.len and line_no > pos.line) break;
            const end = self.lineEndFromStart(start);
            try writer.print("{d:5} | {s}\n", .{ line_no, self.lex.buffer[start..end] });
            if (line_no == pos.line) {
                try writer.print("      | ", .{});
                var col: usize = 1;
                while (col < pos.column) : (col += 1) try writer.print(" ", .{});
                try writer.print("^ found '{s}', expected {s}\n", .{ found, expected });
            }
            if (end >= self.lex.buffer.len) break;
        }
        if (self.tok.tag == .r_brace and err == ParserError.ExpectedDeclaration) {
            try writer.print("  |\n  | Note: unexpected closing brace at top level; this '}}' does not match any opening brace in the current declaration context.\n", .{});
            try writer.print("  | Hint: check whether the previous function, impl, struct, or module has an extra '}}'.\n", .{});
        } else if (self.tok.tag == .eof) {
            if (self.findBraceNote(self.tok.loc.start)) |open_pos| {
                try writer.print("  |\n  | Note: reached end of file while a '{{' opened near line {}, column {} may still be unmatched.\n", .{ open_pos.line, open_pos.column });
            }
        }
    }

    fn lexeme(self: *Parser, loc: lexer.Token.Loc) []const u8 {
        return self.lex.buffer[loc.start..loc.end];
    }

    fn stringSliceLessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn isImportPathToken(tag: lexer.Token.Tag) bool {
        return switch (tag) {
            .identifier,
            .asterisk,
            .slash,
            .dot,
            .range,
            .minus,
            .double_colon,
            => true,
            else => false,
        };
    }

    fn parseImportPathTokenSequence(self: *Parser) ParserError![]const u8 {
        var buf = std.array_list.Managed(u8).init(self.allocator);
        while (isImportPathToken(self.peek())) {
            const part = self.lexeme(self.tok.loc);
            try buf.appendSlice(part);
            self.advance();
        }
        if (buf.items.len == 0) return ParserError.SyntaxError;
        return try buf.toOwnedSlice();
    }

    fn isGlobImportPath(path: []const u8) bool {
        return std.mem.indexOfScalar(u8, path, '*') != null;
    }

    fn isSlaStdImport(path: []const u8) bool {
        return std.mem.eql(u8, path, "sla_std") or std.mem.startsWith(u8, path, "sla_std/");
    }

    fn readSlaStdPathIfExists(self: *Parser, root: []const u8, rel_path: []const u8) !?[]const u8 {
        if (rel_path.len == 0) return null;
        const candidate = try std.fs.path.join(self.allocator, &.{ root, rel_path });
        _ = sio.cwd().access(candidate, .{}) catch |err| {
            if (err == error.FileNotFound or err == error.NotDir or err == error.IsDir) return null;
            return err;
        };
        return candidate;
    }

    fn resolveSlaStdImportPath(self: *Parser, import_path: []const u8) !?[]const u8 {
        if (!isSlaStdImport(import_path)) return null;
        if (std.mem.eql(u8, import_path, "sla_std")) return null;
        const rel_path = import_path["sla_std/".len..];

        if (sio.getEnvVarOwned(self.allocator, "SLA_STD_DIR")) |env_root| {
            if (try self.readSlaStdPathIfExists(env_root, rel_path)) |resolved| return resolved;
        } else |_| {}

        if (host_paths.homeDirectory(self.allocator)) |home| {
            defer self.allocator.free(home);
            const home_std_root = try std.fs.path.join(self.allocator, &.{ home, "projects", "sa_plugins", "sa_plugin_sla", "sla_std" });
            if (try self.readSlaStdPathIfExists(home_std_root, rel_path)) |resolved| return resolved;
        }

        const candidate_roots = [_][]const u8{
            "sla_std",
            "sa_plugin_sla/sla_std",
            "../sa_plugin_sla/sla_std",
            "../sa_plugins/sa_plugin_sla/sla_std",
            "../../sa_plugins/sa_plugin_sla/sla_std",
            "/home/vscode/projects/sa_plugins/sa_plugin_sla/sla_std",
        };
        for (candidate_roots) |root| {
            if (try self.readSlaStdPathIfExists(root, rel_path)) |resolved| return resolved;
        }
        return null;
    }

    fn globNameMatches(pattern: []const u8, name: []const u8) bool {
        const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, name);
        if (std.mem.indexOfScalarPos(u8, pattern, star + 1, '*') != null) return false;
        const prefix = pattern[0..star];
        const suffix = pattern[star + 1 ..];
        if (name.len < prefix.len + suffix.len) return false;
        return std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, suffix);
    }

    fn isKnownTypeName(self: *Parser, name: []const u8) bool {
        if (std.mem.eql(u8, name, "Self") and self.current_impl_target != null) return true;
        for (self.known_types.items) |ty_name| {
            if (std.mem.eql(u8, ty_name, name)) return true;
        }
        return false;
    }

    fn isKnownEnumName(self: *Parser, name: []const u8) bool {
        for (self.known_enums.items) |enum_name| {
            if (std.mem.eql(u8, enum_name, name)) return true;
        }
        return false;
    }

    fn isKnownModuleName(self: *Parser, name: []const u8) bool {
        for (self.known_modules.items) |module_name| {
            if (std.mem.eql(u8, module_name, name)) return true;
        }
        return false;
    }

    fn recordImportModuleName(self: *Parser, import_path: []const u8) !void {
        const base = std.fs.path.basename(import_path);
        const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
        if (stem.len == 0 or self.isKnownModuleName(stem)) return;
        try self.known_modules.append(stem);
    }

    fn recordImplTargetType(self: *Parser, target_ty: *ast.Type) !void {
        switch (target_ty.*) {
            .user_defined => try self.known_types.append(target_ty.user_defined.name),
            else => {},
        }
    }

    pub fn parseProgram(self: *Parser) ParserError!*ast.Node {
        var decls = std.array_list.Managed(*ast.Node).init(self.allocator);
        errdefer decls.deinit();

        while (self.peek() != .eof) {
            if (self.peek() == .keyword_using) {
                const decl = try self.parseUsingDecl();
                try decls.append(decl);
                continue;
            }
            if (self.peek() == .keyword_mod) {
                try self.parseModuleDeclInto(&decls, null);
                _ = self.match(.semicolon);
                continue;
            }
            const decl = try self.parseDecl();
            if (decl.* == .program) {
                for (decl.program.decls) |inner_decl| {
                    try decls.append(inner_decl);
                    switch (inner_decl.*) {
                        .struct_decl => try self.known_types.append(inner_decl.struct_decl.name),
                        .type_alias_decl => try self.known_types.append(inner_decl.type_alias_decl.name),
                        .enum_decl => {
                            try self.known_types.append(inner_decl.enum_decl.name);
                            try self.known_enums.append(inner_decl.enum_decl.name);
                        },
                        .impl_decl => try self.recordImplTargetType(inner_decl.impl_decl.target_ty),
                        else => {},
                    }
                }
            } else {
                try decls.append(decl);
                switch (decl.*) {
                    .struct_decl => try self.known_types.append(decl.struct_decl.name),
                    .type_alias_decl => try self.known_types.append(decl.type_alias_decl.name),
                    .enum_decl => {
                        try self.known_types.append(decl.enum_decl.name);
                        try self.known_enums.append(decl.enum_decl.name);
                    },
                    .impl_decl => try self.recordImplTargetType(decl.impl_decl.target_ty),
                    else => {},
                }
            }
            // Consume optional semicolon after top‑level declaration to tolerate both styles
            _ = self.match(.semicolon);
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .program = .{ .decls = try decls.toOwnedSlice() } };
        return node;
    }

    fn parseDecl(self: *Parser) ParserError!*ast.Node {
        const is_pub = self.match(.keyword_pub);
        const is_extern = self.match(.keyword_extern);
        const abi = if (is_extern) try self.parseOptionalExternAbi() else null;
        const is_inline = self.match(.keyword_inline);
        const is_async = self.match(.keyword_async);
        if (self.peek() == .keyword_struct) {
            if (is_inline) return ParserError.InlineStructNotAllowed;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseStructDecl();
        } else if (self.peek() == .keyword_union) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseUnionDecl();
        } else if (self.peek() == .keyword_enum) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseEnumDecl();
        } else if (self.peek() == .keyword_trait) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseTraitDecl();
        } else if (self.peek() == .keyword_type) {
            if (is_inline or is_async or is_extern) return ParserError.ExpectedDeclaration;
            return try self.parseTypeAliasDecl();
        } else if (self.peek() == .l_brace) {
            if (!is_extern) return ParserError.ExternBlockRequiresExtern;
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseExternBlock(abi);
        } else if (self.peek() == .keyword_impl) {
            if (is_inline) return ParserError.InlineImplNotAllowed;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseImplDecl();
        } else if (self.peek() == .keyword_fn) {
            return try self.parseFuncDecl(is_pub, is_inline, is_async, is_extern, abi, false, false);
        } else if (self.peek() == .keyword_const) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseConstStmt();
        } else if (self.peek() == .keyword_macro) {
            if (is_inline) return ParserError.InlineMacroNotAllowed;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseMacroDecl();
        } else if (self.peek() == .keyword_using) {
            if (is_pub or is_extern or is_inline or is_async or abi != null) return ParserError.ExpectedDeclaration;
            return try self.parseUsingDecl();
        } else if (self.peek() == .at) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseAtDecl();
        } else {
            return ParserError.ExpectedDeclaration;
        }
    }

    fn parseModuleDeclInto(self: *Parser, decls: *std.array_list.Managed(*ast.Node), parent_prefix: ?[]const u8) ParserError!void {
        try self.expect(.keyword_mod);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const module_name = self.lexeme(name_tok.loc);

        if (parent_prefix == null and !self.isKnownModuleName(module_name)) {
            try self.known_modules.append(module_name);
        }

        const module_prefix = if (parent_prefix) |prefix|
            std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ prefix, module_name }) catch return ParserError.OutOfMemory
        else
            std.fmt.allocPrint(self.allocator, "{s}", .{module_name}) catch return ParserError.OutOfMemory;

        try self.expect(.l_brace);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            if (self.peek() == .keyword_mod) {
                try self.parseModuleDeclInto(decls, module_prefix);
                _ = self.match(.semicolon);
                continue;
            }

            if (self.peek() == .keyword_type) {
                const decl = try self.parseTypeAliasDecl();
                const mangled = std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ module_prefix, decl.type_alias_decl.name }) catch return ParserError.OutOfMemory;
                decl.type_alias_decl.name = mangled;
                try decls.append(decl);
                _ = self.match(.semicolon);
                continue;
            }

            const is_pub = self.match(.keyword_pub);
            const is_extern = self.match(.keyword_extern);
            const abi = if (is_extern) try self.parseOptionalExternAbi() else null;
            const is_inline = self.match(.keyword_inline);
            const is_async = self.match(.keyword_async);
            if (self.peek() != .keyword_fn) return ParserError.ExpectedDeclaration;

            const decl = try self.parseFuncDecl(is_pub, is_inline, is_async, is_extern, abi, false, false);
            const mangled = std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ module_prefix, decl.func_decl.name }) catch return ParserError.OutOfMemory;
            decl.func_decl.name = mangled;
            try decls.append(decl);
            _ = self.match(.semicolon);
        }
        try self.expect(.r_brace);
    }

    fn parseAtDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.at);
        if (self.peek() == .keyword_overload) {
            return try self.parseOverloadDeclAfterAt();
        }

        const ident = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(ident.loc);

        if (std.mem.eql(u8, name, "test")) {
            return try self.parseTestDeclAfterAt();
        } else if (std.mem.eql(u8, name, "import")) {
            return try self.parseImportDeclAfterAt();
        } else if (std.mem.eql(u8, name, "no_mangle")) {
            const is_pub = self.match(.keyword_pub);
            const is_extern = self.match(.keyword_extern);
            const abi = if (is_extern) try self.parseOptionalExternAbi() else null;
            const is_inline = self.match(.keyword_inline);
            const is_async = self.match(.keyword_async);
            if (self.peek() != .keyword_fn) return ParserError.ExpectedDeclaration;
            return try self.parseFuncDecl(is_pub, is_inline, is_async, is_extern, abi, true, false);
        } else if (std.mem.eql(u8, name, "derive")) {
            return try self.parseDeriveDeclAfterAt();
        }

        return ParserError.SyntaxError;
    }

    fn parseDeriveDeclAfterAt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.l_paren);
        var derives = std.array_list.Managed([]const u8).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const derive_tok = self.tok;
            try self.expect(.identifier);
            try derives.append(self.lexeme(derive_tok.loc));
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_paren);

        _ = self.match(.keyword_pub);
        if (self.peek() != .keyword_struct) return ParserError.ExpectedDeclaration;
        try self.expect(.keyword_struct);
        return try self.parseAggregateDecl(false, try derives.toOwnedSlice());
    }

    fn parseOptionalExternAbi(self: *Parser) ParserError!?[]const u8 {
        if (self.peek() != .string_literal) return null;
        const abi_tok = self.tok;
        try self.expect(.string_literal);
        const raw = self.lexeme(abi_tok.loc);
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return ParserError.SyntaxError;
        return raw[1 .. raw.len - 1];
    }

    fn parseStructDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_struct);
        return try self.parseAggregateDecl(false, &.{});
    }

    fn parseUnionDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_union);
        return try self.parseAggregateDecl(true, &.{});
    }

    fn parseTypeAliasDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_type);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);
        try self.expect(.equal);

        var components = std.array_list.Managed(ast.TypeAliasComponent).init(self.allocator);
        while (true) {
            if (self.peek() == .l_brace) {
                try self.expect(.l_brace);
                var fields = std.array_list.Managed(ast.Field).init(self.allocator);
                while (self.peek() != .r_brace and self.peek() != .eof) {
                    const f_tok = self.tok;
                    try self.expect(.identifier);
                    const f_name = self.lexeme(f_tok.loc);
                    try self.expect(.colon);
                    const f_ty = try self.parseType();
                    try fields.append(.{ .name = f_name, .ty = f_ty });
                    _ = self.match(.comma);
                }
                try self.expect(.r_brace);
                try components.append(.{ .inline_struct = try fields.toOwnedSlice() });
            } else {
                try components.append(.{ .ty = try self.parseType() });
            }
            if (!self.match(.ampersand)) break;
        }
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .type_alias_decl = .{ .name = name, .components = try components.toOwnedSlice() } };
        return node;
    }

    fn parseExternBlock(self: *Parser, abi: ?[]const u8) ParserError!*ast.Node {
        try self.expect(.l_brace);
        var decls = std.array_list.Managed(*ast.Node).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const is_pub = self.match(.keyword_pub);
            if (self.peek() != .keyword_fn) return ParserError.ExpectedDeclaration;
            const decl = try self.parseFuncDecl(is_pub, false, false, true, abi, false, true);
            try decls.append(decl);
            _ = self.match(.semicolon);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .program = .{ .decls = try decls.toOwnedSlice() } };
        return node;
    }

    fn parseAggregateDecl(self: *Parser, is_union: bool, derives: []const []const u8) ParserError!*ast.Node {
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        var generics = std.array_list.Managed([]const u8).init(self.allocator);
        if (self.match(.less_than)) {
            while (true) {
                const g_tok = self.tok;
                try self.expect(.identifier);
                try generics.append(self.lexeme(g_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expectGenericClose();
        }

        var fields = std.array_list.Managed(ast.Field).init(self.allocator);
        var is_opaque = false;
        if (self.match(.semicolon)) {
            is_opaque = true;
        } else if (self.match(.l_paren)) {
            var field_index: usize = 0;
            while (self.peek() != .r_paren and self.peek() != .eof) {
                const f_ty = try self.parseType();
                const f_name = std.fmt.allocPrint(self.allocator, "{}", .{field_index}) catch return ParserError.OutOfMemory;
                try fields.append(.{ .name = f_name, .ty = f_ty });
                field_index += 1;
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_paren);
        } else {
            try self.expect(.l_brace);
            while (self.peek() != .r_brace and self.peek() != .eof) {
                const f_tok = self.tok;
                try self.expect(.identifier);
                const f_name = self.lexeme(f_tok.loc);
                try self.expect(.colon);
                const f_ty = try self.parseType();
                try fields.append(.{ .name = f_name, .ty = f_ty });
                _ = self.match(.comma);
            }
            try self.expect(.r_brace);
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .struct_decl = .{
                .name = name,
                .derives = derives,
                .generics = try generics.toOwnedSlice(),
                .fields = try fields.toOwnedSlice(),
                .is_union = is_union,
                .is_opaque = is_opaque,
            },
        };
        return node;
    }

    fn parseEnumDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_enum);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        var generics = std.array_list.Managed([]const u8).init(self.allocator);
        if (self.match(.less_than)) {
            while (true) {
                const g_tok = self.tok;
                try self.expect(.identifier);
                try generics.append(self.lexeme(g_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expectGenericClose();
        }

        try self.expect(.l_brace);
        var variants = std.array_list.Managed(ast.EnumVariant).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const variant_tok = self.tok;
            try self.expect(.identifier);
            const variant_name = self.lexeme(variant_tok.loc);

            // Explicit discriminant: `Red = 1` (C/TS-like). Leading digits
            // only; a trailing type suffix (`1u8`) is accepted and ignored.
            var discriminant: ?i64 = null;
            if (self.match(.equal)) {
                var negative = false;
                if (self.match(.minus)) negative = true;
                const num_tok = self.tok;
                try self.expect(.int_literal);
                const num_str = self.lexeme(num_tok.loc);
                // #11: drop `_` separators in enum discriminant digits.
                const num_clean = try stripNumericSeparators(self.allocator, num_str);
                var digit_len: usize = 0;
                while (digit_len < num_clean.len and std.ascii.isDigit(num_clean[digit_len])) : (digit_len += 1) {}
                if (digit_len == 0) return ParserError.InvalidCharacter;
                var value = std.fmt.parseInt(i64, num_clean[0..digit_len], 10) catch return ParserError.InvalidCharacter;
                if (negative) value = -value;
                discriminant = value;
            }

            var fields = std.array_list.Managed(ast.Field).init(self.allocator);
            if (self.match(.l_brace)) {
                while (self.peek() != .r_brace and self.peek() != .eof) {
                    const f_tok = self.tok;
                    try self.expect(.identifier);
                    const f_name = self.lexeme(f_tok.loc);
                    try self.expect(.colon);
                    const f_ty = try self.parseType();
                    try fields.append(.{ .name = f_name, .ty = f_ty });
                    _ = self.match(.comma);
                }
                try self.expect(.r_brace);
            } else if (self.match(.l_paren)) {
                var field_index: usize = 0;
                while (self.peek() != .r_paren and self.peek() != .eof) {
                    const f_ty = try self.parseType();
                    const f_name = std.fmt.allocPrint(self.allocator, "{}", .{field_index}) catch return ParserError.OutOfMemory;
                    try fields.append(.{ .name = f_name, .ty = f_ty });
                    field_index += 1;
                    if (!self.match(.comma)) break;
                }
                try self.expect(.r_paren);
            }

            try variants.append(.{ .name = variant_name, .fields = try fields.toOwnedSlice(), .discriminant = discriminant });
            _ = self.match(.comma);
        }
        try self.expect(.r_brace);

        // Explicit discriminants only make sense on fieldless variants, and
        // effective values (explicit or C-like auto-increment from 0) must be
        // unique or match arms would silently miscompile. Deliberately
        // stricter than C: `A, B = 0` (aliased tags) is rejected here.
        {
            var seen = std.array_list.Managed(i64).init(self.allocator);
            var next_auto: i64 = 0;
            for (variants.items) |variant| {
                if (variant.fields.len != 0 and variant.discriminant != null) return ParserError.UnexpectedToken;
                const value = variant.discriminant orelse next_auto;
                for (seen.items) |prev| {
                    if (prev == value) return ParserError.UnexpectedToken;
                }
                seen.append(value) catch return ParserError.OutOfMemory;
                next_auto = value + 1;
            }
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .enum_decl = .{ .name = name, .generics = try generics.toOwnedSlice(), .variants = try variants.toOwnedSlice() } };
        return node;
    }

    fn parseTraitDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_trait);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);
        var supertraits = std.array_list.Managed([]const u8).init(self.allocator);
        if (self.match(.colon)) {
            while (true) {
                const super_tok = self.tok;
                try self.expect(.identifier);
                try supertraits.append(self.lexeme(super_tok.loc));
                if (!self.match(.plus)) break;
            }
        }
        try self.expect(.l_brace);

        var methods = std.array_list.Managed(ast.TraitMethod).init(self.allocator);
        const prev_impl_target = self.current_impl_target;
        self.current_impl_target = try self.makeUserDefinedType("Self", &.{});
        defer self.current_impl_target = prev_impl_target;
        while (self.peek() != .r_brace and self.peek() != .eof) {
            try self.expect(.keyword_fn);
            const method_name_tok = self.tok;
            try self.expect(.identifier);
            const method_name = self.lexeme(method_name_tok.loc);

            _ = try self.parseGenericParams();

            try self.expect(.l_paren);
            var params = std.array_list.Managed(ast.Param).init(self.allocator);
            if (self.peek() != .r_paren and self.peek() != .eof) {
                const first_is_borrow = self.match(.ampersand);
                const first_is_move = if (!first_is_borrow) self.match(.caret) else false;
                const first_tok = self.tok;
                try self.expect(.identifier);
                const first_name = self.lexeme(first_tok.loc);

                if (std.mem.eql(u8, first_name, "self")) {
                    const self_ty = try self.makeUserDefinedType("Self", &.{});
                    try params.append(.{ .name = "self", .ty = self_ty, .is_borrow = first_is_borrow, .is_move = first_is_move });
                    if (self.match(.comma)) {
                        while (self.peek() != .r_paren and self.peek() != .eof) {
                            const p_is_borrow = self.match(.ampersand);
                            const p_is_move = if (!p_is_borrow) self.match(.caret) else false;
                            const p_tok = self.tok;
                            try self.expect(.identifier);
                            const p_name = self.lexeme(p_tok.loc);
                            try self.expect(.colon);
                            const p_ty = try self.parseType();
                            try params.append(.{ .name = p_name, .ty = p_ty, .is_borrow = p_is_borrow, .is_move = p_is_move });
                            if (!self.match(.comma)) break;
                        }
                    }
                } else {
                    try self.expect(.colon);
                    const first_ty = try self.parseType();
                    try params.append(.{ .name = first_name, .ty = first_ty, .is_borrow = first_is_borrow, .is_move = first_is_move });
                    while (self.match(.comma)) {
                        if (self.peek() == .r_paren or self.peek() == .eof) break;
                        const p_is_borrow = self.match(.ampersand);
                        const p_is_move = if (!p_is_borrow) self.match(.caret) else false;
                        const p_tok = self.tok;
                        try self.expect(.identifier);
                        const p_name = self.lexeme(p_tok.loc);
                        try self.expect(.colon);
                        const p_ty = try self.parseType();
                        try params.append(.{ .name = p_name, .ty = p_ty, .is_borrow = p_is_borrow, .is_move = p_is_move });
                    }
                }
            }
            try self.expect(.r_paren);

            var ret_ty: *ast.Type = undefined;
            if (self.match(.arrow)) {
                ret_ty = try self.parseType();
            } else {
                ret_ty = try self.allocator.create(ast.Type);
                ret_ty.* = .{ .primitive = .void_type };
            }
            try self.expect(.semicolon);
            try methods.append(.{ .name = method_name, .params = try params.toOwnedSlice(), .ret_ty = ret_ty });
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .trait_decl = .{ .name = name, .supertraits = try supertraits.toOwnedSlice(), .methods = try methods.toOwnedSlice() } };
        return node;
    }

    fn parseImplDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_impl);
        const first_ty = try self.parseType();
        var trait_name: ?[]const u8 = null;
        var target_ty = first_ty;
        if (self.match(.keyword_for)) {
            switch (first_ty.*) {
                .user_defined => |ud| trait_name = ud.name,
                else => return ParserError.UnexpectedTypeToken,
            }
            target_ty = try self.parseType();
        }
        try self.expect(.l_brace);

        var methods = std.array_list.Managed(*ast.Node).init(self.allocator);
        const prev_impl_target = self.current_impl_target;
        self.current_impl_target = target_ty;
        defer self.current_impl_target = prev_impl_target;
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const is_inline = self.match(.keyword_inline);
            const is_async = self.match(.keyword_async);
            if (is_inline or is_async) return ParserError.ExpectedDeclaration;
            try methods.append(try self.parseMethodDecl(target_ty, trait_name));
            _ = self.match(.semicolon);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .impl_decl = .{ .trait_name = trait_name, .target_ty = target_ty, .methods = try methods.toOwnedSlice() } };
        return node;
    }

    fn parseOverloadDeclAfterAt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_overload);
        const target_ty = try self.parseType();
        try self.expect(.l_brace);

        var methods = std.array_list.Managed(*ast.Node).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            try methods.append(try self.parseOverloadMethodDecl(target_ty));
            _ = self.match(.semicolon);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .overload_decl = .{ .target_ty = target_ty, .methods = try methods.toOwnedSlice() } };
        return node;
    }

    fn parseGenericParams(self: *Parser) ParserError![]const []const u8 {
        var generics = std.array_list.Managed([]const u8).init(self.allocator);
        if (self.match(.less_than)) {
            while (true) {
                const g_tok = self.tok;
                try self.expect(.identifier);
                try generics.append(self.lexeme(g_tok.loc));
                if (self.match(.colon)) {
                    try self.expect(.identifier);
                }
                if (!self.match(.comma)) break;
            }
            try self.expectGenericClose();
        }
        return try generics.toOwnedSlice();
    }

    fn parseMethodDecl(self: *Parser, target_ty: *ast.Type, trait_name: ?[]const u8) ParserError!*ast.Node {
        try self.expect(.keyword_fn);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        const generics = try self.parseGenericParams();

        try self.expect(.l_paren);

        var params = std.array_list.Managed(ast.Param).init(self.allocator);
        if (self.peek() != .r_paren and self.peek() != .eof) {
            const first_is_borrow = self.match(.ampersand);
            const first_is_move = if (!first_is_borrow) self.match(.caret) else false;
            const first_tok = self.tok;
            try self.expect(.identifier);
            const first_name = self.lexeme(first_tok.loc);

            if (std.mem.eql(u8, first_name, "self")) {
                try params.append(.{ .name = "self", .ty = target_ty, .is_borrow = first_is_borrow, .is_move = first_is_move });
                if (self.match(.comma)) {
                    while (self.peek() != .r_paren and self.peek() != .eof) {
                        const p_is_borrow = self.match(.ampersand);
                        const p_is_move = if (!p_is_borrow) self.match(.caret) else false;
                        const p_tok = self.tok;
                        try self.expect(.identifier);
                        const p_name = self.lexeme(p_tok.loc);
                        try self.expect(.colon);
                        const p_ty = try self.parseType();
                        try params.append(.{ .name = p_name, .ty = p_ty, .is_borrow = p_is_borrow, .is_move = p_is_move });
                        if (!self.match(.comma)) break;
                    }
                }
            } else {
                try self.expect(.colon);
                const first_ty = try self.parseType();
                try params.append(.{ .name = first_name, .ty = first_ty, .is_borrow = first_is_borrow, .is_move = first_is_move });
                while (self.match(.comma)) {
                    if (self.peek() == .r_paren or self.peek() == .eof) break;
                    const p_is_borrow = self.match(.ampersand);
                    const p_is_move = if (!p_is_borrow) self.match(.caret) else false;
                    const p_tok = self.tok;
                    try self.expect(.identifier);
                    const p_name = self.lexeme(p_tok.loc);
                    try self.expect(.colon);
                    const p_ty = try self.parseType();
                    try params.append(.{ .name = p_name, .ty = p_ty, .is_borrow = p_is_borrow, .is_move = p_is_move });
                }
            }
        }

        try self.expect(.r_paren);

        var ret_ty: *ast.Type = undefined;
        if (self.match(.arrow)) {
            ret_ty = try self.parseType();
        } else {
            ret_ty = try self.allocator.create(ast.Type);
            ret_ty.* = .{ .primitive = .void_type };
        }

        const body_result = try self.parseOrCaptureFunctionBody(try self.shouldParseMethodBody(target_ty, trait_name, name));

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .func_decl = .{
                .name = name,
                .is_pub = false,
                .generics = generics,
                .params = try params.toOwnedSlice(),
                .ret_ty = ret_ty,
                .body = body_result.body,
                .is_inline = false,
                .is_async = false,
            },
        };
        try self.rememberFunctionBodySpan(node, body_result.span);
        return node;
    }

    fn parseOverloadMethodDecl(self: *Parser, target_ty: *ast.Type) ParserError!*ast.Node {
        try self.expect(.keyword_fn);
        const op = switch (self.peek()) {
            .plus => ast.BinaryOp.add,
            .minus => ast.BinaryOp.sub,
            .asterisk => ast.BinaryOp.mul,
            .slash => ast.BinaryOp.div,
            else => return ParserError.ExpectedDeclaration,
        };
        self.advance();
        const op_name = switch (op) {
            .add => "op_add",
            .sub => "op_sub",
            .mul => "op_mul",
            .div => "op_div",
            else => unreachable,
        };

        const generics = try self.parseGenericParams();

        try self.expect(.l_paren);

        var params = std.array_list.Managed(ast.Param).init(self.allocator);
        if (self.peek() != .r_paren and self.peek() != .eof) {
            const first_is_borrow = self.match(.ampersand);
            const first_is_move = if (!first_is_borrow) self.match(.caret) else false;
            const first_tok = self.tok;
            try self.expect(.identifier);
            const first_name = self.lexeme(first_tok.loc);
            try self.expect(.colon);
            const first_ty = try self.parseType();
            try params.append(.{ .name = first_name, .ty = first_ty, .is_borrow = first_is_borrow, .is_move = first_is_move });
            while (self.match(.comma)) {
                if (self.peek() == .r_paren or self.peek() == .eof) break;
                const p_is_borrow = self.match(.ampersand);
                const p_is_move = if (!p_is_borrow) self.match(.caret) else false;
                const p_tok = self.tok;
                try self.expect(.identifier);
                const p_name = self.lexeme(p_tok.loc);
                try self.expect(.colon);
                const p_ty = try self.parseType();
                try params.append(.{ .name = p_name, .ty = p_ty, .is_borrow = p_is_borrow, .is_move = p_is_move });
            }
        }

        try self.expect(.r_paren);

        var ret_ty: *ast.Type = undefined;
        if (self.match(.arrow)) {
            ret_ty = try self.parseType();
        } else {
            ret_ty = try self.allocator.create(ast.Type);
            ret_ty.* = .{ .primitive = .void_type };
        }

        const body_result = try self.parseOrCaptureFunctionBody(try self.shouldParseMethodBody(target_ty, null, op_name));

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .func_decl = .{
                .name = op_name,
                .is_pub = false,
                .generics = generics,
                .params = try params.toOwnedSlice(),
                .ret_ty = ret_ty,
                .body = body_result.body,
                .is_inline = false,
                .is_async = false,
                .operator = op,
            },
        };
        try self.rememberFunctionBodySpan(node, body_result.span);
        return node;
    }

    fn parseFuncDecl(self: *Parser, is_pub: bool, is_inline: bool, is_async: bool, is_extern: bool, abi: ?[]const u8, no_mangle: bool, is_decl_only: bool) ParserError!*ast.Node {
        try self.expect(.keyword_fn);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        const generics = try self.parseGenericParams();

        try self.expect(.l_paren);

        var params = std.array_list.Managed(ast.Param).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const is_borrow = self.match(.ampersand);
            const is_move = if (!is_borrow) self.match(.caret) else false;
            const p_tok = self.tok;
            try self.expect(.identifier);
            const p_name = self.lexeme(p_tok.loc);
            try self.expect(.colon);
            const p_ty = try self.parseType();
            if (self.peek() == .equal) {
                self.last_expected = "r_paren (default parameter values such as `= 1` are not supported; define f_default() + f_full(...) instead, see demos/basic/47_default_args)";
                return ParserError.SyntaxError;
            }
            try params.append(.{ .name = p_name, .ty = p_ty, .is_borrow = is_borrow, .is_move = is_move });
            if (!self.match(.comma)) break;
        }

        try self.expect(.r_paren);

        var ret_ty: *ast.Type = undefined;
        if (self.match(.arrow)) {
            ret_ty = try self.parseType();
        } else {
            ret_ty = try self.allocator.create(ast.Type);
            ret_ty.* = .{ .primitive = .void_type };
        }

        const body_result = if (is_decl_only)
            FunctionBodyParseResult{ .body = &.{}, .span = null }
        else
            try self.parseOrCaptureFunctionBody(self.shouldParseFunctionBody(name));

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .func_decl = .{
                .name = name,
                .is_pub = is_pub,
                .is_extern = is_extern,
                .abi = abi,
                .no_mangle = no_mangle,
                .is_decl_only = is_decl_only,
                .generics = generics,
                .params = try params.toOwnedSlice(),
                .ret_ty = ret_ty,
                .body = body_result.body,
                .is_inline = is_inline,
                .is_async = is_async,
            },
        };
        try self.rememberFunctionBodySpan(node, body_result.span);
        return node;
    }

    fn parseMacroDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_macro);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        try self.expect(.l_paren);

        var params = std.array_list.Managed([]const u8).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const p_tok = self.tok;
            try self.expect(.identifier);
            try params.append(self.lexeme(p_tok.loc));
            if (!self.match(.comma)) break;
        }

        try self.expect(.r_paren);

        const body = if (self.shouldParseMacroBody(name)) try self.parseBlock() else blk: {
            try self.skipBlock();
            break :blk &.{};
        };

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .macro_decl = .{
                .name = name,
                .params = try params.toOwnedSlice(),
                .body = body,
            },
        };
        return node;
    }

    fn parseImportDeclAfterAt(self: *Parser) ParserError!*ast.Node {
        const import_path = if (self.peek() == .string_literal) blk: {
            const path_tok = self.tok;
            try self.expect(.string_literal);
            const raw_path = self.lexeme(path_tok.loc);
            if (raw_path.len < 2 or raw_path[0] != '"' or raw_path[raw_path.len - 1] != '"') {
                return ParserError.SyntaxError;
            }
            break :blk raw_path[1 .. raw_path.len - 1];
        } else try self.parseImportPathTokenSequence();
        _ = self.match(.semicolon);

        // For cross-file .sla imports, pre-scan the imported file for declared
        // type/enum names so the rest of this file can recognize struct literals
        // like `ImportedType { ... }`. This mirrors how plugin.zig later merges
        // the imported AST, but the parser needs the names earlier to disambiguate
        // `Name { ... }` from a block during its single forward pass.
        if (std.mem.endsWith(u8, import_path, ".sla")) {
            try self.recordImportModuleName(import_path);
            if (self.options.prescan_sla_import_types) self.prescanSlaImportTypes(import_path) catch {};
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .import_decl = .{ .path = import_path } };
        return node;
    }

    fn parseUsingDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_using);
        const path = try self.parseImportPathTokenSequence();
        _ = self.match(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .using_decl = .{ .path = path } };
        return node;
    }

    fn prescanSlaImportTypes(self: *Parser, import_path: []const u8) !void {
        // Bound recursion depth to avoid pathological import graphs.
        if (self.import_scan_depth >= 32) return;

        if (isGlobImportPath(import_path)) {
            const pattern_path = if (std.fs.path.isAbsolute(import_path))
                try self.allocator.dupe(u8, import_path)
            else
                try std.fs.path.join(self.allocator, &.{ self.base_dir, import_path });

            const dir_path = std.fs.path.dirname(pattern_path) orelse ".";
            const pattern_name = std.fs.path.basename(pattern_path);
            var dir = sio.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
            defer dir.close();

            var matches = std.array_list.Managed([]const u8).init(self.allocator);
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (!globNameMatches(pattern_name, entry.name)) continue;
                if (!std.mem.endsWith(u8, entry.name, ".sla")) continue;
                const child_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                try matches.append(child_path);
            }
            std.mem.sort([]const u8, matches.items, {}, stringSliceLessThan);
            for (matches.items) |child_path| {
                try self.prescanResolvedSlaImportTypes(child_path);
            }
            return;
        }

        const resolved_path = if (try self.resolveSlaStdImportPath(import_path)) |std_path|
            std_path
        else if (std.fs.path.isAbsolute(import_path))
            try self.allocator.dupe(u8, import_path)
        else
            try std.fs.path.join(self.allocator, &.{ self.base_dir, import_path });

        try self.prescanResolvedSlaImportTypes(resolved_path);
    }

    fn prescanResolvedSlaImportTypes(self: *Parser, resolved_path: []const u8) !void {
        const canonical_path = blk: {
            const real = sio.cwd().realpathAlloc(self.allocator, resolved_path) catch break :blk resolved_path;
            const normed = host_paths.normalizePathSlashes(self.allocator, real) catch {
                break :blk real;
            };
            self.allocator.free(real);
            break :blk normed;
        };
        if (self.import_type_scan_cache.get(canonical_path)) |surface| {
            self.import_type_scan_cache_hits += 1;
            try self.mergeKnownTypeSurface(surface);
            return;
        }
        // Insert a cycle guard before parsing. The completed surface replaces it
        // below; recursive imports of this path observe an empty surface.
        try self.import_type_scan_cache.put(canonical_path, .{
            .types = &.{},
            .enums = &.{},
            .source = &.{},
            .expanded_source = &.{},
            .complete = false,
        });

        const source = sio.cwd().readFileAlloc(self.allocator, canonical_path, 16 * 1024 * 1024) catch return;
        const expanded_source = source_expand.expand(self.allocator, source) catch return;

        const import_dir = std.fs.path.dirname(canonical_path) orelse ".";

        var sub = initWithDirAndOptions(self.allocator, expanded_source, import_dir, .{
            .parse_function_bodies = false,
            .parse_macro_bodies = false,
            .parse_test_bodies = false,
        });
        sub.import_scan_depth = self.import_scan_depth + 1;
        sub.import_type_scan_cache = self.import_type_scan_cache;
        sub.import_type_scan_cache_hits = self.import_type_scan_cache_hits;
        const prog = sub.parseProgram() catch {
            self.import_type_scan_cache = sub.import_type_scan_cache;
            self.import_type_scan_cache_hits = sub.import_type_scan_cache_hits;
            return;
        };
        self.import_type_scan_cache = sub.import_type_scan_cache;
        self.import_type_scan_cache_hits = sub.import_type_scan_cache_hits;
        if (prog.* != .program) return;

        const surface = ImportTypeSurface{
            .types = try self.allocator.dupe([]const u8, sub.known_types.items),
            .enums = try self.allocator.dupe([]const u8, sub.known_enums.items),
            .source = source,
            .expanded_source = expanded_source,
            .complete = true,
        };
        try self.import_type_scan_cache.put(canonical_path, surface);
        try self.mergeKnownTypeSurface(surface);
    }

    fn mergeKnownTypeSurface(self: *Parser, surface: ImportTypeSurface) !void {
        // Cached surfaces include transitive imports, matching the original
        // recursive parser behavior without rereading or reparsing the file.
        for (surface.types) |name| {
            if (!self.isKnownTypeName(name)) try self.known_types.append(name);
        }
        for (surface.enums) |name| {
            if (!self.isKnownEnumName(name)) try self.known_enums.append(name);
        }
    }

    fn parseTestDeclAfterAt(self: *Parser) ParserError!*ast.Node {
        var is_ignored = false;
        var should_panic = false;

        while (self.peek() == .identifier) {
            const mod_str = self.lexeme(self.tok.loc);
            if (std.mem.eql(u8, mod_str, "ignored")) {
                is_ignored = true;
                self.advance();
            } else if (std.mem.eql(u8, mod_str, "should_panic")) {
                should_panic = true;
                self.advance();
            } else {
                break;
            }
        }

        const name_tok = self.tok;
        try self.expect(.string_literal);
        const raw_name = self.lexeme(name_tok.loc);
        if (raw_name.len < 2 or raw_name[0] != '"' or raw_name[raw_name.len - 1] != '"') {
            return ParserError.SyntaxError;
        }
        const name = raw_name[1 .. raw_name.len - 1];

        try self.expect(.l_paren);
        try self.expect(.r_paren);

        const body = if (self.options.parse_test_bodies) try self.parseBlock() else blk: {
            try self.skipBlock();
            break :blk &.{};
        };

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .test_decl = .{
                .name = name,
                .is_ignored = is_ignored,
                .should_panic = should_panic,
                .body = body,
            },
        };
        return node;
    }

    const FunctionBodyParseResult = struct {
        body: []const *ast.Node,
        span: ?[]const u8,
    };

    fn parseOrCaptureFunctionBody(self: *Parser, should_parse: bool) ParserError!FunctionBodyParseResult {
        if (should_parse) {
            const span = try self.peekBlockSpan();
            const body = try self.parseBlock();
            return .{ .body = body, .span = span };
        }
        const span = try self.skipBlockSpan();
        return .{ .body = &.{}, .span = span };
    }

    fn rememberFunctionBodySpan(self: *Parser, node: *ast.Node, span: ?[]const u8) ParserError!void {
        const body_span = span orelse return;
        try self.function_body_spans.put(node, body_span);
    }

    fn peekBlockSpan(self: *const Parser) ParserError![]const u8 {
        if (self.tok.tag != .l_brace) {
            return ParserError.SyntaxError;
        }
        var lex = lexer.Lexer.init(self.lex.buffer[self.tok.loc.start..]);
        var depth: usize = 0;
        var end: usize = self.tok.loc.start;
        // Mirror the lexer template state so `${...}` interpolation braces
        // don't disturb the block depth (#4: skipped @test bodies containing
        // template literals were truncated at the first interp `}`).
        var in_template = false;
        var interp_depth: u16 = 0;
        var tmpl_stack: [8]u16 = std.mem.zeroes([8]u16);
        var tmpl_sp: u8 = 0;
        while (true) {
            const tok = lex.next();
            if (tok.tag == .template_start) {
                if (tmpl_sp >= tmpl_stack.len) return ParserError.SyntaxError;
                tmpl_stack[tmpl_sp] = interp_depth;
                tmpl_sp += 1;
                interp_depth = 0;
                in_template = true;
                continue;
            }
            if (in_template) {
                if (tok.tag == .template_interp) {
                    in_template = false;
                    interp_depth = 1;
                } else if (tok.tag == .template_end) {
                    if (tmpl_sp == 0) return ParserError.SyntaxError;
                    tmpl_sp -= 1;
                    interp_depth = tmpl_stack[tmpl_sp];
                    in_template = false;
                } else if (tok.tag == .eof) {
                    return ParserError.SyntaxError;
                }
                continue;
            }
            switch (tok.tag) {
                .template_interp => {
                    in_template = false;
                    interp_depth = 1;
                },
                .l_brace => {
                    if (interp_depth > 0) interp_depth += 1;
                    depth += 1;
                    end = self.tok.loc.start + tok.loc.end;
                },
                .r_brace => {
                    if (interp_depth > 0) {
                        interp_depth -= 1;
                        if (interp_depth == 0) {
                            in_template = true;
                            continue;
                        }
                    }
                    if (depth == 0) {
                        return ParserError.SyntaxError;
                    }
                    depth -= 1;
                    end = self.tok.loc.start + tok.loc.end;
                    if (depth == 0) {
                        return self.lex.buffer[self.tok.loc.start..end];
                    }
                },
                .eof => {
                    return ParserError.SyntaxError;
                },
                else => {},
            }
        }
    }

    fn skipBlock(self: *Parser) ParserError!void {
        _ = try self.skipBlockSpan();
    }

    fn skipBlockSpan(self: *Parser) ParserError![]const u8 {
        if (self.tok.tag != .l_brace) {
            self.last_expected = @tagName(lexer.Token.Tag.l_brace);
            return ParserError.SyntaxError;
        }
        const start = self.tok.loc.start;
        var end = self.tok.loc.end;
        self.advance();
        var depth: usize = 1;
        // Same template-state mirror as peekBlockSpan (#4).
        var in_template = false;
        var interp_depth: u16 = 0;
        var tmpl_stack: [8]u16 = std.mem.zeroes([8]u16);
        var tmpl_sp: u8 = 0;
        while (depth > 0 and self.peek() != .eof) {
            if (self.peek() == .template_start) {
                if (tmpl_sp >= tmpl_stack.len) {
                    self.last_expected = "matching closing brace";
                    return ParserError.SyntaxError;
                }
                tmpl_stack[tmpl_sp] = interp_depth;
                tmpl_sp += 1;
                interp_depth = 0;
                in_template = true;
                self.advance();
                continue;
            }
            if (in_template) {
                if (self.peek() == .template_interp) {
                    in_template = false;
                    interp_depth = 1;
                } else if (self.peek() == .template_end) {
                    if (tmpl_sp == 0) {
                        self.last_expected = "matching closing brace";
                        return ParserError.SyntaxError;
                    }
                    tmpl_sp -= 1;
                    interp_depth = tmpl_stack[tmpl_sp];
                    in_template = false;
                }
                self.advance();
                continue;
            }
            switch (self.peek()) {
                .template_interp => {
                    in_template = false;
                    interp_depth = 1;
                    self.advance();
                },
                .l_brace => {
                    if (interp_depth > 0) interp_depth += 1;
                    depth += 1;
                    end = self.tok.loc.end;
                    self.advance();
                },
                .r_brace => {
                    if (interp_depth > 0) {
                        interp_depth -= 1;
                        if (interp_depth == 0) {
                            in_template = true;
                            end = self.tok.loc.end;
                            self.advance();
                            continue;
                        }
                    }
                    depth -= 1;
                    end = self.tok.loc.end;
                    self.advance();
                },
                else => self.advance(),
            }
        }
        if (depth != 0) {
            self.last_expected = "matching closing brace";
            return ParserError.SyntaxError;
        }
        return self.lex.buffer[start..end];
    }

    fn shouldParseFunctionBody(self: *const Parser, name: []const u8) bool {
        if (!self.options.parse_function_bodies) return false;
        const selected = self.options.function_body_names orelse return true;
        return selected.contains(name);
    }

    fn shouldParseMacroBody(self: *const Parser, name: []const u8) bool {
        if (!self.options.parse_macro_bodies) return false;
        const selected = self.options.macro_body_names orelse return true;
        return selected.contains(name);
    }

    fn concreteTypeNameForMethodSelection(ty: *const ast.Type) ?[]const u8 {
        return lowering_rules.concreteTypeName(ty);
    }

    fn shouldParseMethodBody(self: *const Parser, target_ty: *const ast.Type, trait_name: ?[]const u8, method_name: []const u8) !bool {
        if (!self.options.parse_function_bodies) return false;
        const selected = self.options.function_body_names orelse return true;
        const type_name = concreteTypeNameForMethodSelection(target_ty) orelse return false;
        const symbol = if (trait_name) |tn|
            try std.fmt.allocPrint(self.allocator, "{s}__{s}_{s}", .{ type_name, tn, method_name })
        else
            try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ type_name, method_name });
        defer self.allocator.free(symbol);
        return selected.contains(symbol);
    }

    fn parseBlock(self: *Parser) ParserError![]const *ast.Node {
        try self.expect(.l_brace);
        var stmts = std.array_list.Managed(*ast.Node).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const stmt = try self.parseStmt();
            try stmts.append(stmt);
        }
        try self.expect(.r_brace);
        return try stmts.toOwnedSlice();
    }

    fn parseStmt(self: *Parser) ParserError!*ast.Node {
        if (self.peek() == .keyword_using) {
            return try self.parseUsingDecl();
        } else if (self.peek() == .keyword_let) {
            return try self.parseLetStmt();
        } else if (self.peek() == .keyword_const) {
            return try self.parseConstStmt();
        } else if (self.peek() == .keyword_var) {
            return try self.parseVarStmt();
        } else if (self.peek() == .keyword_return) {
            return try self.parseReturnStmt();
        } else if (self.peek() == .keyword_for) {
            return try self.parseForStmt();
        } else if (self.peek() == .keyword_while) {
            return try self.parseWhileStmt();
        } else if (self.peek() == .keyword_break) {
            return try self.parseBreakStmt();
        } else if (self.peek() == .keyword_continue) {
            return try self.parseContinueStmt();
        } else if (self.peek() == .bang) {
            return try self.parseReleaseStmt();
        } else if (self.peek() == .l_brace) {
            const body = try self.parseBlock();
            const node = try self.allocator.create(ast.Node);
            node.* = .{ .block_stmt = .{ .body = body } };
            return node;
        } else {
            const expr = try self.parseExpr(0);
            if (self.match(.equal)) {
                var rhs = try self.parseExpr(0);
                // #12: right-associative `=` chains (`a = b = ... = value`).
                // Desugars to `{ let __chainK = value; ... = __chainK; }` so
                // the value evaluates once (mirrors the `__qcN` precedent for
                // `?.` chains; plain single assignment below is untouched).
                var chain_targets = std.array_list.Managed(*ast.Node).init(self.allocator);
                try chain_targets.append(expr);
                while (self.match(.equal)) {
                    try chain_targets.append(rhs);
                    rhs = try self.parseExpr(0);
                }
                try self.expect(.semicolon);
                if (chain_targets.items.len > 1) {
                    const tmp_name = try std.fmt.allocPrint(self.allocator, "__chain{d}", .{self.synth_counter});
                    self.synth_counter += 1;
                    var chain_body = std.array_list.Managed(*ast.Node).init(self.allocator);
                    const tmp_let = try self.allocator.create(ast.Node);
                    tmp_let.* = .{ .let_stmt = .{ .name = tmp_name, .ty = null, .value = rhs } };
                    try chain_body.append(tmp_let);
                    var ci: usize = chain_targets.items.len;
                    while (ci > 0) {
                        ci -= 1;
                        const tmp_read = try self.allocator.create(ast.Node);
                        tmp_read.* = .{ .identifier = tmp_name };
                        const chain_assign = try self.allocator.create(ast.Node);
                        chain_assign.* = .{ .assign_stmt = .{ .target = chain_targets.items[ci], .value = tmp_read } };
                        try chain_body.append(chain_assign);
                    }
                    const chain_block = try self.allocator.create(ast.Node);
                    chain_block.* = .{ .block_stmt = .{ .body = try chain_body.toOwnedSlice() } };
                    return chain_block;
                }
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = rhs } };
                return node;
            }
            if (self.match(.plus_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const sum = try self.allocator.create(ast.Node);
                sum.* = .{ .binary_expr = .{ .op = .add, .left = expr, .right = rhs } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = sum } };
                return node;
            }
            if (self.match(.minus_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const value = try self.allocator.create(ast.Node);
                value.* = .{ .binary_expr = .{ .op = .sub, .left = expr, .right = rhs } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = value } };
                return node;
            }
            if (self.match(.asterisk_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const value = try self.allocator.create(ast.Node);
                value.* = .{ .binary_expr = .{ .op = .mul, .left = expr, .right = rhs } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = value } };
                return node;
            }
            if (self.match(.slash_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const value = try self.allocator.create(ast.Node);
                value.* = .{ .binary_expr = .{ .op = .div, .left = expr, .right = rhs } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = value } };
                return node;
            }
            if (self.match(.percent_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const value = try self.allocator.create(ast.Node);
                value.* = .{ .binary_expr = .{ .op = .mod, .left = expr, .right = rhs } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = value } };
                return node;
            }
            // `a ??= b` desugars to `a = Some(a.unwrap_or(b))`, mirroring
            // `+=` above (same target-reuse tradeoff: complex place
            // expressions evaluate twice; bind them first). The `Some`
            // wrap-back is required: `unwrap_or` yields the inner value,
            // but the target holds an `Option`.
            if (self.match(.question_question_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const fallback_args = try self.allocator.alloc(*ast.Node, 2);
                fallback_args[0] = expr;
                fallback_args[1] = rhs;
                const fallback_generics = try self.allocator.alloc(*ast.Type, 0);
                const fallback = try self.allocator.create(ast.Node);
                fallback.* = .{
                    .call_expr = .{
                        .func_name = "unwrap_or",
                        .associated_target = null,
                        .generics = fallback_generics,
                        .args = fallback_args,
                    },
                };
                const some_args = try self.allocator.alloc(*ast.Node, 1);
                some_args[0] = fallback;
                const some_generics = try self.allocator.alloc(*ast.Type, 0);
                const some_call = try self.allocator.create(ast.Node);
                some_call.* = .{
                    .call_expr = .{
                        .func_name = "Some",
                        .associated_target = null,
                        .generics = some_generics,
                        .args = some_args,
                    },
                };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = some_call } };
                return node;
            }
            if (self.match(.pipe_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const value = try self.allocator.create(ast.Node);
                value.* = .{ .binary_expr = .{ .op = .bit_or, .left = expr, .right = rhs } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = value } };
                return node;
            }
            if (self.match(.ampersand_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const value = try self.allocator.create(ast.Node);
                value.* = .{ .binary_expr = .{ .op = .bit_and, .left = expr, .right = rhs } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = value } };
                return node;
            }
            if (!self.match(.semicolon)) {
                // `name:` at statement level is a loop-label definition, which
                // SLA does not support (#9).
                if (expr.* == .identifier and self.peek() == .colon) {
                    self.last_expected = "semicolon (loop labels such as `outer:` are not supported; restructure with an inner break, see demos/basic/48_nested_break)";
                    return ParserError.SyntaxError;
                }
                if (self.peek() != .r_brace) {
                    try self.expect(.semicolon);
                }
            }
            const node = try self.allocator.create(ast.Node);
            node.* = .{ .expr_stmt = expr };
            return node;
        }
    }

    fn parseLetStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_let);
        if (self.peek() == .keyword_mut) return ParserError.UnexpectedToken;

        if (self.peek() == .identifier) {
            const first_name = self.lexeme(self.tok.loc);
            if (std.mem.eql(u8, first_name, "Some") or std.mem.eql(u8, first_name, "None") or std.mem.eql(u8, first_name, "Option") or
                std.mem.eql(u8, first_name, "Ok") or std.mem.eql(u8, first_name, "Err") or std.mem.eql(u8, first_name, "Result") or
                self.isKnownEnumName(first_name))
            {
                const pattern = try self.parseLetPattern();
                try self.expect(.equal);
                const val = try self.parseExpr(0);
                try self.expect(.keyword_else);
                const else_block = try self.parseBlock();
                try self.expect(.semicolon);

                const node = try self.allocator.create(ast.Node);
                node.* = .{ .let_else_stmt = .{ .pattern = pattern, .value = val, .else_block = else_block } };
                return node;
            }
        }

        if (self.peek() == .l_paren) {
            self.advance();
            var names = std.array_list.Managed([]const u8).init(self.allocator);
            while (self.peek() != .r_paren and self.peek() != .eof) {
                const name_tok = self.tok;
                try self.expect(.identifier);
                try names.append(self.lexeme(name_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_paren);
            try self.expect(.equal);
            const val = try self.parseExpr(0);
            try self.expect(.semicolon);

            const node = try self.allocator.create(ast.Node);
            node.* = .{
                .let_destructure_stmt = .{
                    .names = try names.toOwnedSlice(),
                    .value = val,
                },
            };
            return node;
        }

        if (self.peek() == .l_bracket) {
            self.advance();
            var names = std.array_list.Managed([]const u8).init(self.allocator);
            var rest_name: ?[]const u8 = null;
            var rest_alias: ?[]const u8 = null;
            while (self.peek() != .r_bracket and self.peek() != .eof) {
                if (self.peek() == .range) {
                    self.advance();
                    const rest_tok = self.tok;
                    try self.expect(.identifier);
                    rest_name = self.lexeme(rest_tok.loc);
                    if (self.match(.keyword_as)) {
                        const alias_tok = self.tok;
                        try self.expect(.identifier);
                        rest_alias = self.lexeme(alias_tok.loc);
                    }
                    _ = self.match(.comma);
                    break;
                }
                const name_tok = self.tok;
                try self.expect(.identifier);
                try names.append(self.lexeme(name_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_bracket);
            try self.expect(.equal);
            const val = try self.parseExpr(0);
            try self.expect(.semicolon);

            const node = try self.allocator.create(ast.Node);
            node.* = .{
                .let_destructure_stmt = .{
                    .names = try names.toOwnedSlice(),
                    .value = val,
                    .rest_name = rest_name,
                    .rest_alias = rest_alias,
                    .is_slice = true,
                },
            };
            return node;
        }

        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        var ty: ?*ast.Type = null;
        if (self.match(.colon)) {
            ty = try self.parseType();
        }

        try self.expect(.equal);
        const val = try self.parseExpr(0);
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .let_stmt = .{
                .name = name,
                .ty = ty,
                .value = val,
            },
        };
        return node;
    }

    fn parseConstStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_const);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        var ty: ?*ast.Type = null;
        if (self.match(.colon)) {
            ty = try self.parseType();
        }

        try self.expect(.equal);
        const val = try self.parseExpr(0);
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .const_stmt = .{
                .name = name,
                .ty = ty,
                .value = val,
            },
        };
        return node;
    }

    fn parseVarStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_var);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        try self.expect(.colon);
        const ty = try self.parseType();
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .var_stmt = .{
                .name = name,
                .ty = ty,
            },
        };
        return node;
    }

    fn parseReturnStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_return);
        var val: ?*ast.Node = null;
        if (self.peek() != .semicolon) {
            val = try self.parseExpr(0);
        }
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .return_stmt = .{
                .value = val,
            },
        };
        return node;
    }

    fn parseForStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_for);
        const var_tok = self.tok;
        try self.expect(.identifier);
        const var_name = self.lexeme(var_tok.loc);

        try self.expect(.keyword_in);
        const start = try self.parseExpr(0);
        const end = if (self.match(.range)) try self.parseExpr(0) else null;

        const body = try self.parseBlock();

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .for_stmt = .{
                .var_name = var_name,
                .start = start,
                .end = end,
                .body = body,
            },
        };
        return node;
    }

    fn parseWhileStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_while);
        var let_pattern: ?ast.EnumPattern = null;
        const cond = if (self.match(.keyword_let)) blk: {
            let_pattern = try self.parseLetPattern();
            try self.expect(.equal);
            break :blk try self.parseExpr(0);
        } else try self.parseExpr(0);
        const body = try self.parseBlock();

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .while_stmt = .{
                .cond = cond,
                .let_pattern = let_pattern,
                .body = body,
            },
        };
        return node;
    }

    fn parseBreakStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_break);
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .break_stmt = .{} };
        return node;
    }

    fn parseContinueStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_continue);
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .continue_stmt = .{} };
        return node;
    }

    fn parseReleaseStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.bang);
        const var_tok = self.tok;
        try self.expect(.identifier);
        const var_name = self.lexeme(var_tok.loc);
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .release_stmt = .{
                .var_name = var_name,
            },
        };
        return node;
    }

    fn makeUserDefinedType(self: *Parser, name: []const u8, generics: []const *ast.Type) ParserError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{
            .user_defined = .{
                .name = name,
                .generics = generics,
            },
        };
        return ty;
    }

    fn genericLookaheadBoundary(tag: lexer.Token.Tag) bool {
        return switch (tag) {
            .semicolon,
            .l_brace,
            .r_brace,
            .r_paren,
            .r_bracket,
            .equal,
            .plus,
            .plus_equal,
            .minus,
            .minus_equal,
            .asterisk,
            .asterisk_equal,
            .slash,
            .slash_equal,
            .percent,
            .percent_equal,
            .ampersand,
            .amp_amp,
            .ampersand_equal,
            .pipe,
            .pipe_pipe,
            .pipe_equal,
            .caret,
            .less_less,
            .less_equal,
            .greater_equal,
            .spaceship,
            .equal_equal,
            .bang_equal,
            .arrow,
            .fat_arrow,
            .range,
            .question_mark,
            => true,
            else => false,
        };
    }

    fn looksLikeGenericStructLiteralTail(self: *Parser) bool {
        var lex_copy = self.lex;
        var tok_copy = self.tok;
        var depth: usize = 1;

        while (tok_copy.tag != .eof) {
            if (depth == 1 and genericLookaheadBoundary(tok_copy.tag)) return false;
            switch (tok_copy.tag) {
                .less_than => depth += 1,
                .greater_than => {
                    depth -= 1;
                    if (depth == 0) {
                        tok_copy = lex_copy.next();
                        return tok_copy.tag == .l_brace;
                    }
                },
                .greater_greater => {
                    if (depth <= 2) {
                        tok_copy = lex_copy.next();
                        return tok_copy.tag == .l_brace;
                    }
                    depth -= 2;
                },
                else => {},
            }
            tok_copy = lex_copy.next();
        }
        return false;
    }

    fn parseStructLiteral(self: *Parser, ty: *ast.Type) ParserError!*ast.Node {
        try self.expect(.l_brace);

        var fields = std.array_list.Managed(ast.StructLiteralField).init(self.allocator);
        var update_expr: ?*ast.Node = null;
        while (self.peek() != .r_brace and self.peek() != .eof) {
            if (self.peek() == .range) {
                self.advance();
                update_expr = try self.parseExpr(0);
                _ = self.match(.comma);
                break;
            }

            const field_tok = self.tok;
            try self.expect(.identifier);
            const field_name = self.lexeme(field_tok.loc);
            try self.expect(.colon);
            const value = try self.parseExpr(0);
            try fields.append(.{ .name = field_name, .value = value });
            _ = self.match(.comma);
        }

        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .struct_literal = .{
                .ty = ty,
                .fields = try fields.toOwnedSlice(),
                .update_expr = update_expr,
            },
        };
        return node;
    }

    fn parseGenericStructLiteralTail(self: *Parser, name: []const u8) ParserError!*ast.Node {
        var generics = std.array_list.Managed(*ast.Type).init(self.allocator);
        while (true) {
            const ty = try self.parseType();
            try generics.append(ty);
            if (!self.match(.comma)) break;
        }
        try self.expectGenericClose();
        const lit_ty = try self.makeUserDefinedType(name, try generics.toOwnedSlice());
        return try self.parseStructLiteral(lit_ty);
    }

    fn parseEnumLiteralAfterName(self: *Parser, enum_name: []const u8) ParserError!*ast.Node {
        try self.expect(.double_colon);
        const variant_tok = self.tok;
        try self.expect(.identifier);
        const variant_name = self.lexeme(variant_tok.loc);

        var fields = std.array_list.Managed(ast.EnumLiteralField).init(self.allocator);
        if (self.match(.l_brace)) {
            while (self.peek() != .r_brace and self.peek() != .eof) {
                const field_tok = self.tok;
                try self.expect(.identifier);
                const field_name = self.lexeme(field_tok.loc);
                try self.expect(.colon);
                const value = try self.parseExpr(0);
                try fields.append(.{ .name = field_name, .value = value });
                _ = self.match(.comma);
            }
            try self.expect(.r_brace);
        } else if (self.match(.l_paren)) {
            var field_index: usize = 0;
            while (self.peek() != .r_paren and self.peek() != .eof) {
                const value = try self.parseExpr(0);
                const field_name = std.fmt.allocPrint(self.allocator, "{}", .{field_index}) catch return ParserError.OutOfMemory;
                try fields.append(.{ .name = field_name, .value = value });
                field_index += 1;
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_paren);
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .enum_literal = .{ .enum_name = enum_name, .variant_name = variant_name, .fields = try fields.toOwnedSlice() } };
        return node;
    }

    fn parseModuleCallAfterName(self: *Parser, module_name: []const u8) ParserError!*ast.Node {
        try self.expect(.double_colon);

        var path_parts = std.array_list.Managed([]const u8).init(self.allocator);
        try path_parts.append(module_name);

        while (true) {
            const part_tok = self.tok;
            try self.expect(.identifier);
            try path_parts.append(self.lexeme(part_tok.loc));
            if (self.peek() == .double_colon) {
                var lex_copy = self.lex;
                const next_tok = lex_copy.next();
                if (next_tok.tag == .less_than) break;
                self.advance();
                continue;
            }
            break;
        }

        var generics = std.array_list.Managed(*ast.Type).init(self.allocator);
        _ = self.match(.double_colon);
        if (self.match(.less_than)) {
            while (true) {
                const ty = try self.parseType();
                try generics.append(ty);
                if (!self.match(.comma)) break;
            }
            try self.expectGenericClose();
        }

        try self.expect(.l_paren);
        var args = std.array_list.Managed(*ast.Node).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const arg = try self.parseExpr(0);
            try args.append(arg);
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_paren);

        var name_buf = std.array_list.Managed(u8).init(self.allocator);
        for (path_parts.items, 0..) |part, i| {
            if (i > 0) try name_buf.appendSlice("__");
            try name_buf.appendSlice(part);
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .call_expr = .{
                .func_name = try name_buf.toOwnedSlice(),
                .associated_target = null,
                .generics = try generics.toOwnedSlice(),
                .args = try args.toOwnedSlice(),
            },
        };
        return node;
    }

    fn parseAssociatedCallAfterName(self: *Parser, target_name: []const u8) ParserError!*ast.Node {
        try self.expect(.double_colon);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const func_name = self.lexeme(name_tok.loc);
        try self.expect(.l_paren);

        var args = std.array_list.Managed(*ast.Node).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const arg = try self.parseExpr(0);
            try args.append(arg);
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_paren);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .call_expr = .{
                .func_name = func_name,
                .associated_target = target_name,
                .generics = &.{},
                .args = try args.toOwnedSlice(),
            },
        };
        return node;
    }

    fn looksLikeGenericFunctionCallTail(self: *Parser) bool {
        var lex_copy = self.lex;
        var tok_copy = self.tok;
        var depth: usize = 1;

        while (tok_copy.tag != .eof) {
            if (depth == 1 and genericLookaheadBoundary(tok_copy.tag)) return false;
            switch (tok_copy.tag) {
                .less_than => depth += 1,
                .greater_than => {
                    depth -= 1;
                    if (depth == 0) {
                        tok_copy = lex_copy.next();
                        return tok_copy.tag == .l_paren;
                    }
                },
                .greater_greater => {
                    if (depth <= 2) {
                        tok_copy = lex_copy.next();
                        return tok_copy.tag == .l_paren;
                    }
                    depth -= 2;
                },
                else => {},
            }
            tok_copy = lex_copy.next();
        }
        return false;
    }

    fn genericFunctionRefBoundary(tag: lexer.Token.Tag) bool {
        return switch (tag) {
            .comma, .semicolon, .r_paren, .r_brace, .r_bracket, .eof => true,
            else => false,
        };
    }

    fn looksLikeGenericFunctionRefTail(self: *Parser) bool {
        var lex_copy = self.lex;
        var tok_copy = self.tok;
        var depth: usize = 1;

        while (tok_copy.tag != .eof) {
            if (depth == 1 and genericLookaheadBoundary(tok_copy.tag)) return false;
            switch (tok_copy.tag) {
                .less_than => depth += 1,
                .greater_than => {
                    depth -= 1;
                    if (depth == 0) {
                        tok_copy = lex_copy.next();
                        return genericFunctionRefBoundary(tok_copy.tag);
                    }
                },
                .greater_greater => {
                    if (depth <= 2) {
                        tok_copy = lex_copy.next();
                        return genericFunctionRefBoundary(tok_copy.tag);
                    }
                    depth -= 2;
                },
                else => {},
            }
            tok_copy = lex_copy.next();
        }
        return false;
    }

    fn looksLikeGenericMethodCallTail(self: *Parser) bool {
        if (self.peek() != .less_than) return false;
        var lex_copy = self.lex;
        var tok_copy = lex_copy.next();
        var depth: usize = 1;

        while (tok_copy.tag != .eof) {
            if (depth == 1 and genericLookaheadBoundary(tok_copy.tag)) return false;
            switch (tok_copy.tag) {
                .less_than => depth += 1,
                .greater_than => {
                    depth -= 1;
                    if (depth == 0) {
                        tok_copy = lex_copy.next();
                        return tok_copy.tag == .l_paren;
                    }
                },
                .greater_greater => {
                    if (depth <= 2) {
                        tok_copy = lex_copy.next();
                        return tok_copy.tag == .l_paren;
                    }
                    depth -= 2;
                },
                else => {},
            }
            tok_copy = lex_copy.next();
        }
        return false;
    }

    fn parseGenericCallTail(self: *Parser, func_name: []const u8) ParserError!*ast.Node {
        var generics = std.array_list.Managed(*ast.Type).init(self.allocator);
        while (true) {
            const ty = try self.parseType();
            try generics.append(ty);
            if (!self.match(.comma)) break;
        }
        try self.expectGenericClose();
        try self.expect(.l_paren);

        var args = std.array_list.Managed(*ast.Node).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const arg = try self.parseExpr(0);
            try args.append(arg);
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_paren);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .call_expr = .{
                .func_name = func_name,
                .associated_target = null,
                .generics = try generics.toOwnedSlice(),
                .args = try args.toOwnedSlice(),
            },
        };
        return node;
    }

    fn parseGenericFunctionRefTail(self: *Parser, func_name: []const u8) ParserError!*ast.Node {
        var generics = std.array_list.Managed(*ast.Type).init(self.allocator);
        while (true) {
            const ty = try self.parseType();
            try generics.append(ty);
            if (!self.match(.comma)) break;
        }
        try self.expectGenericClose();

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .generic_func_ref = .{ .func_name = func_name, .generics = try generics.toOwnedSlice() } };
        return node;
    }

    fn parseClosureLiteral(self: *Parser) ParserError!*ast.Node {
        if (self.match(.pipe_pipe)) {
            const body = try self.parseExpr(0);
            const node = try self.allocator.create(ast.Node);
            node.* = .{ .closure_literal = .{ .params = &.{}, .body = body } };
            return node;
        }
        try self.expect(.pipe);
        var params = std.array_list.Managed(ast.Param).init(self.allocator);
        while (self.peek() != .pipe and self.peek() != .eof) {
            const p_tok = self.tok;
            try self.expect(.identifier);
            const p_name = self.lexeme(p_tok.loc);
            const p_ty = if (self.match(.colon)) blk: {
                break :blk try self.parseType();
            } else blk: {
                const ty = try self.allocator.create(ast.Type);
                ty.* = .infer;
                break :blk ty;
            };
            try params.append(.{ .name = p_name, .ty = p_ty });
            if (!self.match(.comma)) break;
        }
        try self.expect(.pipe);
        const body = try self.parseExpr(0);
        const node = try self.allocator.create(ast.Node);
        node.* = .{ .closure_literal = .{ .params = try params.toOwnedSlice(), .body = body } };
        return node;
    }

    fn parseEnumPattern(self: *Parser) ParserError!ast.EnumPattern {
        const enum_tok = self.tok;
        try self.expect(.identifier);
        const first_name = self.lexeme(enum_tok.loc);

        var enum_name: []const u8 = if (std.mem.eql(u8, first_name, "Ok") or std.mem.eql(u8, first_name, "Err")) "Result" else "Option";
        var variant_name: []const u8 = first_name;
        if (self.match(.double_colon)) {
            const variant_tok = self.tok;
            try self.expect(.identifier);
            enum_name = first_name;
            variant_name = self.lexeme(variant_tok.loc);
        } else if (!std.mem.eql(u8, first_name, "Some") and !std.mem.eql(u8, first_name, "None") and
            !std.mem.eql(u8, first_name, "Ok") and !std.mem.eql(u8, first_name, "Err"))
        {
            return ParserError.UnexpectedToken;
        }

        var bindings = std.array_list.Managed([]const u8).init(self.allocator);
        if (self.match(.l_brace)) {
            while (self.peek() != .r_brace and self.peek() != .eof) {
                const bind_tok = self.tok;
                try self.expect(.identifier);
                try bindings.append(self.lexeme(bind_tok.loc));
                _ = self.match(.comma);
            }
            try self.expect(.r_brace);
        } else if (self.match(.l_paren)) {
            while (self.peek() != .r_paren and self.peek() != .eof) {
                const bind_tok = self.tok;
                try self.expect(.identifier);
                try bindings.append(self.lexeme(bind_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_paren);
        }

        return .{ .enum_name = enum_name, .variant_name = variant_name, .bindings = try bindings.toOwnedSlice() };
    }

    fn parseLetPattern(self: *Parser) ParserError!ast.EnumPattern {
        const first_tok = self.tok;
        try self.expect(.identifier);
        const first_name = self.lexeme(first_tok.loc);

        var enum_name: []const u8 = if (std.mem.eql(u8, first_name, "Ok") or std.mem.eql(u8, first_name, "Err")) "Result" else "Option";
        var variant_name: []const u8 = first_name;
        if (self.match(.double_colon)) {
            const variant_tok = self.tok;
            try self.expect(.identifier);
            enum_name = first_name;
            variant_name = self.lexeme(variant_tok.loc);
        }

        var bindings = std.array_list.Managed([]const u8).init(self.allocator);
        if (self.match(.l_brace)) {
            while (self.peek() != .r_brace and self.peek() != .eof) {
                const bind_tok = self.tok;
                try self.expect(.identifier);
                try bindings.append(self.lexeme(bind_tok.loc));
                _ = self.match(.comma);
            }
            try self.expect(.r_brace);
        } else if (self.match(.l_paren)) {
            while (self.peek() != .r_paren and self.peek() != .eof) {
                const bind_tok = self.tok;
                try self.expect(.identifier);
                try bindings.append(self.lexeme(bind_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_paren);
        }

        return .{ .enum_name = enum_name, .variant_name = variant_name, .bindings = try bindings.toOwnedSlice() };
    }

    fn parseIfLetChain(self: *Parser) ParserError![]const ast.IfLetCond {
        var chain = std.array_list.Managed(ast.IfLetCond).init(self.allocator);
        while (true) {
            try self.expect(.keyword_let);
            const pattern = try self.parseLetPattern();
            try self.expect(.equal);
            const value = try self.parseExpr(self.getInfixPrecedence(.amp_amp));
            try chain.append(.{ .pattern = pattern, .value = value });
            if (!self.match(.amp_amp)) break;
            if (self.peek() != .keyword_let) return ParserError.UnexpectedToken;
        }
        return try chain.toOwnedSlice();
    }

    fn parseMatchExpr(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_match);
        const val = try self.parseExpr(0);
        try self.expect(.l_brace);

        var cases = std.array_list.Managed(ast.MatchCase).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const pattern = try self.parseEnumPattern();
            const guard = if (self.match(.keyword_if)) try self.parseExpr(0) else null;
            try self.expect(.fat_arrow);
            const body = try self.parseBlock();
            try cases.append(.{ .pattern = pattern, .guard = guard, .body = body });
            _ = self.match(.comma);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .match_expr = .{ .val = val, .cases = try cases.toOwnedSlice() } };
        return node;
    }

    fn parseInlineAsmExpr(self: *Parser) ParserError!*ast.Node {
        try self.expect(.l_paren);
        const template_tok = self.tok;
        try self.expect(.string_literal);
        const raw_template = self.lexeme(template_tok.loc);

        var operands = std.array_list.Managed(ast.InlineAsmOperand).init(self.allocator);
        while (self.match(.comma)) {
            if (self.peek() == .r_paren) break;
            const constraint_tok = self.tok;
            try self.expect(.identifier);
            const constraint = self.lexeme(constraint_tok.loc);
            try self.expect(.l_paren);
            const reg_tok = self.tok;
            try self.expect(.string_literal);
            const raw_reg = self.lexeme(reg_tok.loc);
            try self.expect(.r_paren);
            const value_tok = self.tok;
            try self.expect(.identifier);
            const value_name = self.lexeme(value_tok.loc);
            _ = raw_reg;
            try operands.append(.{ .constraint = constraint, .var_name = value_name });
        }
        try self.expect(.r_paren);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .inline_asm_expr = .{ .template = raw_template[1 .. raw_template.len - 1], .operands = try operands.toOwnedSlice() } };
        return node;
    }

    fn parseExpr(self: *Parser, precedence: u8) ParserError!*ast.Node {
        var left = try self.parsePrefixExpr();
        while (true) {
            // Ternary interception only fires at the loosest level: inside
            // a tighter operator's RHS (precedence >= 1) the `?` must be left
            // for the outer loop, so `a == b ? x : y` conditions on the whole
            // comparison. Postfix `?` (try) still works everywhere: a failed
            // ternary attempt restores the cursor and falls through below.
            if (self.peek() == .question_mark and precedence < 1) {
                const saved_lex = self.lex;
                const saved_tok = self.tok;

                self.advance();
                const ternary = if (tokenStartsPrefixExpr(self.peek())) blk: {
                    const then_expr = self.parseExpr(0) catch break :blk null;
                    if (!self.match(.colon)) break :blk null;
                    const else_expr = self.parseExpr(0) catch break :blk null;

                    const then_node = try self.allocator.create(ast.Node);
                    then_node.* = .{ .expr_stmt = then_expr };
                    const else_node = try self.allocator.create(ast.Node);
                    else_node.* = .{ .expr_stmt = else_expr };

                    const then_block = try self.allocator.alloc(*ast.Node, 1);
                    then_block[0] = then_node;
                    const else_block = try self.allocator.alloc(*ast.Node, 1);
                    else_block[0] = else_node;

                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .if_expr = .{ .cond = left, .then_block = then_block, .else_block = else_block } };
                    break :blk node;
                } else null;

                if (ternary) |node| {
                    left = node;
                    continue;
                }

                self.lex = saved_lex;
                self.tok = saved_tok;
            }

            // Null-coalescing `a ?? b` desugars to the Option method call
            // `a.unwrap_or(b)` (single evaluation, no new AST/lowering work).
            // Same loosest-level rule as ternary: only fire at precedence 0,
            // so `x == none ?? y` keeps the whole comparison as the LHS.
            if (self.peek() == .question_question and precedence < 1) {
                self.advance();
                const rhs = try self.parseExpr(1);

                const args = try self.allocator.alloc(*ast.Node, 2);
                args[0] = left;
                args[1] = rhs;
                const generics = try self.allocator.alloc(*ast.Type, 0);
                const node = try self.allocator.create(ast.Node);
                node.* = .{
                    .call_expr = .{
                        .func_name = "unwrap_or",
                        .associated_target = null,
                        .generics = generics,
                        .args = args,
                    },
                };
                left = node;
                continue;
            }

            // Non-null assertion `x!` desugars to the Option/Result method
            // call `x.unwrap()` (TS `!` is compile-time-only; SLA checks at
            // runtime and panics on None/Err — same zero-machinery trick as
            // `??` above). Postfix binds tightest: fire at any level. A bare
            // `.bang` can never legally follow an operand otherwise (`!=`
            // lexes as one token), so there is no ambiguity with prefix `!`.
            if (self.peek() == .bang) {
                self.advance();
                const args = try self.allocator.alloc(*ast.Node, 1);
                args[0] = left;
                const generics = try self.allocator.alloc(*ast.Type, 0);
                const node = try self.allocator.create(ast.Node);
                node.* = .{
                    .call_expr = .{
                        .func_name = "unwrap",
                        .associated_target = null,
                        .generics = generics,
                        .args = args,
                    },
                };
                left = node;
                continue;
            }

            // Optional chain `a?.field` / `a?.method(args)` desugars (single
            // evaluation) to:
            //   if let Some(__qcN) = a { Some(__qcN.field) } else { None }
            // so a None LHS yields None instead of propagating. Postfix binds
            // tightest: fire at any level; `a?.b == c` reads `(a?.b) == c`.
            // Generic method form `a?.m<T>()` is not covered (clear error when
            // `<` follows the field name).
            if (self.peek() == .question_dot) {
                self.advance();
                const field_tok = self.tok;
                if (self.peek() != .identifier and self.peek() != .int_literal) return ParserError.UnexpectedToken;
                self.advance();
                const field_name = self.lexeme(field_tok.loc);

                const tmp_name = try std.fmt.allocPrint(self.allocator, "__qc{d}", .{self.synth_counter});
                self.synth_counter += 1;
                const bindings = try self.allocator.alloc([]const u8, 1);
                bindings[0] = tmp_name;
                const chain = try self.allocator.alloc(ast.IfLetCond, 1);
                chain[0] = .{
                    .pattern = .{ .enum_name = "Option", .variant_name = "Some", .bindings = bindings },
                    .value = left,
                };

                const tmp_ident = try self.allocator.create(ast.Node);
                tmp_ident.* = .{ .identifier = tmp_name };
                // `a?.method(args)`: the wrapped value is a UFCS method call
                // `method(__qcN, args...)`; otherwise a plain field access.
                const wrapped_value = blk: {
                    if (self.peek() == .l_paren) {
                        self.advance();
                        var call_args = std.array_list.Managed(*ast.Node).init(self.allocator);
                        try call_args.append(tmp_ident);
                        if (self.peek() != .r_paren and self.peek() != .eof) {
                            while (true) {
                                const arg = try self.parseExpr(0);
                                try call_args.append(arg);
                                if (!self.match(.comma)) break;
                            }
                        }
                        try self.expect(.r_paren);
                        const method_generics = try self.allocator.alloc(*ast.Type, 0);
                        const method_call = try self.allocator.create(ast.Node);
                        method_call.* = .{
                            .call_expr = .{
                                .func_name = field_name,
                                .associated_target = null,
                                .generics = method_generics,
                                .args = try call_args.toOwnedSlice(),
                            },
                        };
                        break :blk method_call;
                    } else {
                        const field_access = try self.allocator.create(ast.Node);
                        field_access.* = .{ .field_expr = .{ .expr = tmp_ident, .field_name = field_name } };
                        break :blk field_access;
                    }
                };
                const some_args = try self.allocator.alloc(*ast.Node, 1);
                some_args[0] = wrapped_value;
                const generics = try self.allocator.alloc(*ast.Type, 0);
                const some_call = try self.allocator.create(ast.Node);
                some_call.* = .{
                    .call_expr = .{
                        .func_name = "Some",
                        .associated_target = null,
                        .generics = generics,
                        .args = some_args,
                    },
                };
                const then_node = try self.allocator.create(ast.Node);
                then_node.* = .{ .expr_stmt = some_call };
                const none_ident = try self.allocator.create(ast.Node);
                none_ident.* = .{ .identifier = "None" };
                const else_node = try self.allocator.create(ast.Node);
                else_node.* = .{ .expr_stmt = none_ident };
                const then_block = try self.allocator.alloc(*ast.Node, 1);
                then_block[0] = then_node;
                const else_block = try self.allocator.alloc(*ast.Node, 1);
                else_block[0] = else_node;

                const node = try self.allocator.create(ast.Node);
                node.* = .{
                    .if_expr = .{
                        .cond = left,
                        .let_chain = chain,
                        .then_block = then_block,
                        .else_block = else_block,
                    },
                };
                left = node;
                continue;
            }

            var op_prec = self.getInfixPrecedence(self.peek());
            // A `<` following an identifier may begin a generic call `f<T>(...)`,
            // generic struct literal `S<T> { ... }`, or generic function reference
            // `f<T>`. These tails bind tighter than any binary operator, so detect
            // them before the precedence-based break. Without this, an expression
            // like `a + f<T>(x)` parses `<` as a comparison (precedence 5, below
            // `+`), leaving `f` as a dangling bare identifier.
            //
            // The looksLike* helpers expect the `<` to have already been consumed
            // (they scan from self.tok with depth=1), so probe on a saved cursor
            // that has advanced past the `<`, then restore.
            if (self.peek() == .less_than and left.* == .identifier) {
                const saved_lex = self.lex;
                const saved_tok = self.tok;
                self.advance();
                const is_generic_tail = self.looksLikeGenericStructLiteralTail() or
                    self.looksLikeGenericFunctionCallTail() or
                    self.looksLikeGenericFunctionRefTail();
                self.lex = saved_lex;
                self.tok = saved_tok;
                if (is_generic_tail) op_prec = 10;
            }
            if (op_prec <= precedence) break;
            left = try self.parseInfixExpr(left, op_prec);
        }

        return left;
    }

    fn tokenStartsPrefixExpr(tag: lexer.Token.Tag) bool {
        return switch (tag) {
            .int_literal,
            .float_literal,
            .string_literal,
            .template_start,
            .identifier,
            .ampersand,
            .caret,
            .asterisk,
            .minus,
            .bang,
            .keyword_if,
            .keyword_switch,
            .keyword_match,
            .keyword_unsafe,
            .keyword_await,
            .pipe,
            .pipe_pipe,
            .l_paren,
            .l_bracket,
            => true,
            else => false,
        };
    }

    /// #11: copy a numeric literal lexeme sans `_` separators. The lexer only
    /// keeps `_` between digits, so dropping every `_` is exact.
    fn stripNumericSeparators(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
        var out = try allocator.alloc(u8, str.len);
        var len: usize = 0;
        for (str) |ch| {
            if (ch == '_') continue;
            out[len] = ch;
            len += 1;
        }
        return out[0..len];
    }

    fn integerSuffixPrimitive(suffix: []const u8) ?ast.Primitive {
        if (std.mem.eql(u8, suffix, "i8")) return .i8;
        if (std.mem.eql(u8, suffix, "i16")) return .i16;
        if (std.mem.eql(u8, suffix, "i32")) return .i32;
        if (std.mem.eql(u8, suffix, "i64")) return .i64;
        if (std.mem.eql(u8, suffix, "isize")) return .isize;
        if (std.mem.eql(u8, suffix, "u8")) return .u8;
        if (std.mem.eql(u8, suffix, "u16")) return .u16;
        if (std.mem.eql(u8, suffix, "u32")) return .u32;
        if (std.mem.eql(u8, suffix, "u64")) return .u64;
        if (std.mem.eql(u8, suffix, "usize")) return .usize;
        return null;
    }

    fn parsePrefixExpr(self: *Parser) ParserError!*ast.Node {
        const tag = self.peek();
        switch (tag) {
            .int_literal => {
                const tok = self.tok;
                self.advance();
                const str = self.lexeme(tok.loc);
                // #11: drop `_` separators before scanning digits/suffix.
                const clean = try stripNumericSeparators(self.allocator, str);
                var digit_len: usize = 0;
                var base: u8 = 10;
                var digits_start: usize = 0;
                if (clean.len >= 2 and clean[0] == '0' and (clean[1] == 'x' or clean[1] == 'X')) {
                    base = 16;
                    digits_start = 2;
                    digit_len = 2;
                    while (digit_len < clean.len and std.ascii.isHex(clean[digit_len])) : (digit_len += 1) {}
                } else {
                    while (digit_len < clean.len and std.ascii.isDigit(clean[digit_len])) : (digit_len += 1) {}
                }
                const primitive = if (digit_len < clean.len)
                    integerSuffixPrimitive(clean[digit_len..]) orelse return ParserError.InvalidCharacter
                else
                    null;
                const digits = clean[digits_start..digit_len];
                const unsigned_wide_suffix = if (primitive) |primitive_ty| primitive_ty == .u64 or primitive_ty == .usize else false;
                const val: i64 = if (unsigned_wide_suffix) blk: {
                    const unsigned = std.fmt.parseInt(u64, digits, base) catch return ParserError.InvalidCharacter;
                    break :blk @bitCast(unsigned);
                } else std.fmt.parseInt(i64, digits, base) catch return ParserError.InvalidCharacter;
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .literal = .{ .int_val = val } };
                if (primitive) |primitive_ty| {
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = primitive_ty };
                    const cast_node = try self.allocator.create(ast.Node);
                    cast_node.* = .{ .cast_expr = .{ .expr = node, .ty = ty } };
                    return cast_node;
                }
                return node;
            },
            .float_literal => {
                const tok = self.tok;
                self.advance();
                const str = self.lexeme(tok.loc);
                // #11: drop `_` separators before parsing.
                const clean = try stripNumericSeparators(self.allocator, str);
                const val = std.fmt.parseFloat(f64, clean) catch return ParserError.InvalidCharacter;
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .literal = .{ .float_val = val } };
                return node;
            },
            .string_literal => {
                const tok = self.tok;
                self.advance();
                const raw = self.lexeme(tok.loc);
                const val = raw[1 .. raw.len - 1];
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .literal = .{ .string_val = val } };
                return node;
            },
            .template_start => {
                return try self.parseTemplateLiteral();
            },
            .identifier => {
                const tok = self.tok;
                self.advance();
                const str = self.lexeme(tok.loc);
                if (std.mem.eql(u8, str, "asm") and self.match(.bang)) {
                    return try self.parseInlineAsmExpr();
                }
                if (self.peek() == .double_colon) {
                    if (self.isKnownEnumName(str)) {
                        return try self.parseEnumLiteralAfterName(str);
                    }
                    if (self.isKnownModuleName(str)) {
                        return try self.parseModuleCallAfterName(str);
                    }
                    var lex_copy = self.lex;
                    var tok_copy = lex_copy.next();
                    if (tok_copy.tag == .identifier) {
                        const assoc_name = self.lexeme(tok_copy.loc);
                        tok_copy = lex_copy.next();
                        if (tok_copy.tag == .double_colon) {
                            return try self.parseModuleCallAfterName(str);
                        }
                        if (tok_copy.tag == .l_paren) {
                            return try self.parseAssociatedCallAfterName(str);
                        }
                        if (std.mem.eql(u8, str, "Ordering")) {
                            _ = self.match(.double_colon);
                            const assoc_tok = self.tok;
                            try self.expect(.identifier);
                            const node = try self.allocator.create(ast.Node);
                            node.* = .{ .identifier = try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ str, self.lexeme(assoc_tok.loc) }) };
                            return node;
                        }
                        _ = assoc_name;
                    }
                    return try self.parseEnumLiteralAfterName(str);
                }
                if (self.peek() == .l_brace and self.isKnownTypeName(str)) {
                    const lit_ty = if (std.mem.eql(u8, str, "Self"))
                        self.current_impl_target orelse return ParserError.UnexpectedTypeToken
                    else
                        try self.makeUserDefinedType(str, &.{});
                    return try self.parseStructLiteral(lit_ty);
                }
                if (std.mem.eql(u8, str, "true")) {
                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .literal = .{ .bool_val = true } };
                    return node;
                } else if (std.mem.eql(u8, str, "false")) {
                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .literal = .{ .bool_val = false } };
                    return node;
                }
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .identifier = str };
                return node;
            },
            .ampersand => {
                self.advance();
                const expr = try self.parseExpr(6);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .borrow_expr = .{ .expr = expr } };
                return node;
            },
            .caret => {
                self.advance();
                const expr = try self.parseExpr(6);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .move_expr = .{ .expr = expr } };
                return node;
            },
            .asterisk => {
                self.advance();
                const expr = try self.parseExpr(6);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .deref_expr = .{ .expr = expr } };
                return node;
            },
            .minus => {
                // Unary minus: lower to (0 - expr)
                self.advance();
                const zero = try self.allocator.create(ast.Node);
                zero.* = .{ .literal = .{ .int_val = 0 } };
                const expr = try self.parseExpr(6);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .binary_expr = .{ .op = .sub, .left = zero, .right = expr } };
                return node;
            },
            .bang => {
                // Logical NOT for bool: lower to (expr == false)
                self.advance();
                const expr = try self.parseExpr(8);
                const false_lit = try self.allocator.create(ast.Node);
                false_lit.* = .{ .literal = .{ .bool_val = false } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .binary_expr = .{ .op = .eq, .left = expr, .right = false_lit } };
                return node;
            },
            .keyword_if => {
                return try self.parseIfExpr();
            },
            .keyword_switch => {
                return try self.parseSwitchExpr();
            },
            .keyword_match => {
                return try self.parseMatchExpr();
            },
            .keyword_unsafe => {
                self.advance();
                const body = try self.parseBlock();
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .unsafe_expr = .{ .body = body } };
                return node;
            },
            .keyword_await => {
                self.advance();
                const expr = try self.parseExpr(6);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .await_expr = .{ .expr = expr } };
                return node;
            },
            .pipe, .pipe_pipe => {
                return try self.parseClosureLiteral();
            },
            .l_paren => {
                self.advance();
                const expr = try self.parseExpr(0);
                if (self.match(.comma)) {
                    var elements = std.array_list.Managed(*ast.Node).init(self.allocator);
                    try elements.append(expr);
                    while (self.peek() != .r_paren and self.peek() != .eof) {
                        const elem = try self.parseExpr(0);
                        try elements.append(elem);
                        if (!self.match(.comma)) break;
                    }
                    try self.expect(.r_paren);
                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .tuple_literal = .{ .elements = try elements.toOwnedSlice() } };
                    return node;
                }
                try self.expect(.r_paren);
                return expr;
            },
            .l_bracket => {
                self.advance();
                var elements = std.array_list.Managed(*ast.Node).init(self.allocator);
                if (self.peek() != .r_bracket and self.peek() != .eof) {
                    const first = try self.parseExpr(0);
                    if (self.match(.semicolon)) {
                        const len_tok = self.tok;
                        try self.expect(.int_literal);
                        const len_str = self.lexeme(len_tok.loc);
                        // #11: drop `_` separators before scanning length digits.
                        const len_clean = try stripNumericSeparators(self.allocator, len_str);
                        var digit_len: usize = 0;
                        while (digit_len < len_clean.len and std.ascii.isDigit(len_clean[digit_len])) : (digit_len += 1) {}
                        const len = std.fmt.parseInt(usize, len_clean[0..digit_len], 10) catch return ParserError.InvalidCharacter;
                        try self.expect(.r_bracket);
                        const node = try self.allocator.create(ast.Node);
                        node.* = .{ .repeat_array_literal = .{ .value = first, .len = len } };
                        return node;
                    }
                    try elements.append(first);
                    while (self.peek() != .r_bracket and self.peek() != .eof) {
                        if (!self.match(.comma)) break;
                        if (self.peek() == .r_bracket) break;
                        const elem = try self.parseExpr(0);
                        try elements.append(elem);
                    }
                }
                try self.expect(.r_bracket);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .array_literal = .{ .elements = try elements.toOwnedSlice() } };
                return node;
            },
            else => {
                std.debug.print("Unexpected prefix token: {s} at index {}\n", .{ @tagName(tag), self.tok.loc.start });
                return ParserError.UnexpectedToken;
            },
        }
    }

    fn parseInfixExpr(self: *Parser, left: *ast.Node, precedence: u8) ParserError!*ast.Node {
        const tag = self.peek();
        self.advance();

        switch (tag) {
            .plus, .minus, .asterisk, .slash, .percent, .ampersand, .amp_amp, .pipe, .pipe_pipe, .caret, .less_less, .greater_greater, .less_than, .greater_than, .less_equal, .greater_equal, .spaceship, .equal_equal, .bang_equal => {
                if (tag == .less_than and left.* == .identifier and self.looksLikeGenericStructLiteralTail()) {
                    return try self.parseGenericStructLiteralTail(left.identifier);
                }
                if (tag == .less_than and left.* == .identifier and self.looksLikeGenericFunctionCallTail()) {
                    return try self.parseGenericCallTail(left.identifier);
                }
                if (tag == .less_than and left.* == .identifier and self.looksLikeGenericFunctionRefTail()) {
                    return try self.parseGenericFunctionRefTail(left.identifier);
                }

                const op = switch (tag) {
                    .plus => ast.BinaryOp.add,
                    .minus => ast.BinaryOp.sub,
                    .asterisk => ast.BinaryOp.mul,
                    .slash => ast.BinaryOp.div,
                    .percent => ast.BinaryOp.mod,
                    .ampersand => ast.BinaryOp.bit_and,
                    .amp_amp => ast.BinaryOp.logical_and,
                    .pipe => ast.BinaryOp.bit_or,
                    .pipe_pipe => ast.BinaryOp.logical_or,
                    .caret => ast.BinaryOp.bit_xor,
                    .less_less => ast.BinaryOp.shl,
                    .greater_greater => ast.BinaryOp.shr,
                    .less_than => ast.BinaryOp.lt,
                    .less_equal => ast.BinaryOp.le,
                    .greater_than => ast.BinaryOp.gt,
                    .greater_equal => ast.BinaryOp.ge,
                    .spaceship => ast.BinaryOp.spaceship,
                    .equal_equal => ast.BinaryOp.eq,
                    .bang_equal => ast.BinaryOp.ne,
                    else => unreachable,
                };
                const right = try self.parseExpr(precedence);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .binary_expr = .{ .op = op, .left = left, .right = right } };
                return node;
            },
            .dot => {
                if (self.peek() == .keyword_await) {
                    self.advance();
                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .await_expr = .{ .expr = left } };
                    return node;
                }
                const field_tok = self.tok;
                if (self.peek() != .identifier and self.peek() != .int_literal) {
                    return ParserError.UnexpectedToken;
                }
                self.advance();
                const field_name = self.lexeme(field_tok.loc);

                if (self.peek() == .l_paren or self.looksLikeGenericMethodCallTail()) {
                    var generic_args = std.array_list.Managed(*ast.Type).init(self.allocator);
                    if (self.match(.less_than)) {
                        while (true) {
                            const t = try self.parseType();
                            try generic_args.append(t);
                            if (!self.match(.comma)) break;
                        }
                        try self.expectGenericClose();
                    }

                    try self.expect(.l_paren);
                    var args = std.array_list.Managed(*ast.Node).init(self.allocator);
                    try args.append(left);
                    while (self.peek() != .r_paren and self.peek() != .eof) {
                        const arg = try self.parseExpr(0);
                        try args.append(arg);
                        if (!self.match(.comma)) break;
                    }
                    try self.expect(.r_paren);

                    const node = try self.allocator.create(ast.Node);
                    node.* = .{
                        .call_expr = .{
                            .func_name = field_name,
                            .associated_target = null,
                            .generics = try generic_args.toOwnedSlice(),
                            .args = try args.toOwnedSlice(),
                        },
                    };
                    return node;
                }

                const node = try self.allocator.create(ast.Node);
                node.* = .{ .field_expr = .{ .expr = left, .field_name = field_name } };
                return node;
            },
            .bang => {
                if (self.peek() != .l_paren) return ParserError.UnexpectedInfixToken;
                if (left.* != .identifier) return ParserError.InvalidCallTarget;
                var args = std.array_list.Managed(*ast.Node).init(self.allocator);
                self.advance();
                while (self.peek() != .r_paren and self.peek() != .eof) {
                    const arg = try self.parseExpr(0);
                    try args.append(arg);
                    if (!self.match(.comma)) break;
                }
                try self.expect(.r_paren);
                const node = try self.allocator.create(ast.Node);
                node.* = .{
                    .call_expr = .{
                        .func_name = left.identifier,
                        .associated_target = null,
                        .generics = &.{},
                        .args = try args.toOwnedSlice(),
                    },
                };
                return node;
            },
            .l_paren => {
                var func_name: []const u8 = "";
                var callee: ?*ast.Node = null;
                switch (left.*) {
                    .identifier => |id| func_name = id,
                    // #13: immediately-invoked closure literal; every other
                    // non-identifier callee keeps the historical rejection.
                    .closure_literal => callee = left,
                    else => return ParserError.InvalidCallTarget,
                }

                var args = std.array_list.Managed(*ast.Node).init(self.allocator);
                while (self.peek() != .r_paren and self.peek() != .eof) {
                    const arg = try self.parseExpr(0);
                    try args.append(arg);
                    if (!self.match(.comma)) break;
                }
                try self.expect(.r_paren);

                const node = try self.allocator.create(ast.Node);
                node.* = .{
                    .call_expr = .{
                        .func_name = func_name,
                        .associated_target = null,
                        .generics = &.{},
                        .args = try args.toOwnedSlice(),
                        .callee = callee,
                    },
                };
                return node;
            },
            .l_bracket => {
                const start = try self.parseExpr(0);
                if (self.match(.range)) {
                    const end = try self.parseExpr(0);
                    try self.expect(.r_bracket);
                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .slice_expr = .{ .target = left, .start = start, .end = end } };
                    return node;
                }
                try self.expect(.r_bracket);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .index_expr = .{ .target = left, .index = start } };
                return node;
            },
            .keyword_as => {
                const cast_ty = try self.parseType();
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .cast_expr = .{ .expr = left, .ty = cast_ty } };
                return node;
            },
            .question_mark => {
                const saved_lex = self.lex;
                const saved_tok = self.tok;

                const ternary_result = if (tokenStartsPrefixExpr(self.peek())) blk: {
                    const then_expr = self.parseExpr(0) catch break :blk null;
                    if (!self.match(.colon)) break :blk null;
                    const else_expr = self.parseExpr(0) catch break :blk null;

                    const then_node = try self.allocator.create(ast.Node);
                    then_node.* = .{ .expr_stmt = then_expr };
                    const else_node = try self.allocator.create(ast.Node);
                    else_node.* = .{ .expr_stmt = else_expr };

                    const then_block = try self.allocator.alloc(*ast.Node, 1);
                    then_block[0] = then_node;
                    const else_block = try self.allocator.alloc(*ast.Node, 1);
                    else_block[0] = else_node;

                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .if_expr = .{ .cond = left, .then_block = then_block, .else_block = else_block } };
                    break :blk node;
                } else null;

                if (ternary_result) |node| return node;

                self.lex = saved_lex;
                self.tok = saved_tok;

                const node = try self.allocator.create(ast.Node);
                node.* = .{ .try_expr = .{ .expr = left } };
                return node;
            },
            else => return ParserError.UnexpectedInfixToken,
        }
    }

    fn getInfixPrecedence(self: *Parser, tag: lexer.Token.Tag) u8 {
        _ = self;
        return switch (tag) {
            .pipe_pipe => 1,
            .amp_amp => 2,
            .pipe => 1,
            .caret => 2,
            .ampersand => 3,
            .equal_equal, .bang_equal, .spaceship => 4,
            .less_than, .greater_than, .less_equal, .greater_equal => 5,
            .less_less, .greater_greater => 6,
            .plus, .minus => 7,
            .asterisk, .slash, .percent => 8,
            .dot, .bang, .l_paren, .l_bracket => 10,
            // `??` shares ternary's loosest level: `a ?? b == c` reads the
            // whole comparison as the fallback, matching `?:` behavior.
            .question_question => 1,
            // Ternary `?:` binds looser than every binary operator (C-like):
            // `a == b ? x : y` must read the whole comparison as the
            // condition, not `b ? x : y`. Postfix `?` (try) is unaffected:
            // it is attempted first at the interception site below and only
            // falls through here when no colon follows.
            .question_mark => 1,
            .keyword_as => 9,
            else => 0,
        };
    }

    /// Appends one raw template chunk to a synthesized `format()` pattern.
    /// Backslashes pass through untouched (regular strings unescape them
    /// downstream); only template-only escapes are resolved here (`\${`
    /// would otherwise be an unknown downstream escape). `"` is escaped
    /// for the synthesized literal; `{`/`}` are doubled for `format()`.
    fn appendTemplateChunk(out: *std.array_list.Managed(u8), raw: []const u8) ParserError!void {
        const push = struct {
            fn s(list: *std.array_list.Managed(u8), text: []const u8) ParserError!void {
                list.appendSlice(text) catch return ParserError.OutOfMemory;
            }
            fn c(list: *std.array_list.Managed(u8), ch: u8) ParserError!void {
                list.append(ch) catch return ParserError.OutOfMemory;
            }
        };
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\\') {
                if (i + 1 >= raw.len) {
                    try push.c(out, c);
                    break;
                }
                const n = raw[i + 1];
                if (n == '$' and i + 2 < raw.len and raw[i + 2] == '{') {
                    try push.s(out, "${");
                    i += 3;
                    continue;
                } else if (n == '`') {
                    try push.c(out, '`');
                    i += 2;
                    continue;
                } else {
                    try push.c(out, c);
                    try push.c(out, n);
                    i += 2;
                    continue;
                }
            }
            if (c == '"') {
                try push.s(out, "\\\"");
            } else if (c == '{') {
                try push.s(out, "{{");
            } else if (c == '}') {
                try push.s(out, "}}");
            } else {
                try push.c(out, c);
            }
            i += 1;
        }
    }

    /// Parses a template literal (called on `template_start`) and desugars
    /// `` `head ${a} tail` `` to `format("head {} tail", a)`. Interpolation
    /// reuses the existing `format()` machinery, so supported value types
    /// are exactly `format()`'s (strings, ints, floats, bools). A template
    /// without interpolation degrades to a plain string literal.
    fn parseTemplateLiteral(self: *Parser) ParserError!*ast.Node {
        try self.expect(.template_start);
        var fmt_parts = std.array_list.Managed(u8).init(self.allocator);
        var args = std.array_list.Managed(*ast.Node).init(self.allocator);
        while (true) {
            if (self.peek() == .template_string) {
                const tok = self.tok;
                self.advance();
                try appendTemplateChunk(&fmt_parts, self.lexeme(tok.loc));
            } else if (self.peek() == .template_interp) {
                self.advance();
                const arg = try self.parseExpr(0);
                try self.expect(.r_brace);
                fmt_parts.appendSlice("{}") catch return ParserError.OutOfMemory;
                args.append(arg) catch return ParserError.OutOfMemory;
            } else if (self.peek() == .template_end) {
                self.advance();
                break;
            } else {
                return ParserError.UnexpectedToken;
            }
        }
        const fmt_text = fmt_parts.toOwnedSlice() catch return ParserError.OutOfMemory;
        const fmt_node = try self.allocator.create(ast.Node);
        fmt_node.* = .{ .literal = .{ .string_val = fmt_text } };
        if (args.items.len == 0) return fmt_node;
        const call_args = try self.allocator.alloc(*ast.Node, args.items.len + 1);
        call_args[0] = fmt_node;
        @memcpy(call_args[1..], args.items);
        const generics = try self.allocator.alloc(*ast.Type, 0);
        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .call_expr = .{
                .func_name = "format",
                .associated_target = null,
                .generics = generics,
                .args = call_args,
            },
        };
        return node;
    }

    fn parseIfExpr(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_if);
        var let_chain: ?[]const ast.IfLetCond = null;
        const cond = if (self.peek() == .keyword_let) blk: {
            const parsed_chain = try self.parseIfLetChain();
            let_chain = parsed_chain;
            break :blk parsed_chain[0].value;
        } else try self.parseExpr(0);
        const then_block = try self.parseBlock();
        var else_block: ?[]const *ast.Node = null;
        if (self.match(.keyword_else)) {
            if (self.peek() == .keyword_if) {
                const nested_if = try self.parseIfExpr();
                // Normalize `else if` to the same AST shape as an explicit
                // `else { if ...; }` block: a block of statements whose tail is
                // an expr_stmt-wrapped expression. A bare nested if_expr
                // statement is not understood by the statement-level walkers
                // in the type checker or either emitter.
                const nested_stmt = try self.allocator.create(ast.Node);
                nested_stmt.* = .{ .expr_stmt = nested_if };
                const slice = try self.allocator.alloc(*ast.Node, 1);
                slice[0] = nested_stmt;
                else_block = slice;
            } else {
                else_block = try self.parseBlock();
            }
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .if_expr = .{
                .cond = cond,
                .let_chain = let_chain,
                .then_block = then_block,
                .else_block = else_block,
            },
        };
        return node;
    }

    fn parseSwitchExpr(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_switch);
        const val = try self.parseExpr(0);
        try self.expect(.l_brace);

        var cases = std.array_list.Managed(ast.Case).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const pattern = try self.parseExpr(0);
            try self.expect(.fat_arrow);

            var body: []const *ast.Node = undefined;
            if (self.peek() == .l_brace) {
                body = try self.parseBlock();
            } else {
                const single = try self.parseStmt();
                const slice = try self.allocator.alloc(*ast.Node, 1);
                slice[0] = single;
                body = slice;
            }

            try cases.append(.{ .pattern = pattern, .body = body });
            if (self.peek() == .comma) self.advance();
        }

        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .switch_expr = .{
                .val = val,
                .cases = try cases.toOwnedSlice(),
            },
        };
        return node;
    }

    fn parseTypeAtom(self: *Parser) ParserError!*ast.Type {
        const tag = self.peek();
        const tok = self.tok;
        self.advance();

        const makePrimitive = struct {
            fn apply(allocator: std.mem.Allocator, primitive: ast.Primitive) ParserError!*ast.Type {
                const ty = allocator.create(ast.Type) catch return ParserError.OutOfMemory;
                ty.* = .{ .primitive = primitive };
                return ty;
            }
        }.apply;

        switch (tag) {
            .identifier => {
                const name = self.lexeme(tok.loc);
                if (std.mem.eql(u8, name, "Self")) {
                    return self.current_impl_target orelse return ParserError.UnexpectedTypeToken;
                } else if (std.mem.eql(u8, name, "int")) {
                    return try makePrimitive(self.allocator, .i64);
                } else if (std.mem.eql(u8, name, "float")) {
                    return try makePrimitive(self.allocator, .f64);
                } else if (std.mem.eql(u8, name, "bool")) {
                    return try makePrimitive(self.allocator, .boolean);
                } else if (std.mem.eql(u8, name, "void")) {
                    return try makePrimitive(self.allocator, .void_type);
                } else if (std.mem.eql(u8, name, "ptr")) {
                    return try makePrimitive(self.allocator, .raw_ptr);
                } else if (std.mem.eql(u8, name, "i8")) {
                    return try makePrimitive(self.allocator, .i8);
                } else if (std.mem.eql(u8, name, "i16")) {
                    return try makePrimitive(self.allocator, .i16);
                } else if (std.mem.eql(u8, name, "i32")) {
                    return try makePrimitive(self.allocator, .i32);
                } else if (std.mem.eql(u8, name, "i64")) {
                    return try makePrimitive(self.allocator, .i64);
                } else if (std.mem.eql(u8, name, "isize")) {
                    return try makePrimitive(self.allocator, .isize);
                } else if (std.mem.eql(u8, name, "u8")) {
                    return try makePrimitive(self.allocator, .u8);
                } else if (std.mem.eql(u8, name, "u16")) {
                    return try makePrimitive(self.allocator, .u16);
                } else if (std.mem.eql(u8, name, "u32")) {
                    return try makePrimitive(self.allocator, .u32);
                } else if (std.mem.eql(u8, name, "u64")) {
                    return try makePrimitive(self.allocator, .u64);
                } else if (std.mem.eql(u8, name, "usize")) {
                    return try makePrimitive(self.allocator, .usize);
                } else if (std.mem.eql(u8, name, "f32")) {
                    return try makePrimitive(self.allocator, .f32);
                } else if (std.mem.eql(u8, name, "f64")) {
                    return try makePrimitive(self.allocator, .f64);
                }

                var generics = std.array_list.Managed(*ast.Type).init(self.allocator);
                if (self.match(.less_than)) {
                    while (true) {
                        const t = try self.parseType();
                        try generics.append(t);
                        if (!self.match(.comma)) break;
                    }
                    try self.expectGenericClose();
                }

                if (std.mem.eql(u8, name, "future")) {
                    if (generics.items.len != 1) return ParserError.UnexpectedTypeToken;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .future = generics.items[0] };
                    return ty;
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{
                    .user_defined = .{
                        .name = name,
                        .generics = try generics.toOwnedSlice(),
                    },
                };
                return ty;
            },
            .keyword_dyn => {
                const trait_tok = self.tok;
                try self.expect(.identifier);
                const trait_name = self.lexeme(trait_tok.loc);
                return try self.makeUserDefinedType(
                    try std.fmt.allocPrint(self.allocator, "__dyn_{s}", .{trait_name}),
                    &.{},
                );
            },
            .keyword_extern => {
                const abi = try self.parseOptionalExternAbi();
                try self.expect(.keyword_fn);
                return try self.parseFunctionType(abi);
            },
            .keyword_fn => {
                return try self.parseFunctionType(null);
            },
            .ampersand => {
                const inner = try self.parseType();
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .borrow = inner };
                return ty;
            },
            .asterisk => {
                const inner = try self.parseType();
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .pointer = inner };
                return ty;
            },
            .l_bracket => {
                const elem = try self.parseType();
                if (self.match(.semicolon)) {
                    const len_tok = self.tok;
                    try self.expect(.int_literal);
                    const len_str = self.lexeme(len_tok.loc);
                    // #11: drop `_` separators in fixed array length.
                    const len_clean = try stripNumericSeparators(self.allocator, len_str);
                    const len = std.fmt.parseInt(usize, len_clean, 10) catch return ParserError.InvalidCharacter;
                    try self.expect(.r_bracket);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .array = .{ .elem = elem, .len = len } };
                    return ty;
                }
                try self.expect(.r_bracket);
                const generics = try self.allocator.alloc(*ast.Type, 1);
                generics[0] = elem;
                return try self.makeUserDefinedType("Slice", generics);
            },
            .l_paren => {
                const first = try self.parseType();
                if (self.match(.comma)) {
                    var elems = std.array_list.Managed(*ast.Type).init(self.allocator);
                    try elems.append(first);
                    while (self.peek() != .r_paren and self.peek() != .eof) {
                        const elem = try self.parseType();
                        try elems.append(elem);
                        if (!self.match(.comma)) break;
                    }
                    try self.expect(.r_paren);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .tuple = .{ .elems = try elems.toOwnedSlice() } };
                    return ty;
                }
                try self.expect(.r_paren);
                return first;
            },
            else => return ParserError.UnexpectedTypeToken,
        }
    }

    fn parseType(self: *Parser) ParserError!*ast.Type {
        return try self.parseTypeAtom();
    }

    fn parseFunctionType(self: *Parser, abi: ?[]const u8) ParserError!*ast.Type {
        try self.expect(.l_paren);
        var params = std.array_list.Managed(*ast.Type).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const param_ty = try self.parseType();
            try params.append(param_ty);
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_paren);

        var ret_ty = try self.allocator.create(ast.Type);
        ret_ty.* = .{ .primitive = .void_type };
        if (self.match(.arrow)) {
            ret_ty = try self.parseType();
        }

        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .fn_ptr = .{ .abi = abi, .params = try params.toOwnedSlice(), .ret = ret_ty } };
        return ty;
    }
};

test "parse immediately-invoked closure literal callee" {
    const source =
        \\fn main() -> i32 {
        \\    let v = (|x: int| x * 2)(21);
        \\    return v;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, source);
    const prog = try p.parseProgram();

    const d1 = prog.program.decls[0];
    const s1 = d1.func_decl.body[0];
    try std.testing.expect(s1.* == .let_stmt);
    try std.testing.expect(s1.let_stmt.value.* == .call_expr);
    const call = s1.let_stmt.value.call_expr;
    try std.testing.expect(call.callee != null);
    try std.testing.expect(call.callee.?.* == .closure_literal);
}

test "parse numeric separators" {
    const source =
        \\fn main() -> i32 {
        \\    let a = 1_000;
        \\    let b = 0xFF_FF;
        \\    let c = 7_000.5;
        \\    return a;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, source);
    const prog = try p.parseProgram();

    const d1 = prog.program.decls[0];
    const s1 = d1.func_decl.body[0];
    try std.testing.expect(s1.* == .let_stmt);
    try std.testing.expect(s1.let_stmt.value.* == .literal);
    try std.testing.expectEqual(@as(i64, 1000), s1.let_stmt.value.literal.int_val);
    const s2 = d1.func_decl.body[1];
    try std.testing.expect(s2.let_stmt.value.* == .literal);
    try std.testing.expectEqual(@as(i64, 65535), s2.let_stmt.value.literal.int_val);
    const s3 = d1.func_decl.body[2];
    try std.testing.expect(s3.let_stmt.value.* == .literal);
    try std.testing.expectEqual(@as(f64, 7000.5), s3.let_stmt.value.literal.float_val);
}

test "parse chain assignment desugar" {
    const source =
        \\fn main() -> i32 {
        \\    a = b = 5;
        \\    return a;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, source);
    const prog = try p.parseProgram();

    const d1 = prog.program.decls[0];
    const s1 = d1.func_decl.body[0];
    // `a = b = 5` desugars to `{ let __chainK = 5; b = __chainK; a = __chainK; }`.
    try std.testing.expect(s1.* == .block_stmt);
    try std.testing.expectEqual(@as(usize, 3), s1.block_stmt.body.len);
    try std.testing.expect(s1.block_stmt.body[0].* == .let_stmt);
    try std.testing.expect(s1.block_stmt.body[0].let_stmt.value.* == .literal);
    try std.testing.expect(s1.block_stmt.body[1].* == .assign_stmt);
    try std.testing.expect(s1.block_stmt.body[2].* == .assign_stmt);
}

test "parse struct and function" {
    const source =
        \\struct Option<T> {
        \\    has_value: bool,
        \\    value: T
        \\}
        \\
        \\fn sum_range(limit: i64) -> i64 {
        \\    let sum = 0;
        \\    for i in 1..limit {
        \\        sum = sum + i;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn try_demo() -> i64 {
        \\    let val = fetch();
        \\    return val;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, source);
    const prog = try p.parseProgram();

    try std.testing.expect(prog.* == .program);
    try std.testing.expectEqual(@as(usize, 3), prog.program.decls.len);

    const d1 = prog.program.decls[0];
    try std.testing.expect(d1.* == .struct_decl);
    try std.testing.expectEqualSlices(u8, "Option", d1.struct_decl.name);
    try std.testing.expectEqual(@as(usize, 1), d1.struct_decl.generics.len);
    try std.testing.expectEqualSlices(u8, "T", d1.struct_decl.generics[0]);
    try std.testing.expectEqual(@as(usize, 2), d1.struct_decl.fields.len);
    try std.testing.expectEqualSlices(u8, "has_value", d1.struct_decl.fields[0].name);

    const d2 = prog.program.decls[1];
    try std.testing.expect(d2.* == .func_decl);
    try std.testing.expectEqualSlices(u8, "sum_range", d2.func_decl.name);
    try std.testing.expectEqual(@as(usize, 1), d2.func_decl.params.len);
    try std.testing.expectEqualSlices(u8, "limit", d2.func_decl.params[0].name);
    try std.testing.expect(d2.func_decl.ret_ty.* == .primitive);
    try std.testing.expect(d2.func_decl.ret_ty.primitive == .i64);

    const d3 = prog.program.decls[2];
    try std.testing.expect(d3.* == .func_decl);
    try std.testing.expectEqualSlices(u8, "try_demo", d3.func_decl.name);
    try std.testing.expectEqual(@as(usize, 2), d3.func_decl.body.len);
    const s1 = d3.func_decl.body[0];
    try std.testing.expect(s1.* == .let_stmt);
    try std.testing.expectEqualSlices(u8, "val", s1.let_stmt.name);
    try std.testing.expect(s1.let_stmt.value.* == .call_expr);
    try std.testing.expectEqualSlices(u8, "fetch", s1.let_stmt.value.call_expr.func_name);
}

test "parse sla import basename as module namespace" {
    const source =
        \\@import "dep.sla"
        \\
        \\fn call_dep() -> i32 {
        \\    return dep::imported_a();
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, source);
    const prog = try p.parseProgram();

    try std.testing.expect(prog.* == .program);
    try std.testing.expectEqual(@as(usize, 2), prog.program.decls.len);
    try std.testing.expect(p.isKnownModuleName("dep"));

    const fn_decl = prog.program.decls[1];
    try std.testing.expect(fn_decl.* == .func_decl);
    try std.testing.expectEqual(@as(usize, 1), fn_decl.func_decl.body.len);
    const ret = fn_decl.func_decl.body[0];
    try std.testing.expect(ret.* == .return_stmt);
    const value = ret.return_stmt.value.?;
    try std.testing.expect(value.* == .call_expr);
    try std.testing.expectEqualSlices(u8, "dep__imported_a", value.call_expr.func_name);
}

test "parser accepts explicit u64 max literal suffix" {
    const source =
        \\fn max_literal() -> u64 {
        \\    let max: u64 = 18446744073709551615u64;
        \\    return max;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, source);
    const prog = try p.parseProgram();

    const fn_decl = prog.program.decls[0];
    try std.testing.expect(fn_decl.* == .func_decl);
    const let_stmt = fn_decl.func_decl.body[0];
    try std.testing.expect(let_stmt.* == .let_stmt);
    const value = let_stmt.let_stmt.value;
    try std.testing.expect(value.* == .cast_expr);
    try std.testing.expect(value.cast_expr.ty.* == .primitive);
    try std.testing.expectEqual(ast.Primitive.u64, value.cast_expr.ty.primitive);
    try std.testing.expect(value.cast_expr.expr.* == .literal);
    try std.testing.expectEqual(@as(i64, -1), value.cast_expr.expr.literal.int_val);
}

test "sla import type prescan skips imported function bodies" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.writeFile(.{
        .sub_path = "dep.sla",
        .data =
        \\struct ImportedThing {
        \\    value: i32,
        \\}
        \\
        \\fn invalid_imported_body() -> i32 {
        \\    let = ;
        \\}
        ,
    });

    try tdir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const source =
        \\@import "dep.sla"
        \\
        \\fn main() -> i32 {
        \\    let item = ImportedThing { value: 41 };
        \\    return item.value;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.initWithDir(allocator, source, ".");
    const prog = try p.parseProgram();

    try std.testing.expect(prog.* == .program);
    try std.testing.expect(p.isKnownTypeName("ImportedThing"));
}

test "sla import type prescan visits diamond dependencies once" {
    var original_cwd = try sio.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var tdir: sio.Dir = .{ .inner = tmp.dir };

    try tdir.writeFile(.{
        .sub_path = "common.sla",
        .data =
        \\struct SharedThing {
        \\    value: i32,
        \\}
        ,
    });
    try tdir.writeFile(.{
        .sub_path = "left.sla",
        .data =
        \\@import "common.sla"
        \\struct LeftThing { shared: SharedThing }
        ,
    });
    try tdir.writeFile(.{
        .sub_path = "right.sla",
        .data =
        \\@import "common.sla"
        \\struct RightThing { shared: SharedThing }
        ,
    });

    try tdir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const source =
        \\@import "left.sla"
        \\@import "right.sla"
        \\@import "left.sla"
        \\
        \\fn main() -> i32 {
        \\    let item = SharedThing { value: 42 };
        \\    return item.value;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.initWithDir(allocator, source, ".");
    const prog = try p.parseProgram();

    try std.testing.expect(prog.* == .program);
    try std.testing.expect(p.isKnownTypeName("SharedThing"));
    try std.testing.expect(p.isKnownTypeName("LeftThing"));
    try std.testing.expect(p.isKnownTypeName("RightThing"));
    try std.testing.expectEqual(@as(usize, 3), p.prescannedImportPathCount());
}

test "sla parser selectively parses named function bodies" {
    const source =
        \\fn used() -> i32 {
        \\    return 41;
        \\}
        \\
        \\fn unused_invalid() -> i32 {
        \\    let = ;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var selected = std.StringHashMap(void).init(allocator);
    try selected.put("used", {});
    var p = Parser.initWithDirAndOptions(allocator, source, ".", .{
        .function_body_names = &selected,
    });
    const prog = try p.parseProgram();

    try std.testing.expect(prog.* == .program);
    try std.testing.expectEqual(@as(usize, 2), prog.program.decls.len);
    try std.testing.expectEqual(@as(usize, 1), prog.program.decls[0].func_decl.body.len);
    try std.testing.expectEqual(@as(usize, 0), prog.program.decls[1].func_decl.body.len);
}

test "sla parser records exact skipped function body spans" {
    const source =
        \\fn first() -> i32 {
        \\    return 1;
        \\}
        \\
        \\impl Holder {
        \\    fn second(self) -> i32 {
        \\        return 2;
        \\    }
        \\}
        \\
        \\fn invalid_body() -> i32 {
        \\    let = ;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.initWithDirAndOptions(allocator, source, ".", .{
        .parse_function_bodies = false,
        .parse_macro_bodies = false,
        .parse_test_bodies = false,
    });
    const prog = try p.parseProgram();
    try std.testing.expect(prog.* == .program);

    const first = prog.program.decls[0];
    const first_span = p.functionBodySpanFor(first) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        \\{
        \\    return 1;
        \\}
    , first_span);

    const impl_decl = prog.program.decls[1];
    try std.testing.expect(impl_decl.* == .impl_decl);
    const second = impl_decl.impl_decl.methods[0];
    const second_span = p.functionBodySpanFor(second) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        \\{
        \\        return 2;
        \\    }
    , second_span);

    const body = try Parser.parseFunctionBodySpan(allocator, first_span, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), body.len);
    try std.testing.expect(body[0].* == .return_stmt);
}

test "sla parser selectively parses named macro bodies" {
    const source =
        \\macro used(value) {
        \\    return value;
        \\}
        \\
        \\macro unused_invalid(value) {
        \\    let = ;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var selected = std.StringHashMap(void).init(allocator);
    try selected.put("used", {});
    var p = Parser.initWithDirAndOptions(allocator, source, ".", .{
        .macro_body_names = &selected,
    });
    const prog = try p.parseProgram();

    try std.testing.expect(prog.* == .program);
    try std.testing.expectEqual(@as(usize, 2), prog.program.decls.len);
    try std.testing.expectEqual(@as(usize, 1), prog.program.decls[0].macro_decl.body.len);
    try std.testing.expectEqual(@as(usize, 0), prog.program.decls[1].macro_decl.body.len);
}

test "sla parser distinguishes postfix try from ternary" {
    const source =
        \\struct LocalResult {
        \\    is_err: bool,
        \\    value: i64,
        \\    error: i64,
        \\}
        \\
        \\fn propagate(result: LocalResult) -> i64 {
        \\    let value = result?;
        \\    return value;
        \\}
        \\
        \\fn choose(flag: bool) -> i64 {
        \\    return flag ? 1 : 2;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const prog = try parser.parseProgram();

    const propagate = prog.program.decls[1].func_decl;
    try std.testing.expect(propagate.body[0].* == .let_stmt);
    try std.testing.expect(propagate.body[0].let_stmt.value.* == .try_expr);

    const choose = prog.program.decls[2].func_decl;
    try std.testing.expect(choose.body[0].* == .return_stmt);
    try std.testing.expect(choose.body[0].return_stmt.value.?.* == .if_expr);
}

test "sla ternary binds looser than ==" {
    const source =
        \\fn compare(a: i64, b: i64) -> i64 {
        \\    return a == b ? 1 : 2;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const prog = try parser.parseProgram();

    const compare = prog.program.decls[0].func_decl;
    try std.testing.expect(compare.body[0].* == .return_stmt);
    const ife = &compare.body[0].return_stmt.value.?.if_expr;
    // The whole comparison must be the condition, not just `b`.
    try std.testing.expect(ife.cond.* == .binary_expr);
    try std.testing.expect(ife.cond.binary_expr.op == .eq);
}

test "sla null coalescing desugars to unwrap_or call" {
    const source =
        \\fn coalesce(a: i64) -> i64 {
        \\    return a ?? 9;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const prog = try parser.parseProgram();

    const coalesce = prog.program.decls[0].func_decl;
    try std.testing.expect(coalesce.body[0].* == .return_stmt);
    const call = coalesce.body[0].return_stmt.value.?.call_expr;
    try std.testing.expect(std.mem.eql(u8, call.func_name, "unwrap_or"));
    try std.testing.expect(call.args.len == 2);
}

test "sla postfix bang desugars to unwrap call" {
    const source =
        \\fn force(a: i64) -> i64 {
        \\    return a!;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const prog = try parser.parseProgram();

    const force = prog.program.decls[0].func_decl;
    try std.testing.expect(force.body[0].* == .return_stmt);
    const call = force.body[0].return_stmt.value.?.call_expr;
    try std.testing.expect(std.mem.eql(u8, call.func_name, "unwrap"));
    try std.testing.expect(call.args.len == 1);
}

test "sla optional chain desugars to if-let-Some" {    const source =
        \\fn pick(o: i64) -> i64 {
        \\    return o?.field;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const prog = try parser.parseProgram();

    const pick = prog.program.decls[0].func_decl;
    try std.testing.expect(pick.body[0].* == .return_stmt);
    const ife = &pick.body[0].return_stmt.value.?.if_expr;
    try std.testing.expect(ife.let_chain != null);
    try std.testing.expect(ife.let_chain.?[0].pattern.variant_name[0] == 'S');
    try std.testing.expect(ife.else_block != null);
}

test "sla optional call desugars to if-let-Some with call" {    const source =
        \\fn invoke(o: i64) -> i64 {
        \\    return o?.method(1, 2);
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const prog = try parser.parseProgram();

    const invoke = prog.program.decls[0].func_decl;
    try std.testing.expect(invoke.body[0].* == .return_stmt);
    const ife = &invoke.body[0].return_stmt.value.?.if_expr;
    try std.testing.expect(ife.let_chain != null);
    const then_call = ife.then_block[0].expr_stmt.call_expr;
    try std.testing.expect(std.mem.eql(u8, then_call.func_name, "Some"));
    const inner = then_call.args[0].call_expr;
    try std.testing.expect(std.mem.eql(u8, inner.func_name, "method"));
    try std.testing.expect(inner.args.len == 3);
}

test "syntax diagnostic includes location token and context" {
    const source =
        \\fn ok() -> i32 {
        \\    return 1;
        \\}
        \\}
        \\fn later() -> i32 {
        \\    return 2;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, source);
    try std.testing.expectError(ParserError.ExpectedDeclaration, p.parseProgram());

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try p.printDiagnostic(sio.managedWriter(&out), "bad.sla", ParserError.ExpectedDeclaration);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Syntax Error: failed to parse bad.sla:4:1: error.ExpectedDeclaration") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "4 | }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "^ found '}', expected function, struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "unexpected closing brace at top level") != null);
}

test "parser rejects legacy let mut" {
    const source =
        \\fn main() {
        \\    let mut value = 1;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), source);
    try std.testing.expectError(ParserError.UnexpectedToken, p.parseProgram());
}

test "sla template literal desugars to format call" {
    const source =
        \\fn greet(name: i64) -> i64 {
        \\    return `hi ${name}!`;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const prog = try parser.parseProgram();

    const greet = prog.program.decls[0].func_decl;
    try std.testing.expect(greet.body[0].* == .return_stmt);
    const call = greet.body[0].return_stmt.value.?.call_expr;
    try std.testing.expect(std.mem.eql(u8, call.func_name, "format"));
    try std.testing.expect(call.args.len == 2);
    try std.testing.expect(call.args[0].* == .literal);
}

test "sla plain template degrades to string literal" {    const source =
        \\fn plain() -> i64 {
        \\    return `just text`;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const prog = try parser.parseProgram();

    const plain = prog.program.decls[0].func_decl;
    try std.testing.expect(plain.body[0].* == .return_stmt);
    try std.testing.expect(plain.body[0].return_stmt.value.?.* == .literal);
}

test "sla enum accepts explicit discriminants" {
    const source =
        \\enum Code {
        \\    Ok,
        \\    NotFound = 5,
        \\    Denied,
        \\    Custom = -2,
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const prog = try parser.parseProgram();

    try std.testing.expect(prog.program.decls[0].* == .enum_decl);
    const variants = prog.program.decls[0].enum_decl.variants;
    try std.testing.expectEqual(@as(usize, 4), variants.len);
    try std.testing.expect(variants[0].discriminant == null);
    try std.testing.expectEqual(@as(i64, 5), variants[1].discriminant.?);
    try std.testing.expect(variants[2].discriminant == null);
    try std.testing.expectEqual(@as(i64, -2), variants[3].discriminant.?);
}

test "sla enum rejects duplicate effective discriminants" {
    const source =
        \\enum Dup {
        \\    A,
        \\    B = 0,
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    try std.testing.expectError(ParserError.UnexpectedToken, parser.parseProgram());
}

test "sla enum rejects explicit value on payload variant" {
    const source =
        \\enum Bad {
        \\    Pair = 3 { x: i32 },
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    try std.testing.expectError(ParserError.UnexpectedToken, parser.parseProgram());
}

test "sla nullish assign desugars to assign unwrap_or" {
    const source =
        \\fn fill(slot: i64) -> i64 {
        \\    let present = slot;
        \\    present ??= 9;
        \\    return present;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const prog = try parser.parseProgram();

    const fill = prog.program.decls[0].func_decl;
    try std.testing.expect(fill.body[1].* == .assign_stmt);
    const some_call = fill.body[1].assign_stmt.value.call_expr;
    try std.testing.expect(std.mem.eql(u8, some_call.func_name, "Some"));
    try std.testing.expect(some_call.args.len == 1);
    const fallback = some_call.args[0].call_expr;
    try std.testing.expect(std.mem.eql(u8, fallback.func_name, "unwrap_or"));
    try std.testing.expect(fallback.args.len == 2);
}
