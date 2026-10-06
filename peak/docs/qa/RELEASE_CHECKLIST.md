# Release checklist

Copy to `docs/qa/releases/<version>.md` and fill in. Driven by the `peak-release-gate` skill.

Version: ______  Build: ______  Date: ______  Tester: ______

| # | Check | Skill | Result | Evidence |
|---|---|---|---|---|
| 1 | Swift Testing suite green | `swift-testing` | | |
| 2 | XCUITest suite green | `xcuitest` | | |
| 3 | Clean install + upgrade install on Simulator, logs clean | `ios-debugger-agent` | | |
| 4 | ETTrace on hot paths; no unexplained regression | `ios-ettrace-performance` | | |
| 5 | SwiftUI performance audit (Home feed) | `swiftui-performance-audit` | | |
| 6 | Memgraph comparison after repeated flows; no leaks | `ios-memgraph-leaks` | | |
| 7 | Widgets: all families, stale/empty/signed-out/error | `widgetkit` | | |
| 8 | Live Activities: backgrounded + terminated updates | ActivityKit docs | | |
| 9 | Notifications: permission, foreground/background, cold-start deep link, burst | `usernotifications` | | |
| 10 | OAuth: concurrent refresh → exactly one refresh; revoked token → clean sign-out | `swift-concurrency` | | |
| 11 | SwiftData migration from previous release | `guide-swiftdata` | | |
| 12 | Visual QA pass (`VISUAL_QA.md`) | `hig` | | |
| 13 | Physical iPhone pass | — | | |
| 14 | Crash/hang/MetricKit review of previous build | — | | |

**Verdict:** Ship / Hold. **Blocking items:**
