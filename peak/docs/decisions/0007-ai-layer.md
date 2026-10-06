# 0007 — AI layer: facts in code, words from Claude, actions by the creator

- **Date:** 2026-10-06
- **Status:** accepted
- **Skills consulted:** claude-api (raw HTTP shape, structured outputs, refusal fallbacks, models and pricing),
  roblox-cloud (scopes, incremental consent), roblox-analytics (funnels/custom events need in-game logging),
  roblox-security (no cookies, server authority)

## Context

The owner wants AI that explains numbers and recommends next steps (spec: `docs/ai/AI_FEATURES.md`).
The risks are wrong numbers, causation stated as fact, AI taking real actions, uncontrolled cost, and sending
creator data to a third party without consent. The owner's iPhone 12 can't run Apple's on-device model, so AI
has to run on the server.

## Decision

1. **Deterministic engines first** (`PeakKit/Insights`): anomaly detection, possible causes, update impact, alert
   digest, briefing facts, goal planning, funnel drop-off, portfolio health and the Claude-prompt generator are plain
   Swift with unit tests. Every user gets them for free, and they are the fallback whenever AI is off or fails.
2. **Claude only narrates and ranks.** The server sends the computed facts (aggregates only, no player IDs) and
   asks for structured JSON output (`output_config.format` with a JSON schema).
   - **Number grounding:** each number in the reply must match a fact (after formatting such as 1.2K or 18%).
     If any number doesn't match, the template text is used instead.
   - **Causes:** they arrive typed as `possible` with evidence; the UI always says "Possible cause".
3. **Raw HTTP to `POST /v1/messages`.** The server is Swift, which has no official SDK, so this is the
   claude-api skill's documented path. Headers: `x-api-key`, `anthropic-version: 2023-06-01`.
   - Interactive requests opt into server-side refusal fallback with `fallbacks: "default"` and
     `anthropic-beta: server-side-fallback-2026-07-01`.
   - `stop_reason` is checked before `content` is read. A `refusal` or `max_tokens` stop falls back to the template.
   - Batch jobs (overnight briefings) don't send `fallbacks`, because the Batches API rejects it.
4. **Model per feature, set by environment variable:**
   - `PEAK_AI_MODEL` sets the default; `PEAK_AI_MODEL_BRIEFING`, `PEAK_AI_MODEL_ASK` and `PEAK_AI_MODEL_REPORT`
     override it per feature.
   - The default is `claude-opus-5-5`, per the claude-api skill, which says the owner, not the code, chooses a
     cheaper model.
   - Cheaper options: `claude-sonnet-5-5` ($2 / $10 per million tokens) and `claude-haiku-4-5` ($1 / $5).
     Opus 5.5 is $4 / $20.
5. **"Ask your analytics" is a tool loop over read-only tools.** The tools are list games, get series,
   get insights and get update impact.
   - Every tool is scoped to the caller's own universes, so no tool can write.
   - The loop is capped at 6 rounds and 8 tool calls.
6. **Off by default.**
   - With no `ANTHROPIC_API_KEY` on the server, AI is off for everyone.
   - Each user must also opt in on a consent screen that says what is sent to Anthropic.
   - Per-user daily limits apply: `PEAK_AI_DAILY_ASKS`, default 20.
   - There's a server-wide monthly spend cap, `PEAK_AI_MONTHLY_BUDGET_USD`, computed from each response's `usage`.
   - Above the cap, AI calls stop and templates are served.
7. **Read-only Roblox scopes.** V1 adds read scopes only, each requested when the user turns on the feature that
   needs it (roblox-cloud: re-authorize when scopes change; the app already handles `409 reconnect_required`):
   `universe:read`, `ad.campaign:read`, `game-pass:read`, `developer-product:read`, `universe.thumbnail:read`,
   `group:read`. No write scope, so AI can't change prices, publish, spend ad money, edit groups or pay out.
8. **Untrusted text stays data.** Imported feedback, logs and CSVs go inside delimited blocks marked as data. No tool
   can act on them, because there are no write tools.

## Alternatives considered

- **Apple Foundation Models (on-device):** free and private, but it needs iOS 26 on Apple Intelligence hardware. The
  owner's iPhone 12 can't run it, and neither can CI. It may be added later as an optional extra.
- **Free-tier hosted models:** quotas change without notice, and free tiers often allow training on the input,
  which would be creators' data.
- **A generic chatbot over raw data:** it invents numbers, and it can't be tested.
- **Letting AI apply changes, with confirmation:** this was rejected for V1 because holding write tokens at all
  raises the cost of any server compromise.

## Consequences

- Insights work for every user with AI off. AI improves the wording but isn't required.
- App Store: the privacy label must declare "Usage data → third-party AI" once a user opts in, along with the
  in-app consent (guideline 5.1.2(i)).
- Ad performance needs an Ads Manager CSV import, because the Ads API has no metrics.
- Group payouts are not available at all (cookie-only).
- Place versions use the public `updated` timestamp unless the creator adds an Open Cloud API key.
- Cost scales with use. Briefings can be batched at 50% off; chat is capped per user.
