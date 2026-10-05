# RBX Pulse development log

One entry per substantial feature. Write the skills report **before** coding, then
update the entry with what was verified.

```
## YYYY-MM-DD — <Feature>
Skills: <skill>, <skill>
Reason: <why each skill applies>
Deployment-target notes: <#available gates, or "none">
Verified: built ☐ ran on Simulator ☐ tests ☐ visual QA ☐ device ☐
Not verified / why:
Decisions: <links to docs/decisions/NNNN>
```

---

## 2026-10-05 — Project setup: skill-driven development

Skills: skill-creator (writing the project skills)
Reason: Set up `CLAUDE.md`, the plugin declarations, the skill policy and vetting
record, and the `rbx-feature-workflow` and `rbx-release-gate` project skills.
Deployment-target notes: target not yet chosen. This blocks the first feature; see decision 0001.
Verified: both packs cloned and inspected (marketplace/plugin names, licences, scripts,
MCP server). No iOS code exists yet, so there was nothing to build.
Not verified / why: plugin auto-install from `.claude/settings.json` needs a
local Claude Code session to confirm.
Decisions: [0001](decisions/0001-adopt-skill-packs.md)

## 2026-10-05 — Slice 1: RBXPulseKit core (models, engines, formatting, deep links, snapshots)

Skills: ios-dev, guide-swift-testing, swift-testing, guide-swift-concurrency
Reason: ios-dev for routing and the correctness checklist; Swift Testing guides for idiomatic,
parameterized edge-case tests; concurrency guide for Sendable models and the
reentrancy-safe snapshot store.
Deployment-target notes: Foundation only. Builds on Linux, so it compiles and is tested in the
Swift 6.1 Docker image and on CI.
Verified: 60 tests passing in the Swift 6.1 container. Mutation check: changing the at-risk tolerance and
the K→M rounding promotion each made the tests fail, so they bite. The determinism test caught random
goal-task IDs in sample data (would also break SwiftUI identity); fixed.

## 2026-10-05 — Slice 2: Auth session + API client

Skills: guide-swift-concurrency (actors.md, bug-patterns.md, cancellation), swift-concurrency,
roblox-cloud, guide-swift-testing (async-tests.md)
Reason: single-flight rotating-token refresh is the main race in the app; roblox-cloud
covers the OAuth/PKCE/rotation rules; async tests prove one refresh under N concurrent callers.
Deployment-target notes: Keychain store is `#if canImport(Security)`.
Verified: 100 concurrent callers → exactly 1 refresh; 30 concurrent 401s → 1 refresh; sign-out and sign-in
during an in-flight refresh; cancelled caller doesn't abort the shared refresh. 20 repeated runs (0 flakes)
and ThreadSanitizer clean, locally and on CI (Linux). Mutation check: removing the single-flight guard
caused 100 refreshes and 5 failing tests. Package also passes on macOS CI (Keychain store compiles).

## 2026-10-05 — Slice 3: iOS app shell, Home/Games/Goals/Ads/Alerts, game chart, widgets

Skills: ios-dev (correctness checklist), swiftui-ui-patterns (app-wiring, async-state), hig (44pt targets,
tab count, Dynamic Type), guide-swiftui-charts (chartXSelection, RuleMark, accessible labels), widgetkit,
ios-app-intents (widget configuration), xcuitest (smoke journeys + screenshots)
Reason: first runnable app; widget must read the cached snapshot only; charts must stay simple and accessible.
Deployment-target notes: iOS 17 APIs only (`@Observable`, `chartXSelection`, `AppIntentConfiguration`,
`containerBackground`). Nothing newer than 17.0 is used, so no `#available` gates yet.
Verified (CI, macos-15 runner): app + widget extension compile under Swift 6 strict concurrency; app
unit tests and XCUITest journeys run on a simulator; 14 screenshots reviewed (light, dark, empty, error,
accessibility XXL, every tab, game chart, goal detail).
Found by visual QA: every screen overflowed the right edge by ~4% on the "iPhone Air" simulator (window wider
than screen, even system List/search field), so it's a simulator/SDK compatibility mode, not our layout. CI now pins a
plain "iPhone NN" device and `testContentFitsScreenWidth` guards it. Also fixed: unequal metric-card heights,
duplicated goal title.
First compile failure on CI was a bad find-and-replace of mine (`statusColor`). Lesson: no blind replaces.
Not verified: widgets on a Home Screen (WidgetKit timelines need a device or manual simulator check),
App Group sharing (CI builds unsigned), physical device.
Decisions: [0002](decisions/0002-deployment-target.md), [0003](decisions/0003-architecture-and-auth.md)
