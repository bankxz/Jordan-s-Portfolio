# 0004 — Verifying iOS work from a session without a Mac

- **Date:** 2026-10-05
- **Status:** accepted
- **Skills consulted:** rbx-feature-workflow, guide-swift-testing, xcuitest, ios-debugger-agent (not runnable on Linux)

## Context

Claude often works on RBX Pulse from Linux cloud sessions, where there's no Xcode, Simulator or
XcodeBuildMCP, so `ios-debugger-agent` can't run there. The project rule is "build it, run it, look at
it", and "it compiles" doesn't count as done.

## Decision

Three layers, from fastest to slowest:

1. **Package logic locally:** `docker run --rm -v "$PWD":/pkg -w /pkg swift:6.1-noble swift test`
   (a registry mirror such as `mirror.gcr.io/library/swift:6.1-noble` works when Docker Hub rate-limits).
   Add `--sanitize=thread` for concurrency work.
2. **App on CI:** `.github/workflows/rbx-pulse.yml` on `macos-15`. It generates the project with
   XcodeGen, builds the app + widget extension, and runs Swift Testing + XCUITest on a plain
   "iPhone NN" simulator.
3. **Visual QA on CI output:** UI tests save named screenshots (light, dark, empty, error, accessibility
   XXL, every tab, deep links). CI publishes them, with `summary.txt` and `test-summary.json`, to the
   `ci-screenshots/<branch>` branch, because artifact downloads go through blob storage the
   session proxy blocks. Fetch the branch and look at every image.

On a Mac, `ios-debugger-agent` (XcodeBuildMCP) stays the primary loop, and CI is the backstop.

## Alternatives considered

- **Trust compilation only** — rejected. The first green build still had a window wider than the screen
  and numbers wrapping mid-value at accessibility sizes; only screenshots revealed them.
- **Artifacts only** — not reachable from cloud sessions (blob storage blocked).

## Consequences

- `ci-screenshots/*` branches are force-pushed on every run; they're disposable and never merged.
- One CI round trip is about 10–15 minutes, so batch small fixes and use package tests for fast iteration.
- Not covered by CI: widgets on a real Home Screen, App Group sharing (CI builds unsigned), push
  notifications, physical-device performance and memory. Those stay on the release gate.
