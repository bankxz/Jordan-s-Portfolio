# RBX Pulse backend contract (v1)

Implemented in `Server/` (decision 0005). The app talks only to this backend. The backend talks to
Roblox (OAuth, Open Cloud Analytics, and the public games API), stores Roblox tokens, polls metrics,
evaluates alerts and sends APNs.

All payload types are Swift types in `Packages/RBXPulseKit` (`BackendAPI.swift` and the models). The
server encodes and the app decodes the same types; `Server/Tests/.../AppCompatibilityTests.swift` drives the
server with the app's networking stack over real HTTP to keep them in sync.

- JSON with `application/json`. Dates are ISO 8601 UTC (`2026-10-05T18:00:00Z`). Responses carry `Cache-Control: no-store`.
- Authenticated endpoints need `Authorization: Bearer <access token>` (`rbxp_at_…`).
- Errors use the body `{"error": "<code>"}` (`BackendAPI.ErrorBody`):

| Status | Codes | App mapping (`APIError`) |
|---|---|---|
| 400 | `invalid_body`, `invalid_metric`, `invalid_range`, `invalid_universe`, `invalid_id`, `id_mismatch`, `invalid_device_token`, `invalid_threshold`, `invalid_fraction`, `invalid_window`, `invalid_cooldown`, `too_many_rules` | `unexpectedStatus(400)` |
| 401 | `unauthorized` (+ `WWW-Authenticate: Bearer`) | refresh once, then `unauthorized` / `AuthError.sessionExpired` |
| 404 | `not_found` (also for other users' resources) | `notFound` |
| 409 | `reconnect_required`: Roblox access was revoked or expired | `reconnectRequired` |
| 429 | `rate_limited` + `Retry-After` | `rateLimited` |
| 5xx | | `server` |

## Auth

| Method | Path | Auth | Body | Response |
|---|---|---|---|---|
| POST | `/v1/auth/roblox/start` | rate-limited | — | `{ "authorizeURL": "https://apis.roblox.com/oauth/v1/authorize?..." }` |
| GET | `/oauth/roblox/callback` | rate-limited | Roblox redirect (`code`, `state` / `error`) | `302` → `rbxpulse://auth/complete?code=<session code>` or `?error=<code>` |
| POST | `/v1/auth/session` | rate-limited | `{ "code": "rbxp_sc_…" }` | `AuthTokens` |
| POST | `/v1/auth/refresh` | rate-limited | `{ "refreshToken": "rbxp_rt_…" }` | `AuthTokens` (rotated); `401` when dead |
| POST | `/v1/auth/logout` | ✓ | — | `204`; revokes this device's session family |
| DELETE | `/v1/account` | ✓ | — | `204`; revokes the Roblox grant and deletes all of the user's data |

Callback error codes: `access_denied`, `authorization_failed`, `invalid_request`, `invalid_state`,
`expired`, `invalid_grant`, `server_error`.

Lifetimes: OAuth attempt 10 min · session code 2 min, single use · access token 15 min · refresh token
60 days, rotates on every use; reusing an old one revokes the whole family.

## Data

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/v1/dashboard` | — | `Dashboard` |
| GET | `/v1/games/{universeId}/series?metric=ccu\|visits\|favourites\|robux&range=24h\|7d\|30d` | — | `MetricSeries` (≤ 300 points) |
| PUT | `/v1/games/{universeId}/favourite` | `{ "value": true }` | `204` |
| PUT | `/v1/games/{universeId}/working-on` | `{ "value": true }` | `204` |
| POST | `/v1/devices` | `{ "apnsToken": "<hex>", "sandbox": false }` | `204` |
| GET | `/v1/alerts/rules` | — | `[AlertRule]` |
| PUT | `/v1/alerts/rules/{id}` | `AlertRule` (id must match) | `AlertRule` |
| DELETE | `/v1/alerts/rules/{id}` | — | `204` |

A universe is accessible only if it's in the caller's Roblox grant (`token/resources`).

Dashboard data sources:

| Field | Source | Freshness |
|---|---|---|
| `stats.ccu`, `visits`, `favourites`, game name | `games.roblox.com/v1/games` | polled every 60 s; CCU older than 15 min is reported as 0 with the real `updatedAt` |
| `stats.ccuYesterday` | stored samples | sample within 1 h of "24 h ago" |
| `stats.robux24h` | Analytics Query API `ItemMonetizationRevenue` (OneHour), summed over 24 h | polled every 15 min; `null` without `universe.analytics:read` |
| `ccuSparklines` | stored samples, last 24 h → 24 points | |
| `recentAlerts` | alert evaluator | last 20 |
| `campaigns` | — | always `[]`: Roblox has no ads API for OAuth apps yet |

## Alerts

After each stats poll, the server runs `AlertEngine` (shared with the app) for every enabled rule on
universes the owner still has access to. It fires on the rising edge with cooldown, records the event and
pushes to the user's devices:

```json
{ "aps": { "alert": { "title": "<game name>", "body": "900 players: above 500" }, "sound": "default",
           "thread-id": "game-<id>" },
  "url": "rbxpulse://game/<id>" }
```

Tokens that APNs reports as unregistered are deleted.

## Not yet implemented

| Method | Path | Purpose |
|---|---|---|
| GET/POST/PUT/DELETE | `/v1/goals` | Goal editing (goals are stored and returned in the dashboard already) |
| — | Live Activity push tokens | "Watch Game" Live Activities |
