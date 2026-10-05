# RBX Pulse — Skill Policy

Think of skills as specialised engineers to consult, not a single generic approach:

| Specialist | Owns |
|---|---|
| SwiftUI (`swiftui`, `swiftui-ui-patterns`) | Interface |
| HIG (`hig`) | Usability and system conventions |
| Concurrency (`swift-concurrency`, `guide-swift-concurrency`) | Async architecture, token refresh, sync jobs |
| Widgets (`widgetkit`, `ios-app-intents`) | Home/Lock Screen widgets, configuration |
| Notifications (`usernotifications`) | Permission, local/remote, actions, deep links |
| Testing (`swift-testing`, `guide-swift-testing`, `xcuitest`) | Trying to break the logic and the journeys |
| Debugger (`ios-debugger-agent`) | Reproducing bugs on the Simulator |
| Performance (`ios-ettrace-performance`, `swiftui-performance-audit`, `guide-swiftui-performance-audit`) | Profiling slow paths |
| Memory (`ios-memgraph-leaks`) | Finding leaks |

## Installed packs

### Primary — Prisma Labs Apple Skills (`apple-skills@apple-skills`)

```
claude plugin marketplace add Prisma-Labs-Dev/apple-skills
claude plugin install apple-skills@apple-skills
```

| Skill | Use for |
|---|---|
| `ios-dev` | Router/coordinator. Consult at the start of substantial iOS work. Its Correctness Checklist counts as bugs. |
| `swiftui` | Home, Games, Ads, Groups, Goals, cards, feeds, navigation, sheets, context menus, animations, lists, scrolling, state-driven UI. |
| `hig` | Navigation, hierarchy, button placement, gestures, modals, tab bars, accessibility, touch targets, typography. |
| `swift-concurrency` | async/await, actors, API requests, concurrent Roblox sync, cancellation, task groups, data-race safety. |
| `guide-swift-concurrency` | Architecture decisions — especially OAuth refresh-token rotation. |
| `swift-testing` | Unit tests: calculations, alert engine, goal engine, caching, parsers, repositories, API models, utilities. |
| `guide-swift-testing` | Designing tests that try to break the code, not just compile. |
| `xcuitest` | End-to-end journeys (see list below). |
| `swiftdata` / `guide-swiftdata` | Dashboard cache, preferences, recent searches, favourites cache, offline actions, notes/task cache; migrations and data lifecycle. |
| `widgetkit` | Home/Lock Screen widgets, configurable favourite-game, goal and portfolio widgets, timeline refresh. |
| `usernotifications` | Permission flow, local/remote, actions, categories, deep links, foreground handling. |
| `backgroundtasks` | Any iPhone-side background scheduling — and knowing its limits. |
| `guide-swiftui-charts` | CCU, revenue, retention, campaign, goal-trend and comparison charts; chart touch interaction. |
| `guide-swiftui-performance-audit` | Once real feeds/lists/charts exist: rerenders, expensive bodies, state placement, image loading, animation cost. |

Also available in the pack and usable when relevant: `apple-docs-index`, `tipkit`,
`corehaptics`, `storekit`, `ios-liquid-glass`, `uikit`, `core-animation`.

### Secondary — Build iOS Apps (`build-ios-apps@openai-build-ios-skills`)

```
claude plugin marketplace add mtfum/openai-build-ios-skills
claude plugin install build-ios-apps@openai-build-ios-skills
```

| Skill | Use for |
|---|---|
| `ios-debugger-agent` | **Constantly.** Build, launch on Simulator, interact, read logs, reproduce bugs. Uses the bundled XcodeBuildMCP server. |
| `ios-app-intents` | Widget configuration, Shortcuts, Siri, quick actions, entities ("Open Attack Animals", "Show my current CCU", "Start Creator Focus"). Expose only appropriate actions. |
| `ios-ettrace-performance` | Profiling Home scroll, opening Games, game analytics, chart range switching, search, 100+ games, large datasets. Profile, don't guess. |
| `ios-memgraph-leaks` | **Mandatory before production.** Stress navigation, charts, images, Live Activities, sheets, search, game detail, repeated refresh; compare memgraphs. |
| `swiftui-performance-audit` | Optimisation passes — especially the Home feed. |
| `swiftui-ui-patterns` | Reusable components; one version of each idea. |
| `swiftui-view-refactor` | When a view is hard to reason about. |

### Already available to this account (not a pack)

| Skill | Use for |
|---|---|
| `roblox-cloud` | Roblox Open Cloud APIs, OAuth 2.0 scopes, token lifecycle, webhooks — backend + OAuth work. |
| `roblox-analytics`, `roblox-growth-design` | Shaping which metrics/insights RBX Pulse surfaces and how creators read them. |

### Optional — generator skills (not installed)

Useful areas: networking-layer, push-notifications, deep-linking, test-generator,
preview-data-generator, accessibility-generator, widget-generator,
live-activity-generator, feature-flags, http-cache, error-monitoring, logging, CI/CD,
offline queues.

These are **not installed** because no specific pack has been vetted yet. Before adding
one: vet it per "Adding a skill pack" below and record it in `VETTING.md`. When used,
treat generated code as a starting point — never accept its architecture blindly.

## Priority tiers

| Tier | Skills |
|---|---|
| 1 — use constantly | `ios-dev`, `swiftui`, `hig`, `swift-concurrency`, `swift-testing`, `ios-debugger-agent` |
| 2 — very important | `swiftdata`, `widgetkit`, `usernotifications`, `xcuitest`, `guide-swiftui-charts`, `ios-app-intents`, `backgroundtasks` |
| 3 — QA / hardening | `swiftui-performance-audit`, `ios-ettrace-performance`, `ios-memgraph-leaks`, `guide-swiftui-performance-audit` |
| 4 — feature specific | Live Activities, deep linking, HTTP caching, accessibility, preview data, feature flags, CI/CD, error monitoring |

## Feature → skill map

| Feature | Build with | Then |
|---|---|---|
| Home | `ios-dev`, `swiftui`, `hig`, `swiftui-ui-patterns` | `swiftui-performance-audit` |
| Charts | `swiftui`, `guide-swiftui-charts`, `hig` | ETTrace if chart-heavy |
| OAuth | `swift-concurrency`, `guide-swift-concurrency`, `roblox-cloud`, Keychain/security docs, `swift-testing` | Race-condition tests (N concurrent callers, one refresh) |
| Widgets | `widgetkit`, `ios-app-intents`, `hig` | All sizes, stale data, no data, placeholder |
| Live Activities | Current ActivityKit docs, `usernotifications` (APNs) | Background + terminated-app behaviour |
| Notifications | `usernotifications`, deep-linking guidance | Notification stress tests |
| Local persistence | `swiftdata`, `guide-swiftdata` | Migration tests |
| Async Roblox sync | `swift-concurrency`, `guide-swift-concurrency` | Deliberately stress simultaneous operations |
| Goals | `swiftui`, `swift-testing`, `guide-swift-testing` | Heavy unit coverage of goal maths |
| Social-style UI | `swiftui`, `hig` | Real usability testing |
| Bug investigation | `ios-debugger-agent` | perf → ETTrace · memory → memgraph · SwiftUI stutter → perf audit · concurrency → `swift-concurrency` |

### XCUITest journeys to automate

Connect Roblox · favourite a game · mark Working On · create goal · complete task ·
open ad · configure alert · widget deep-link routes · error handling.

## Adding a skill pack

Skills are third-party instructions and sometimes code. Before installing:

1. Read the source: `SKILL.md` files, any `scripts/`, hooks, and `.mcp.json`.
2. Check licence, maintainer and activity.
3. Check overlap with existing packs — don't stack several SwiftUI packs; overlapping
   packs produce conflicting architecture advice.
4. Check the API baseline it assumes against our deployment target.
5. Record the result in `VETTING.md`, then add it to `.claude/settings.json`.

## Conflicts

Official Apple docs > deployment-target reality > skill opinion. Existing consistent
project architecture beats a skill's preferred architecture. Record every resolved
conflict as a decision in `docs/decisions/`.
