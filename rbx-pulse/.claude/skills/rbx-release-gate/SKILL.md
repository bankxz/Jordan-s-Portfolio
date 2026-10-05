---
name: rbx-release-gate
description: "Pre-release stress and QA gate for RBX Pulse. Runs the performance, memory-leak, SwiftUI audit, Swift Testing, XCUITest, Simulator and device checks and produces a pass/fail report. Use this whenever someone talks about shipping, a TestFlight build, an App Store submission, a release candidate, \"is it ready\", or a production-hardening pass, even if they only ask about one check."
---

# RBX Pulse release gate

A build doesn't ship because it seems to work. The bar is that we tried to break it and
it stayed stable. This gate turns that bar into concrete checks with recorded evidence,
so a release decision rests on results rather than impressions.

The full checklist is in `docs/qa/RELEASE_CHECKLIST.md`. Work through it in order and
fill in a copy as the release report at `docs/qa/releases/<version>.md`.

## Order, and why

1. **Automated tests first.** Run the Swift Testing suite, then the XCUITest suite.
   They're the cheapest signal; a red test ends the gate early.
2. **Simulator run** with `ios-debugger-agent`: a clean install, an upgrade over the
   previous build (to exercise SwiftData migrations), and the main journeys. Watch the
   logs for warnings, not only crashes.
3. **Performance profiling** with `ios-ettrace-performance` on the hot paths: Home scroll,
   opening Games, game analytics, switching chart ranges, search, and 100+ games. Compare
   against the previous release's numbers where they exist. A regression needs a reason
   or a fix.
4. **SwiftUI performance audit** with `swiftui-performance-audit` and
   `guide-swiftui-performance-audit`, focused on the Home feed: live metrics, cards,
   charts, ads and animations.
5. **Memory leaks** with `ios-memgraph-leaks`. This is mandatory. Repeat each flow many
   times (navigation, charts, images, Live Activities, sheets, search, game detail,
   pull-to-refresh), take memgraphs before and after, and compare. Growth that doesn't
   plateau is a leak until proven otherwise.
6. **Widgets and Live Activities**: every widget family; stale, empty, signed-out and
   error states; Live Activity updates with the app backgrounded and terminated.
7. **Notifications**: permission denied and granted, foreground and background, deep
   links from a cold start, and bursts of many pushes.
8. **Physical iPhone.** The Simulator hides thermal, memory, network and push behaviour.
   At least one real-device pass is required.
9. **Diagnostics**: review crash and hang reports and MetricKit/Xcode Organizer data from
   the previous build.

## Report

For each item, record ✅ / ❌ / ⚠️ plus evidence: test counts, trace numbers, memgraph
summary, device model and OS. Say explicitly which checks could not run and why. In a
Linux or cloud session, items 1–9 need a Mac, so mark them "not run" rather than passing
them.

Verdict: **Ship** only if every required item is ✅. Otherwise **Hold**, with a list of
blocking items.
