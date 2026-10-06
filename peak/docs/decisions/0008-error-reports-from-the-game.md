# 0008 — Error reports come from the game, not Roblox's server-logs API

- **Date:** 2026-10-06
- **Status:** accepted
- **Skills consulted:** roblox-cloud (Secrets, HttpService), roblox-security (client is compromised, rate-limit
  remotes, no secrets in client code), roblox-networking (validate type and size, per-player throttles)

## Context

V1 includes an error-log summariser. Roblox's Server Management API has game-server logs, but:
- it is beta;
- it needs `universe:read`, a new OAuth scope, so every user would have to reconnect;
- logs are listed per place version, and versions are found through an endpoint
  (`game-servers:filter-options`) whose response shape isn't documented;
- it only sees server logs, not errors on players' devices.

## Decision

A small open-source Luau reporter runs in the game.

1. **Server script.**
   - Listens to `ScriptContext.Error` and groups identical messages.
   - Sends a batch every 60 s, and on `BindToClose`, to `POST /v1/ingest/errors`.
   - Authenticates with a per-game Peak ingest key stored as a **Roblox Secret** (`peak_ingest`) and sent as
     `Authorization: Bearer …` (Secrets work only in headers or URLs, only on the server, and only for the domain
     set on the secret).
   - Replaces the names, display names and user IDs of players in the server with `<player>` before anything
     is sent.
   - Cuts messages to 500 bytes without splitting a UTF-8 character, because the batch is sent as JSON.
2. **Client script.**
   - Forwards its own `ScriptContext.Error` messages through a RemoteEvent.
   - Throttles itself to 5 a minute.
   - The server re-validates everything: string type, length cap, 5 a minute per player, at most 100 distinct
     messages pending.
3. **Peak server.**
   - The key is created in the app (`POST /v1/games/{id}/error-key`), shown once and stored only as a hash.
     Creating a new key replaces the old one.
   - Ingest is rate-limited per key, capped in size, and normalised with `ErrorClusterer.signature`, which strips
     player names, IDs, numbers and quoted values. Raw messages aren't stored, so no player names are kept.
   - Counts are kept per day, signature, place version and source (server or client), for 30 days. One redacted
     example is kept per row; it keeps script line numbers (`Script:42:`) so the creator knows where to look.
   - Reports are buffered in memory and written every 15 s, so hundreds of game servers each reporting once a
     minute cost a few database writes. A crash loses at most 15 s of counts.
   - At most 500 distinct signatures per game per UTC day; new ones past that are dropped, so junk sent through
     the client remote can't grow storage without limit.
   - A key stops working when its owner loses access to the game, and is deleted with their account. Error counts
     are game data, not user data; they expire after 30 days.
   - Games reach Peak at `PUBLIC_BASE_URL` (https only; it defaults to the OAuth redirect's origin).

## Alternatives considered

- **Server Management API logs:** reasons above. Revisit once it's out of beta with a documented version listing.
- **A Roblox Open Cloud API key in Peak:** the creator would hand Peak a broad credential. A narrow Peak-issued
  ingest key is safer.

## Consequences

- The creator installs two scripts and adds one Secret; the app shows the steps and the scripts.
- `HttpService` must be enabled in the game.
- Client reports are attacker-controllable. They can add noise to the error list but can't do anything else:
  ingest only writes counts for that one game. In Ask, the example is passed as `example_untrusted`, and the
  prompt says never to follow instructions in it.
