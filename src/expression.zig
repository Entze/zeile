const std = @import("std");
const root = @import("root.zig");

const SessionData = root.SessionData;
const Primitive = root.Primitive;

pub const Error = error{ FieldNotFound, NotPrimitive, InvalidSyntax };

/// Evaluate a template string against session data, writing the result.
///
/// Template syntax:
/// - `$$` produces a literal `$`.
/// - `$.field.path` resolves a bare accessor terminated by whitespace or
///   end of input.
/// - `${.field.path}` resolves a braced accessor.
/// - All other text passes through unchanged.
///
/// Returns `error.InvalidSyntax` when a `$` is not followed by `$`, `.`,
/// or `{`, or when a braced accessor has no closing `}`.
/// Propagates `error.FieldNotFound` and `error.NotPrimitive` from the
/// underlying `SessionData.get` call.
pub fn render(data: *const SessionData, template: []const u8, writer: *std.io.Writer) Error!void {
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '$') {
            if (i + 1 >= template.len) return error.InvalidSyntax;
            const next = template[i + 1];
            if (next == '$') {
                writer.writeByte('$') catch return error.InvalidSyntax;
                i += 2;
            } else if (next == '{') {
                const start = i + 2;
                const end = std.mem.indexOfScalarPos(u8, template, start, '}') orelse
                    return error.InvalidSyntax;
                const path = template[start..end];
                const prim = try data.get(path);
                writePrimitive(writer, prim) catch return error.InvalidSyntax;
                i = end + 1;
            } else if (next == '.') {
                const start = i + 1;
                var end = start;
                while (end < template.len and !std.ascii.isWhitespace(template[end])) {
                    end += 1;
                }
                const path = template[start..end];
                const prim = try data.get(path);
                writePrimitive(writer, prim) catch return error.InvalidSyntax;
                i = end;
            } else {
                return error.InvalidSyntax;
            }
        } else {
            writer.writeByte(template[i]) catch return error.InvalidSyntax;
            i += 1;
        }
    }
}

fn writePrimitive(writer: *std.io.Writer, p: Primitive) !void {
    switch (p) {
        .null => try writer.writeAll("null"),
        .bool => |v| try writer.writeAll(if (v) "true" else "false"),
        .byte => |v| try writer.print("{d}", .{v}),
        .unsigned_integer => |v| try writer.print("{d}", .{v}),
        .float => |v| try writer.print("{d}", .{v}),
        .string => |v| try writer.writeAll(v),
        .vim_mode => |v| try writer.writeAll(@tagName(v)),
    }
}

fn parseSessionData(gpa: std.mem.Allocator, path: []const u8) !std.json.Parsed(SessionData) {
    const input = try std.fs.cwd().readFileAlloc(gpa, path, 1024 * 1024);
    defer gpa.free(input);
    return std.json.parseFromSlice(SessionData, gpa, input, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn renderAlloc(data: *const SessionData, template: []const u8, gpa: std.mem.Allocator) Error![]const u8 {
    var aw: std.io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try render(data, template, &aw.writer);
    return aw.toOwnedSlice() catch ""; // allocator failure yields empty
}

// -- Literal text --

test "render: plain text without expressions" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "hello world", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "render: empty string" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("", result);
}

// -- Dollar-sign escaping --

test "render: escaped dollar sign" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$$", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("$", result);
}

test "render: escaped dollar sign in text" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "cost: $$5", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("cost: $5", result);
}

test "render: double escaped dollar signs" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$$$$", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("$$", result);
}

// -- Bare accessors --

test "render: bare accessor for string" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$.cwd", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("/current/working/directory", result);
}

test "render: bare accessor for nested string" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$.model.display_name", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("Opus", result);
}

test "render: bare accessor terminated by space" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$.cwd rest", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("/current/working/directory rest", result);
}

test "render: bare accessor preceded by text" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "dir: $.cwd", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("dir: /current/working/directory", result);
}

test "render: bare accessor for bool" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$.exceeds_200k_tokens", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("false", result);
}

test "render: bare accessor for unsigned integer" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$.cost.total_duration_ms", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("45000", result);
}

test "render: bare accessor for vim_mode" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$.vim.mode", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("NORMAL", result);
}

test "render: bare accessor for byte" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$.context_window.used_percentage", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("8", result);
}

// -- Braced accessors --

test "render: braced accessor for string" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "${.session_id}", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("abc123...", result);
}

test "render: braced accessor embedded in text" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "Claude ${.model.display_name} model", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("Claude Opus model", result);
}

test "render: braced accessor adjacent to text" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "v${.version}!", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("v1.0.80!", result);
}

// -- Combined --

test render {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "Claude ${.model.display_name} $$${.cost.total_cost_usd}", gpa);
    defer gpa.free(result);
    var expected_buf: [64]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "Claude Opus ${d}", .{@as(f64, 0.01234)}) catch unreachable;
    try std.testing.expectEqualStrings(expected, result);
}

// -- Null handling --

test "render: null from optional parent" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/minimal.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "Mode: ${.vim.mode}", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("Mode: null", result);
}

test "render: null bare accessor" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/minimal.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$.vim.mode", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("null", result);
}

// -- Error cases --

test "render: error.FieldNotFound for unknown field" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.FieldNotFound, renderAlloc(&parsed.value, "${.unknown.invalid}", gpa));
}

test "render: error.NotPrimitive for struct field" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.NotPrimitive, renderAlloc(&parsed.value, "${.context_window}", gpa));
}

test "render: error.FieldNotFound for bare accessor" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.FieldNotFound, renderAlloc(&parsed.value, "$.nonexistent", gpa));
}

test "render: error.InvalidSyntax for unclosed brace" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidSyntax, renderAlloc(&parsed.value, "${.cwd", gpa));
}

test "render: error.InvalidSyntax for dollar not followed by valid char" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidSyntax, renderAlloc(&parsed.value, "$x", gpa));
}

test "render: error.InvalidSyntax for dollar at end of input" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidSyntax, renderAlloc(&parsed.value, "end$", gpa));
}

// -- Edge cases --

test "render: multiple braced accessors" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "${.model.id} ${.model.display_name}", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("claude-opus-4-6 Opus", result);
}

test "render: bare then braced accessor" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try renderAlloc(&parsed.value, "$.version ${.model.display_name}", gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("1.0.80 Opus", result);
}
