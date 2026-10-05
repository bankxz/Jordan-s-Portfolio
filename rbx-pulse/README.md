# RBX Pulse

Native iOS app for Roblox creators: live CCU, revenue and retention, ads and campaigns,
groups, goals, alerts, widgets and Live Activities.

This folder is the project root for Claude Code. It holds the skill-driven development
setup. App code comes next.

```
rbx-pulse/
├── CLAUDE.md                         # Rules Claude follows on every task
├── .claude/
│   ├── settings.json                 # Declares + enables the two skill packs
│   └── skills/
│       ├── rbx-feature-workflow/     # Per-feature loop: skills → build → run → test → log
│       └── rbx-release-gate/         # Pre-release stress/QA gate
├── docs/
│   ├── DEV_LOG.md                    # Skills report per feature
│   ├── skills/SKILL_POLICY.md        # Tiers, feature→skill map, conflict rules
│   ├── skills/VETTING.md             # What each pack ships (scripts, MCP) + licence
│   ├── decisions/                    # Architecture decision records
│   └── qa/                           # Visual QA + release checklist
├── evals/evals.json                  # Test prompts for the project skills
└── scripts/install-skills.sh         # Non-interactive skill install
```

## Setup (Mac)

1. Install Xcode, Node.js (for XcodeBuildMCP) and Claude Code.
2. Open this folder in Claude Code and trust it. You'll be prompted to install the
   `apple-skills` and `build-ios-apps` plugins. Or run `scripts/install-skills.sh`.
3. Confirm with `claude plugin list`.
4. Before the first feature, record the deployment target as `docs/decisions/0002-…`.

## Moving to its own repository

Claude Code resolves project settings from the git root. Inside the portfolio repo, open
Claude Code from `rbx-pulse/`, or better, move this folder into its own `rbx-pulse` repo
so `CLAUDE.md` and `.claude/` sit at the repo root:

```
git subtree split --prefix rbx-pulse -b rbx-pulse-only
# create an empty rbx-pulse repo on GitHub, then:
git push git@github.com:<you>/rbx-pulse.git rbx-pulse-only:main
```
