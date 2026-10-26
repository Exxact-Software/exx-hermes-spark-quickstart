#!/usr/bin/env bash
# Point the Hermes desktop app at the CONTAINER agent.
#
#   ./scripts/attach-desktop.sh --profile profiles/spark-qwen38.conf [--launch]
#
# Scope note, because this is the one step that reaches outside the container:
# everything here writes HOST state only -- a forward, ~/.config/Hermes/, and
# ~/.local/bin. It never execs into the sandbox and never touches
# /sandbox/.hermes, so it CANNOT break the config seal.
#
# That distinction is why this exists at all. The obvious way to make the
# desktop app sign in -- `hermes plugins enable basic` inside the sandbox -- was
# tried on 2026-08-20 and poisons the NEXT container start: the config hash stops
# matching, the guard fails closed, and the sandbox crash-loops unrecoverably.
# It is deliberately disabled in onboard-agent.sh. Do not re-add it.
#
# The desktop app itself comes from the HOST Hermes install (`hermes desktop`),
# which this repo does not install -- see the prerequisite check below.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib/profile.sh
. scripts/lib/profile.sh
set -euo pipefail

LAUNCH=0
ARGS=()
for a in "$@"; do case "$a" in --launch) LAUNCH=1 ;; *) ARGS+=("$a") ;; esac; done
profile_bootstrap "${ARGS[@]}"

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

UI="http://127.0.0.1:${CONTROL_UI_PORT}"
CONN="${HERMES_DESKTOP_CONN:-$HOME/.config/Hermes/connection.json}"

# --- prerequisite: the desktop app is not ours to install --------------------
if ! command -v hermes >/dev/null 2>&1; then
  die "the 'hermes' CLI is not on PATH.
    The desktop app ships with the Hermes Agent host install, which this repo
    does not install: https://hermes-agent.nousresearch.com
    Install it, then re-run this. The host agent stays DISABLED -- it is here
    for its desktop client, not to serve the model."
fi
ok "hermes CLI present ($(hermes --version 2>/dev/null | head -1))"

# --- the forward the app talks over -----------------------------------------
TOKEN="$(hermes_dashboard_token "$UI")"
if [[ -z "$TOKEN" ]]; then
  note "control UI not answering -- (re)establishing the forward"
  hermes_forward_restart "$CONTROL_UI_PORT" "$SANDBOX_NAME"
  for _ in $(seq 1 24); do TOKEN="$(hermes_dashboard_token "$UI")"; [[ -n "$TOKEN" ]] && break; sleep 5; done
fi
[[ -n "$TOKEN" ]] || die "the control UI at $UI is not serving a session token.
    Try: hermes-stack-restore"
ok "control UI reachable at $UI"

# --- write the app's config --------------------------------------------------
# Never point the desktop at the PUBLIC dashboard port: that one is behind
# nginx, which blanks the Authorization header, so the app authenticates
# against nothing and fails in a way that looks like a bad token.
mkdir -p "$(dirname "$CONN")"
[[ -f "$CONN" ]] && cp "$CONN" "$CONN.bak-$(date +%Y%m%d-%H%M%S)"
python3 - "$CONN" "$UI" "$TOKEN" <<'PY'
import json, os, sys, tempfile
path, url, token = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as fh: cfg = json.load(fh)
    except Exception: cfg = {}
cfg["mode"] = "remote"
cfg.setdefault("remote", {})
cfg["remote"]["url"] = url
cfg["remote"]["authMode"] = "token"
cfg["remote"]["token"] = {"encoding": "plain", "value": token}
cfg.setdefault("profiles", {})
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as fh: json.dump(cfg, fh, indent=2)
os.replace(tmp, path)
PY
ok "wrote $CONN (remote mode -> $UI)"

# --- prove it, rather than assuming -----------------------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Authorization: Bearer $TOKEN" "$UI/api/sessions")"
[[ "$code" == 200 ]] || die "token written but /api/sessions returned $code"
noauth="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$UI/api/sessions")"
ok "token authenticates (with: 200, without: $noauth)"

# --- keep it working: the token rotates on every dashboard restart -----------
install -d "$HOME/.local/bin"
install -m755 host/hermes-desktop-token-sync "$HOME/.local/bin/hermes-desktop-token-sync"
ok "installed hermes-desktop-token-sync (the token rotates; this re-syncs it)"

printf '\n%s  Desktop app configured.%s\n\n' "$GRN" "$OFF"
printf '    Launch it:  %shermes desktop%s\n' "$YEL" "$OFF"
printf '    %sIf it ever says "gateway session has expired", nothing is broken --%s\n' "$DIM" "$OFF"
printf '    %sthe token rotated. Run: hermes-desktop-token-sync%s\n\n' "$DIM" "$OFF"

if (( LAUNCH )); then
  note "launching..."
  hermes desktop >/dev/null 2>&1 &
  ok "hermes desktop started"
fi
