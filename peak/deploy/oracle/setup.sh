#!/usr/bin/env bash
# Sets up (or updates) Peak's server on an Oracle Cloud Ubuntu machine: Docker, firewall, Postgres, the Peak
# server and https. Run it as the normal "ubuntu" user:
#   curl -fsSLO https://raw.githubusercontent.com/bankxz/Jordan-s-Portfolio/claude/rbx-pulse-skills-setup/peak/deploy/oracle/setup.sh
#   bash setup.sh
# Running it again updates Peak to the latest code and keeps your settings.
set -euo pipefail

REPO="https://github.com/bankxz/Jordan-s-Portfolio.git"
BRANCH="claude/rbx-pulse-skills-setup"
SRC="$HOME/peak-src"
DIR="$SRC/peak/deploy/oracle"
ENV_FILE="$DIR/.env"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mProblem: %s\033[0m\n' "$*" >&2; exit 1; }
ask() { local prompt=$1 var; read -r -p "$prompt" var </dev/tty; printf '%s' "$var"; }
ask_secret() { local prompt=$1 var; read -r -s -p "$prompt" var </dev/tty; echo >&2; printf '%s' "$var"; }

[ "$(id -u)" -ne 0 ] || fail "run this as the normal user (ubuntu), not with sudo."
command -v apt-get >/dev/null || fail "this script is for Ubuntu (pick the Canonical Ubuntu image on Oracle)."

say "1/6 Installing Docker and tools (a few minutes the first time)"
if ! command -v docker >/dev/null || ! sudo docker compose version >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 git openssl curl
  sudo systemctl enable --now docker
fi
sudo docker compose version

say "2/6 Opening ports 80 and 443 on this machine"
# Oracle's Ubuntu images block everything but SSH in iptables, on top of the cloud "security list".
for port in 80 443; do
  if ! sudo iptables -C INPUT -p tcp --dport "$port" -m state --state NEW -j ACCEPT 2>/dev/null; then
    reject_line=$(sudo iptables -L INPUT --line-numbers -n | awk '$2 == "REJECT" {print $1; exit}')
    if [ -n "$reject_line" ]; then
      sudo iptables -I INPUT "$reject_line" -p tcp --dport "$port" -m state --state NEW -j ACCEPT
    else
      sudo iptables -A INPUT -p tcp --dport "$port" -m state --state NEW -j ACCEPT
    fi
  fi
done
if command -v netfilter-persistent >/dev/null; then sudo netfilter-persistent save >/dev/null; fi

# Building the server needs a few GB of memory; add swap on small machines.
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "$mem_kb" -lt 8000000 ] && [ "$(swapon --show | wc -l)" -eq 0 ]; then
  say "Adding 4 GB of swap (this machine has under 8 GB of memory)"
  sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

say "3/6 Getting the latest Peak code"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch -q --depth 1 origin "$BRANCH"
  git -C "$SRC" reset -q --hard FETCH_HEAD
else
  git clone -q --depth 1 --filter=blob:none --sparse --branch "$BRANCH" "$REPO" "$SRC"
  git -C "$SRC" sparse-checkout set peak
fi
git -C "$SRC" log -1 --format='Code version: %h (%cd)' --date=short

say "4/6 Settings"
touch "$ENV_FILE" && chmod 600 "$ENV_FILE"
current() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | sed -e "s/^'//" -e "s/'\$//" || true; }

PEAK_DOMAIN=$(current PEAK_DOMAIN)
ROBLOX_CLIENT_ID=$(current ROBLOX_CLIENT_ID)
ROBLOX_CLIENT_SECRET=$(current ROBLOX_CLIENT_SECRET)
ANTHROPIC_API_KEY=$(current ANTHROPIC_API_KEY)
TOKEN_ENCRYPTION_KEY=$(current TOKEN_ENCRYPTION_KEY)
POSTGRES_PASSWORD=$(current POSTGRES_PASSWORD)

if [ -n "$PEAK_DOMAIN" ]; then
  echo "Keeping saved settings for $PEAK_DOMAIN. (To change them, edit $ENV_FILE or delete it and run again.)"
else
  echo "Your server's address from DuckDNS, e.g. peak-yourname.duckdns.org"
  PEAK_DOMAIN=$(ask "Address: " | tr -d '[:space:]' | sed -e 's#^https\?://##' -e 's#/.*$##')
  [[ "$PEAK_DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || fail "\"$PEAK_DOMAIN\" doesn't look like an address."
  echo
  echo "From your Roblox OAuth app (Creator Dashboard > OAuth 2.0 apps). Its redirect URL must be:"
  echo "  https://$PEAK_DOMAIN/oauth/roblox/callback"
  ROBLOX_CLIENT_ID=$(ask "Roblox client ID: " | tr -d '[:space:]')
  [[ "$ROBLOX_CLIENT_ID" =~ ^[A-Za-z0-9_-]+$ ]] || fail "that doesn't look like a client ID."
  ROBLOX_CLIENT_SECRET=$(ask_secret "Roblox client secret (hidden while you type/paste): " | tr -d '[:space:]')
  [ -n "$ROBLOX_CLIENT_SECRET" ] || fail "the client secret is empty."
  echo
  ANTHROPIC_API_KEY=$(ask_secret "Claude API key for AI wording (optional, press Enter to skip): " | tr -d '[:space:]')
fi
for value in "$ROBLOX_CLIENT_SECRET" "$ANTHROPIC_API_KEY"; do
  [[ "$value" != *"'"* ]] || fail "a value contains a ' character, which isn't supported."
done
# Generated once and kept: changing them would sign everyone out / lose the database password.
[ -n "$TOKEN_ENCRYPTION_KEY" ] || TOKEN_ENCRYPTION_KEY=$(openssl rand -base64 32)
[ -n "$POSTGRES_PASSWORD" ] || POSTGRES_PASSWORD=$(openssl rand -hex 24)

cat > "$ENV_FILE" <<ENVEOF
# Peak server settings. Secret: don't share or commit this file.
PEAK_DOMAIN='$PEAK_DOMAIN'
ROBLOX_CLIENT_ID='$ROBLOX_CLIENT_ID'
ROBLOX_CLIENT_SECRET='$ROBLOX_CLIENT_SECRET'
ANTHROPIC_API_KEY='$ANTHROPIC_API_KEY'
TOKEN_ENCRYPTION_KEY='$TOKEN_ENCRYPTION_KEY'
POSTGRES_PASSWORD='$POSTGRES_PASSWORD'
ENVEOF
chmod 600 "$ENV_FILE"

say "5/6 Checking the address points at this machine"
public_ip=$(curl -fsS -4 --max-time 10 https://api.ipify.org || true)
domain_ip=$(getent ahostsv4 "$PEAK_DOMAIN" | awk 'NR==1 {print $1}' || true)
echo "This machine: ${public_ip:-unknown}   $PEAK_DOMAIN: ${domain_ip:-not found}"
if [ -n "$public_ip" ] && [ "$public_ip" != "$domain_ip" ]; then
  echo "Warning: on duckdns.org, set the IP for your address to $public_ip, or https won't work."
fi

say "6/6 Building and starting Peak (the first build takes 10-20 minutes)"
cd "$DIR"
sudo docker compose up -d --build
sudo docker image prune -f >/dev/null

echo "Waiting for https://$PEAK_DOMAIN/health ..."
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "https://$PEAK_DOMAIN/health" 2>/dev/null | grep -q ok; then
    say "Peak is running at https://$PEAK_DOMAIN"
    echo "Send Claude this address: https://$PEAK_DOMAIN"
    echo "Roblox redirect URL (must match the OAuth app): https://$PEAK_DOMAIN/oauth/roblox/callback"
    echo "To update later, run: bash setup.sh"
    exit 0
  fi
  sleep 10
done
echo
echo "Peak started, but https://$PEAK_DOMAIN isn't answering yet. Common causes:"
echo "  - Ports 80/443 not open in Oracle's security list (see the guide, step 3)."
echo "  - The DuckDNS IP doesn't match this machine (see the warning above)."
echo "Logs: cd $DIR && sudo docker compose logs --tail 50"
exit 1
