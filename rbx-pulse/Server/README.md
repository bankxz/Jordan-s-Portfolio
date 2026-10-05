# RBX Pulse server

Swift 6.2 + Hummingbird 2 + Postgres. Owns Roblox OAuth and Roblox tokens, polls game stats and
revenue, evaluates alerts and sends pushes. The API is in `../docs/api/backend-contract.md`; the
design is in `../docs/decisions/0005-backend.md`.

```
Sources/RBXPulseServerCore/
  Config/     ServerConfig (env vars, secrets redacted in logs)
  Crypto/     random tokens, PKCE S256, SHA-256 hashing, AES-GCM SecretBox
  Roblox/     OAuth client, games stats client, Analytics Query client (all behind HTTPExecutor)
  Auth/       AuthService (OAuth flow, sessions, rotation, reuse detection), RobloxTokenManager
  API/        routes, middleware (auth, rate limit), DashboardBuilder, error shape
  Storage/    Store protocol, InMemoryStore, PostgresStore (+ migrations)
  Workers/    StatsPoller, RevenuePoller, AlertEvaluator, PeriodicService
  Push/       APNs sender (ES256 provider token)
Tests/        Swift Testing: contract suite (memory + Postgres), auth, routes, workers, app compatibility
```

## Configuration

| Variable | Required | Notes |
|---|---|---|
| `ROBLOX_CLIENT_ID` / `ROBLOX_CLIENT_SECRET` | ✓ | From the Roblox OAuth app (Creator Dashboard → OAuth 2.0 apps) |
| `ROBLOX_REDIRECT_URI` | ✓ | `https://<your-host>/oauth/roblox/callback`, registered exactly on the OAuth app |
| `TOKEN_ENCRYPTION_KEY` | ✓ | 32 random bytes, base64: `head -c 32 /dev/urandom \| base64`. Rotating it invalidates stored Roblox tokens (users reconnect). |
| `DATABASE_URL` | prod | `postgres://user:pass@host:5432/db?sslmode=require`. Unset → in-memory (dev only). |
| `APP_CALLBACK_URL` | | Default `rbxpulse://auth/complete` |
| `APNS_PRIVATE_KEY`, `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_BUNDLE_ID` | | `.p8` contents (newlines may be `\n`). Unset → pushes disabled. |
| `PORT`, `HOST`, `LOG_LEVEL` | | Defaults `8080`, `0.0.0.0`, `info` |

### Roblox OAuth app

1. Creator Dashboard → **OAuth 2.0 apps** → create. Category: **Analytics & Insights Tools**.
2. Scopes: `openid`, `profile`, `universe.analytics:read`.
3. Redirect URL: exactly `ROBLOX_REDIRECT_URI`.
4. Store the client secret in your secret manager; it's shown once.

## Run locally

```bash
docker run -d --name rbx-pg -e POSTGRES_PASSWORD=pulse -e POSTGRES_DB=rbxpulse -p 5432:5432 postgres:16
cd Server
ROBLOX_CLIENT_ID=... ROBLOX_CLIENT_SECRET=... \
ROBLOX_REDIRECT_URI=http://localhost:8080/oauth/roblox/callback \
TOKEN_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64) \
DATABASE_URL='postgres://postgres:pulse@localhost:5432/rbxpulse?sslmode=disable' \
swift run rbxpulse-server
```

Migrations run automatically at start-up (advisory-locked, safe with several instances).

## Test

```bash
swift test                                                     # in-memory store
TEST_DATABASE_URL='postgres://postgres:pulse@localhost:5432/rbxpulse?sslmode=disable' \
REQUIRE_POSTGRES=1 swift test                                  # + Postgres contract suite
swift test --sanitize=thread                                   # concurrency
scripts/docker-test.sh                                         # no local Swift toolchain
```

## Deploy

```bash
docker build -f Server/Dockerfile -t rbxpulse-server .        # from rbx-pulse/
```

Any container host works (Fly.io, Render, ECS, Cloud Run with min instances ≥ 1, because the pollers must keep
running). Put it behind HTTPS; the Roblox redirect URL must be `https`. Set the app's
`RBXPULSE_API_BASE_URL` build setting to the server URL to switch the app from demo data to live data.

## Security notes

- Roblox tokens are sealed with AES-256-GCM; RBX Pulse session tokens are stored only as SHA-256 hashes.
- OAuth `state`/PKCE attempts and session codes are single-use (`DELETE ... RETURNING`).
- Refresh tokens rotate; reuse of an old one revokes the whole session family.
- Roblox refresh tokens are single-use: single-flight per user plus compare-and-swap in the database.
- Unauthenticated auth endpoints are rate-limited per client address (in-process; put a shared limiter at
  the edge if you run many instances).
- Every data route checks the universe is in the caller's Roblox grant.
