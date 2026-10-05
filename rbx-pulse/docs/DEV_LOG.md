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

## 2026-10-05 — Slice 2: Auth session + API client

Skills: guide-swift-concurrency (actors.md, bug-patterns.md, cancellation), swift-concurrency,
roblox-cloud, guide-swift-testing (async-tests.md)
Reason: single-flight rotating-token refresh is the main race in the app; roblox-cloud
covers the OAuth/PKCE/rotation rules; async tests prove one refresh under N concurrent callers.
Deployment-target notes: Keychain store is `#if canImport(Security)`.
