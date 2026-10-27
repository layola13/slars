// slars_frontend.zig — the ONLY new frontend module of the slars plugin.
//
// slars shares SLA's parser/checker/lowering/codegen through a symlink farm
// (every other src/*.zig is a relative symlink into ../../sa_plugin_sla/src).
// This module is the slars surface layer, in two parts:
//
//   1. transformSource: a token-level rewrite of Rust surface syntax that
//      SLA does not accept (let mut, `!` macro calls, #[attributes],
//      lifetimes, `loop`, char literals, `..=`, `use`, block comments)
//      into the SLA surface the shared parser accepts. It runs inside the
//      shared Parser's init (slars-owned parser.zig hook), so it applies
//      to the root file and to every imported module alike. It is a no-op
//      on plain SLA sources: every rewrite targets a token pattern that
//      valid SLA code cannot contain.
//
//   2. checkSource: root-file validation + the slars strict checker
//      (SLARS-IMMUTABLE-ASSIGN, SLARS-BORROW-CONFLICT,
//      SLARS-BORROW-IMMUTABLE) plus loud rejections (macro definitions,
//      `static`, raw strings, non-whitelist macros, unsupported derives /
//      attributes, format specifiers, non-prelude `use`). It runs in
//      plugin_compile's runSlaFrontend for `.slars` roots only.
//
// Borrow liveness is lexical-conservative (no NLL): a borrow lives until
// the end of the block that declares its holder binding.

const std = @import("std");

// ---------------------------------------------------------------- tokens

pub const TokKind = enum { ident, number, string_lit, char_lit, lifetime, raw_string, punct };

pub const Tok = struct {
    kind: TokKind,
    start: usize,
    end: usize,
    pre_start: usize,
    line: usize,
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn tokText(source: []const u8, t: Tok) []const u8 {
    return source[t.start..t.end];
}

fn textEq(source: []const u8, t: Tok, s: []const u8) bool {
    return std.mem.eql(u8, tokText(source, t), s);
}

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) ![]Tok {
    var toks = std.array_list.Managed(Tok).init(allocator);
    const n = source.len;
    var i: usize = 0;
    var line: usize = 1;
    while (true) {
        const pre_start = i;
        // Consume whitespace and comments into the prefix region.
        while (i < n) {
            const c = source[i];
            if (c == '\n') {
                line += 1;
                i += 1;
            } else if (c == ' ' or c == '\t' or c == '\r') {
                i += 1;
            } else if (c == '/' and i + 1 < n and source[i + 1] == '/') {
                while (i < n and source[i] != '\n') i += 1;
            } else if (c == '/' and i + 1 < n and source[i + 1] == '*') {
                var depth: usize = 1;
                i += 2;
                while (i < n and depth > 0) {
                    if (source[i] == '\n') line += 1;
                    if (source[i] == '/' and i + 1 < n and source[i + 1] == '*') {
                        depth += 1;
                        i += 2;
                    } else if (source[i] == '*' and i + 1 < n and source[i + 1] == '/') {
                        depth -= 1;
                        i += 2;
                    } else {
                        i += 1;
                    }
                }
            } else break;
        }
        if (i >= n) break;
        const start = i;
        const tok_line = line;
        const c = source[i];
        if (isIdentStart(c)) {
            // Raw string: r"...", r#"..."#, r##"..."##
            if (c == 'r' and i + 1 < n and (source[i + 1] == '"' or source[i + 1] == '#')) {
                var j = i + 1;
                var hashes: usize = 0;
                while (j < n and source[j] == '#') {
                    hashes += 1;
                    j += 1;
                }
                if (j < n and source[j] == '"') {
                    j += 1;
                    while (j < n) {
                        if (source[j] == '"') {
                            var k = j + 1;
                            var h: usize = 0;
                            while (k < n and source[k] == '#' and h < hashes) {
                                h += 1;
                                k += 1;
                            }
                            if (h == hashes) {
                                j = k;
                                break;
                            }
                        }
                        if (source[j] == '\n') line += 1;
                        j += 1;
                    }
                    try toks.append(.{ .kind = .raw_string, .start = start, .end = j, .pre_start = pre_start, .line = tok_line });
                    i = j;
                    continue;
                }
            }
            while (i < n and isIdentChar(source[i])) i += 1;
            try toks.append(.{ .kind = .ident, .start = start, .end = i, .pre_start = pre_start, .line = tok_line });
            continue;
        }
        if (isDigit(c)) {
            i += 1;
            while (i < n and (isDigit(source[i]) or source[i] == '_')) i += 1;
            if (i + 1 < n and source[i] == '.' and isDigit(source[i + 1])) {
                i += 1;
                while (i < n and (isDigit(source[i]) or source[i] == '_')) i += 1;
            }
            if (i < n and (source[i] == 'e' or source[i] == 'E')) {
                var j = i + 1;
                if (j < n and (source[j] == '+' or source[j] == '-')) j += 1;
                if (j < n and isDigit(source[j])) {
                    i = j;
                    while (i < n and (isDigit(source[i]) or source[i] == '_')) i += 1;
                }
            }
            while (i < n and isIdentChar(source[i])) i += 1; // suffix: i32, u64, f64, usize...
            try toks.append(.{ .kind = .number, .start = start, .end = i, .pre_start = pre_start, .line = tok_line });
            continue;
        }
        if (c == '"') {
            i += 1;
            while (i < n and source[i] != '"') {
                if (source[i] == '\\') {
                    i += 1;
                    if (i < n) i += 1;
                } else {
                    if (source[i] == '\n') line += 1;
                    i += 1;
                }
            }
            if (i < n) i += 1;
            try toks.append(.{ .kind = .string_lit, .start = start, .end = i, .pre_start = pre_start, .line = tok_line });
            continue;
        }
        if (c == '\'') {
            // Char literal: '<one codepoint>' or '\<escape>' (incl. \u{...}).
            var is_char = false;
            var char_end: usize = 0;
            if (i + 1 < n and source[i + 1] == '\\') {
                var j = i + 2;
                if (j < n and source[j] == 'u') {
                    j += 1;
                    if (j < n and source[j] == '{') {
                        while (j < n and source[j] != '}') j += 1;
                        if (j < n) j += 1;
                    }
                } else if (j < n) {
                    j += 1;
                }
                if (j < n and source[j] == '\'') {
                    is_char = true;
                    char_end = j + 1;
                }
            } else if (i + 1 < n) {
                const lead = source[i + 1];
                const ulen: usize = if (lead < 0x80) 1 else if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else if (lead & 0xF8 == 0xF0) 4 else 1;
                const j = i + 1 + ulen;
                if (j < n and source[j] == '\'') {
                    is_char = true;
                    char_end = j + 1;
                }
            }
            if (is_char) {
                try toks.append(.{ .kind = .char_lit, .start = start, .end = char_end, .pre_start = pre_start, .line = tok_line });
                i = char_end;
                continue;
            }
            // Lifetime: 'ident or '_
            i += 1;
            while (i < n and isIdentChar(source[i])) i += 1;
            try toks.append(.{ .kind = .lifetime, .start = start, .end = i, .pre_start = pre_start, .line = tok_line });
            continue;
        }
        // Punctuation, longest first.
        const rest = source[i..];
        const multi = [_][]const u8{ "..=", "...", "..", "=>", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "+=", "-=", "*=", "/=", "%=", "->", "::", "?." };
        var matched: usize = 1;
        for (multi) |m| {
            if (std.mem.startsWith(u8, rest, m)) {
                matched = m.len;
                break;
            }
        }
        i += matched;
        try toks.append(.{ .kind = .punct, .start = start, .end = i, .pre_start = pre_start, .line = tok_line });
    }
    return toks.toOwnedSlice();
}

// ------------------------------------------------------------ token utils

fn findMatch(toks: []const Tok, source: []const u8, open_idx: usize, open: []const u8, close: []const u8) ?usize {
    var depth: usize = 0;
    var i = open_idx;
    while (i < toks.len) : (i += 1) {
        const s = tokText(source, toks[i]);
        if (toks[i].kind == .punct and std.mem.eql(u8, s, open)) {
            depth += 1;
        } else if (toks[i].kind == .punct and std.mem.eql(u8, s, close)) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findAngleMatch(toks: []const Tok, source: []const u8, open_idx: usize) ?usize {
    var depth: i64 = 0;
    var i = open_idx;
    while (i < toks.len) : (i += 1) {
        if (toks[i].kind != .punct) continue;
        const s = tokText(source, toks[i]);
        if (std.mem.eql(u8, s, "<")) depth += 1;
        if (std.mem.eql(u8, s, "<<")) depth += 2;
        if (std.mem.eql(u8, s, ">")) depth -= 1;
        if (std.mem.eql(u8, s, ">>")) depth -= 2;
        if (depth == 0) return i;
        if (depth < 0) return null;
    }
    return null;
}

const ArgRange = struct { lo: usize, hi: usize }; // token index range [lo, hi)

fn splitArgs(allocator: std.mem.Allocator, toks: []const Tok, source: []const u8, open_idx: usize, close_idx: usize) ![]ArgRange {
    var args = std.array_list.Managed(ArgRange).init(allocator);
    var depth: i64 = 0;
    var seg_start = open_idx + 1;
    var i = open_idx + 1;
    if (close_idx == open_idx + 1) return args.toOwnedSlice();
    while (i < close_idx) : (i += 1) {
        if (toks[i].kind != .punct) continue;
        const s = tokText(source, toks[i]);
        if (std.mem.eql(u8, s, "(") or std.mem.eql(u8, s, "[") or std.mem.eql(u8, s, "{")) depth += 1;
        if (std.mem.eql(u8, s, ")") or std.mem.eql(u8, s, "]") or std.mem.eql(u8, s, "}")) depth -= 1;
        if (depth == 0 and std.mem.eql(u8, s, ",")) {
            try args.append(.{ .lo = seg_start, .hi = i });
            seg_start = i + 1;
        }
    }
    if (seg_start < close_idx) try args.append(.{ .lo = seg_start, .hi = close_idx });
    return args.toOwnedSlice();
}

fn rangeText(allocator: std.mem.Allocator, source: []const u8, toks: []const Tok, lo: usize, hi: usize) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var k = lo;
    var first = true;
    while (k < hi) : (k += 1) {
        if (!first) {
            // Preserve intra-range spacing coarsely: single space between tokens.
            try out.appendSlice(" ");
        }
        first = false;
        try out.appendSlice(tokText(source, toks[k]));
    }
    return out.toOwnedSlice();
}

fn appendPrefixNorm(out: *std.array_list.Managed(u8), source: []const u8, from: usize, to: usize) !void {
    var i = from;
    while (i < to) {
        if (source[i] == '/' and i + 1 < to and source[i + 1] == '*') {
            var depth: usize = 1;
            i += 2;
            try out.appendSlice("  ");
            while (i < to and depth > 0) {
                if (source[i] == '/' and i + 1 < to and source[i + 1] == '*') {
                    depth += 1;
                    i += 2;
                    try out.appendSlice("  ");
                } else if (source[i] == '*' and i + 1 < to and source[i + 1] == '/') {
                    depth -= 1;
                    i += 2;
                    try out.appendSlice("  ");
                } else {
                    try out.append(if (source[i] == '\n') '\n' else ' ');
                    i += 1;
                }
            }
        } else {
            try out.append(source[i]);
            i += 1;
        }
    }
}

fn countNewlines(source: []const u8, toks: []const Tok, lo: usize, hi: usize) usize {
    var count: usize = 0;
    var k = lo;
    while (k < hi) : (k += 1) {
        for (source[toks[k].pre_start..toks[k].end]) |ch| {
            if (ch == '\n') count += 1;
        }
    }
    return count;
}

fn charCodepoint(source: []const u8, t: Tok) u32 {
    const inner = source[t.start + 1 .. t.end - 1];
    if (inner.len == 0) return 0;
    if (inner[0] == '\\' and inner.len >= 2) {
        switch (inner[1]) {
            'n' => return '\n',
            't' => return '\t',
            'r' => return '\r',
            '0' => return 0,
            '\\' => return '\\',
            '\'' => return '\'',
            '"' => return '"',
            'u' => {
                // \u{XXXX}
                var v: u32 = 0;
                for (inner) |ch| {
                    if (std.ascii.isHex(ch)) {
                        v = v * 16 + (std.fmt.charToDigit(ch, 16) catch 0);
                    }
                }
                return v;
            },
            else => return inner[1],
        }
    }
    const dec = std.unicode.utf8Decode(inner) catch return inner[0];
    return dec;
}

fn rawStringContent(source: []const u8, t: Tok) []const u8 {
    const s = tokText(source, t);
    const first = std.mem.indexOfScalar(u8, s, '"') orelse return "";
    const last = std.mem.lastIndexOfScalar(u8, s, '"') orelse return "";
    if (last <= first) return "";
    return s[first + 1 .. last];
}

// ---------------------------------------------------------------- cfg eval

const CfgParser = struct {
    toks: []const Tok,
    source: []const u8,
    pos: usize,
    hi: usize,
    cfg_test: bool,

    fn peek(self: *const CfgParser) ?[]const u8 {
        if (self.pos >= self.hi) return null;
        return tokText(self.source, self.toks[self.pos]);
    }
    fn next(self: *CfgParser) ?[]const u8 {
        const s = self.peek() orelse return null;
        self.pos += 1;
        return s;
    }
    fn parseExpr(self: *CfgParser) bool {
        const head = self.next() orelse return false;
        if (std.mem.eql(u8, head, "not")) {
            if (self.peek()) |p| {
                if (std.mem.eql(u8, p, "(")) {
                    self.pos += 1;
                    const v = self.parseExpr();
                    if (self.peek()) |q| {
                        if (std.mem.eql(u8, q, ")")) self.pos += 1;
                    }
                    return !v;
                }
            }
            return true;
        }
        if (std.mem.eql(u8, head, "all") or std.mem.eql(u8, head, "any")) {
            const is_all = std.mem.eql(u8, head, "all");
            if (self.peek()) |p| {
                if (std.mem.eql(u8, p, "(")) self.pos += 1;
            }
            var acc = is_all;
            while (self.pos < self.hi) {
                if (self.peek()) |p| {
                    if (std.mem.eql(u8, p, ")")) {
                        self.pos += 1;
                        break;
                    }
                    if (std.mem.eql(u8, p, ",")) {
                        self.pos += 1;
                        continue;
                    }
                }
                const v = self.parseExpr();
                if (is_all) {
                    acc = acc and v;
                } else {
                    acc = acc or v;
                }
            }
            return acc;
        }
        // key = "value" or bare flag
        if (self.peek()) |p| {
            if (std.mem.eql(u8, p, "=")) {
                self.pos += 1;
                const val_tok = self.next() orelse return false;
                const val = stripQuotes(val_tok);
                return cfgKeyValue(head, val);
            }
        }
        return cfgBareFlag(head, self.cfg_test);
    }
};

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn cfgKeyValue(key: []const u8, val: []const u8) bool {
    if (std.mem.eql(u8, key, "target_os")) return std.mem.eql(u8, val, "linux");
    if (std.mem.eql(u8, key, "target_family")) return std.mem.eql(u8, val, "unix");
    if (std.mem.eql(u8, key, "target_endian")) return std.mem.eql(u8, val, "little");
    if (std.mem.eql(u8, key, "target_pointer_width")) return std.mem.eql(u8, val, "64");
    if (std.mem.eql(u8, key, "target_arch")) return std.mem.eql(u8, val, "x86_64");
    return false;
}

fn cfgBareFlag(key: []const u8, cfg_test: bool) bool {
    if (std.mem.eql(u8, key, "unix")) return true;
    if (std.mem.eql(u8, key, "test")) return cfg_test;
    return false;
}

fn evalCfg(toks: []const Tok, source: []const u8, lo: usize, hi: usize, cfg_test: bool) bool {
    var p = CfgParser{ .toks = toks, .source = source, .pos = lo, .hi = hi, .cfg_test = cfg_test };
    if (lo >= hi) return true;
    return p.parseExpr();
}

// ------------------------------------------------------------- derive map

fn deriveMapped(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "Debug")) return "debug";
    if (std.mem.eql(u8, name, "Copy")) return "copy";
    if (std.mem.eql(u8, name, "PartialEq")) return "eq";
    if (std.mem.eql(u8, name, "Eq")) return "eq";
    if (std.mem.eql(u8, name, "PartialOrd")) return "ord";
    if (std.mem.eql(u8, name, "Ord")) return "ord";
    if (std.mem.eql(u8, name, "Hash")) return "hash";
    return null;
}

fn isErasableAttr(name: []const u8) bool {
    const list = [_][]const u8{ "inline", "doc", "allow", "deny", "warn", "forbid", "must_use", "deprecated", "non_exhaustive", "cold", "track_caller" };
    for (list) |a| {
        if (std.mem.eql(u8, name, a)) return true;
    }
    return false;
}

fn skipItem(toks: []const Tok, source: []const u8, from: usize) usize {
    // Skip one item starting at token `from`; returns the index just past it.
    var i = from;
    var depth: i64 = 0;
    while (i < toks.len) : (i += 1) {
        if (toks[i].kind != .punct) continue;
        const s = tokText(source, toks[i]);
        if (std.mem.eql(u8, s, "(") or std.mem.eql(u8, s, "[")) depth += 1;
        if (std.mem.eql(u8, s, ")") or std.mem.eql(u8, s, "]")) depth -= 1;
        if (depth == 0 and std.mem.eql(u8, s, "{")) {
            const close = findMatch(toks, source, i, "{", "}") orelse return toks.len;
            var j = close + 1;
            if (j < toks.len and textEq(source, toks[j], ";")) j += 1;
            return j;
        }
        if (depth == 0 and (std.mem.eql(u8, s, ";") or std.mem.eql(u8, s, ","))) return i + 1;
    }
    return i;
}

// --------------------------------------------------------------- transform

const MacroAction = enum { none, println_like, vec, assert_macro, assert_cmp, panic_call, stringify, concat, cfg_macro, todo_like, reject };

fn macroAction(name: []const u8) MacroAction {
    if (std.mem.eql(u8, name, "println") or std.mem.eql(u8, name, "format")) return .println_like;
    if (std.mem.eql(u8, name, "vec")) return .vec;
    if (std.mem.eql(u8, name, "assert")) return .assert_macro;
    if (std.mem.eql(u8, name, "assert_eq") or std.mem.eql(u8, name, "assert_ne")) return .assert_cmp;
    if (std.mem.eql(u8, name, "panic")) return .panic_call;
    if (std.mem.eql(u8, name, "stringify")) return .stringify;
    if (std.mem.eql(u8, name, "concat")) return .concat;
    if (std.mem.eql(u8, name, "cfg")) return .cfg_macro;
    if (std.mem.eql(u8, name, "todo") or std.mem.eql(u8, name, "unimplemented")) return .todo_like;
    return .none;
}

pub fn transformSource(allocator: std.mem.Allocator, source: []const u8) []const u8 {
    const toks = tokenize(allocator, source) catch return source;
    var out = std.array_list.Managed(u8).init(allocator);
    var segs = std.array_list.Managed([]const u8).init(allocator); // emitted token texts (for comma pop)
    var needs_macro_import = false;
    var in_for_header = false;
    var range_plus_pending = false;

    const emit = struct {
        fn seg(out2: *std.array_list.Managed(u8), segs2: *std.array_list.Managed([]const u8), source2: []const u8, t: Tok, replacement: ?[]const u8) !void {
            try appendPrefixNorm(out2, source2, t.pre_start, t.start);
            const text = replacement orelse tokText(source2, t);
            try out2.appendSlice(text);
            try segs2.append(text);
        }
    };

    var i: usize = 0;
    while (i < toks.len) {
        const t = toks[i];
        const s = tokText(source, t);
        const next_idx: ?usize = if (i + 1 < toks.len) i + 1 else null;
        const next_text: []const u8 = if (next_idx) |ni| tokText(source, toks[ni]) else "";

        // Range-end marker for `for ... in A..=B {`: emit the pending +1.
        if (range_plus_pending and t.kind == .punct and std.mem.eql(u8, s, "{")) {
            out.appendSlice(" + 1") catch {};
            range_plus_pending = false;
            in_for_header = false;
        }

        // ---- attributes
        if (t.kind == .punct and std.mem.eql(u8, s, "#") and next_idx != null and textEq(source, toks[next_idx.?], "[")) {
            const open = next_idx.?;
            const close = findMatch(toks, source, open, "[", "]") orelse {
                emit.seg(&out, &segs, source, t, null) catch {};
                i += 1;
                continue;
            };
            const inner_lo = open + 1;
            const attr_name: []const u8 = if (inner_lo < close) tokText(source, toks[inner_lo]) else "";
            appendPrefixNorm(&out, source, t.pre_start, t.start) catch {};
            if (std.mem.eql(u8, attr_name, "derive")) {
                // #[derive(A, B)] -> @derive(a, b)
                var names = std.array_list.Managed([]const u8).init(allocator);
                var k = inner_lo + 1;
                while (k < close) : (k += 1) {
                    if (toks[k].kind == .ident) {
                        if (deriveMapped(tokText(source, toks[k]))) |m| names.append(m) catch {};
                    }
                }
                out.appendSlice("@derive(") catch {};
                for (names.items, 0..) |nm, idx| {
                    if (idx > 0) out.appendSlice(", ") catch {};
                    out.appendSlice(nm) catch {};
                }
                out.appendSlice(")") catch {};
                segs.append("@derive") catch {};
            } else if (std.mem.eql(u8, attr_name, "cfg")) {
                const keep = evalCfg(toks, source, inner_lo + 1, close, true);
                segs.append("") catch {};
                if (!keep) {
                    // Drop the following item as well.
                    const end = skipItem(toks, source, close + 1);
                    const nl = countNewlines(source, toks, i, end);
                    for (0..nl) |_| out.append('\n') catch {};
                    i = end;
                    continue;
                }
            } else if (std.mem.eql(u8, attr_name, "test")) {
                // #[test] fn name( -> @test "name"(
                var j = close + 1;
                if (j + 1 < toks.len and textEq(source, toks[j], "pub")) j += 1;
                if (j + 1 < toks.len and textEq(source, toks[j], "fn") and toks[j + 1].kind == .ident) {
                    out.appendSlice("@test \"") catch {};
                    out.appendSlice(tokText(source, toks[j + 1])) catch {};
                    out.appendSlice("\"") catch {};
                    segs.append("@test") catch {};
                    i = j + 2;
                    continue;
                }
                segs.append("") catch {};
            } else {
                // Erasable or (root-validated) unsupported: drop the attribute.
                segs.append("") catch {};
            }
            i = close + 1;
            continue;
        }

        // ---- lifetimes: drop, fixing a neighbouring comma
        if (t.kind == .lifetime) {
            const prev_text: []const u8 = if (segs.items.len > 0) segs.items[segs.items.len - 1] else "";
            if (std.mem.eql(u8, next_text, ",") and (std.mem.eql(u8, prev_text, "<") or std.mem.eql(u8, prev_text, "(") or std.mem.eql(u8, prev_text, ","))) {
                appendPrefixNorm(&out, source, t.pre_start, t.start) catch {};
                segs.append("") catch {};
                i += 2; // lifetime + comma
                continue;
            }
            if (std.mem.eql(u8, next_text, ">") and std.mem.eql(u8, prev_text, ",")) {
                // Pop the already-emitted comma segment from `out`.
                if (out.items.len > 0 and out.items[out.items.len - 1] == ',') {
                    _ = out.pop();
                }
                _ = segs.pop();
            }
            appendPrefixNorm(&out, source, t.pre_start, t.start) catch {};
            segs.append("") catch {};
            i += 1;
            continue;
        }

        // ---- char literals -> codepoint integer
        if (t.kind == .char_lit) {
            const cp = charCodepoint(source, t);
            const buf = std.fmt.allocPrint(allocator, "{d}", .{cp}) catch "0";
            emit.seg(&out, &segs, source, t, buf) catch {};
            i += 1;
            continue;
        }

        // ---- raw strings -> escaped string literal (root check rejects these;
        // this path keeps imported files parseable instead of crashing)
        if (t.kind == .raw_string) {
            const content = rawStringContent(source, t);
            var buf = std.array_list.Managed(u8).init(allocator);
            buf.append('"') catch {};
            for (content) |ch| {
                switch (ch) {
                    '"' => buf.appendSlice("\\\"") catch {},
                    '\\' => buf.appendSlice("\\\\") catch {},
                    '\n' => buf.appendSlice("\\n") catch {},
                    '\t' => buf.appendSlice("\\t") catch {},
                    '\r' => buf.appendSlice("\\r") catch {},
                    else => buf.append(ch) catch {},
                }
            }
            buf.append('"') catch {};
            emit.seg(&out, &segs, source, t, buf.toOwnedSlice() catch "\"\"") catch {};
            i += 1;
            continue;
        }

        if (t.kind == .ident) {
            // ---- pub: drop (with optional (crate) style scope)
            if (std.mem.eql(u8, s, "pub")) {
                appendPrefixNorm(&out, source, t.pre_start, t.start) catch {};
                segs.append("") catch {};
                i += 1;
                if (i < toks.len and textEq(source, toks[i], "(")) {
                    if (findMatch(toks, source, i, "(", ")")) |close| i = close + 1;
                }
                continue;
            }
            // ---- mut: drop in let / &mut / param positions
            if (std.mem.eql(u8, s, "mut")) {
                const prev_text: []const u8 = if (segs.items.len > 0) segs.items[segs.items.len - 1] else "";
                var drop = false;
                if (std.mem.eql(u8, prev_text, "&") or std.mem.eql(u8, prev_text, "let")) drop = true;
                if ((std.mem.eql(u8, prev_text, "(") or std.mem.eql(u8, prev_text, ",")) and i + 2 < toks.len and toks[i + 1].kind == .ident and textEq(source, toks[i + 2], ":")) drop = true;
                if (drop) {
                    appendPrefixNorm(&out, source, t.pre_start, t.start) catch {};
                    segs.append("") catch {};
                    i += 1;
                    continue;
                }
            }
            // ---- loop -> while true
            if (std.mem.eql(u8, s, "loop") and std.mem.eql(u8, next_text, "{")) {
                emit.seg(&out, &segs, source, t, "while true") catch {};
                i += 1;
                continue;
            }
            // ---- use: erase the declaration (validation rejects non-prelude paths)
            if (std.mem.eql(u8, s, "use")) {
                var j = i;
                while (j < toks.len and !textEq(source, toks[j], ";")) j += 1;
                if (j < toks.len) j += 1;
                const nl = countNewlines(source, toks, i, j);
                appendPrefixNorm(&out, source, t.pre_start, t.start) catch {};
                for (0..nl) |_| out.append('\n') catch {};
                segs.append("") catch {};
                i = j;
                continue;
            }
            // ---- move closures / dyn: drop the keyword
            if ((std.mem.eql(u8, s, "move") and std.mem.eql(u8, next_text, "|")) or (std.mem.eql(u8, s, "dyn") and next_idx != null)) {
                appendPrefixNorm(&out, source, t.pre_start, t.start) catch {};
                segs.append("") catch {};
                i += 1;
                continue;
            }
            // ---- extern "C": drop both tokens
            if (std.mem.eql(u8, s, "extern") and next_idx != null and toks[next_idx.?].kind == .string_lit) {
                appendPrefixNorm(&out, source, t.pre_start, t.start) catch {};
                segs.append("") catch {};
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, s, "for")) in_for_header = true;

            // ---- macro calls: ident '!' ...
            if (next_idx != null and textEq(source, toks[next_idx.?], "!")) {
                const act = macroAction(s);
                const bang = next_idx.?;
                if (act == .println_like) {
                    emit.seg(&out, &segs, source, t, null) catch {};
                    i = bang + 1; // drop '!'
                    continue;
                }
                if (act == .vec and bang + 1 < toks.len and textEq(source, toks[bang + 1], "[")) {
                    const open = bang + 1;
                    const close = findMatch(toks, source, open, "[", "]") orelse open;
                    appendPrefixNorm(&out, source, t.pre_start, t.start) catch {};
                    out.appendSlice("[") catch {};
                    segs.append("[") catch {};
                    var k = open + 1;
                    while (k < close) : (k += 1) {
                        emit.seg(&out, &segs, source, toks[k], null) catch {};
                    }
                    out.appendSlice("]") catch {};
                    segs.append("]") catch {};
                    i = close + 1;
                    continue;
                }
                if (bang + 1 < toks.len and textEq(source, toks[bang + 1], "(")) {
                    const open = bang + 1;
                    const close = findMatch(toks, source, open, "(", ")") orelse open;
                    const args = splitArgs(allocator, toks, source, open, close) catch &.{};
                    appendPrefixNorm(&out, source, t.pre_start, t.start) catch {};
                    switch (act) {
                        .assert_macro => {
                            if (args.len == 1) {
                                const atext = rangeText(allocator, source, toks, args[0].lo, args[0].hi) catch "";
                                out.appendSlice("SLARS_ASSERT(") catch {};
                                out.appendSlice(atext) catch {};
                                out.appendSlice(")") catch {};
                                needs_macro_import = true;
                            } else if (args.len > 1) {
                                const cond = rangeText(allocator, source, toks, args[0].lo, args[0].hi) catch "";
                                out.appendSlice("{ if (") catch {};
                                out.appendSlice(cond) catch {};
                                out.appendSlice(") == false { println(") catch {};
                                var ai: usize = 1;
                                var first = true;
                                while (ai < args.len) : (ai += 1) {
                                    const atext = rangeText(allocator, source, toks, args[ai].lo, args[ai].hi) catch "";
                                    if (!first) out.appendSlice(", ") catch {};
                                    first = false;
                                    out.appendSlice(atext) catch {};
                                }
                                out.appendSlice("); panic(917003); }; }") catch {};
                            } else {
                                out.appendSlice("SLARS_ASSERT(true)") catch {};
                                needs_macro_import = true;
                            }
                            segs.append("SLARS_ASSERT") catch {};
                        },
                        .assert_cmp => {
                            const is_eq = std.mem.eql(u8, s, "assert_eq");
                            if (args.len >= 2) {
                                const a = rangeText(allocator, source, toks, args[0].lo, args[0].hi) catch "";
                                const b = rangeText(allocator, source, toks, args[1].lo, args[1].hi) catch "";
                                out.appendSlice("{ if (") catch {};
                                out.appendSlice(a) catch {};
                                out.appendSlice(if (is_eq) ") != (" else ") == (") catch {};
                                out.appendSlice(b) catch {};
                                out.appendSlice(") { println(") catch {};
                                if (args.len > 2) {
                                    var ai: usize = 2;
                                    var first = true;
                                    while (ai < args.len) : (ai += 1) {
                                        const atext = rangeText(allocator, source, toks, args[ai].lo, args[ai].hi) catch "";
                                        if (!first) out.appendSlice(", ") catch {};
                                        first = false;
                                        out.appendSlice(atext) catch {};
                                    }
                                } else {
                                    out.appendSlice(if (is_eq) "\"slars assert_eq failed: left={} right={}\", " else "\"slars assert_ne failed: left={} right={}\", ") catch {};
                                    out.appendSlice(a) catch {};
                                    out.appendSlice(", ") catch {};
                                    out.appendSlice(b) catch {};
                                }
                                out.appendSlice(if (is_eq) "); panic(917004); }; }" else "); panic(917005); }; }") catch {};
                            }
                            segs.append("assert_cmp") catch {};
                        },
                        .panic_call => {
                            if (args.len == 0) {
                                out.appendSlice("panic(917000)") catch {};
                            } else if (args.len == 1 and toks[args[0].lo].kind == .string_lit and args[0].hi == args[0].lo + 1) {
                                const atext = rangeText(allocator, source, toks, args[0].lo, args[0].hi) catch "";
                                out.appendSlice("SLARS_PANIC_MSG(") catch {};
                                out.appendSlice(atext) catch {};
                                out.appendSlice(")") catch {};
                                needs_macro_import = true;
                            } else {
                                const atext = rangeText(allocator, source, toks, args[0].lo, args[args.len - 1].hi) catch "";
                                out.appendSlice("panic(") catch {};
                                out.appendSlice(atext) catch {};
                                out.appendSlice(")") catch {};
                            }
                            segs.append("panic") catch {};
                        },
                        .stringify => {
                            const atext = rangeText(allocator, source, toks, open + 1, close) catch "";
                            out.append('"') catch {};
                            for (atext) |ch| {
                                if (ch == '"' or ch == '\\') out.append('\\') catch {};
                                out.append(ch) catch {};
                            }
                            out.append('"') catch {};
                            segs.append("stringify") catch {};
                        },
                        .concat => {
                            var all_lit = args.len > 0;
                            for (args) |ar| {
                                if (ar.hi != ar.lo + 1 or toks[ar.lo].kind != .string_lit) all_lit = false;
                            }
                            if (all_lit) {
                                out.append('"') catch {};
                                for (args) |ar| {
                                    const lit = tokText(source, toks[ar.lo]);
                                    out.appendSlice(stripQuotes(lit)) catch {};
                                }
                                out.append('"') catch {};
                            } else {
                                out.appendSlice("(") catch {};
                                for (args, 0..) |ar, ai| {
                                    const atext = rangeText(allocator, source, toks, ar.lo, ar.hi) catch "";
                                    if (ai > 0) out.appendSlice(" + ") catch {};
                                    out.appendSlice(atext) catch {};
                                }
                                out.appendSlice(")") catch {};
                            }
                            segs.append("concat") catch {};
                        },
                        .cfg_macro => {
                            const v = evalCfg(toks, source, open + 1, close, true);
                            out.appendSlice(if (v) "true" else "false") catch {};
                            segs.append("cfg") catch {};
                        },
                        .todo_like => {
                            out.appendSlice("{ println(\"") catch {};
                            out.appendSlice(s) catch {};
                            out.appendSlice(": not implemented\"); panic(") catch {};
                            out.appendSlice(if (std.mem.eql(u8, s, "todo")) "917090" else "917091") catch {};
                            out.appendSlice("); }") catch {};
                            segs.append("todo") catch {};
                        },
                        else => {
                            out.appendSlice(s) catch {};
                            segs.append(s) catch {};
                        },
                    }
                    i = close + 1;
                    continue;
                }
            }
        }

        // ---- ..= in a for header: emit .. and arm the +1 insertion
        if (t.kind == .punct and std.mem.eql(u8, s, "..=")) {
            if (in_for_header) {
                emit.seg(&out, &segs, source, t, "..") catch {};
                range_plus_pending = true;
            } else {
                emit.seg(&out, &segs, source, t, "..") catch {};
            }
            i += 1;
            continue;
        }
        if (t.kind == .punct and std.mem.eql(u8, s, "{")) in_for_header = false;

        emit.seg(&out, &segs, source, t, null) catch {};
        i += 1;
    }

    const body = out.toOwnedSlice() catch return source;
    if (needs_macro_import) {
        var full = std.array_list.Managed(u8).init(allocator);
        full.appendSlice("@import \"sla_std/std_macros.sla\"\n") catch return body;
        full.appendSlice(body) catch return body;
        return full.toOwnedSlice() catch body;
    }
    return body;
}

// ---------------------------------------------------------------- checking

fn failDiag(stderr: *std.Io.Writer, file: []const u8, line: usize, code: []const u8, msg: []const u8) bool {
    stderr.print("slars check error [{s}] {s} ({s}:{d})\n", .{ code, msg, file, line }) catch {};
    return false;
}

fn failDiagFmt(allocator: std.mem.Allocator, stderr: *std.Io.Writer, file: []const u8, line: usize, code: []const u8, comptime fmt: []const u8, args: anytype) bool {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "check failed";
    return failDiag(stderr, file, line, code, msg);
}

fn validateSource(allocator: std.mem.Allocator, toks: []const Tok, source: []const u8, file: []const u8, stderr: *std.Io.Writer) bool {
    var i: usize = 0;
    var in_for_header = false;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        const s = tokText(source, t);
        if (t.kind == .raw_string) {
            return failDiag(stderr, file, t.line, "SLARS-RAW-STRING", "raw string literals (r#\"...\"#) are not supported in slars phase 1");
        }
        if (t.kind == .punct and std.mem.eql(u8, s, "{")) in_for_header = false;
        if (t.kind == .punct and std.mem.eql(u8, s, "..=")) {
            if (!in_for_header) {
                return failDiag(stderr, file, t.line, "SLARS-RANGE-CTX", "inclusive range ..= is supported in slars phase 1 only in for-loop headers");
            }
            continue;
        }
        if (t.kind != .ident) continue;
        if (std.mem.eql(u8, s, "for")) in_for_header = true;
        if (std.mem.eql(u8, s, "macro_rules")) {
            return failDiag(stderr, file, t.line, "SLARS-MACRO-DEF", "macro_rules! definitions are rejected in slars phase 1 (the macro system is out of scope; use the shipped slars standard macro library)");
        }
        if (std.mem.eql(u8, s, "static")) {
            return failDiag(stderr, file, t.line, "SLARS-STATIC", "static items are rejected in slars phase 1 (no top-level mutable or lazy state; use sa_std global cells)");
        }
        if (std.mem.eql(u8, s, "use")) {
            if (i + 1 < toks.len and toks[i + 1].kind == .ident) {
                const head = tokText(source, toks[i + 1]);
                if (!std.mem.eql(u8, head, "std") and !std.mem.eql(u8, head, "core") and !std.mem.eql(u8, head, "alloc")) {
                    return failDiagFmt(allocator, stderr, file, t.line, "SLARS-USE-PATH", "use of path '{s}::...' is not a prelude import; slars file imports use @import like SLA", .{head});
                }
            }
            continue;
        }
        // Macro-call whitelist / rejection (ident '!' ...)
        if (i + 1 < toks.len and textEq(source, toks[i + 1], "!") and macroAction(s) == .none) {
            // A macro call: ident '!' ('(' | '[')
            if (i + 2 < toks.len and (textEq(source, toks[i + 2], "(") or textEq(source, toks[i + 2], "["))) {
                if (std.mem.eql(u8, s, "print") or std.mem.eql(u8, s, "eprintln")) {
                    return failDiagFmt(allocator, stderr, file, t.line, "SLARS-MACRO-REJECTED", "{s}! is rejected in slars phase 1: formatted output goes through println!/format! so the value flow stays visible to the checker", .{s});
                }
                if (std.mem.eql(u8, s, "dbg")) {
                    return failDiag(stderr, file, t.line, "SLARS-MACRO-REJECTED", "dbg! is rejected in slars phase 1: it moves its operand, which the shared borrow model cannot represent; bind the value, println! it, then use it");
                }
                if (std.mem.eql(u8, s, "matches")) {
                    return failDiag(stderr, file, t.line, "SLARS-MACRO-REJECTED", "matches! is rejected in slars phase 1: pattern-to-bool lowering is not in the shared frontend; write an explicit match");
                }
                return failDiagFmt(allocator, stderr, file, t.line, "SLARS-MACRO-UNKNOWN", "macro {s}! is not in the slars phase-1 whitelist", .{s});
            }
        }
        // Format specifier guard for println!/format!
        if ((std.mem.eql(u8, s, "println") or std.mem.eql(u8, s, "format")) and i + 2 < toks.len and textEq(source, toks[i + 1], "!") and textEq(source, toks[i + 2], "(")) {
            const open = i + 2;
            if (open + 1 < toks.len and toks[open + 1].kind == .string_lit) {
                const lit = tokText(source, toks[open + 1]);
                var k: usize = 0;
                while (k < lit.len) : (k += 1) {
                    if (lit[k] == '{') {
                        if (k + 1 < lit.len and lit[k + 1] == '{') {
                            k += 1;
                            continue;
                        }
                        const close_rel = std.mem.indexOfScalarPos(u8, lit, k, '}') orelse break;
                        const inner = lit[k + 1 .. close_rel];
                        var ok = inner.len == 0;
                        if (!ok) {
                            ok = true;
                            for (inner) |ch| {
                                if (!isDigit(ch)) ok = false;
                            }
                        }
                        if (!ok) {
                            return failDiagFmt(allocator, stderr, file, t.line, "SLARS-FMT-SPEC", "format specifier '{{{s}}}' is not supported in slars phase 1 (only {{}} and positional {{N}})", .{inner});
                        }
                        k = close_rel;
                    }
                }
            }
        }
    }
    // Attribute pass (needs '#' tokens, which are punct kind)
    i = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (t.kind != .punct or !textEq(source, t, "#")) continue;
        if (i + 1 >= toks.len or !textEq(source, toks[i + 1], "[")) continue;
        const open = i + 1;
        const close = findMatch(toks, source, open, "[", "]") orelse continue;
        if (open + 1 >= close) continue;
        const name = tokText(source, toks[open + 1]);
        if (std.mem.eql(u8, name, "derive")) {
            var k = open + 2;
            while (k < close) : (k += 1) {
                if (toks[k].kind != .ident) continue;
                const dn = tokText(source, toks[k]);
                if (deriveMapped(dn) == null) {
                    if (std.mem.eql(u8, dn, "Clone") or std.mem.eql(u8, dn, "Default")) {
                        return failDiagFmt(allocator, stderr, file, t.line, "SLARS-DERIVE-UNSUPPORTED", "derive({s}) has no implementation in the shared SLA backend and is rejected rather than faked", .{dn});
                    }
                    return failDiagFmt(allocator, stderr, file, t.line, "SLARS-DERIVE-UNSUPPORTED", "derive({s}) is not in the slars phase-1 derive set (Debug, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)", .{dn});
                }
            }
        } else if (std.mem.eql(u8, name, "cfg") or std.mem.eql(u8, name, "test")) {
            // supported
        } else if (isErasableAttr(name)) {
            // recognized and erased
        } else {
            return failDiagFmt(allocator, stderr, file, t.line, "SLARS-ATTR-UNSUPPORTED", "attribute #[{s}] is not supported in slars phase 1 (attributes are adjudicated per item, never silently ignored)", .{name});
        }
        i = close;
    }
    return true;
}

// ------------------------------------------------------------ strict check

const Binding = struct { is_mut: bool, pointee_mut: bool };
const Borrow = struct { root: []const u8, is_mut: bool };
const Frame = struct {
    bindings: std.StringHashMap(Binding),
    borrows: std.array_list.Managed(Borrow),
};
const Pending = struct { name: []const u8, binding: Binding };

fn lookupBinding(frames: *std.array_list.Managed(Frame), name: []const u8) ?Binding {
    var idx = frames.items.len;
    while (idx > 0) {
        idx -= 1;
        if (frames.items[idx].bindings.get(name)) |b| return b;
    }
    return null;
}

fn isAssignOp(s: []const u8) bool {
    const ops = [_][]const u8{ "=", "+=", "-=", "*=", "/=", "%=" };
    for (ops) |op| {
        if (std.mem.eql(u8, s, op)) return true;
    }
    return false;
}

fn strictCheck(allocator: std.mem.Allocator, toks: []const Tok, source: []const u8, file: []const u8, stderr: *std.Io.Writer) bool {
    var frames = std.array_list.Managed(Frame).init(allocator);
    frames.append(.{ .bindings = std.StringHashMap(Binding).init(allocator), .borrows = std.array_list.Managed(Borrow).init(allocator) }) catch return true;
    var pending = std.array_list.Managed(Pending).init(allocator);
    var decl_indices = std.AutoHashMap(usize, void).init(allocator);
    var in_let = false;
    var let_frame_depth: usize = 1;

    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        const s = tokText(source, t);
        if (t.kind == .punct and std.mem.eql(u8, s, "{")) {
            var fr = Frame{ .bindings = std.StringHashMap(Binding).init(allocator), .borrows = std.array_list.Managed(Borrow).init(allocator) };
            for (pending.items) |p| fr.bindings.put(p.name, p.binding) catch {};
            pending.clearRetainingCapacity();
            frames.append(fr) catch {};
            continue;
        }
        if (t.kind == .punct and std.mem.eql(u8, s, "}")) {
            if (frames.items.len > 1) _ = frames.pop();
            if (frames.items.len < let_frame_depth) in_let = false;
            continue;
        }
        if (t.kind == .punct and std.mem.eql(u8, s, ";")) {
            if (in_let and frames.items.len == let_frame_depth) in_let = false;
            pending.clearRetainingCapacity();
            continue;
        }
        if (t.kind == .ident and std.mem.eql(u8, s, "fn")) {
            // Parse the parameter list into pending bindings.
            var j = i + 1;
            if (j < toks.len and toks[j].kind == .ident) j += 1; // fn name
            if (j < toks.len and textEq(source, toks[j], "<")) {
                if (findAngleMatch(toks, source, j)) |close| j = close + 1;
            }
            if (j < toks.len and textEq(source, toks[j], "(")) {
                const open = j;
                const close = findMatch(toks, source, open, "(", ")") orelse open;
                const args = splitArgs(allocator, toks, source, open, close) catch &.{};
                for (args) |ar| {
                    if (ar.lo >= ar.hi) continue;
                    // pointee_mut: '&' followed by 'mut' anywhere in the param
                    var pointee_mut = false;
                    var q = ar.lo;
                    while (q + 1 < ar.hi) : (q += 1) {
                        if (textEq(source, toks[q], "&") and textEq(source, toks[q + 1], "mut")) pointee_mut = true;
                    }
                    // Locate the binding name: ident right before ':' if a ':'
                    // exists, else a trailing/standalone 'self'.
                    var name: ?[]const u8 = null;
                    var is_mut = false;
                    var colon: ?usize = null;
                    q = ar.lo;
                    while (q < ar.hi) : (q += 1) {
                        if (textEq(source, toks[q], ":")) {
                            colon = q;
                            break;
                        }
                    }
                    if (colon) |ci| {
                        if (ci > ar.lo and toks[ci - 1].kind == .ident) {
                            name = tokText(source, toks[ci - 1]);
                            if (ci >= ar.lo + 2 and textEq(source, toks[ci - 2], "mut")) is_mut = true;
                        }
                    } else {
                        q = ar.lo;
                        while (q < ar.hi) : (q += 1) {
                            if (textEq(source, toks[q], "self")) {
                                name = "self";
                                // &mut self or mut self
                                var r = ar.lo;
                                while (r + 1 < ar.hi) : (r += 1) {
                                    if (textEq(source, toks[r], "&") and textEq(source, toks[r + 1], "mut")) is_mut = true;
                                }
                                if (ar.lo + 1 < ar.hi and textEq(source, toks[ar.lo], "mut")) is_mut = true;
                            }
                        }
                    }
                    if (name) |nm| {
                        pending.append(.{ .name = nm, .binding = .{ .is_mut = is_mut, .pointee_mut = pointee_mut } }) catch {};
                    }
                }
                i = close;
                continue;
            }
            continue;
        }
        if (t.kind == .ident and std.mem.eql(u8, s, "let")) {
            var k = i + 1;
            var is_mut = false;
            if (k < toks.len and textEq(source, toks[k], "mut")) {
                is_mut = true;
                k += 1;
            }
            // pointee_mut from the statement's &mut occurrences
            var pointee_mut = false;
            {
                var q = i;
                var depth: i64 = 0;
                var steps: usize = 0;
                while (q < toks.len and steps < 400) : (q += 1) {
                    steps += 1;
                    const qs = tokText(source, toks[q]);
                    if (toks[q].kind == .punct and (std.mem.eql(u8, qs, "(") or std.mem.eql(u8, qs, "[") or std.mem.eql(u8, qs, "{"))) depth += 1;
                    if (toks[q].kind == .punct and (std.mem.eql(u8, qs, ")") or std.mem.eql(u8, qs, "]") or std.mem.eql(u8, qs, "}"))) depth -= 1;
                    if (depth == 0 and toks[q].kind == .punct and std.mem.eql(u8, qs, ";")) break;
                    if (q + 1 < toks.len and textEq(source, toks[q], "&") and textEq(source, toks[q + 1], "mut")) pointee_mut = true;
                }
            }
            const top = &frames.items[frames.items.len - 1];
            if (k < toks.len and textEq(source, toks[k], "(")) {
                const close = findMatch(toks, source, k, "(", ")") orelse k;
                var q = k + 1;
                while (q < close) : (q += 1) {
                    if (toks[q].kind == .ident and q + 1 < toks.len and (textEq(source, toks[q + 1], ",") or textEq(source, toks[q + 1], ")"))) {
                        top.bindings.put(tokText(source, toks[q]), .{ .is_mut = is_mut, .pointee_mut = false }) catch {};
                        decl_indices.put(q, {}) catch {};
                    }
                }
            } else if (k < toks.len and toks[k].kind == .ident) {
                if (k + 1 < toks.len and textEq(source, toks[k + 1], "(")) {
                    // Constructor pattern: let Some(v) = ...
                    const open = k + 1;
                    const close = findMatch(toks, source, open, "(", ")") orelse open;
                    var q = open + 1;
                    while (q < close) : (q += 1) {
                        if (toks[q].kind == .ident and q + 1 < toks.len and (textEq(source, toks[q + 1], ",") or textEq(source, toks[q + 1], ")"))) {
                            top.bindings.put(tokText(source, toks[q]), .{ .is_mut = is_mut, .pointee_mut = false }) catch {};
                            decl_indices.put(q, {}) catch {};
                        }
                    }
                } else {
                    top.bindings.put(tokText(source, toks[k]), .{ .is_mut = is_mut, .pointee_mut = pointee_mut }) catch {};
                    decl_indices.put(k, {}) catch {};
                }
            }
            in_let = true;
            let_frame_depth = frames.items.len;
            continue;
        }
        if (t.kind == .ident and std.mem.eql(u8, s, "for")) {
            if (i + 2 < toks.len and toks[i + 1].kind == .ident and textEq(source, toks[i + 2], "in")) {
                frames.items[frames.items.len - 1].bindings.put(tokText(source, toks[i + 1]), .{ .is_mut = false, .pointee_mut = false }) catch {};
                decl_indices.put(i + 1, {}) catch {};
            }
            continue;
        }
        // Borrow events in expression position.
        if (t.kind == .punct and std.mem.eql(u8, s, "&")) {
            const prev_text: []const u8 = if (i > 0) tokText(source, toks[i - 1]) else "";
            const expr_pos = std.mem.eql(u8, prev_text, "=") or std.mem.eql(u8, prev_text, "(") or std.mem.eql(u8, prev_text, ",") or std.mem.eql(u8, prev_text, "[") or std.mem.eql(u8, prev_text, "=>") or std.mem.eql(u8, prev_text, "return") or std.mem.eql(u8, prev_text, "match") or std.mem.eql(u8, prev_text, "if") or std.mem.eql(u8, prev_text, "while") or std.mem.eql(u8, prev_text, "&&") or std.mem.eql(u8, prev_text, "||") or std.mem.eql(u8, prev_text, "?");
            if (expr_pos) {
                var j = i + 1;
                var is_mut_b = false;
                if (j < toks.len and textEq(source, toks[j], "mut")) {
                    is_mut_b = true;
                    j += 1;
                }
                if (j < toks.len and toks[j].kind == .ident) {
                    const root = tokText(source, toks[j]);
                    if (is_mut_b) {
                        if (lookupBinding(&frames, root)) |b| {
                            if (!b.is_mut and !b.pointee_mut) {
                                return failDiagFmt(allocator, stderr, file, t.line, "SLARS-BORROW-IMMUTABLE", "cannot borrow '{s}' as mutable because it is not declared as mutable", .{root});
                            }
                        }
                    }
                    if (in_let) {
                        for (frames.items) |fr| {
                            for (fr.borrows.items) |bo| {
                                if (std.mem.eql(u8, bo.root, root) and (is_mut_b or bo.is_mut)) {
                                    return failDiagFmt(allocator, stderr, file, t.line, "SLARS-BORROW-CONFLICT", "cannot borrow '{s}' because a previous borrow is still live in this block", .{root});
                                }
                            }
                        }
                        frames.items[frames.items.len - 1].borrows.append(.{ .root = root, .is_mut = is_mut_b }) catch {};
                    }
                }
            }
            continue;
        }
        // Assignment events.
        if (t.kind == .ident) {
            if (decl_indices.contains(i)) continue;
            if (i > 0 and (textEq(source, toks[i - 1], ".") or textEq(source, toks[i - 1], "*"))) continue;
            if (i + 1 < toks.len and isAssignOp(tokText(source, toks[i + 1]))) {
                if (lookupBinding(&frames, s)) |b| {
                    if (!b.is_mut) {
                        return failDiagFmt(allocator, stderr, file, t.line, "SLARS-IMMUTABLE-ASSIGN", "cannot assign to immutable binding '{s}' (declare it with 'let mut' to make it assignable)", .{s});
                    }
                }
                continue;
            }
            if (i + 1 < toks.len and (textEq(source, toks[i + 1], ".") or textEq(source, toks[i + 1], "["))) {
                var j = i + 1;
                const walked = true;
                while (j < toks.len) {
                    if (textEq(source, toks[j], ".") and j + 1 < toks.len and toks[j + 1].kind == .ident) {
                        j += 2;
                    } else if (textEq(source, toks[j], "[")) {
                        j = (findMatch(toks, source, j, "[", "]") orelse j) + 1;
                    } else break;
                }
                if (walked and j < toks.len and isAssignOp(tokText(source, toks[j]))) {
                    if (lookupBinding(&frames, s)) |b| {
                        if (!b.is_mut) {
                            return failDiagFmt(allocator, stderr, file, t.line, "SLARS-IMMUTABLE-ASSIGN", "cannot assign through immutable binding '{s}' (declare it with 'let mut')", .{s});
                        }
                    }
                }
                continue;
            }
        }
    }
    return true;
}

/// Root-file gate for `.slars` sources: validation (loud rejections) plus
/// the strict checker. Returns true when the source may proceed to the
/// shared SLA frontend.
pub fn checkSource(allocator: std.mem.Allocator, source: []const u8, file: []const u8, stderr: *std.Io.Writer) bool {
    const toks = tokenize(allocator, source) catch return true;
    if (!validateSource(allocator, toks, source, file, stderr)) return false;
    if (!strictCheck(allocator, toks, source, file, stderr)) return false;
    return true;
}
