# 0006 — Rename RBX Pulse → Peak

- **Date:** 2026-10-06
- **Status:** accepted
- **Skills consulted:** hig (app naming, icon), peak-feature-workflow

## Context

"RBX Pulse" put Roblox's abbreviation in the product name. Roblox's brand guidelines restrict
third-party use of its marks, and App Review rejects names that imply an official affiliation.
The owner picked **Peak**: short, about hitting record CCU and revenue, and not tied to Roblox.

## Decision

| Thing | Old | New |
|---|---|---|
| Display name / app target | RBX Pulse / `RBXPulse` | Peak / `Peak` |
| Shared package | `RBXPulseKit` | `PeakKit` |
| Server package / binary | `RBXPulseServer` / `rbxpulse-server` | `PeakServer` / `peak-server` |
| Bundle ID | `com.rbxpulse.app` | `com.peakstats.app` (widgets `.widgets`) |
| URL scheme | `rbxpulse://` | `peakstats://` |
| App Group | `group.com.rbxpulse.shared` | `group.com.peakstats.shared` |
| Keychain service | `com.rbxpulse.session` | `com.peakstats.session` |
| Server token prefixes | `rbxp_sc_`, `rbxp_at_`, `rbxp_rt_` | `pk_sc_`, `pk_at_`, `pk_rt_` |
| Project skills | `rbx-feature-workflow`, `rbx-release-gate` | `peak-feature-workflow`, `peak-release-gate` |
| Home hero card type | `CreatorPulseCard` | `LiveNowCard` (label "Live now" unchanged) |

New icon: a white rising line peaking at a summit ring on a teal→navy gradient.

The URL scheme is `peakstats`, not `peak`: a bare dictionary word is more likely to clash with
another installed app's scheme.

## Consequences

- No data migration was needed: nothing has shipped, and there are no live users or stored tokens.
- **Before the first App Store Connect upload,** finalise the bundle ID, App Group and URL scheme.
  After that upload the bundle ID can't change, and changing the App Group or scheme breaks
  widgets and the OAuth callback for existing installs. `peakstats.app` is a placeholder: the
  owner doesn't own that domain yet.
- "Peak" is a common word, and other apps use it (for example, the "Peak – Brain Training" app).
  Do a trademark search and check App Store name availability before submitting. A store
  subtitle such as "Peak: Stats for Roblox creators" is the likely fallback. Describing
  compatibility ("for Roblox creators") is fine; implying endorsement isn't.
- The Roblox OAuth app registration must list `peakstats://auth/complete`, or the HTTPS
  equivalent, as a redirect URL.
