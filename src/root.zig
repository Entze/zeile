const std = @import("std");

pub const Model = struct {
    id: []const u8,
    display_name: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(Model) == 32);
}

pub const Workspace = struct {
    current_dir: []const u8,
    project_dir: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(Workspace) == 32);
}

pub const OutputStyle = struct {
    name: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(OutputStyle) == 16);
}

pub const Cost = struct {
    total_cost_usd: f64,
    total_duration_ms: u64,
    total_api_duration_ms: u64,
    total_lines_added: u64,
    total_lines_removed: u64,
};

comptime {
    std.debug.assert(@sizeOf(Cost) == 40);
}

pub const TokenUsage = struct {
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_input_tokens: u64,
    cache_read_input_tokens: u64,
};

comptime {
    std.debug.assert(@sizeOf(TokenUsage) == 32);
}

pub const ContextWindow = struct {
    total_input_tokens: u64,
    total_output_tokens: u64,
    context_window_size: u64,
    used_percentage: ?u8,
    remaining_percentage: ?u8,
    current_usage: ?TokenUsage,
};

comptime {
    std.debug.assert(@sizeOf(ContextWindow) == 72);
}

pub const RateLimitWindow = struct {
    used_percentage: f64,
    resets_at: u64,
};

comptime {
    std.debug.assert(@sizeOf(RateLimitWindow) == 16);
}

pub const RateLimits = struct {
    five_hour: ?RateLimitWindow,
    seven_day: ?RateLimitWindow,
};

comptime {
    std.debug.assert(@sizeOf(RateLimits) == 48);
}

pub const VimMode = enum {
    NORMAL,
    INSERT,
};

comptime {
    std.debug.assert(@sizeOf(VimMode) == 1);
}

pub const Vim = struct {
    mode: VimMode,
};

comptime {
    std.debug.assert(@sizeOf(Vim) == 1);
}

pub const Agent = struct {
    name: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(Agent) == 16);
}

pub const Worktree = struct {
    name: []const u8,
    path: []const u8,
    branch: ?[]const u8,
    original_cwd: []const u8,
    original_branch: ?[]const u8,
};

comptime {
    std.debug.assert(@sizeOf(Worktree) == 80);
}

pub const SessionData = struct {
    cwd: []const u8,
    session_id: []const u8,
    transcript_path: []const u8,
    model: Model,
    workspace: Workspace,
    version: []const u8,
    output_style: OutputStyle,
    cost: Cost,
    context_window: ContextWindow,
    exceeds_200k_tokens: bool,
    rate_limits: ?RateLimits,
    vim: ?Vim,
    agent: ?Agent,
    worktree: ?Worktree,
};

comptime {
    std.debug.assert(@sizeOf(SessionData) == 432);
}
