# Peak development log

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
record, and the `peak-feature-workflow` and `peak-release-gate` project skills.
Deployment-target notes: target not yet chosen. This blocks the first feature; see decision 0001.
Verified: both packs cloned and inspected (marketplace/plugin names, licences, scripts,
MCP server). No iOS code exists yet, so there was nothing to build.
Not verified / why: plugin auto-install from `.claude/settings.json` needs a
local Claude Code session to confirm.
Decisions: [0001](decisions/0001-adopt-skill-packs.md)

## 2026-10-05 — Slice 1: PeakKit core (models, engines, formatting, deep links, snapshots)

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
QA rounds 2–4 (CI screenshots on iPhone 17 / iOS 26.2, Xcode 16.4):
- Overflow fixed by the simulator change; `testContentFitsScreenWidth` passes.
- Deep-link UI test failed because `XCUIApplication.open(_:)` didn't deliver the custom-scheme URL. The
  screenshot showed the app still on Home. Switched to `XCUIDevice.shared.system.open(_:)` (the same
  path a widget tap takes), and it passes. Added `-openURL` launch routing as a second, OS-independent test.
- Accessibility XXL: game cards wrapped mid-number ("+9 / .7 / %"). Cards now stack vertically at
  accessibility sizes, and numbers don't wrap.
- Chart: the last x-axis label clipped at "now". Explicit marks at 20/50/80% of the range.
- Round 5: game detail at accessibility sizes uses one metric column, and chart axis text is capped at xLarge.
Result: CI run 37376194351 (commit 21fe261) is green. 24/24 app unit + UI tests on iPhone 17 / iOS 26.2,
95/95 package tests on Linux (+TSan) and macOS. All 18 screenshots reviewed.
Decisions: [0004](decisions/0004-verification-without-a-mac.md)

### Next slices (not started)
1. Connect Roblox: `ASWebAuthenticationSession` → backend `/v1/auth/roblox/start` → session exchange
   (needs the backend). Skills: swift-concurrency, roblox-cloud, xcuitest.
2. Backend service implementing `docs/api/backend-contract.md` (Swift, reusing PeakKit; server-side
   AlertEngine + APNs).
3. Notifications: permission flow, categories, deep links. Skills: usernotifications.
4. Live Activities ("Watch Game"): ActivityKit + push updates. Push-to-start needs `#available(iOS 17.2, *)`.
5. SwiftData cache for offline launch. Skills: swiftdata, guide-swiftdata.
6. Groups screen, goal/alert-rule editing.
7. Before the first TestFlight: peak-release-gate (ETTrace, memgraph, physical device).

## 2026-10-05 — Slice 4: Backend (Server/)

Skills: roblox-cloud (OAuth flow, token rotation, Open Cloud mechanics), roblox-security (server
authority, rate limiting, idempotency, secrets server-side), guide-swift-concurrency (single-flight
refresh, structured worker lifecycles), guide-swift-testing (async tests, concurrency stress)
Reason: the backend owns Roblox OAuth and rotating tokens — the riskiest code in the product.
Primary sources read first (Roblox/creator-docs): oauth2-reference, oauth2-develop, oauth2-registration,
analytics guide + metrics, Open Cloud openapi.json scopes. See decision 0005.
Deployment-target notes: server only (Linux, Swift 6.1). No iOS APIs.
Verified (local, Swift 6.2 container + Postgres 16 container):
- 89 server tests: config/crypto (incl. the RFC 7636 PKCE vector), the store contract suite against **both** stores,
  Roblox client request/response shapes from the documented payloads, the OAuth flow, session rotation, refresh
  reuse → family revocation, single-flight Roblox refresh (50 callers → 1 refresh), cross-instance CAS, routes
  (errors, rate limits, ownership isolation, rule hijack attempt), workers (batching, failure isolation, idempotent
  minute samples, alert edge + push + dead-token cleanup, revenue scope gating), APNs ES256 JWT verified with the
  public key, graceful periodic services.
- `AppCompatibilityTests`: the app's own PeakKit stack (APIClient, AuthSessionCoordinator,
  BackendTokenRefresher, URLSessionTransport) against the live server over HTTP: sign-in, dashboard, flags, series,
  transparent refresh after expiry, rules, reconnect (409), logout.
- ThreadSanitizer clean. Mutation checks: removing reuse detection, Roblox single-flight, or the Postgres CAS
  guard each fails the suite (CAS: 20 of 20 concurrent rotations "won" without it).
- Release binary smoke test against a fresh database: migrations applied (14 tables), authorize URL correct
  (S256 PKCE, scopes), forged state rejected, protected routes 401, 0 secret occurrences in logs.
Not verified: real Roblox endpoints (no egress to roblox.com from this environment; requests follow the
primary-source docs), real APNs delivery (needs an Apple key), the Docker image build (runs in CI).
Kit change: `APIError.reconnectRequired` (409) → app shows "Reconnect" (AppModel + tests updated).
Decisions: [0005](decisions/0005-backend.md)

## 2026-10-06 — Rename to Peak

Skills: hig (naming, icon), peak-feature-workflow
Reason: the owner chose "Peak"; the old name used Roblox's "RBX" abbreviation (see decision 0006).
Changes: every target, package, module, bundle ID, URL scheme, App Group, keychain service, token prefix,
project skill, CI workflow and doc renamed. `CreatorPulseCard` is now `LiveNowCard`. New app icon.
Verified (local): no old-name strings left (grep); PeakKit 95 tests (Swift 6.1 container); server 89 tests
against Postgres 16 (Swift 6.2 container). One rename slip was caught by the suite: an auth test expected
scheme `peak` instead of `peakstats`.
Verified in CI: the app build, simulator unit and UI tests, and screenshots (title "Peak").
Decisions: [0006](decisions/0006-rename-to-peak.md)

## 2026-10-06 — Slice 5: AI insights (V1 foundation)

Skills: claude-api (raw HTTP Messages API for Swift, structured outputs, refusal fallbacks, model/pricing),
roblox-cloud (read-only scopes, incremental consent), roblox-analytics (funnels/custom events need in-game
AnalyticsService logging), guide-swift-testing (edge cases: empty, flat, noisy, huge, DST), swiftui/hig (briefing
card, Ask screen; skills not installed in this cloud session, so the macOS CI job does the visual checks)
Reason: AI must be grounded in computed facts, label causes as possible, never act, and stay within a budget.
Deployment-target notes: none in PeakKit (Foundation only). Charts/SwiftUI in the app stay iOS 17.
Feasibility check: Open Cloud openapi.json and the Analytics supported-metrics page (2026-10-06). See
docs/ai/AI_FEATURES.md.
Decisions: [0007](decisions/0007-ai-layer.md)
Slice 5a (PeakKit engines, commit c8130dc): 52 new tests, mutation-checked (removing the crash-rate override or
loosening the number tolerance fails tests).
Slice 5b (server):
- Claude over raw HTTP: structured output, `fallbacks: "default"` for models that support it, refusal and
  `max_tokens` checked before content, cost from `usage`.
- AI service: consent, daily ask limit, monthly budget, number check, read-only Ask tool loop with assistant turns
  round-tripped unchanged (preserved thinking).
- Insight routes, briefing narration cache, update detection from the games API `updated` field, Postgres
  migration v2 (timeline_events, ai_consents, ai_usage).
- Verified locally: 109 server tests in memory and against Postgres 16 (run twice against the same database);
  the app's RemoteInsightService against the live server in AppCompatibilityTests; mutation checks (removing the
  number check, the consent check or the half-open sample window each fails tests).
- Found while testing: a closed sample window averaged the previous half hour into "now", reporting a 40% drop
  as 20%. Fixed with a half-open window.
- Not verified: real Claude API calls (no key in this environment; request shape follows the claude-api skill),
  and whether Roblox's `updated` changes only on publish.
Slice 5c (app):
- InsightsModel (separate from AppModel, so a failed insight never blanks the dashboard).
- Today's briefing card on Home and a full Briefing screen. Facts show exact numbers; AI summaries are marked "AI".
- Ask Peak sheet with an AI consent screen (what's sent, to whom, numbers checked, AI never changes anything).
- "Unusual now" digests on Alerts, with possible causes labelled as such, a next step, and a shareable Claude prompt.
- Update impact card on game detail and portfolio health on Games.
- Goal planner sheet on Goals: on-device, offline, no AI.
- Demo mode uses DemoInsightService, so CI screenshots show every state.
- Unit tests for InsightsModel. UI journeys with screenshots: home-briefing (light, dark, AX-XXL), briefing-detail,
  ask-consent, ask-suggestions, ask-answer, alerts-unusual, games-portfolio, game-update-impact, goal-planner.
- Open before release: a privacy policy that names Anthropic; I removed an unverified "doesn't train on this data"
  claim from the consent screen (RELEASE_CHECKLIST items 15–17).

## 2026-10-06 — Slice 6: Roblox Analytics ingestion (retention, sessions, crash rate, funnels)

Skills: roblox-cloud (Open Cloud Analytics Query API: request schema, operations, 30/min limit), roblox-analytics
(funnels need LogFunnelStepEvent; Roblox back-fills skipped steps), guide-swift-testing
Reason: update reports, portfolio health, the briefing and retention alerts were CCU/revenue-only.
Primary source: Open Cloud openapi.json (QueryRequest: breakdown, filter, limit; DataPoint.status) and the
supported-metrics page (granularities, dimensions, 28-day crash data).
- Generic AnalyticsQuery and an AnalyticsPoller run every 6 h. Queries are paced at 20/min; one failing metric
  doesn't stop the rest; insignificant points are dropped.
- Postgres migration v3 (insight_samples, funnel_snapshots).
- Funnel steps are ordered by player count: back-fill makes counts non-increasing, so this doesn't depend on the
  label format.
- Wired into update impact (whole days only), retention/crash anomalies, portfolio health, the briefing, the
  `/v1/games/{id}/funnels` endpoint, an Ask `get_funnels` tool and the app's FunnelCard.
- Verified locally: 114 server tests in memory and on Postgres 16, 151 PeakKit tests.
- Not verified: real Roblox responses. In particular, whether rates arrive as fractions or percentages (normalised
  either way), and the FunnelStep label format (ordering doesn't depend on it).
Slice 6b: digest push notifications.
- One push per incident every 5 minutes, bad news only, at most once per game, metric and direction every 6 h,
  claimed atomically (Postgres migration v4).
- Tests: 118 server tests, in memory and on Postgres, including 10 concurrent claims giving exactly 1 winner.

## 2026-10-06 — Slice 7: Ad results import and campaign analyst

Skills: roblox-cloud (Ads Management API has no performance metrics, so performance comes from a CSV import),
guide-swift-testing, swiftui/hig (import sheet with an on-device preview before upload)
- CampaignImport: tolerant CSV with RFC 4180 quoting, header aliases, sums rows per campaign, skips totals,
  stable IDs so re-imports replace; missing required columns are reported, never guessed.
- CampaignAnalyst compares campaigns with each other (no public benchmark): increase / maintain / reduce /
  pause / needs data.
- Server: `POST /v1/campaigns/import` with a 2 MB body limit, Postgres migration v5, dashboard campaigns,
  and an Ask tool `get_campaigns`.
- App: Import sheet (parse preview on device), suggestion under each campaign.
- Verified locally: 157 PeakKit tests and 121 server tests (in memory and on Postgres).
- Not verified: the real Ads Manager export's headers. The alias list covers common names; the preview shows
  what was found before anything uploads.

## 2026-10-06 — Slice 8: Notifications in the app, and the morning briefing

Skills: usernotifications (permission in context, APNs registration, foreground presentation, taps; skill not
installed in this cloud session, so I followed Apple's UserNotifications docs), guide-swift-concurrency (delegate
callbacks are nonisolated; only Sendable values cross to the main actor)
Reason: the app never registered for push. Rule alerts and digest pushes built on the server couldn't reach
anyone.
- NotificationController: asks for permission from a button on Alerts, never at launch.
- The device token goes to the backend with the time zone. Taps follow only Peak's own routes, including a tap
  that cold-starts the app.
- Notifications show while Peak is open.
- `aps-environment` entitlement added.
- Server: device time zone (Postgres migration v6, invalid IDs dropped).
- BriefingNotifier pushes the briefing at 8:00 local time, once per local day.
- Verified locally: 125 server tests (in memory and on Postgres, migrations 1–6), 160 PeakKit tests.
- Not verified: real APNs delivery (needs an Apple key and a device). The system permission dialog isn't
  exercised in UI tests.
- **Correction (CI run 37436023399):** the app crashed at launch, and every app and UI test failed. The cause was
  `getNotificationSettings`: its completion handler runs on a background queue, and inside the `@MainActor`
  controller the closure was main-actor isolated, so Swift 6's runtime check trapped. Fixed in cc86f99 with a
  `nonisolated` helper. Linux builds can't catch this; only the simulator job does.

## 2026-10-06 — Slice 9: Error reports from the game (V1 #8, the error-log summariser)

Skills: roblox-security (the client is compromised, no secrets in client code, rate-limit remotes),
roblox-networking (validate type and size, per-player throttles), roblox-cloud (Secrets, HttpService),
swiftui-ui-patterns (`.sheet(item:)`, explicit load states), guide-swift-testing.
Reason: the beta server-logs API needs a new scope and only sees server errors (decision 0008).
- `Roblox/PeakErrorReporter.server.luau` and `.client.luau`. The app shows the same text; a PeakKit test checks
  they match.
- PeakKit:
  - `ErrorCount` and `ErrorClusterer.cluster(counts:)`.
  - `redacted` examples that keep line numbers.
  - The cluster summary and location.
  - A Claude prompt for an error.
  - Service methods and demo data.
- Server:
  - Ingest keys (hash only) and `POST /v1/ingest/errors` with a per-key limit.
  - A 15 s write buffer, the daily signature cap and 30-day retention (Postgres migration v7).
  - `GET /v1/games/{id}/errors` and the Ask tool `get_errors`.
  - `PUBLIC_BASE_URL`.
- App: an errors card on game detail ("New in v128", a Claude prompt per error) and a setup sheet. The setup
  sheet creates the key on a tap, never automatically, because a new key stops the old one. The key is copied
  local-only and expires from the clipboard after 10 minutes.
- Also fixed two Postgres test races, where one test's delete removed rows another test was using.
- Verified locally: 168 PeakKit tests, and 135 server tests in memory and on Postgres 16 (migrations 1–7),
  run twice.
- Luau: both scripts compile with `luau-compile`. `Roblox/run-tests.sh` runs them against stubbed Roblox
  services: 19 checks covering grouping, player-name scrubbing, the bearer header from the secret, per-player
  client limits, the 100-pending cap, UTF-8-safe cutting, and a missing secret. It runs locally, not in CI
  (no pinned Luau release yet).
- Not verified: the scripts in a real Roblox game, and Roblox Secrets end to end.
