# Peak — Claude development rules

Peak is a native iOS app for Roblox creators: live game metrics (CCU, revenue,
retention), ads/campaigns, groups, goals and tasks, alerts, Home/Lock Screen widgets
and Live Activities. Stack: Swift, SwiftUI, Swift Charts, SwiftData, WidgetKit,
ActivityKit, App Intents, UserNotifications/APNs, BackgroundTasks, Keychain, Roblox
OAuth 2.0, plus a backend that is the source of truth for shared/server data.

These APIs change every year. Do not build this app from generic model memory —
consult the installed skills and current Apple documentation.

## 1. Skills are mandatory

Two skill packs are declared in `.claude/settings.json` and install when the project
is trusted (or run `scripts/install-skills.sh`):

| Pack | Plugin | Role |
|---|---|---|
| Prisma Labs Apple Skills | `apple-skills@apple-skills` | Primary Apple knowledge: `ios-dev` router, `swiftui`, `hig`, concurrency, testing, SwiftData, WidgetKit, notifications, background tasks, XCUITest, Charts, perf audit |
| Build iOS Apps | `build-ios-apps@openai-build-ios-skills` | Practical tools: `ios-debugger-agent` (XcodeBuildMCP), `ios-app-intents`, ETTrace, memgraph leaks, SwiftUI perf audit, UI patterns, view refactor |

Project skills in `.claude/skills/`:
- `peak-feature-workflow` — the per-feature loop below. Use it for every meaningful feature or bug fix.
- `peak-release-gate` — the pre-release stress/QA gate. Use it before any TestFlight or App Store build.

Full policy, tiers and the feature→skill map: `docs/skills/SKILL_POLICY.md`.
Vetting record for the packs: `docs/skills/VETTING.md`.

### Skill usage rule (every meaningful feature)

1. Identify the technical areas the task touches.
2. Check which skills are installed.
3. Load only the relevant skills (start substantial iOS work with `ios-dev`). Don't load every skill for every task.
4. Follow their guidance while implementing.
5. Check that guidance against the deployment target (`apple-skills` is written for iOS 26+ — see §4).
6. Build the feature.
7. Run the relevant tests.
8. Run it in the Simulator when possible (`ios-debugger-agent`).
9. If it misbehaves, use the debugging/performance skills — don't guess.
10. Record architectural decisions in `docs/decisions/` and the skills report in `docs/DEV_LOG.md`.

### Skills report

At the start of each substantial feature, add an entry to `docs/DEV_LOG.md`:

```
Feature: Goal Widget
Skills: widgetkit, ios-app-intents, swiftui, swift-testing
Reason: WidgetKit implementation, configuration intent, UI, progress-calculation tests.
```

## 2. Skills don't own the project

- Skills are expertise, not architecture owners. Don't rewrite consistent existing
  architecture because a skill prefers a different one.
- If two skills disagree: (1) check current official Apple docs, (2) check the
  deployment target, (3) pick the best fit, (4) record why in `docs/decisions/`.
- Treat skills like dependencies. Don't install a new pack without vetting it
  (source, licence, what it ships — scripts, hooks, MCP servers) and recording it in
  `docs/skills/VETTING.md`. Don't add packs that overlap the two above.

## 3. Build → run → verify, in small steps

Never write thousands of lines and then try to compile. The loop is:

small feature → build → run in Simulator → inspect → test → checkpoint commit → next.

"It compiles" is not done. "It seems to work" is not done. Done means it was built,
run, interacted with, tested, and we tried to break it.

Simulator work needs macOS + Xcode. From a Linux/cloud session, verify through the macOS CI job
and its published screenshots (decision 0004), and state plainly what CI can't cover.

## 4. Current Apple API rule

For WidgetKit, ActivityKit, App Intents, SwiftUI, SwiftData, background execution and
notifications:
1. Read the relevant installed skill.
2. Check current Apple documentation when uncertain.
3. Confirm availability for the deployment target; gate newer APIs with `#available`.
4. Avoid deprecated patterns.
5. Don't assume the newest API exists on every supported iPhone.

Deployment target: **iOS 17.0, Swift 6 language mode** (decision 0002). Anything newer than
17.0 needs `#available` and a fallback.

## 5. Non-negotiable product/engineering facts

- **Widgets are not mini-apps.** They render cached snapshots on a timeline; design for
  stale data and show "updated X ago".
- **iOS does not grant arbitrary background execution.** Reliable Roblox monitoring and
  alert evaluation run server-side; the phone receives APNs pushes and Live Activity
  push updates.
- **Roblox OAuth refresh tokens rotate.** Concurrent requests that each see an expired
  access token must not each refresh — serialize refresh behind one actor/coordinator
  (client) and one lock per account (backend). Tokens live in the Keychain only.
  Use `swift-concurrency` + `guide-swift-concurrency`, and the `roblox-cloud` skill for
  Roblox OAuth scopes and token lifecycle.
- **No unowned detached tasks.** Every `Task` has a clear owner and cancellation path.
- **Backend is source of truth.** SwiftData is cache, preferences and offline queue only.

## 6. Project layout and commands

| Path | What |
|---|---|
| `Packages/PeakKit` | Platform-neutral logic: models, goal/alert engines, formatting, routes, snapshots, API client, auth coordinator, sample data. Builds and tests on Linux. |
| `App/` | SwiftUI app (`AppModel` is the single `@MainActor @Observable` state owner). |
| `Widgets/` | Widget extension. Reads `WidgetSnapshot` only, never the network. |
| `SharedUI/` | Views compiled into both the app and widgets. |
| `Tests/AppTests`, `Tests/UITests` | Swift Testing for app models; XCUITest journeys + screenshots. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated, not committed. |
| `Server/` | Backend: Swift 6.2 + Hummingbird + Postgres (decision 0005). Owns Roblox OAuth/tokens, polling, alerts, APNs. See `Server/README.md`. |

- Package tests anywhere: `cd Packages/PeakKit && swift test` (add `--sanitize=thread` for concurrency work).
  On Linux without a toolchain: `docker run --rm -v "$PWD":/pkg -w /pkg swift:6.1-noble swift test`.
- App on a Mac: `brew install xcodegen && xcodegen generate && open Peak.xcodeproj`.
- Server: `cd Server && swift test` (Swift 6.2). With Postgres: set `TEST_DATABASE_URL` and `REQUIRE_POSTGRES=1`.
  Without a toolchain: `Server/scripts/docker-test.sh`. Any change to `PeakKit` API types must keep
  `AppCompatibilityTests` green, because that's the app↔server contract check.
- Launch arguments for QA: `-demoMode normal|empty|failing`, `-colorScheme dark|light`,
  `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXL`.
- CI (`.github/workflows/peak.yml`) runs package tests on Linux (+TSan) and macOS, builds the app,
  runs unit + UI tests on a simulator, and uploads screenshots as the `peak-screenshots` artifact.
  Look at the screenshots: that's the visual QA pass when no Mac is available.

## 7. UI rules

- Reuse components (`MetricCard`, `GameCard`, `GoalCard`, `InsightCard`, `AlertRow`,
  `CampaignCard`, `LiveNowCard`, `EmptyState`, `LoadingCard`, `ErrorCard`). Don't
  create competing variants of the same idea (`swiftui-ui-patterns`).
- Use `hig` for predictable interactions while keeping Peak's own identity. HIG
  compliance doesn't prove the UI is intuitive — test it with real people.
- Charts stay visually simple (`guide-swiftui-charts`).
- Split views when they're hard to reason about, not to hit a line count (`swiftui-view-refactor`).
- Inspect rendered UI, not just code — see `docs/qa/VISUAL_QA.md`.

## 8. Release standard

No release because "it seems to work". The bar is: we tried to break it and it stayed
stable. Run `peak-release-gate` / `docs/qa/RELEASE_CHECKLIST.md` before every build that
leaves a developer's machine.
