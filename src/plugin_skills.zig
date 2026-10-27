const std = @import("std");
const sio = @import("sio");
const plugin_api = @import("plugin_api");

pub const skills = [_]plugin_api.SkillSection{
    .{
        .name = "slars",
        .summary = "Sla compiler and tools",
        .items = &.{
            "sla init [path]",
            "sla skills [--json]",
            "sla stability schema|verify ...",
            "sla build [file] [-p <package>] [--out <file>]",
            "sla build-workspace [-p <package>] [sa-build-exe-options...]",
            "sla build-exe [file] [-p <package>] [sa-build-exe-options...]",
            "sla build-wasm [file] [-p <package>] [sa-build-wasm-options...]",
            "sla build-js [file] [-p <package>] [sa-build-js-options...]",
            "sla build-c [file] [-p <package>] [sa-build-c-options...]",
            "sla sab build [file] [-p <package>] [--out <file.sab>]",
            "sla sab workspace [-p <package>] [--sab-out <file.sab>] [sa-build-exe-options...]",
            "slab build|workspace|disasm ...",
            "sla check [file] [-p <package>]",
            "sla test [file] [-p <package>] [--test-backend auto|sab|sa] [sa-test-options...]",
        },
    },
};

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try sio.cwd().makePath(dir);
    }
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeJsonStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeByte(']');
}

pub fn writeSlaSkillsJson(writer: anytype) !void {
    try writer.writeAll("{\"status\":\"ok\",\"skills\":[");
    for (skills, 0..) |section, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"name\":");
        try writeJsonString(writer, section.name);
        try writer.writeAll(",\"summary\":");
        try writeJsonString(writer, section.summary);
        try writer.writeAll(",\"items\":");
        try writeJsonStringArray(writer, section.items);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

pub fn writeSlaSkillSectionText(writer: anytype, section: plugin_api.SkillSection) !void {
    try writer.print("{s}\n", .{section.name});
    try writer.print("summary: {s}\n", .{section.summary});
    for (section.items) |item| {
        try writer.print("- {s}\n", .{item});
    }
}

fn writeMarkdownCodeList(writer: anytype, items: []const []const u8) !void {
    for (items) |item| try writer.print("- `{s}`\n", .{item});
}

fn writeSlaAgentSkillMarkdown(writer: anytype, agent_name: []const u8) !void {
    const description = if (std.mem.eql(u8, agent_name, "claude"))
        "Use the installed SLA plugin from Claude to build, check, test, scaffold, and inspect direct SAB workflows."
    else
        "Use the installed SLA plugin from Codex to build, check, test, scaffold, and inspect direct SAB workflows.";

    try writer.writeAll("---\n");
    try writer.writeAll("name: \"sla\"\n");
    try writer.writeAll("description: ");
    try writeJsonString(writer, description);
    try writer.writeByte('\n');
    try writer.writeAll("when_to_use: \"Use when working on .sla sources, SLA workspace builds, direct SLA-to-SAB output, or SLA plugin CLI commands.\"\n");
    try writer.writeAll("---\n\n");

    try writer.writeAll("# SLA Toolchain\n\n");
    try writer.writeAll("## Core Workflow\n");
    try writer.writeAll("- Use `sa sla init [path]` to scaffold a minimal SLA binary project.\n");
    try writer.writeAll("- Use `sa sla build <file>` only when a visible `.sa` text artifact is needed.\n");
    try writer.writeAll("- Use `sa sla build-exe <file>` or `sa sla sab workspace` for executable builds through the direct SAB path.\n");
    try writer.writeAll("- Use `sa sla build-wasm <file>` for WebAssembly (.wasm), `sa sla build-js <file>` for JavaScript (.js), and `sa sla build-c <file>` for portable C (.c) through the same direct SAB path.\n");
    try writer.writeAll("- Use `sa sla test <file>` for tests through the direct SAB path by default; add `--test-backend sa` only when debugging legacy `.test.sa` output.\n");
    try writer.writeAll("- Use `sa sla sab build <file>` to emit managed SAB under `.sla-cache/sab/`; add `--out <file.sab>` only for an inspection copy.\n");
    try writer.writeAll("- Keep SLA-to-SA and SLA-to-SAB as separate mainlines; SAB output must not be implemented as `sla -> sa -> sab`.\n");
    try writer.writeAll("- Prefer focused checks with `timeout 120s`; do not run full test suites unless explicitly requested. Build commands do not need the timeout wrapper.\n\n");

    try writer.writeAll("## CLI Skill Sections\n");
    for (skills) |section| {
        try writer.print("### {s}\n", .{section.name});
        try writer.print("{s}\n", .{section.summary});
        try writeMarkdownCodeList(writer, section.items);
        try writer.writeByte('\n');
    }
}

pub const SlaAgentSkillPaths = struct {
    codex: []const u8,
    claude: []const u8,
};

pub fn writeSlaAgentSkills() !SlaAgentSkillPaths {
    const codex_path = ".codex/skills/sla/SKILL.md";
    const claude_path = ".claude/skills/sla/SKILL.md";
    try ensureParentDir(codex_path);
    try ensureParentDir(claude_path);
    {
        var file = try sio.cwd().createFile(codex_path, .{ .truncate = true });
        defer file.close();
        var fbuf: [8192]u8 = undefined;
        var fw = file.writer(&fbuf);
        try writeSlaAgentSkillMarkdown(&fw.interface, "codex");
        try fw.interface.flush();
    }
    {
        var file = try sio.cwd().createFile(claude_path, .{ .truncate = true });
        defer file.close();
        var fbuf: [8192]u8 = undefined;
        var fw = file.writer(&fbuf);
        try writeSlaAgentSkillMarkdown(&fw.interface, "claude");
        try fw.interface.flush();
    }
    return .{ .codex = codex_path, .claude = claude_path };
}
