# Peak AI — feature spec and data feasibility

The rule: **AI explains what the numbers mean and says what to do next.** It is not a generic chatbot.
Architecture and guardrails: [decision 0007](../decisions/0007-ai-layer.md).

## How every AI feature works

1. **Code computes the facts.** Changes, baselines, anomalies, before/after comparisons, funnel drop-offs and
   goal paths come from deterministic engines in `PeakKit/Insights`, with unit tests. These run free for every
   user, on every iPhone, with or without AI.
2. **AI writes the words.** Claude turns those facts into sentences and ranked next steps. A validator rejects
   any AI text that contains a number not present in the facts, and the template text is shown instead.
3. **Causes are only ever "possible".** Correlations (an update shipped 2 h before the drop) are labelled
   *Possible cause*, with the evidence, never as fact.
4. **Recommend, never act.** Peak requests **read-only** Roblox scopes. It cannot change prices, publish, spend ad
   money, change group roles or pay out, because it never holds a token that allows it. AI prepares the change
   (a draft, a checklist, the exact values); you make it in Creator Hub.

## What Roblox lets Peak see

Checked against `Roblox/creator-docs` (Open Cloud `openapi.json` and the Analytics *supported metrics* page)
on 2026-10-06.

| Key | Meaning |
|---|---|
| ✅ | Available to Peak through OAuth after the user grants the scope |
| 🔑 | Only with an Open Cloud **API key** the creator creates and pastes (optional advanced setup) |
| 📥 | Not in any API. The creator imports it (CSV export, paste, upload) |
| ⛔ | Only via the `.ROBLOSECURITY` cookie. **Peak will never ask for it**, so the feature is not built |

Data sources used below:

| Data | Source | Scope | Notes |
|---|---|---|---|
| CCU, visits, favourites, last-updated time | public games API | none | `updated` timestamp doubles as "an update was published" |
| Revenue, ARPDAU, ARPPU, payer conversion | Analytics Query API | `universe.analytics:read` ✅ | |
| D1/D7/D30 retention, cohorts, stickiness | Analytics Query API | `universe.analytics:read` ✅ | daily granularity; D7 needs 7 days after an update |
| Session length, playtime, DAU/MAU, new-user first-session bucket | Analytics Query API | ✅ | |
| Crashes, FPS, memory, CPU, server frame rate | Analytics Query API | ✅ | split by `PlaceVersion`, `Platform`, `OperatingSystem`; 28-day retention |
| DataStore / MemoryStore requests by status | Analytics Query API | ✅ | one-minute granularity: good for error anomalies |
| Funnels, custom events, economy transactions | Analytics Query API | ✅ | only if the game logs them with `AnalyticsService` |
| Thumbnail impressions / play-through by thumbnail | Analytics Query API + thumbnail-personalization API | ✅ + `universe.thumbnail:read` ✅ | |
| Discovery funnel (impressions → detail page → play) | Analytics Query API | ✅ | |
| Abuse reports | Analytics Query API | ✅ | |
| Rewarded-video ad **earnings** (ads shown *in* your game) | Analytics Query API | ✅ | publisher side only |
| Ad campaigns you run: status, budget, schedule, targeting, creatives | Ads Management API (experimental) | `ad.campaign:read` ✅ | **no impressions, CTR, plays or spend in the API** → 📥 Ads Manager CSV |
| Game pass / developer product prices | Game Passes / Developer Products APIs | `game-pass:read`, `developer-product:read` ✅ | poll to detect price changes |
| Experiments (A/B) incl. sample-ratio-mismatch and MDE | Experimentation API | `universe:read` ✅ | |
| Game server logs | Server Management API (beta) | `universe:read` ✅ | per server job; 100 req/min |
| Place version history (exact publish times, notes) | Place Version History API | 🔑 API key only | fallback: the public `updated` timestamp ✅ |
| Group roles and memberships | Groups v2 API | `group:read` ✅ | diff by polling; there's no audit log |
| Group payouts, group revenue, audit log | legacy groups/economy APIs | ⛔ cookie only | |
| Roblox-wide outages | public status page | none | to verify before building |
| Economy tables, progression design, scripts, player feedback | — | 📥 | upload/paste; treated as untrusted text |

## Feature list (all 42) with feasibility

### Essential

| # | Feature | Data | Status |
|---|---|---|---|
| 1 | Daily AI briefing | CCU, revenue, retention ✅ · ad performance 📥 · group activity: roles ✅, payouts ⛔ | **V1** |
| 2 | Ask your analytics | everything Peak stores, via read-only tools scoped to your games | **V1** |
| 3 | Anomaly detection | CCU, revenue ✅ (minutes) · retention ✅ (daily, so "collapse" lands next day) · DataStore errors, crashes ✅ · ad spend vs players 📥 · payouts ⛔ · role changes ✅ | **V1** (no payouts) |
| 4 | Possible-cause analysis | updates ✅ · campaign start/stop/budget ✅ · server problems ✅ · weekend/school-time ✅ (calendar) · thumbnails ✅ · prices ✅ · Roblox outages (status page) | **V1** (core correlator) |
| 5 | Update impact report | CCU, session length, D1/D7, revenue per player, crash rate by version ✅ · new-player completion ✅ if funnels logged | **V1** |
| 6 | AI goal planner | local | **V1** |
| 7 | Smart alert prioritisation | anomaly engine + `Platform` split ✅ | **V1** |

### Game improvement

| # | Feature | Data | Status |
|---|---|---|---|
| 8 | Funnel drop-off detector | funnel metrics ✅ (game must log funnel steps) | **V1** |
| 9 | Progression wall detector | custom events ✅ + economy table 📥 | later |
| 10 | Economy balance assistant (simulation) | economy table 📥 + economy metrics ✅ | later |
| 11 | Retention doctor | D1/D7/D30 ✅ (Roblox reports D30, not D28) | later |
| 12 | Churn-risk segments | `UserSegmentation*` dimensions ✅. Aggregated only, never per player | later |
| 13 | Release readiness score | performance ✅ + funnels ✅ + bugs 📥 | later |
| 14 | Experiment generator | Experimentation API ✅ (Peak drafts it; you create it) | later |
| 15 | Automatic experiment analysis | Experimentation API stats + SRM ✅ | later |

### Advertising

| # | Feature | Data | Status |
|---|---|---|---|
| 16 | Ad campaign analyst | campaigns ✅ + performance 📥 (Ads Manager CSV) | **V1** (import) |
| 17 | Budget recommendation | same; suggestion only, never writes | later |
| 18 | Creative fatigue detector | thumbnails ✅ · ad creatives 📥 | later |
| 19 | Thumbnail and icon reviewer | thumbnail images ✅ + Claude vision | later |
| 20 | Creative variant generator | text concepts and prompts only | later |
| 21 | Audience quality analysis | ad data 📥 + `AcquisitionSource` retention ✅ | later |
| 22 | Ad forecasting | history 📥; always a range | later |

### Development

| # | Feature | Data | Status |
|---|---|---|---|
| 23 | Error-log summariser | server logs ✅ (beta) + crash metrics ✅; client errors only if the game forwards them | **V1** (server logs + crash metrics) |
| 24 | Bug severity scoring | 23 + reports 📥 | later |
| 25 | AI bug reproduction steps | 23 | later |
| 26 | Performance advisor | performance metrics ✅ | later |
| 27 | Screenshot-to-task | Claude vision | later |
| 28 | Claude development prompt generator | local facts + template | **V1** |
| 29 | Patch risk assessment | source code 📥 (repo link) | later |

### Content and community

| # | Feature | Data | Status |
|---|---|---|---|
| 30–32 | Feedback summariser, duplicate clustering, idea ranker | imports 📥 (prompt-injection safe: imported text is data, never instructions) | later |
| 33 | Update notes generator | your notes; publishing notes needs 🔑 + your approval | later |
| 34 | TikTok idea generator | update data ✅ | later |
| 35 | Content opportunity alerts | custom events ✅ (counter goes 0 → 1) + calendar | later |
| 36 | Sentiment tracking | imports 📥 | later |

### Groups and portfolio

| # | Feature | Data | Status |
|---|---|---|---|
| 37 | Portfolio health score | all games ✅ | **V1** |
| 38 | Resource recommendation | 37 | later |
| 39 | Group activity summary | roles/members ✅ · games ✅ · revenue/payouts ⛔ | later (no payouts) |
| 40 | Suspicious group activity | role/permission changes ✅ · publishing ✅ · payouts ⛔ | later (no payouts) |
| 41 | Cross-game insights | all games ✅ | later |
| 42 | Weekly studio report | everything above | later |

## Version 1

1. Daily AI briefing
2. Ask your analytics
3. Anomaly detection (+ possible causes, + smart prioritisation)
4. Update impact report
5. Goal planner
6. Funnel drop-off detector
7. Ad campaign analyst (campaigns from the API, performance from the Ads Manager CSV)
8. Error-log summariser (server logs + crash metrics)
9. Portfolio health score
10. Claude prompt generator

## Never automated

Prices, publishing, ad spend, group permissions and payouts. Peak holds no write scopes in V1. If a later
version adds one, every change goes through a confirmation screen that shows the exact before → after.
