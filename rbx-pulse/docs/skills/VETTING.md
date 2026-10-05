# Skill pack vetting record

Every installed pack is inspected before being added to `.claude/settings.json`.
Re-check when a pack's version changes.

## apple-skills (Prisma-Labs-Dev/apple-skills)

- **Vetted:** 2026-10-05, plugin version 1.0.20
- **Licence:** MIT (Ilia Abolhasani / Prisma Labs)
- **Marketplace / plugin:** `apple-skills` / `apple-skills`
- **Ships:** Markdown skills only for iOS. One macOS skill (`guide-macos-spm-packaging`)
  includes shell templates — not relevant to RBX Pulse; ignore.
- **Hooks / MCP servers:** none.
- **Baseline caveat:** written for **iOS 26+** APIs. Every API it recommends must be
  checked against the RBX Pulse deployment target and gated with `#available` if needed.
- **Note:** `ios-dev` mentions Apple's `swiftui-specialist` skill shipped with newer
  Xcode. Use it if present on the Mac; it isn't required.
- **Disabled in pack:** `guide-swiftui-ui-patterns`, `guide-swiftui-view-refactor`,
  `guide-swiftui-animations`, `ios-design-consultant`, `ios-ui-craft` — so no conflict with
  the build-ios-apps equivalents.

## build-ios-apps (mtfum/openai-build-ios-skills)

- **Vetted:** 2026-10-05
- **Licence:** MIT (original work © OpenAI, packaged by mtfum)
- **Marketplace / plugin:** `openai-build-ios-skills` / `build-ios-apps`
- **Ships:** 8 skills. Scripts: `ios-ettrace-performance/scripts/{collect_ios_dsyms.sh,
  analyze_flamegraph_json.py}`, `ios-memgraph-leaks/scripts/{capture_sim_memgraph.sh,
  summarize_memgraph_leaks.py}` — local profiling helpers.
- **MCP server:** `.mcp.json` starts **XcodeBuildMCP** via `npx -y xcodebuildmcp@latest mcp`
  (workflows: simulator, ui-automation, debugging, logging). It's required by
  `ios-debugger-agent`.
  - Risk: `@latest` is unpinned, so it pulls new code on each start. Acceptable for
    development. If it ever misbehaves, pin a version in a local MCP override.
  - Needs macOS + Xcode + Node. It won't do anything useful in a Linux/cloud session.
- **Skills used:** `ios-debugger-agent`, `ios-app-intents`, `ios-ettrace-performance`,
  `ios-memgraph-leaks`, `swiftui-performance-audit`, `swiftui-ui-patterns`,
  `swiftui-view-refactor`.
- **Not used:** `swiftui-liquid-glass` — overlaps `apple-skills/ios-liquid-glass`. Prefer
  the apple-skills one if Liquid Glass is adopted.

## Rejected / deferred

- **Generator collections** (widget/live-activity/push/http-cache generators): deferred
  until a specific pack is chosen and vetted.
- **More SwiftUI packs:** rejected — overlapping advice causes architecture conflicts.
