---
name: release
description: >
  Create a RELEASE.txt file for the current branch that describes the changes
  since branching off main. Use this skill whenever the user mentions creating
  a release, writing release notes, preparing a RELEASE.txt, bumping a version,
  or wants to describe what changed on their branch for the changelog. Also
  trigger when the user says "/release" or asks about PATCH/MINOR/MAJOR levels.
---

# Release Notes Generator

Create a RELEASE.txt at the repo root. This file feeds the CD pipeline: after
merging to main, its contents are prepended to CHANGELOG.md and RELEASE.txt is
deleted. Every branch creates RELEASE.txt from scratch.

## Format

```
LEVEL
Short overview of the release

- Bullet point of a user-facing or developer-facing change
- Another change
```

- **Line 1**: exactly one of `PATCH`, `MINOR`, or `MAJOR`
- **Line 2**: a brief phrase (a few words) summarizing the release
- **Remaining lines**: bullet points of changes relevant to users or major
  internal changes relevant to developers. Use markdown sparingly.
- The file ends with a single trailing newline.

The semantic version level follows [semver](https://semver.org/):
- **PATCH** — bug fixes, internal improvements, no new features
- **MINOR** — new features, backwards-compatible additions
- **MAJOR** — breaking changes to the public interface

## Workflow

1. **Parse the argument.** The user may pass the level as an argument
   (e.g., `/release PATCH`). If no level is given, ask which level applies.

2. **Gather context.** Run these in parallel:
   - `git log main..HEAD --oneline` — commits since branching off main
   - `git diff main..HEAD --stat` — files changed
   - Read the first ~30 lines of `CHANGELOG.md` for style reference

3. **Compose the file.** Summarize the commits into a short overview line and
   bullet points. Focus on *what changed for the user* rather than echoing
   commit messages verbatim. Group related commits into single bullets when
   it makes sense. Keep the tone consistent with existing changelog entries.

4. **Write `RELEASE.txt`** at the repo root.

## Examples

A minimal patch:
```
PATCH
Fix a small bug
```

A minor release:
```
MINOR
Add a new feature
```

A major release with extra context:
```
MAJOR
Breaking change

Multi-paragraph notes.
```

A real-world patch:
```
PATCH
Improve release and changelog scripts

- Stream RELEASE.txt and CHANGELOG.md line by line instead of reading entirely into memory
- Move action_validator from checkers to linters in hk config
- Add unit tests and test fixtures for release and changelog scripts
- Reorganize test resources into subdirectories
```
