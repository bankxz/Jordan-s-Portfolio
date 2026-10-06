# Installing Peak on your iPhone without a Mac or a paid Apple account

CI builds an unsigned iPhone app file on every push. AltStore or Sideloadly signs it with your free Apple ID
and installs it from a Windows PC (or a Mac).

What you give up with a free Apple ID:
- **The app stops opening after 7 days.** Refresh it (AltStore does this by itself over Wi-Fi while the PC is
  on, and Sideloadly can too) or reinstall it.
- **No push notifications.** Alerts and the briefing still show in the app.
- **The home screen widgets don't receive data.** They need an App Group, which isn't included in this
  build.
- **A few apps at a time.** Free Apple IDs can only have a few sideloaded apps installed at once.

## 1. Get the app file

1. Open the repo on GitHub → **Actions** → the latest **Peak** run on branch `claude/rbx-pulse-skills-setup`.
2. Under **Artifacts**, download **Peak-ipa**, which arrives as a zip. Unzip it to get `Peak.ipa`.

Which server the app talks to is set in `peak/Config/sideload.env`. While that is empty, the app runs in
demo mode with sample data, which is handy for a first try. Once your server is up, put its https address
there (or ask Claude to), and the next CI run builds a live version.

## 2a. Install with AltStore (refreshes by itself)

1. On the PC, install **AltServer** from altstore.io. AltStore's site says which iTunes and iCloud versions it
   needs; on Windows these are Apple's own downloads, not the Microsoft Store versions.
2. Connect the iPhone with a cable. Trust the computer if asked.
3. Click the AltServer icon in the tray → **Install AltStore** → your iPhone. Sign in with your Apple ID.
4. On the iPhone:
   - Settings → General → VPN & Device Management → trust your Apple ID.
   - Settings → Privacy & Security → turn on **Developer Mode** and restart.
5. Copy `Peak.ipa` to the phone, for example via iCloud Drive, or AirDrop from a Mac.
6. In AltStore → **My Apps** → **+** → pick `Peak.ipa`.
7. Keep AltServer running on the PC, with the phone on the same Wi-Fi, so AltStore can refresh Peak before
   the 7 days run out.

## 2b. Install with Sideloadly (simplest)

1. Install **Sideloadly** from sideloadly.io, plus the iTunes/iCloud versions its site lists.
2. Connect the iPhone with a cable.
3. Drag `Peak.ipa` into Sideloadly, enter your Apple ID, and press **Start**.
4. On the iPhone, trust your Apple ID and turn on Developer Mode, as in AltStore step 4.
5. Repeat every 7 days, or turn on Sideloadly's auto-refresh.

## 3. Sign in

Open Peak → **Sign in with Roblox**. Roblox's own page opens. Sign in there, pick the games Peak may see, and
you're back in the app.

Your Apple ID goes only to AltStore/Sideloadly and Apple, never to Peak or this repo.
