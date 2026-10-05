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
