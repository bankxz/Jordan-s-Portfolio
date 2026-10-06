# Peak error reporter (Roblox)

Two scripts that send your game's errors to Peak, which groups them and shows them on the game's page in the
app ([decision 0008](../docs/decisions/0008-error-reports-from-the-game.md)).

| File | Where it goes |
|---|---|
| `PeakErrorReporter.server.luau` | A Script in ServerScriptService |
| `PeakErrorReporter.client.luau` | A LocalScript in StarterPlayer > StarterPlayerScripts |

Setup (the app walks through the same steps, under a game's Errors card):
1. In Studio: Game Settings > Security > Allow HTTP Requests.
2. In Peak: create a key for the game. It's shown once.
3. In Creator Hub: your game > Secrets. Add `peak_ingest` with the key as its value and your Peak server's
   domain.
4. Add the scripts. Set `ENDPOINT` in the server script; the app's copy already has it filled in.

What leaves the game:
- Grouped error messages with counts, the place version, and whether each came from the server or a player's
  device.
- Names, display names and user IDs of players in the server are replaced with `<player>` before sending.
  Peak's server strips IDs, numbers and quoted values again.

The PeakKit test `shippedScriptsMatchTheApp` keeps these files identical to what the app shows.

Behaviour tests run the scripts against stubbed Roblox services (needs the
[`luau` CLI](https://github.com/luau-lang/luau/releases)):

    LUAU=/path/to/luau ./run-tests.sh
