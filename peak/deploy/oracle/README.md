# Peak's server on Oracle Cloud (free, always on)

One Oracle "Always Free" machine runs everything: the database, Peak's server and https. The cost is $0. Oracle
asks for a card to check your identity, but Always Free resources aren't charged.

Total time: about an hour, mostly waiting. Do the steps in order. Claude can help at any step: send a screenshot.

## What you'll have at the end
- `https://<your-name>.duckdns.org`: your Peak server, running 24/7.
- The Peak app on your phone signing in with Roblox and showing your real games.

## Step 1: Oracle account
1. Go to **oracle.com/cloud/free** → **Start for free**.
2. Pick a **home region** close to you. It can't be changed later, and the free machines must be in this region.
3. Finish the sign-up, including the card check. Stay on the free account; don't upgrade to "Pay As You Go"
   unless you decide to later (see "If Oracle stops your machine" below).

## Step 2: Create the machine
1. In the Oracle console: **☰ menu → Compute → Instances → Create instance**.
2. **Name:** `peak`.
3. **Image:** click **Change image** → **Canonical Ubuntu** → **24.04** (22.04 also works).
4. **Shape:** click **Change shape** → **Ampere** → **VM.Standard.A1.Flex** → **2 OCPUs, 12 GB memory**. That's
   half of the free allowance, and plenty.
5. **Networking:** keep "Create new virtual cloud network" and "Assign a public IPv4 address".
6. **SSH keys:** choose **Generate a key pair for me**, then click **Save private key**. Keep that file safe;
   it's how you log in.
7. Click **Create**. When it's running, copy the **Public IP address** from the instance page.

If you see **"Out of capacity"**, the free machines in your region are taken right now. Try another
"Availability domain" on the same page, or try again later. It usually works within a day.

## Step 3: Open the web ports
On the instance page:
1. Click the **subnet** link → **Security lists** (or **Security**) → **Default Security List** → **Add Ingress
   Rules**.
2. Add a rule with **Source CIDR** `0.0.0.0/0`, **IP Protocol** TCP and **Destination port** `80`.
3. Add another rule, the same but with destination port `443`.

The setup script opens the same ports on the machine itself.

## Step 4: A free address (DuckDNS)
1. Go to **duckdns.org** and sign in with Google, GitHub or similar.
2. Type a name, e.g. `peak-yourname`, and click **add domain**.
3. In **current ip**, paste the machine's public IP from step 2, and click **update ip**.

Your address is now `peak-yourname.duckdns.org`.

## Step 5: Roblox OAuth app
Creator Dashboard → **OAuth 2.0 apps** → create:
- **Category:** Analytics & Insights Tools
- **Scopes:** `openid`, `profile`, `universe.analytics:read`
- **Redirect URL:** `https://peak-yourname.duckdns.org/oauth/roblox/callback`

Keep the **client ID** and **client secret** for the next step. The secret is shown once; never paste it into a
chat.

## Step 6: Run the setup (one command)
1. On Windows, open **PowerShell** and connect to the machine. Use your key file's path and your IP:
   ```
   ssh -i C:\Users\you\Downloads\ssh-key.key ubuntu@YOUR.PUBLIC.IP
   ```
   Type `yes` when asked about the fingerprint.

   If it says the key's permissions are "too open", run these, then try again:
   ```
   icacls C:\Users\you\Downloads\ssh-key.key /inheritance:r
   icacls C:\Users\you\Downloads\ssh-key.key /grant:r "$($env:USERNAME):(R)"
   ```
2. On the machine, paste:
   ```
   curl -fsSLO https://raw.githubusercontent.com/bankxz/Jordan-s-Portfolio/claude/rbx-pulse-skills-setup/peak/deploy/oracle/setup.sh
   bash setup.sh
   ```
3. It asks for:
   - your DuckDNS address;
   - the Roblox client ID and secret (the secret stays hidden while you paste);
   - optionally a Claude API key (press Enter to skip; AI wording stays off).

   Then it builds Peak, which takes 10–20 minutes the first time.
4. When it says **"Peak is running at https://…"**, send that address to Claude. Claude then sets
   `peak/Config/sideload.env`, and the next app file (`.ipa`) uses your server.

## Updating
Connect as in step 6 and run `bash setup.sh` again. It downloads the latest Peak and restarts it, keeping your
settings and data.

## If Oracle stops your machine
Oracle may stop an Always Free machine it considers idle: CPU, network **and** memory all under 15% for 7 days.
Peak is light, so this can happen.
- Oracle emails you before stopping it. Stopping isn't deleting: your data stays.
- To bring it back: **Compute → Instances → peak → Start**. Peak starts by itself.
- To avoid it entirely, you can upgrade the account to **Pay As You Go**. Always Free resources stay free, and
  idle machines aren't stopped. The catch is that anything beyond the free limits would be charged to the
  card. Only do this if you're comfortable checking that.

## Useful commands (on the machine)
```
cd ~/peak-src/peak/deploy/oracle
sudo docker compose ps                     # what's running
sudo docker compose logs --tail 100 server # Peak's server log
sudo docker compose restart server         # restart Peak
```
Settings live in `~/peak-src/peak/deploy/oracle/.env`. It's secret: never share it.
