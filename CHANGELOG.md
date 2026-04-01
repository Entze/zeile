# Changelog

All notable changes to this project will be documented in this file.

This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and uses a continuous
release process.

## 0.1.3

Add a comprehensive README with \<makeareadme.com> as template

## 0.1.2

Improve release and changelog scripts

- Stream RELEASE.txt and CHANGELOG.md line by line instead of reading entirely
  into memory
- Move action_validator from checkers to linters in hk config
- Add unit tests and test fixtures for release and changelog scripts
- Reorganize test resources into subdirectories

## 0.1.1

Fix issue in CD pipeline to actually publish releases.

## 0.1.0

Add CD pipeline for automated releases

Zeile is a status line formatter for Claude Code sessions. It reads session
metadata from stdin and renders a compact, color-coded status line showing cost,
token usage, rate limits with countdown timers, and context window utilization.
It includes a progress bar renderer with multi-stage animations.

This release introduces an automated CD pipeline: merging a RELEASE.txt to main
triggers version bumping, changelog updates, binary builds (x86_64 linux-gnu and
linux-musl), and a GitHub release with uploaded artifacts.
