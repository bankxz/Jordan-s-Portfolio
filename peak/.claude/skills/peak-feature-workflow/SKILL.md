---
name: peak-feature-workflow
description: "The Peak development loop — pick the right Apple skills, implement in small steps, build, run in the Simulator, test, and log decisions. Use this for any meaningful Peak work, even if the user doesn't name it: new screens or cards (Home, Games, Ads, Groups, Goals), charts, Roblox OAuth or sync, widgets, Live Activities, notifications, SwiftData persistence, App Intents, refactors, and bug fixes. Skip it only for trivial edits like a typo or a copy change."
---

# Peak feature workflow

This app depends on Apple frameworks that change every year (WidgetKit, ActivityKit,
App Intents, SwiftData, notifications), and on Roblox OAuth with rotating refresh tokens.
Code written from memory tends to compile and still be wrong: deprecated APIs, widgets
treated like live mini-apps, races between token refreshes. This loop exists so that
every feature is grounded in current guidance and actually seen running before we move on.

## 1. Scope and select skills

List the technical areas the task touches, then pick skills using the feature map in
`docs/skills/SKILL_POLICY.md`. Load only those skills. Loading every skill wastes context
and mixes unrelated advice. For substantial iOS work, start with `ios-dev`, which routes
to the right reference.

Check that the skills are actually installed before relying on them. If a pack is
missing, say so and point to `scripts/install-skills.sh` instead of quietly falling back
to memory.

## 2. Write the skills report

Append to `docs/DEV_LOG.md` before writing code:

```
## YYYY-MM-DD — <Feature>
Skills: <skill>, <skill>, ...
Reason: <one line on why each matters here>
Deployment-target notes: <any API that needs #available, or "none">
```

This is short on purpose. It makes the skill choice deliberate and leaves a trail for
when something breaks later.

## 3. Check the APIs against the deployment target

`apple-skills` is written for iOS 26+. For every framework API you're about to use,
confirm it exists at the deployment target recorded in `docs/decisions/`. Gate newer APIs
with `#available` and give them a sensible fallback. When a skill and the official Apple
docs disagree, the docs win. Record the conflict as a decision (step 7).

## 4. Implement in a small slice

Build the smallest vertical slice that can run: one view, one service method, one widget
family. Follow the loaded skills. Keep the project's existing architecture even if a
skill prefers another. Skills provide expertise; they don't own the project.

Project invariants worth re-reading before each slice:
- Widgets render cached snapshots. Design for stale data and show "updated X ago".
- Reliable monitoring is server-side; the phone gets APNs pushes. Don't plan around
  arbitrary background execution.
- Token refresh is serialized: one in-flight refresh per account, and every other caller
  awaits it.
- Every `Task` has an owner and a cancellation path. Don't use fire-and-forget `Task.detached`.
- Reuse shared components (`MetricCard`, `GameCard`, `EmptyState`, `ErrorCard`, …).

## 5. Build, run, look

On macOS with Xcode, use `ios-debugger-agent`: build, launch on a booted Simulator,
drive the UI, and read the logs. Look at the rendered result and walk through the relevant
rows in `docs/qa/VISUAL_QA.md`: loading, empty, error, long text, huge numbers, Dark Mode,
large Dynamic Type.

In a Linux or cloud session there's no Simulator, but you can still verify (decision 0004):
run package tests in the `swift:6.1-noble` Docker image, push to trigger the macOS CI job, then
fetch the `ci-screenshots/<branch>` branch and actually look at every screenshot plus
`test-summary.json`. Add a UI-test screenshot for any new screen or state. Anything CI can't cover
(Home Screen widgets, App Group sharing, push, device performance) must be written down as
unverified, never reported as verified.

## 6. Test by trying to break it

- Logic (calculations, goal and alert engines, parsers, caches, repositories): use
  `swift-testing`, guided by `guide-swift-testing`. Include edge cases: zero, negative,
  huge values, empty collections, time zones and DST, and malformed API payloads.
- Concurrency (sync jobs, token refresh): fire many concurrent callers and assert that
  exactly one refresh happens. Test cancellation mid-flight.
- Journeys: `xcuitest` for flows a user would notice breaking.
- If something misbehaves, investigate with tools rather than guesses:
  `ios-debugger-agent` → then ETTrace (slow), memgraph (memory growth), the SwiftUI
  performance audit (stutter), or `swift-concurrency` (races).

## 7. Record and checkpoint

- If you chose between real alternatives, resolved a skill conflict, or set a
  convention, write `docs/decisions/NNNN-title.md` from `0000-template.md`.
- Update the dev log entry with what was verified and what wasn't.
- Make a checkpoint commit, then start the next slice.

The loop is small feature → build → run → inspect → test → commit. Writing thousands of
lines before the first build hides bugs that are cheap to catch early.
