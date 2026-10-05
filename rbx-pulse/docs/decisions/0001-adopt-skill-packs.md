# 0001 — Adopt two skill packs as mandatory development knowledge

- **Date:** 2026-10-05
- **Status:** accepted
- **Skills consulted:** n/a (setup)

## Context

RBX Pulse relies on fast-moving Apple frameworks (SwiftUI, SwiftData, WidgetKit,
ActivityKit, App Intents, notifications, background execution) and on Roblox OAuth with
rotating refresh tokens. Generic model knowledge goes stale quickly in these areas.

## Decision

- Primary pack: `apple-skills@apple-skills` (Prisma-Labs-Dev/apple-skills).
- Secondary pack: `build-ios-apps@openai-build-ios-skills` (mtfum/openai-build-ios-skills),
  used mainly for the Simulator debugger, App Intents, ETTrace, memgraph and SwiftUI
  performance/UI-pattern skills.
- Both are declared in `.claude/settings.json`. Usage is governed by `CLAUDE.md`,
  `docs/skills/SKILL_POLICY.md` and the `rbx-feature-workflow` / `rbx-release-gate` skills.
- Official Apple documentation outranks any skill.

## Alternatives considered

- **Several overlapping SwiftUI packs** — rejected; conflicting architecture advice.
- **Generator collections** (widget, Live Activity, push, HTTP-cache generators) —
  deferred until a specific pack is vetted.
- **No skills** — rejected; too much reliance on outdated framework knowledge.

## Consequences

- `apple-skills` targets iOS 26+, so every API needs a deployment-target check.
  → Follow-up: decision 0002 must set the deployment target.
- `build-ios-apps` runs XcodeBuildMCP via unpinned `npx …@latest`; see `VETTING.md`.
- Simulator-based verification needs macOS + Xcode. Cloud/Linux sessions can write docs,
  backend code and Swift logic, but can't verify iOS builds.
