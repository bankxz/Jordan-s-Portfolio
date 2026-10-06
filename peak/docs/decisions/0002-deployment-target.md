# 0002 — Deployment target: iOS 17.0, Swift 6 language mode

- **Date:** 2026-10-05
- **Status:** accepted
- **Skills consulted:** ios-dev, widgetkit, guide-swiftui-charts, swiftdata, guide-swift-concurrency

## Context

`apple-skills` documents iOS 26+ APIs. Peak needs to reach creators on older
iPhones, but the core feature set depends on APIs that only became stable recently.

| Need | Minimum iOS |
|---|---|
| `@Observable` / Observation (ios-dev checklist mandates it over `ObservableObject`) | 17 |
| SwiftData (local cache) | 17 |
| `AppIntentConfiguration` widgets, interactive widgets, `containerBackground` | 17 |
| Swift Charts `chartXSelection` (touch interaction) | 17 |
| ActivityKit Live Activities + push updates | 16.1 |
| Live Activity push-to-start | 17.2 → gate with `#available` |
| Liquid Glass, iOS 26 SwiftUI APIs | 26 → gate with `#available` |

## Decision

- **Minimum iOS 17.0**, iPhone only for v1.
- **Swift 6 language mode** with complete strict concurrency in every target.
- Anything newer than 17.0 (push-to-start, iOS 18 widget controls, iOS 26 Liquid Glass)
  must be behind `#available` with a working fallback.
- Build with the current stable Xcode (CI uses the runner default; minimum Xcode 16).

## Alternatives considered

- **iOS 16** — loses Observation, SwiftData and AppIntent widget configuration. That means
  two state systems and a CoreData stack. Rejected.
- **iOS 18 / 26** — drops a meaningful share of creators' devices for little gain. Rejected
  for v1. Revisit yearly.

## Consequences

- Skill guidance that uses iOS 18+/26 APIs needs an `#available` check on each use.
- `@Observable` view models must be `@MainActor` (ios-dev checklist).
