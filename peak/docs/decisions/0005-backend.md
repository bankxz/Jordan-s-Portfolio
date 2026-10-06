# 0005 — Backend: Swift server on Hummingbird + Postgres

- **Date:** 2026-10-05
- **Status:** accepted
- **Skills consulted:** roblox-cloud (OAuth, Open Cloud mechanics), roblox-security (server authority,
  rate limits, idempotency, no secrets client-side), guide-swift-concurrency, guide-swift-testing

## Context

The app (decision 0003) needs a backend that owns Roblox OAuth, stores rotating Roblox tokens, polls
game stats, evaluates alerts and sends pushes. Facts below come from the primary sources
(`Roblox/creator-docs`: `cloud/auth/oauth2-reference.md`, `cloud/guides/analytics/*`,
`reference/cloud/openapi.json`), fetched 2026-10-05.

| Fact | Source |
|---|---|
| OAuth base `https://apis.roblox.com/oauth`: `v1/authorize`, `v1/token`, `v1/token/resources`, `v1/token/revoke`, `v1/userinfo` | oauth2-reference |
| Auth code: 1-minute lifetime, single use | oauth2-reference |
| Access token 15 min; refresh token 90 days, **single use** (rotates) | oauth2-reference |
| Client auth: HTTP Basic or `client_id`/`client_secret` in the form body; PKCE `S256` supported | oauth2-reference |
| `token/resources` → `resource_infos[].resources.universe.ids` = universes the user granted | oauth2-reference |
| `userinfo.sub` is the stable user ID (usernames change) | oauth2-reference |
| `universe.analytics:read` scope → `POST /analytics-query-api/v1/universes/{id}/metrics` | openapi.json |
| Metrics: `ItemMonetizationRevenue` (OneHour), `DailyRevenue`, `DailyActiveUsers`, `PeakConcurrentPlayers` (OneMinute) | analytics/metrics.md |
| Analytics may return `202` + `done: false`; poll `GET /analytics-query-api/{path}` | analytics/index.md |
| Redirect URLs may be HTTPS or custom schemes; max 10 | oauth2-registration |

Live CCU, visits and favourites come from the public web API `games.roblox.com/v1/games?universeIds=`
(`playing`, `visits`, `favoritedCount`, `rootPlaceId`, `name`), which takes up to 100 IDs per call. It's not
Open Cloud, so treat it as best-effort: tolerate missing fields and 429s.

## Decision

- **Swift 6 + Hummingbird 2** in `Server/`, depending on `PeakKit`, so the API types are literally the
  ones the app decodes. Postgres (PostgresNIO) for storage; an in-memory store with the same protocol
  for tests and local dev.
- **Scopes:** `openid profile universe.analytics:read`. Universes come from `token/resources`.
- **Roblox tokens** are encrypted at rest (AES-GCM, key from `TOKEN_ENCRYPTION_KEY`). Refresh is
  single-flight per user in-process, plus compare-and-swap on the stored refresh-token hash in the
  database, so two server instances can't both spend the same single-use token.
- **Peak sessions** are opaque random tokens, stored only as SHA-256 hashes. 15-minute access
  token, 60-day refresh token, rotation on every refresh, and reuse of a rotated refresh token revokes
  the whole session family (theft detection).
- **OAuth attempts** (state + PKCE verifier) and one-time session codes are single-use and expire after
  10 minutes and 2 minutes respectively; consumption is atomic.
- **Workers** run as structured services with cancellation: stats poller (60 s), revenue poller (15 min),
  alert evaluation after each stats poll using the shared `AlertEngine`, APNs sender.
- Rate limits on unauthenticated auth endpoints. Tokens and codes are never logged.

## Alternatives considered

- **Vapor** — heavier, and Hummingbird 2 is built on structured concurrency end to end. Either would do.
- **Node/TypeScript** — would duplicate every model and the alert/goal engines. Rejected.
- **Analytics via API key** — needs each creator to paste a key; OAuth gives per-universe consent. Rejected.

## Consequences

- Needs a Roblox OAuth app registered (category: Analytics & Insights) with the backend callback URL,
  and an APNs key for pushes. Both are configuration; the server runs without APNs (pushes disabled).
- `robux24h` is only filled for universes whose owner granted `universe.analytics:read`; otherwise `null`
  (the app already shows "—").
- The games web API can change without notice; failures degrade to stale stats with freshness labels.
