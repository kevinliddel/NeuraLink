# Contributing to NeuraLink

Thank you for your interest in contributing to **NeuraLink**! 🎉  
This document describes everything you need to know to get your changes merged cleanly and quickly.

---

## Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Coding Standards](#coding-standards)
- [Branch & Commit Conventions](#branch--commit-conventions)
- [Pull Request Process](#pull-request-process)
- [Writing Tests](#writing-tests)
- [Reporting Bugs](#reporting-bugs)
- [Suggesting Features](#suggesting-features)
- [VRM Spec Compliance](#vrm-spec-compliance)

---

## Getting Started

1. **Fork** the repository and clone your fork:
   ```bash
   git clone https://github.com/<your-username>/NeuraLink.git
   cd NeuraLink
   ```

2. Open the project in Xcode 16+:
   ```bash
   open NeuraLink.xcodeproj
   ```

3. Build and run on a physical device or simulator running **iOS 17.0+**.  
   No CocoaPods or Swift Package Manager bootstrap is required — all dependencies are vendored or built from source.

---

## Development Setup

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| Xcode | 16.0 | Build, sign, deploy |
| Swift | 6.0 | Language version |
| SwiftLint | 0.57+ | Style enforcement |
| iOS Simulator / Device | iOS 17.0+ | Run target |

### Install SwiftLint

```bash
brew install swiftlint
```

After every coding session, run:

```bash
swiftlint lint --strict
```

Fix **all** reported violations before opening a Pull Request. The CI pipeline enforces `--strict` mode and will block merging if any lint error or warning is present.

---

## Project Structure

```
NeuraLink/
├── AI/              — OpenAI Realtime WebSocket manager, Silero VAD, chat state
├── Sky/             — Realtime sky system (time provider, palette, renderer, uniforms)
├── Terrain/         — Snow terrain renderer, shadow passes
├── VRM/             — VRM loader, MToon shaders, Spring-Bone physics, animation
│   └── Shaders/     — All .metal shader files
├── UI/              — SwiftUI views, model selection, chat overlay
└── Models/          — Bundled .vrm, .vrma, and character assets
docs/                — Project documentation and screenshots
```

Each module lives in its own folder. **Do not** mix concerns across folders — a change to the sky system should not touch VRM loader files, and vice versa.

---

## Coding Standards

These rules are **mandatory** and enforced by both SwiftLint and code review:

### File Size
- **Maximum 500 lines per file.** If a file grows beyond this limit, split it following clean-architecture principles before submitting your PR.

### Complexity
- Keep **cyclomatic complexity ≤ 10** per function.
- Keep **cognitive complexity low** — prefer early returns, named helpers, and flat logic over deeply nested conditionals.

### Architecture
- Follow the existing module boundaries (Sky, VRM, Terrain, AI, UI).
- Shared GPU data structures must have matching Swift and Metal definitions with explicit byte offsets documented in comments (see `SkyUniforms.swift` as a reference).

### Swift Style
- Use `// MARK: -` sections to organise code within files.
- Prefer `private` / `fileprivate` over `internal` wherever possible.
- Avoid force-unwraps (`!`). Use `guard let` or `if let` with a logged fallback.
- No `print()` in production paths — use `vrmLog()` so log lines can be toggled off.

### Metal Shaders
- Every shader file must open with a comment block explaining its purpose and the coordinate conventions used.
- Uniform structs must document their byte size and offset of each field.
- Keep GPU helper functions `static` and prefixed with the shader domain (e.g., `skyHash`, `terrainNoise`) to avoid name collisions in the unified Metal library.

---

## Branch & Commit Conventions

### Branch Names

| Type | Pattern | Example |
|------|---------|---------|
| Feature | `feat/<short-description>` | `feat/cloud-shadow-casting` |
| Bug fix | `fix/<short-description>` | `fix/night-ambient-flicker` |
| Docs | `docs/<short-description>` | `docs/sky-system-guide` |
| Refactor | `refactor/<short-description>` | `refactor/vrm-loader-split` |
| Test | `test/<short-description>` | `test/sky-palette-edge-cases` |

### Commit Messages

Follow the **Conventional Commits** specification:

```
<type>(<scope>): <short summary>

[optional body]

[optional footer]
```

**Types:** `feat` · `fix` · `docs` · `refactor` · `test` · `chore` · `perf`  
**Scopes:** `sky` · `vrm` · `terrain` · `ai` · `ui` · `shaders` · `ci`

**Examples:**
```
feat(sky): add cirrus cloud high-altitude layer
fix(terrain): clear shadow map on model removal to remove stale shadow
docs(sky): add time-of-day reference table
refactor(vrm): split VRMLoader into parser and builder modules
```

- Limit the subject line to **72 characters**.
- Write in the **imperative mood** ("add", "fix", "remove" — not "added", "fixed", "removed").
- Reference issues with `Closes #<number>` in the footer when applicable.

---

## Pull Request Process

1. **Rebase** on the latest `main` before opening your PR:
   ```bash
   git fetch origin
   git rebase origin/main
   ```

2. Ensure all of the following pass locally:
   - `swiftlint lint --strict` — zero warnings, zero errors.
   - The Xcode build succeeds on the simulator (`Cmd+B`).
   - All unit tests pass (`Cmd+U`).

3. Open the PR against `main`. Fill in the **PR template** completely:
   - What problem does this solve?
   - How was it tested?
   - Screenshots / recordings (for visual changes — required for Sky, Terrain, and UI changes).

4. At least **one maintainer review** is required before merging.

5. PRs are merged with **Squash and Merge** to keep `main` history linear.

> **Draft PRs** are welcome for work-in-progress feedback. Prefix the title with `[WIP]`.

---

## Writing Tests

Tests live in `NeuraLinkTests/`. The project uses **XCTest**.

### Unit Test Rules
- Every new public function in `Sky/`, `VRM/`, and `AI/` should have a corresponding unit test.
- Use `SkyTimeProvider`'s injectable `now` closure pattern to freeze time in sky tests rather than sleeping.
- Mock Metal device creation with `MTLCreateSystemDefaultDevice()` guarded by `try XCTSkipIf(device == nil)` on CI where GPU is unavailable.
- Test file names must mirror the source file: `SkyColorPaletteTests.swift` tests `SkyColorPalette.swift`.

### Running Tests
```bash
# From Xcode
Cmd + U

# From command line
xcodebuild test -scheme NeuraLink -destination 'platform=iOS Simulator,name=iPhone 16'
```

All tests must pass before a PR can be merged.

---

## Reporting Bugs

Open a **GitHub Issue** using the **Bug Report** template. Include:

- iOS version and device (or simulator model).
- Steps to reproduce — be specific.
- Expected behaviour vs actual behaviour.
- Xcode console logs (redact your OpenAI API key if present).
- A screen recording if the bug is visual.

---

## Suggesting Features

Open a **GitHub Issue** using the **Feature Request** template. Describe:

- The problem you're trying to solve (not just the solution).
- How the feature fits the project's scope (VRM character viewer + AI companion).
- Any prior art or references (e.g., VRM spec links, rendering papers).

For significant changes, open an issue **before** writing code so we can align on design.

---

## VRM Spec Compliance

NeuraLink is built against the official VRM ecosystem. All contributions touching VRM loading, materials, physics, or animation must remain compliant with the specs below:

| Area | Spec |
|------|------|
| Core model | [VRM 1.0](https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_vrm-1.0) · [VRM 0.x](https://github.com/vrm-c/vrm-specification/tree/master/specification/0.0) |
| Materials | [MToon 1.0](https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_materials_mtoon-1.0) |
| Physics | [Spring-Bone 1.0](https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_springBone-1.0) |
| Animation | [VRM Animation 1.0](https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_vrm_animation-1.0) |

Both VRM 0.x and 1.0 must continue to load correctly after any VRM-related change. Add regression tests for both versions when modifying the loader.

---

Thank you for helping make NeuraLink better! 🌸
