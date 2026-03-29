const std = @import("std");

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
    used_percentage: ?u8,
    /// Pre-calculated percentage of context window remaining.
    remaining_percentage: ?u8,
    /// Token counts from the last API call.
    current_usage: ?TokenUsage,
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
    rate_limits: ?RateLimits,
    /// Vim mode configuration. Present when vim mode is enabled.
    vim: ?Vim,
    /// Agent configuration. Present when running with `--agent`.
    agent: ?Agent,
    /// Git worktree information. Present only during worktree sessions.
    worktree: ?Worktree,
};

comptime {
    std.debug.assert(@sizeOf(SessionData) == 432);
}

test SessionData {
    const gpa = std.testing.allocator;
    const input = try std.fs.cwd().readFileAlloc(gpa, "tests/resources/example.json", 1024 * 1024);
    defer gpa.free(input);
    const parsed = try std.json.parseFromSlice(SessionData, gpa, input, .{});
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
