## Development

- Use `mise exec -- hk fix` to format and apply fixes suggested by linters
- Use `mise exec -- hk check` to present issues that have to be fixed manually
- Use `mise exec -- hk run lint` to run checks that are executed during CI for PR QA
- `zig std` does not emit any information, instead it starts a webserver and opens the browser, you cannot use it for reference. Directly use the zig source code instead.

## Style Guide

### Naming

- Avoid redundancy in names
  - Value
  - Data
  - Context
  - Manager
  - utils, misc, or somebody's initials
  Everything is a value, all types are data, everything is context, all logic manages state. Nothing is communicated by using a word that applies to all types.

  Temptation to use "utilities", "miscellaneous", or somebody's initials is a failure to categorize, or more commonly, overcategorization. Such declarations can live at the root of a module that needs them with no namespace needed.
- Avoid Redundant Names in Fully-Qualified Namespaces
  Every declaration is assigned a fully qualified namespace by the compiler, creating a tree structure. Choose names based on the fully-qualified namespace, and avoid redundant name segments. For example an enum in the namespace `json` does not need the prefix `Json` in `JsonValue` instead only call it `Value` so at call site it becomes `json.Value`.
- Put the most significant and specific information in names first, units last. For example `input_bytes_max` instead of `max_input_bytes` and `latency_ms_max` instead of `max_latency_ms`.

### Documentation

- Omit any information that is redundant based on the name of the thing being documented.
- Duplicating information onto multiple similar functions is encouraged because it helps IDEs and other tools provide better help text.
- Use the word **assume** to indicate invariants that cause unchecked Illegal Behavior when violated.
- Use the word **assert** to indicate invariants that cause safety-checked Illegal Behavior when violated.

### Commit Messages

- Commit messages have a header, a body and a footer
- Aim for 50 characters for the header (soft-limit)
- The header has to fit within 72 characters (hard-limit)
- The header is a proper sentence without punctuation (no conventional commits)
- The header uses imperative mood
- The header explains the _what_ of the commit
- The body is a proper paragraph hard-wrapped at 72, characters
- The body focuses und the _why_ and the non-obvious _what_
- The footer is for references to commits (`Refs: #N`) and attribution
- If you commit on behalf of the user attribute the agent used to author the code (not necessarily the commit, `Co-authored-by: Claude MODEL VERSION <noreply@anthropic.com>`)
- If you commit as claude (check the git config) attribute the user (Co-authored-by: Lukas Grassauer <lukas@grassauer.eu>)
