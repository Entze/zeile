# 📝 zeile

A compact, color-coded status line formatter for Claude Code sessions.

[![CI](https://github.com/Entze/zeile/actions/workflows/ci.yml/badge.svg)](https://github.com/Entze/zeile/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE.txt)
[![Version](https://img.shields.io/github/v/release/Entze/zeile)](https://github.com/Entze/zeile/releases/latest)

📝 zeile reads Claude Code session metadata from stdin as JSON and renders a
compact, color-coded status line showing the current model, session cost, lines
changed, 5-hour and 7-day rate limit windows with countdown timers and progress
bars, and context window utilization.

Written in ⚡ Zig, zeile works both as a standalone CLI application and as a
reusable library that other ⚡ Zig programs can depend on.

## Example output

```
Claude Opus [$0.01] [+156-23]
[5D: [##/       ]  23.5%  1h23m] [7D: [####.     ]  41.2%  3d12h] [CTX: [v         ]   8%]
```

Colors adjust automatically:

| Range  | 5-hour window | 7-day window | Context window |
| ------ | ------------- | ------------ | -------------- |
| Green  | < 66.6 %      | < 75 %       | < 50 %         |
| Yellow | ≥ 66.6 %      | ≥ 75 %       | ≥ 50 %         |
| Red    | ≥ 88.8 %      | ≥ 90 %       | ≥ 65 %         |

## Installation

### Application

**Recommended — using [mise](https://mise.jdx.dev/):**

```sh
mise use "github:entze/zeile"
```

**Manual — download a pre-built binary from the
[latest release](https://github.com/Entze/zeile/releases/latest):**

```sh
# Linux x86_64, dynamically linked (glibc)
curl -Lo zeile https://github.com/Entze/zeile/releases/latest/download/zeile-x86_64-linux-gnu
chmod +x zeile

# Linux x86_64, statically linked (musl)
curl -Lo zeile https://github.com/Entze/zeile/releases/latest/download/zeile-x86_64-linux-musl
chmod +x zeile
```

### Library

Requires ⚡ Zig 0.15.2 or later. Add zeile as a dependency with
[`zig fetch`](https://ziglang.org/documentation/master/#zig-fetch):

```sh
zig fetch --save "https://github.com/Entze/zeile/archive/refs/tags/v0.1.2.tar.gz"
```

Then wire the module into your `build.zig`:

```zig
const zeile_dep = b.dependency("zeile", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zeile", zeile_dep.module("zeile"));
```

## Usage

### Application

Configure Claude Code to invoke zeile as its status line renderer by adding a
`statusLine` entry to `~/.claude/settings.json` (user-wide) or
`.claude/settings.json` (project):

```json
{
  "statusLine": {
    "type": "command",
    "command": "zeile"
  }
}
```

Claude Code pipes a JSON object with session metadata to zeile on every update.
You can also test zeile manually:

```sh
echo '{
  "cwd": "/project",
  "session_id": "abc123",
  "transcript_path": "/project/.claude/transcript.jsonl",
  "model": { "id": "claude-opus-4-6", "display_name": "Opus" },
  "workspace": { "current_dir": "/project", "project_dir": "/project" },
  "version": "1.0.80",
  "output_style": { "name": "default" },
  "cost": {
    "total_cost_usd": 0.01234,
    "total_duration_ms": 45000,
    "total_api_duration_ms": 2300,
    "total_lines_added": 156,
    "total_lines_removed": 23
  },
  "context_window": {
    "total_input_tokens": 15234,
    "total_output_tokens": 4521,
    "context_window_size": 200000,
    "used_percentage": 8,
    "remaining_percentage": 92
  },
  "exceeds_200k_tokens": false
}' | zeile
```

zeile exits with status 1 and prints a diagnostic to stderr on malformed input.

### Library

```zig
const std = @import("std");
const zeile = @import("zeile");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.fs.File.stdin().readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(input);

    const parsed = try std.json.parseFromSlice(
        zeile.SessionData,
        allocator,
        input,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const session = parsed.value;
    std.debug.print("model:   {s}\n", .{session.model.display_name});
    std.debug.print("cost:    ${d:.4}\n", .{session.cost.total_cost_usd});

    // Resolve any field by dot-separated path without manual optional unwrapping.
    const used = try session.get(".context_window.used_percentage");
    switch (used) {
        .byte => |pct| std.debug.print("context: {}%\n", .{pct}),
        .null => std.debug.print("context: n/a\n", .{}),
        else => unreachable,
    }
}
```

**`zeile.SessionData`** is a struct that mirrors the JSON Claude Code sends to
status line scripts. All optional fields default to `null` when absent from the
input. `SessionData.get(path)` resolves a dot-separated field path to a
`zeile.Primitive` union value, returning `.null` when any optional in the chain
is absent at runtime.

**`zeile.progressbar`** is a sub-module with a `format` function that renders
text-based progress bars with configurable width, fill characters, and
multi-stage animation segments. It can be used independently of the rest of the
library.

See the [source documentation](https://github.com/Entze/zeile/tree/main/src) and
the [latest release](https://github.com/Entze/zeile/releases/latest) for the
full API reference.

## Support

Open an issue on [GitHub](https://github.com/Entze/zeile/issues) to report a bug
or request a feature.

## Contributing

Bug reports and pull requests are welcome. Before submitting a patch:

```sh
mise exec -- hk fix                            # auto-format and apply linter fixes
mise exec -- hk check                          # surface issues requiring manual attention
mise exec -- zig build --summary all test      # run unit tests
```

## License

[GNU General Public License v3.0](LICENSE.txt)
