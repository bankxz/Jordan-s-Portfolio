# RBX Pulse

Native iOS app for Roblox creators: live CCU, revenue and retention, ads and campaigns,
goals, alerts, Home/Lock Screen widgets and (next) Live Activities.

**Status:** the app runs on sample data (demo mode) or against the backend in `Server/` (Roblox OAuth,
stats and revenue polling, server-side alerts + APNs). Next: the in-app "Connect Roblox" flow.

```
rbx-pulse/
├── CLAUDE.md                     # Rules Claude follows on every task (skills, build→run→verify)
├── .claude/
│   ├── settings.json             # Declares + enables the apple-skills and build-ios-apps packs
│   └── skills/                   # rbx-feature-workflow, rbx-release-gate
├── project.yml                   # XcodeGen spec (app, widgets, unit + UI tests)
├── Packages/RBXPulseKit/         # Shared logic + 95 Swift Testing tests (runs on Linux too)
├── App/                          # SwiftUI app: Home, Games, Goals, Ads, Alerts, game chart
├── Widgets/                      # Game Pulse (configurable) + Goals widgets
├── Server/                       # Backend: Hummingbird + Postgres (see Server/README.md)
├── SharedUI/                     # Views shared by app and widgets
├── Tests/AppTests, Tests/UITests # App model tests; XCUITest journeys + screenshots
├── docs/
│   ├── DEV_LOG.md                # Skills report + verification per slice
│   ├── decisions/                # 0001 skills · 0002 iOS 17 · 0003 architecture & auth · 0004 verification · 0005 backend
│   ├── api/backend-contract.md   # Backend endpoints the app expects
│   ├── skills/                   # Skill policy + vetting record
│   └── qa/                       # Visual QA + release checklist
└── scripts/install-skills.sh
```

## Run it (Mac)

```bash
brew install xcodegen
xcodegen generate
open RBXPulse.xcodeproj        # Run the RBXPulse scheme on an iPhone simulator
```

With no `RBXPULSE_API_BASE_URL` build setting, the app runs on deterministic sample data.
Launch arguments: `-demoMode normal|empty|failing`, `-colorScheme dark|light`.

## Test

```bash
cd Packages/RBXPulseKit && swift test                 # logic, on macOS or Linux
swift test --sanitize=thread                          # concurrency (auth refresh)
xcodebuild test -project RBXPulse.xcodeproj -scheme RBXPulse \
  -destination 'platform=iOS Simulator,name=iPhone 16'  # app + UI tests
```

CI runs all of the above on every push touching `rbx-pulse/` and uploads screenshots.

## Skills setup

Open this folder in Claude Code and trust it, or run `scripts/install-skills.sh`. See `CLAUDE.md`
and `docs/skills/SKILL_POLICY.md`.

## Moving to its own repository

Claude Code resolves project settings from the git root. Move this folder into its own repo so
`CLAUDE.md` and `.claude/` sit at the root. Then move `.github/workflows/rbx-pulse.yml` along with
it, and drop the `rbx-pulse/` path prefixes:

```bash
git subtree split --prefix rbx-pulse -b rbx-pulse-only
git push git@github.com:<you>/rbx-pulse.git rbx-pulse-only:main
```
