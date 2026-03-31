const std = @import("std");

pub const progressbar = @import("progressbar.zig");

/// Current model identifier and display name.
pub const Model = struct {
    /// Current model identifier (e.g. "claude-opus-4-6").
    id: []const u8,
    /// Human-readable model name (e.g. "Opus").
    display_name: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(Model) == 32);
}

/// Workspace directory information.
pub const Workspace = struct {
    /// Current working directory. Preferred over the top-level `cwd` field
    /// for consistency with `project_dir`.
    current_dir: []const u8,
    /// Directory where Claude Code was launched. May differ from `current_dir`
    /// if the working directory changes during a session.
    project_dir: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(Workspace) == 32);
}

/// Output style configuration.
pub const OutputStyle = struct {
    /// Name of the current output style.
    name: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(OutputStyle) == 16);
}

/// Session cost and timing information.
pub const Cost = struct {
    /// Total session cost in USD.
    total_cost_usd: f64,
    /// Total wall-clock time since the session started, in milliseconds.
    total_duration_ms: u64,
    /// Total time spent waiting for API responses, in milliseconds.
    total_api_duration_ms: u64,
    /// Total lines of code added during the session.
    total_lines_added: u64,
    /// Total lines of code removed during the session.
    total_lines_removed: u64,
};

comptime {
    std.debug.assert(@sizeOf(Cost) == 40);
}

/// Token counts from a single API call.
pub const TokenUsage = struct {
    /// Number of input tokens.
    input_tokens: u64,
    /// Number of output tokens.
    output_tokens: u64,
    /// Number of tokens used for cache creation.
    cache_creation_input_tokens: u64,
    /// Number of tokens read from cache.
    cache_read_input_tokens: u64,
};

comptime {
    std.debug.assert(@sizeOf(TokenUsage) == 32);
}

/// Context window usage and statistics.
pub const ContextWindow = struct {
    /// Cumulative input token count across the session.
    total_input_tokens: u64,
    /// Cumulative output token count across the session.
    total_output_tokens: u64,
    /// Maximum context window size in tokens.
    /// 200000 by default, or 1000000 for models with extended context.
    context_window_size: u64,
    /// Pre-calculated percentage of context window used.
    used_percentage: ?u8 = null,
    /// Pre-calculated percentage of context window remaining.
    remaining_percentage: ?u8 = null,
    /// Token counts from the last API call.
    current_usage: ?TokenUsage = null,
};

comptime {
    std.debug.assert(@sizeOf(ContextWindow) == 72);
}

/// Rate limit usage within a specific time window.
pub const RateLimitWindow = struct {
    /// Percentage of the rate limit consumed, from 0 to 100.
    used_percentage: f64,
    /// Unix epoch seconds when the rate limit window resets.
    resets_at: u64,
};

comptime {
    std.debug.assert(@sizeOf(RateLimitWindow) == 16);
}

/// Rate limit information for 5-hour and 7-day windows.
pub const RateLimits = struct {
    /// 5-hour rate limit window.
    five_hour: ?RateLimitWindow,
    /// 7-day rate limit window.
    seven_day: ?RateLimitWindow,
};

comptime {
    std.debug.assert(@sizeOf(RateLimits) == 48);
}

/// Vim editor mode.
pub const VimMode = enum {
    NORMAL,
    INSERT,
};

comptime {
    std.debug.assert(@sizeOf(VimMode) == 1);
}

/// Vim mode configuration. Present when vim mode is enabled.
pub const Vim = struct {
    /// Current vim mode (NORMAL or INSERT).
    mode: VimMode,
};

comptime {
    std.debug.assert(@sizeOf(Vim) == 1);
}

/// Agent configuration. Present when running with the `--agent` flag
/// or agent settings configured.
pub const Agent = struct {
    /// Agent name.
    name: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(Agent) == 16);
}

/// Git worktree information. Present only during `--worktree` sessions.
pub const Worktree = struct {
    /// Name of the active worktree.
    name: []const u8,
    /// Absolute path to the worktree directory.
    path: []const u8,
    /// Git branch name for the worktree. Absent for hook-based worktrees.
    branch: ?[]const u8,
    /// The directory Claude was in before entering the worktree.
    original_cwd: []const u8,
    /// Git branch checked out before entering the worktree. Absent for
    /// hook-based worktrees.
    original_branch: ?[]const u8,
};

comptime {
    std.debug.assert(@sizeOf(Worktree) == 80);
}

/// Leaf value from the `SessionData` struct hierarchy.
pub const Primitive = union(enum) {
    null,
    bool: bool,
    byte: u8,
    unsigned_integer: u64,
    float: f64,
    string: []const u8,
    vim_mode: VimMode,
};

/// Claude Code session data, sent via stdin to status line scripts.
pub const SessionData = struct {
    /// Current working directory. Same value as `workspace.current_dir`.
    cwd: []const u8,
    /// Unique session identifier.
    session_id: []const u8,
    /// Path to conversation transcript file.
    transcript_path: []const u8,
    /// Current model information.
    model: Model,
    /// Workspace directory information.
    workspace: Workspace,
    /// Claude Code version.
    version: []const u8,
    /// Output style configuration.
    output_style: OutputStyle,
    /// Session cost and timing information.
    cost: Cost,
    /// Context window usage and statistics.
    context_window: ContextWindow,
    /// Whether the total token count (input, cache, and output tokens
    /// combined) from the most recent API response exceeds 200k. This is
    /// a fixed threshold regardless of actual context window size.
    exceeds_200k_tokens: bool,
    /// Rate limit information. May be absent.
    rate_limits: ?RateLimits = null,
    /// Vim mode configuration. Present when vim mode is enabled.
    vim: ?Vim = null,
    /// Agent configuration. Present when running with `--agent`.
    agent: ?Agent = null,
    /// Git worktree information. Present only during worktree sessions.
    worktree: ?Worktree = null,

    /// Resolve a dot-separated field path to a leaf value.
    /// Returns `error.FieldNotFound` if the path does not match any field.
    /// Returns `error.NotPrimitive` if the path resolves to a struct.
    /// Returns `.null` if any optional in the chain is null at runtime.
    pub fn get(data: *const SessionData, path: []const u8) error{ FieldNotFound, NotPrimitive }!Primitive {
        return getField(SessionData, "", data, path);
    }
};

comptime {
    std.debug.assert(@sizeOf(SessionData) == 432);
}

fn stripOptional(comptime T: type) type {
    return if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
}

fn isPrimitive(comptime T: type) bool {
    const Inner = stripOptional(T);
    return Inner == bool or Inner == u8 or Inner == u64 or Inner == f64 or Inner == []const u8 or Inner == VimMode;
}

fn wrapPrimitive(comptime T: type, value: T) Primitive {
    if (@typeInfo(T) == .optional) {
        return if (value) |v| wrapPrimitive(@typeInfo(T).optional.child, v) else .null;
    }
    if (T == bool) return .{ .bool = value };
    if (T == u8) return .{ .byte = value };
    if (T == u64) return .{ .unsigned_integer = value };
    if (T == f64) return .{ .float = value };
    if (T == []const u8) return .{ .string = value };
    if (T == VimMode) return .{ .vim_mode = value };
    unreachable;
}

fn getField(comptime T: type, comptime prefix: []const u8, data: *const T, path: []const u8) error{ FieldNotFound, NotPrimitive }!Primitive {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const field_path = comptime prefix ++ "." ++ field.name;
        const FieldType = field.type;
        const Inner = comptime stripOptional(FieldType);
        if (std.mem.eql(u8, path, field_path)) {
            if (comptime isPrimitive(Inner)) {
                return wrapPrimitive(FieldType, @field(data.*, field.name));
            }
            if (comptime @typeInfo(FieldType) == .optional) {
                if (@field(data.*, field.name) == null) return .null;
            }
            return error.NotPrimitive;
        }
        if (comptime @typeInfo(Inner) == .@"struct") {
            if (std.mem.startsWith(u8, path, comptime field_path ++ ".")) {
                if (comptime @typeInfo(FieldType) == .optional) {
                    const val = @field(data.*, field.name) orelse return .null;
                    return getField(Inner, field_path, &val, path);
                }
                return getField(Inner, field_path, &@field(data.*, field.name), path);
            }
        }
    }
    return error.FieldNotFound;
}

test SessionData {
    const gpa = std.testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(gpa, "tests/resources/session_data/good/complete.json", 1024 * 1024);
    defer gpa.free(input);
    const parsed = try std.json.parseFromSlice(SessionData, gpa, input, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const session = parsed.value;

    try std.testing.expectEqualStrings("/current/working/directory", session.cwd);
    try std.testing.expectEqualStrings("abc123...", session.session_id);
    try std.testing.expectEqualStrings("/path/to/transcript.jsonl", session.transcript_path);
    try std.testing.expectEqualStrings("claude-opus-4-6", session.model.id);
    try std.testing.expectEqualStrings("Opus", session.model.display_name);
    try std.testing.expectEqualStrings("/current/working/directory", session.workspace.current_dir);
    try std.testing.expectEqualStrings("/original/project/directory", session.workspace.project_dir);
    try std.testing.expectEqualStrings("1.0.80", session.version);
    try std.testing.expectEqualStrings("default", session.output_style.name);
    try std.testing.expect(session.cost.total_cost_usd == 0.01234);
    try std.testing.expectEqual(@as(u64, 45000), session.cost.total_duration_ms);
    try std.testing.expectEqual(@as(u64, 2300), session.cost.total_api_duration_ms);
    try std.testing.expectEqual(@as(u64, 156), session.cost.total_lines_added);
    try std.testing.expectEqual(@as(u64, 23), session.cost.total_lines_removed);
    try std.testing.expectEqual(@as(u64, 15234), session.context_window.total_input_tokens);
    try std.testing.expectEqual(@as(u64, 4521), session.context_window.total_output_tokens);
    try std.testing.expectEqual(@as(u64, 200000), session.context_window.context_window_size);
    try std.testing.expectEqual(@as(?u8, 8), session.context_window.used_percentage);
    try std.testing.expectEqual(@as(?u8, 92), session.context_window.remaining_percentage);
    const usage = session.context_window.current_usage.?;
    try std.testing.expectEqual(@as(u64, 8500), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 1200), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 5000), usage.cache_creation_input_tokens);
    try std.testing.expectEqual(@as(u64, 2000), usage.cache_read_input_tokens);
    try std.testing.expect(!session.exceeds_200k_tokens);
    const five_hour = session.rate_limits.?.five_hour.?;
    try std.testing.expect(five_hour.used_percentage == 23.5);
    try std.testing.expectEqual(@as(u64, 1738425600), five_hour.resets_at);
    const seven_day = session.rate_limits.?.seven_day.?;
    try std.testing.expect(seven_day.used_percentage == 41.2);
    try std.testing.expectEqual(@as(u64, 1738857600), seven_day.resets_at);
    try std.testing.expectEqual(VimMode.NORMAL, session.vim.?.mode);
    try std.testing.expectEqualStrings("security-reviewer", session.agent.?.name);
    const worktree = session.worktree.?;
    try std.testing.expectEqualStrings("my-feature", worktree.name);
    try std.testing.expectEqualStrings("/path/to/.claude/worktrees/my-feature", worktree.path);
    try std.testing.expectEqualStrings("worktree-my-feature", worktree.branch.?);
    try std.testing.expectEqualStrings("/path/to/project", worktree.original_cwd);
    try std.testing.expectEqualStrings("main", worktree.original_branch.?);
}

fn parseSessionData(gpa: std.mem.Allocator, path: []const u8) !std.json.Parsed(SessionData) {
    const input = try std.fs.cwd().readFileAlloc(gpa, path, 1024 * 1024);
    defer gpa.free(input);
    return std.json.parseFromSlice(SessionData, gpa, input, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

test "get: string" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try parsed.value.get(".cwd");
    try std.testing.expectEqualStrings("/current/working/directory", result.string);
}

test "get: bool" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try parsed.value.get(".exceeds_200k_tokens");
    try std.testing.expectEqual(false, result.bool);
}

test "get: byte" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try parsed.value.get(".context_window.used_percentage");
    try std.testing.expectEqual(@as(u8, 8), result.byte);
}

test "get: unsigned_integer" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try parsed.value.get(".cost.total_duration_ms");
    try std.testing.expectEqual(@as(u64, 45000), result.unsigned_integer);
}

test "get: float" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try parsed.value.get(".cost.total_cost_usd");
    try std.testing.expect(result.float == 0.01234);
}

test "get: vim_mode" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    const result = try parsed.value.get(".vim.mode");
    try std.testing.expectEqual(VimMode.NORMAL, result.vim_mode);
}

test "get: null from optional parent" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/minimal.json");
    defer parsed.deinit();
    try std.testing.expectEqual(Primitive.null, try parsed.value.get(".vim.mode"));
}

test "get: null from nested optional" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/minimal.json");
    defer parsed.deinit();
    try std.testing.expectEqual(Primitive.null, try parsed.value.get(".rate_limits.five_hour.used_percentage"));
}

test "get: null from optional leaf" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/minimal.json");
    defer parsed.deinit();
    try std.testing.expectEqual(Primitive.null, try parsed.value.get(".context_window.used_percentage"));
}

test "get: error.FieldNotFound for unknown top-level field" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.FieldNotFound, parsed.value.get(".nonexistent"));
}

test "get: error.FieldNotFound for unknown nested field" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.FieldNotFound, parsed.value.get(".model.nonexistent"));
}

test "get: error.NotPrimitive for non-optional struct" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.NotPrimitive, parsed.value.get(".model"));
}

test "get: error.NotPrimitive for optional struct" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.NotPrimitive, parsed.value.get(".rate_limits"));
}

test "get: null for null optional struct" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/minimal.json");
    defer parsed.deinit();
    try std.testing.expectEqual(Primitive.null, try parsed.value.get(".rate_limits"));
}

test "get: error.NotPrimitive for nested struct" {
    const gpa = std.testing.allocator;
    const parsed = try parseSessionData(gpa, "tests/resources/session_data/good/complete.json");
    defer parsed.deinit();
    try std.testing.expectError(error.NotPrimitive, parsed.value.get(".context_window.current_usage"));
}
