#!/usr/bin/env bash
# Make the Hermes dashboard reachable from another machine.
#
# Optionally behind a password: DASHBOARD_AUTH=basic|none in the profile.
#
# WHY THIS IS NEEDED: the dashboard binds 127.0.0.1 only. `--control-ui-port`
# sets the port, not the bind address -- there is no flag for it. On a headless
# Spark the URL that `nemohermes <name> dashboard-url` prints is therefore
# unreachable from your laptop unless you already have an SSH/VS Code tunnel.
#
# WHY A PLAIN PORT FORWARD IS NOT ENOUGH: Hermes rejects requests whose Host is
# not localhost (anti-DNS-rebinding, GHSA-ppp5-vxwm-4cf7) and rejects websockets
# whose Origin is not the loopback dashboard. A TCP forward gets HTTP 400 on
# every request, or -- worse -- a page that loads perfectly with a chat that
# dies with "connection interrupted (code 1006)". Three headers must be
# rewritten. That is what this nginx proxy does.
#
# WHY AUTH IS OPTIONAL, AND WHY IT DEFAULTS ON: this proxy originally shipped
# with no auth and said so only in a comment. Anyone who could reach the bind
# address got the dashboard, including its Keys page, and an unauthenticated
# Hermes has already been pentested to root shell and arbitrary file write. So a
# machine a colleague or customer can reach must not be open -> `basic` default.
#
# BUT AUTH IS NOT PART OF HERMES. It is a feature this repo adds on top of
# Hermes, and a demo does not need it -- a password prompt shows a viewer
# something they will not get by installing Hermes. `DASHBOARD_AUTH=none` exists
# for that, and the demo profile (spark-video) uses it. A demo should depict
# Hermes, not our hardening.
#
#   ./scripts/expose-dashboard.sh --profile profiles/spark-qwen38.conf
#   ./scripts/expose-dashboard.sh --profile profiles/spark-qwen38.conf --stop
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib/profile.sh
. scripts/lib/profile.sh
# shellcheck source=scripts/lib/common.sh
. scripts/lib/common.sh
set -euo pipefail

STOP=0; PROFILE_ARGS=()
while (( $# )); do
  case "$1" in
    --stop)     STOP=1; shift ;;
    --bind-ip)  BIND_IP="${2:-}"; shift 2 ;;
    --profile)  PROFILE_ARGS=(--profile "${2:-}"); shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
profile_bootstrap "${PROFILE_ARGS[@]:-}"

PROXY_NAME="hermes-dash-${SANDBOX_NAME}"
LISTEN_PORT="$DASHBOARD_PUBLIC_PORT"
UI_PORT="$CONTROL_UI_PORT"
CRED_DIR="${CRED_DIR:-${HERMES_CRED_DIR:-$HOME/.hermes-quickstart}}"

if (( STOP )); then
  docker rm -f "$PROXY_NAME" >/dev/null 2>&1 && echo "stopped $PROXY_NAME" || echo "$PROXY_NAME was not running"
  exit 0
fi

# A repeated install/teardown cycle leaves an openshell forward that is still
# BOUND on this port but answers nothing -- the failure mode this repo keeps
# running into, and why the rule here is to judge a forward by what it serves
# rather than by whether the port is taken. Rebuild it once before giving up,
# instead of making the user work out that a listening port is the problem.
if ! curl -sSf --max-time 5 "http://127.0.0.1:${UI_PORT}/" >/dev/null 2>&1; then
  echo "nothing served on 127.0.0.1:${UI_PORT}; rebuilding the forward"
  hermes_forward_restart "$UI_PORT" "$SANDBOX_NAME"
  curl -sSf --max-time 10 "http://127.0.0.1:${UI_PORT}/" >/dev/null 2>&1 \
    || { echo "no dashboard on 127.0.0.1:${UI_PORT} -- is the sandbox running?" >&2; exit 1; }
  echo "forward rebuilt"
fi

AUTH_MODE="${DASHBOARD_AUTH:-basic}"
case "$AUTH_MODE" in
  none|basic) ;;
  *) echo "DASHBOARD_AUTH='$AUTH_MODE' is not valid (expected: none | basic)" >&2; exit 2 ;;
esac

# --- credential ------------------------------------------------------------
# Generated, not configured. A password in a committed profile is a password in
# everyone's git history.
#
# ⚠ AUTH IS NOT PART OF HERMES. This basic-auth layer is added by this repo, so
# showing it to a viewer shows something they will not get by installing Hermes.
# So DASHBOARD_AUTH=none exists, and the demo profile uses it -- a demo should
# depict Hermes, not our hardening.
# `basic` remains the default for anything a colleague or customer can reach.
mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
PASS_FILE="$CRED_DIR/dashboard.password"
HTPASSWD="$CRED_DIR/dashboard.htpasswd"

if [[ "$AUTH_MODE" == none ]]; then
  PASS=""
elif [[ ! -s "$PASS_FILE" ]]; then
  # tr -dc can exit non-zero when head closes the pipe early; that is expected.
  PASS="$( { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom || true; } | head -c 24)"
  [[ ${#PASS} -eq 24 ]] || { echo "could not generate a password" >&2; exit 1; }
  umask 077; printf '%s\n' "$PASS" > "$PASS_FILE"
  echo "generated a dashboard password -> $PASS_FILE"
else
  PASS="$(head -1 "$PASS_FILE")"
fi
[[ "$AUTH_MODE" == basic ]] && chmod 600 "$PASS_FILE"

# openssl is present everywhere we run; an htpasswd binary is not. -apr1 is the
# Apache MD5 format nginx accepts.
if [[ "$AUTH_MODE" == basic ]]; then
SALT="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 8 || echo hermessalt)"
HASH="$(openssl passwd -apr1 -salt "$SALT" "$PASS")"
printf '%s:%s\n' "$DASHBOARD_AUTH_USER" "$HASH" > "$HTPASSWD"
# 0644, deliberately, and only on the HASH file. nginx's worker runs as uid 101
# inside the container and cannot read a 0600 bind mount -- that failure mode is
# a 500 on every authenticated request, which looks like a broken proxy rather
# than a permissions problem. Confidentiality comes from the parent directory
# being 0700: no other host user can traverse into it. The plaintext password
# file beside this one stays 0600 and is never mounted anywhere.
chmod 644 "$HTPASSWD"
fi

# --- proxy -----------------------------------------------------------------
AUTH_STANZA=""
if [[ "$AUTH_MODE" == basic ]]; then
  AUTH_STANZA=$'    auth_basic           "Hermes ('"${SANDBOX_NAME}"$')";\n    auth_basic_user_file /etc/nginx/htpasswd;'
fi

# Durable, NOT mktemp in /tmp. The nginx container bind-mounts this file for as
# long as it runs, but systemd-tmpfiles cleans /tmp on an age policy (10 days on
# many distros, 30 on others). The container keeps working off the open inode,
# so nothing breaks at cleanup time -- it breaks at the NEXT restart, weeks
# later, with a "no such file" that looks nothing like its cause. Lives beside
# the htpasswd it is generated with, and is regenerated on every run anyway.
CONF="$CRED_DIR/dashboard-proxy.conf"
cat > "$CONF" <<NGINX
events { worker_connections 1024; }
http {
  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
  server {
    listen ${LISTEN_PORT};
    proxy_http_version 1.1;

${AUTH_STANZA}

    # 1. anti-DNS-rebinding: any other Host gets HTTP 400
    proxy_set_header Host localhost;
    # 2. uvicorn trusts loopback; a real client IP 403s every chat socket
    proxy_set_header X-Forwarded-For 127.0.0.1;
    proxy_set_header X-Real-IP 127.0.0.1;
    # 3. websocket Origin check: wrong Origin => 403 handshake => UI shows
    #    "Chat connection interrupted (code 1006)"
    proxy_set_header Origin http://localhost:${UI_PORT};
    # Never forward the browser's credentials to the dashboard itself.
    proxy_set_header Authorization "";

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;

    location / { proxy_pass http://127.0.0.1:${UI_PORT}; }
  }
}
NGINX

# Recreate rather than reload: a single-file bind mount follows the inode, so an
# in-place edit leaves nginx serving the old file while reload reports success.
docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
MOUNTS=(-v "${CONF}:/etc/nginx/nginx.conf:ro")
[[ "$AUTH_MODE" == basic ]] && MOUNTS+=(-v "${HTPASSWD}:/etc/nginx/htpasswd:ro")
# --restart unless-stopped: without it the proxy did not come back after a
# reboot and nothing else restarted it, so the published dashboard port was
# dead on every boot while the loopback dashboard behind it was fine. `--stop`
# uses `docker rm -f`, which is what "unless-stopped" should not override.
docker run -d --name "$PROXY_NAME" --network host --restart unless-stopped \
  "${MOUNTS[@]}" \
  nginx:alpine >/dev/null

sleep 4

ANON="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
  "http://${BIND_IP}:${LISTEN_PORT}/" 2>/dev/null || echo 000)"

if [[ "$AUTH_MODE" == none ]]; then
  # Nothing to prove about a password; prove the page is actually reachable,
  # because that is the claim being made.
  if [[ "$ANON" == "200" ]]; then
    echo
    if [[ "$BIND_IP" == 127.0.0.1 ]]; then
      echo "✓ dashboard on THIS MACHINE ONLY:  http://127.0.0.1:${LISTEN_PORT}"
      echo "  nothing is exposed to your network. To publish it deliberately:"
      echo "    ./install.sh --profile <profile> --bind-ip auto     # tailscale, else LAN"
      echo "    ./install.sh --profile <profile> --bind-ip <address>"
    else
      echo "✓ dashboard reachable at:  http://${BIND_IP}:${LISTEN_PORT}"
    fi
    echo "  no password — DASHBOARD_AUTH=none, matching what Hermes itself does"
    echo "  ⚠ anyone who can reach ${BIND_IP} can use this agent. Fine on an"
    echo "    isolated box; use DASHBOARD_AUTH=basic anywhere others can reach."
    echo "  click 'New chat'"
    echo "  stop with: ./scripts/expose-dashboard.sh --profile <profile> --stop"
  else
    echo "✗ dashboard not reachable: got ${ANON}, want 200" >&2
    docker logs --tail 20 "$PROXY_NAME" >&2
    docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
    exit 1
  fi
else
  # Verify BOTH directions. A 200 alone would not prove the password is enforced,
  # and a 401 alone would not prove a valid login works.
  AUTHED="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -u "${DASHBOARD_AUTH_USER}:${PASS}" "http://${BIND_IP}:${LISTEN_PORT}/" 2>/dev/null || echo 000)"
  if [[ "$ANON" == "401" && "$AUTHED" == "200" ]]; then
    echo
    echo "✓ dashboard reachable at:  http://${BIND_IP}:${LISTEN_PORT}"
    echo "  user: ${DASHBOARD_AUTH_USER}   password: ${PASS_FILE}"
    echo "  verified: no credentials -> 401, valid credentials -> 200"
    echo "  click 'New chat' -- existing sessions keep the config they were created with"
    echo "  stop with: ./scripts/expose-dashboard.sh --profile <profile> --stop"
  else
    echo "✗ auth check failed: anonymous=${ANON} (want 401), authenticated=${AUTHED} (want 200)" >&2
    docker logs --tail 20 "$PROXY_NAME" >&2
    echo "  refusing to leave an unverified dashboard exposed -- removing the proxy" >&2
    docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
    exit 1
  fi
fi
