#!/usr/bin/env bash
# Hermes Workspace — installer entry point
#
# Thin proxy to the full installer at scripts/install.sh.
# Both invocation styles work and resolve to the same (best) installer:
#
#   curl -fsSL https://raw.githubusercontent.com/Konor11/hermes-workspace/main/install.sh | bash
#   bash scripts/install.sh
#
# The full installer provisions Hermes Agent + Gateway + Dashboard + Workspace
# + Caddy (HTTPS reverse proxy) in one command, with systemd/docker modes,
# auto port picking, custom domains, and an interactive `hermes setup` step
# (run with a real PTY so password/token prompts are shown).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"

# Running from inside a cloned repo — exec the local copy directly.
if [[ -f "$SCRIPT_DIR/scripts/install.sh" ]]; then
  exec bash "$SCRIPT_DIR/scripts/install.sh" "$@"
fi

# Running via pipe (curl | bash) — fetch the real installer from the repo.
REAL_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/Konor11/hermes-workspace/main/scripts/install.sh}"
TMP="$(mktemp -t hermes-workspace-install.XXXXXX.sh)"
if curl -fsSL "$REAL_URL" -o "$TMP"; then
  exec bash "$TMP" "$@"
else
  echo "Failed to download the installer from: $REAL_URL" >&2
  exit 1
fi
