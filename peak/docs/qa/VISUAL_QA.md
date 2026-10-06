# Visual QA

Inspect the rendered UI in the Simulator or on a device. Reading the SwiftUI code is
not enough.

## Per screen / component

- [ ] Spacing and alignment are consistent with the shared components
- [ ] No clipping or truncation of important values
- [ ] Scroll behaviour (inertia, pull-to-refresh, scroll-to-top)
- [ ] Safe areas (notch, Dynamic Island, home indicator)
- [ ] Keyboard interaction (fields not covered, dismiss behaviour)
- [ ] Long titles (game names, group names)
- [ ] Very large numbers (CCU 1,000,000+, Robux 10,000,000+) and zero values
- [ ] Small device (iPhone SE / mini class) and large device (Pro Max class)
- [ ] Light Mode and Dark Mode
- [ ] Dynamic Type at default, largest standard size and largest accessibility size
- [ ] VoiceOver labels on metrics and charts
- [ ] States: loading · empty · offline · error · signed-out · stale data

## Preview matrix

Every important component (`MetricCard`, `GameCard`, `GoalCard`, `InsightCard`,
`AlertRow`, `CampaignCard`, `LiveNowCard`, `EmptyState`, `LoadingCard`,
`ErrorCard`) has Xcode previews for:

normal · empty · loading · error · very long text · huge values · zero values ·
light · dark · large Dynamic Type

## Getting screenshots without a Mac

Every push that touches `peak/` runs the UI tests on CI. They save named screenshots
(`home-light`, `home-dark`, `home-a11y-xxl`, `home-empty`, `home-error`, `games-light`,
`game-detail-7d-light`, `goal-detail-light`, `ads-light`, `alerts-light`, …), and CI publishes them,
with `summary.txt` and `test-summary.json`, to the `ci-screenshots/<branch>` branch:

```bash
git fetch origin ci-screenshots/<branch> && git worktree add /tmp/shots FETCH_HEAD
```

Open every image and walk through the checklist above. Screenshots are the evidence for a visual QA pass.
