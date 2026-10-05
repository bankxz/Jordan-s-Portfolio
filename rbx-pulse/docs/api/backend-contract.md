# RBX Pulse backend contract (v1)

The app talks only to the RBX Pulse backend. The backend talks to Roblox (Open Cloud + OAuth),
stores Roblox tokens, polls metrics, evaluates alerts and sends APNs. See decision 0003.

Swift types for every payload live in `Packages/RBXPulseKit` (`BackendAPI.swift`, models). The
same package can be used by a Swift backend, so app and server can't drift apart.

- JSON, `application/json`. Dates are ISO 8601 UTC (`2026-10-05T18:00:00Z`).
- Authenticated endpoints need `Authorization: Bearer <access token>`.
- Errors: `401` means the access token is expired or invalid (the client refreshes once, then retries
  once). `403` means forbidden. `404` means not found. `429` means rate limited, with an optional
  `Retry-After` in seconds. `5xx` means a server error.

## Auth

| Method | Path | Auth | Body | Response |
|---|---|---|---|---|
| POST | `/v1/auth/roblox/start` | — | — | `{ "authorizeURL": "https://apis.roblox.com/oauth/v1/authorize?..." }` |
| GET | `/oauth/roblox/callback` | — | Roblox redirect (`code`, `state`) | `302` → `rbxpulse://auth/complete?code=<one-time session code>` |
| POST | `/v1/auth/session` | — | `{ "code": "<one-time session code>" }` | `AuthTokens` |
| POST | `/v1/auth/refresh` | — | `{ "refreshToken": "..." }` | `AuthTokens`; `400`/`401` = refresh token dead |
| POST | `/v1/auth/logout` | ✓ | — | `204`; the backend revokes the Roblox tokens |

`AuthTokens`: `{ "accessToken": "...", "refreshToken": "...", "accessTokenExpiresAt": "<date>" }`

Backend rules (from `roblox-cloud`):
- Fresh `state` and PKCE verifier per attempt. Verify `state` before exchanging. The code is single-use.
- Confidential client: the client secret stays server-side.
- Roblox refresh tokens rotate. Allow one refresh per Roblox account at a time (row lock or
  advisory lock), and replace the stored pair atomically.
- RBX Pulse refresh tokens also rotate. Detect reuse of an old refresh token, then revoke the
  session family.
- Request minimum scopes. Never log codes or tokens.

## Data

| Method | Path | Response |
|---|---|---|
| GET | `/v1/dashboard` | `Dashboard` |
| GET | `/v1/games/{universeId}/series?metric=ccu\|visits\|favourites\|robux&range=24h\|7d\|30d` | `MetricSeries` |
| PUT | `/v1/games/{universeId}/favourite` | body `{ "value": true }` → `204` |
| PUT | `/v1/games/{universeId}/working-on` | body `{ "value": true }` → `204` |

`Dashboard`:

```json
{
  "games": [Game],
  "goals": [Goal],
  "campaigns": [Campaign],
  "recentAlerts": [AlertEvent],
  "ccuSparklines": { "<universeId>": MetricSeries },
  "generatedAt": "<date>"
}
```

There's a decoding fixture in `Tests/RBXPulseKitTests/APIClientTests.swift`
(`dashboardDecodesContractFixture`). Update it whenever the contract changes.

## Planned (not yet implemented in the app)

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/devices` | Register an APNs device token + Live Activity push tokens |
| GET/POST/PUT/DELETE | `/v1/alerts/rules` | Alert rules (`AlertRule`) |
| GET/POST/PUT/DELETE | `/v1/goals` | Goals and tasks |

Alert evaluation runs on the server with `AlertEngine` (shared package). It stores `AlertRuleState`
per rule and sends APNs with `rbxpulse://game/<id>` as the deep link.
