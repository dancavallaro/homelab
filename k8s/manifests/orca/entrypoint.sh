#!/bin/bash
set -euo pipefail

# Saved credentials are sealed against the machine ID, so it must outlive the pod.
[ -s "$HOME/.machine-id" ] || tr -d '-' </proc/sys/kernel/random/uuid >"$HOME/.machine-id"

# Lives on the volume so Claude Code's own updater works between image builds.
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash \
  || echo "Claude Code install failed; sessions can't run claude until it's installed" >&2

mkdir -p "$HOME/workspaces"

serve=(orca-ide serve --port 6768 --bind 0.0.0.0 --pairing-address "$ORCA_PAIRING_ADDRESS")

# Pairing links are credentials and stdout goes to Loki. --supervise would redact the link.
if [ -e "$HOME/.pair-next-start" ]; then
  [ "$(cat "$HOME/.pair-next-start")" = mobile ] && serve+=(--mobile-pairing)
  rm -f "$HOME/.pair-next-start"
  umask 077
  exec "${serve[@]}" >"$HOME/pairing.txt" 2>&1
fi

rm -f "$HOME/pairing.txt"
# --supervise restarts a crashed orcad in place, so terminals outlive it.
exec "${serve[@]}" --supervise --no-pairing
