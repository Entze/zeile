# Changelog

All notable changes to this project will be documented in this file.

This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and uses a continuous
release process.

## 0.4.0

Rework color calculation

- Affordable rate is the unspent share divided by the hours until the window
  resets.
- Current rate is the spent share divided by the hours since the window opened,
  and zero when nothing is spent.
- pressure returns their ratio mapped to a value from 0 to 1, linear in the
  logarithm of the multiple. Green holds up to 1.15 times the affordable rate,
  yellow sits at 1.7 and red at 2.5 and beyond.

A ratio of exactly 1 means spending in lockstep with the clock, so a window
consumed linearly stays green for its whole life. An untouched window is always
green and an exhausted one is always red.

Also fix CD pipeline by including README.md in release patch.

## 0.3.0

Upgrade to zig 0.16.0

## 0.2.12

- Replace 5D with 5h
- Replace 7D with 7d

## 0.2.11

Update zizmor to v1.30.1

## 0.2.10

Update actions/github-script to v9

## 0.2.9

Update action-validator to v0.9.0

## 0.2.8

Update actionlint to v1.7.12

## 0.2.7

Update bump-my-version to v1.5.1

## 0.2.6

Update actions/checkout to v7

## 0.2.5

Update pkl to v0.32.1

## 0.2.4

Update pinact to v4

## 0.2.3

Update jdx/mise-action to v4.3.0

## 0.2.2

Update hk to v1.58.1

## 0.2.1

Activate Renovate[bot]

## 0.2.0

Add expression language for template rendering

- Add an expression language module (`expression.zig`) supporting variables and
  literals

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
