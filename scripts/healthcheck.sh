#!/usr/bin/env bash
# Is this install actually healthy?
#
# Every check states what it expects, so "nothing errored" cannot be mistaken
# for "the check ran". Read-only: starts nothing, stops nothing, changes nothing.
#
#   ./scripts/healthcheck.sh --profile profiles/spark-qwen38.conf
#
# Exit 0 = healthy, 1 = something is wrong, 2 = could not run the checks.
#
# THE CHECK THAT MATTERS MOST IS THE SEAL. NemoClaw hashes the agent config at
# image build time and re-verifies it on every container start, failing CLOSED:
# on a mismatch the entrypoint sets HERMES_RESTART_FAILURE_CODE=mcp-integrity
# and drops into a sleep loop that never respawns the gateway. So a drifted
# config breaks NOTHING you can see -- it arms the sandbox to quarantine itself
# on its next start, which (restart policy unless-stopped) means the next
# reboot. Install works, demo works, and weeks later the machine comes up dead.
#
# The installer no longer causes that drift. Nothing prevents someone else from
# causing it again with a stray `hermes config set`, which is why this exists.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib/profile.sh
. scripts/lib/profile.sh
# shellcheck source=scripts/lib/common.sh
. scripts/lib/common.sh
set -uo pipefail
profile_bootstrap "$@"

GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
PASS=0; FAIL=0; WARN=0
pass() { PASS=$((PASS+1)); printf '%s  PASS%s  %-24s %s\n' "$GRN" "$OFF" "$1" "${2:-}"; }
fail() { FAIL=$((FAIL+1)); printf '%s  FAIL%s  %-24s %s\n' "$RED" "$OFF" "$1" "${2:-}"; }
warn() { WARN=$((WARN+1)); printf '%s  WARN%s  %-24s %s\n' "$YEL" "$OFF" "$1" "${2:-}"; }

UI="http://127.0.0.1:${CONTROL_UI_PORT}"
verdict() { local v="${1%% *}" d="${1#* }"; case "$v" in
  pass|match) pass "$2" "$d" ;; fail|drift) fail "$2" "$d" ;;
  na) printf '%s  n/a %s  %-24s %s\n' "$DIM" "$OFF" "$2" "$d" ;; *) warn "$2" "$d" ;; esac; }

# systemctl --user needs the user's own bus. Without XDG_RUNTIME_DIR -- unset in
# any non-login shell -- is-enabled fails and this reported "reboot recovery not
# enabled" about units that were enabled and a timer that was scheduled.
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
[[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] \
  || export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
# OpenShell names containers openshell-<workspace>--<sandbox>-<uuid> (0.0.137:
# openshell-default--hermes-demo-<uuid>), not openshell-<sandbox>-<uuid>. The
# pattern accepts both. Search ALL containers, not just running ones: after the
# 2026-10-23 reboot the sandbox container existed, Exited (137), and this
# reported "no container matching openshell-hermes-demo-*" -- a pattern that
# matches neither layout, and a message that hid the real state.
CPAT="^openshell-(.+--)?${SANDBOX_NAME}-[0-9a-f-]{36}"
C="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "${CPAT}\$" | head -1)" || true
C_ANY="$(docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null \
          | grep -E "${CPAT}\|" | head -1)" || true

printf '\n  %s%s / %s%s\n\n' "$DIM" "$PROFILE_NAME" "${SANDBOX_NAME}" "$OFF"

# --- 0. the gateway every openshell call goes to ------------------------------
GW_V="$(hermes_gateway_verdict "$(hermes_gateway_name_for_port "$NEMOCLAW_GATEWAY_PORT")")"
verdict "$GW_V" "OpenShell gateway"
# The gateway must be the one the user unit serves, or it will not be there
# after a reboot (a gateway started by an install session dies with the session).
gw_env="${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateway.env"
if grep -qx "OPENSHELL_SERVER_PORT=${NEMOCLAW_GATEWAY_PORT}" "$gw_env" 2>/dev/null \
   && systemctl --user is-enabled nemoclaw-openshell-gateway.service >/dev/null 2>&1; then
  pass "gateway survives reboot" "nemoclaw-openshell-gateway.service serves :${NEMOCLAW_GATEWAY_PORT}"
else
  fail "gateway survives reboot" "nothing at boot serves :${NEMOCLAW_GATEWAY_PORT} (see $gw_env)"
fi

# --- 1. the sandbox exists ---------------------------------------------------
if [[ -z "$C" ]]; then
  if [[ -n "$C_ANY" ]]; then
    fail "sandbox running" "${C_ANY%%|*} is ${C_ANY#*|}"
  else
    fail "sandbox running" "no container matching openshell-[<workspace>--]${SANDBOX_NAME}-<uuid>"
  fi
  printf '\n  %d passed, %d failed, %d warnings\n\n' "$PASS" "$FAIL" "$WARN"
  exit 1
fi
pass "sandbox container" "$C"

# A running container is NOT a working sandbox. After the 2026-10-23 reboot the
# container was up (docker start) while OpenShell held the sandbox in
# Phase: Error and every NemoClaw command refused it -- and this check, which
# only looked at docker, passed.
phase="$(hermes_sandbox_phase "$SANDBOX_NAME")"
case "$phase" in
  Ready) pass "sandbox Ready" "OpenShell phase Ready" ;;
  "")    fail "sandbox Ready" "OpenShell did not report a phase (gateway down?)" ;;
  *)     fail "sandbox Ready" "OpenShell phase $phase"
         [[ "$phase" == Error ]] && printf '        %sError is terminal. Fix: ./scripts/reset.py down --sandbox %s --yes && ./install.sh --profile <profile>%s\n' "$DIM" "$SANDBOX_NAME" "$OFF" ;;
esac

policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$C" 2>/dev/null)"
# NemoClaw 0.0.137 sets 'no' and nothing brings the sandbox back on its own --
# the gateway user service starts the gateway, not sandboxes. 'no' is fine only
# with the shutdown hook that leaves it Stopped (startable) instead of Error.
hook=0
systemctl is-enabled hermes-sandbox-shutdown.service >/dev/null 2>&1 \
  && systemctl is-active hermes-sandbox-shutdown.service >/dev/null 2>&1 && hook=1
verdict "$(hermes_restart_verdict "$policy" "$hook")" "sandbox reboot survival"

# --- 2. THE SEAL -------------------------------------------------------------
# Compare the config.yaml digest the guard checks against the live file. The
# .env line of the anchors legitimately differs (one hashes the file with a
# generated API_SERVER_KEY stripped), so compare ONLY the config.yaml line.
#
# Two layouts (see hermes_seal_verdict in lib/common.sh): older NemoClaw keeps a
# single root-owned anchor in /etc/nemoclaw; 0.0.137 guards against
# /sandbox/.hermes/.config-hash, rewrites config.yaml at startup and leaves the
# /etc anchor holding the hash of the pre-rewrite copy. Reading /etc alone
# reported DRIFTED on every healthy 0.0.137 sandbox.
seal="$(docker exec "$C" sh -lc '
  e=$(sed -n 1p /etc/nemoclaw/hermes.config-hash 2>/dev/null | cut -d" " -f1)
  s=$(sed -n 1p /sandbox/.hermes/.config-hash 2>/dev/null | cut -d" " -f1)
  b=$(sha256sum /sandbox/.hermes/config.yaml 2>/dev/null | cut -d" " -f1)
  n=$(sha256sum /sandbox/.hermes/.native-local-startup-config 2>/dev/null | cut -d" " -f1)
  echo "${e:--}|${s:--}|${b:--}|${n:--}"' 2>/dev/null)"
IFS='|' read -r s_etc s_sbx s_live s_nat <<<"${seal:--|-|-|-}"
for v in s_etc s_sbx s_live s_nat; do [[ "${!v}" == - ]] && printf -v "$v" ''; done
sv="$(hermes_seal_verdict "$s_etc" "$s_sbx" "$s_live" "$s_nat")"
case "${sv%% *}" in
  match)   pass "config seal" "${sv#* } (${s_live:0:12}...)" ;;
  unknown) warn "config seal" "could not read the hashes: ${sv#* }" ;;
  *)
    fail "config seal" "DRIFTED -- ${sv#* }"
    printf '        %sThis sandbox will QUARANTINE ITSELF on its next start.%s\n' "$RED" "$OFF"
    printf '        %sSomething ran `hermes config set` (or equivalent) after onboarding.%s\n' "$DIM" "$OFF"
    printf '        %sFix: ./scripts/reset.py down --sandbox %s --yes && ./install.sh --profile <profile>%s\n' "$DIM" "$SANDBOX_NAME" "$OFF"
    ;;
esac

# Line 3 is the MCP digest on older NemoClaw; 0.0.137 retired it (two-line file).
anchor_body="$(docker exec "$C" sh -lc 'cat /etc/nemoclaw/hermes.config-hash 2>/dev/null' 2>/dev/null)"
verdict "$(hermes_mcp_verdict "$anchor_body")" "MCP digest"

# --- 3. inference ------------------------------------------------------------
if [[ "${INFERENCE_MODE:-local}" == local ]]; then
  if curl -sSf --max-time 6 "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
    pass "model serving" "port ${VLLM_PORT}, model ${SERVED_MODEL_NAME}"
  else
    fail "model serving" "nothing answering on ${VLLM_PORT}"
  fi
fi

# --- 4. tool calls actually parse -------------------------------------------
# The failure this catches looks like a weak model, not a broken install: with a
# mismatched parser the model emits a fine tool call and it is returned as prose.
probe="$(curl -sS --max-time 120 "http://127.0.0.1:${VLLM_PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' -d '{
    "model": "'"$SERVED_MODEL_NAME"'", "max_tokens": 200, "tool_choice": "auto",
    "messages": [{"role":"user","content":"List the files in /tmp. Use the tool."}],
    "tools": [{"type":"function","function":{"name":"run_command","description":"Run a shell command",
      "parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}]}' 2>/dev/null)"
if grep -q '"tool_calls"' <<<"$probe"; then
  pass "tool calls parse" "--tool-call-parser ${TOOL_CALL_PARSER}"
else
  fail "tool calls parse" "parser '${TOOL_CALL_PARSER}' did not yield tool_calls"
  printf '        %sThe agent will answer questions and silently never use a tool.%s\n' "$RED" "$OFF"
fi

# --- 5. the control UI, judged by what it serves, never by a bound port ------
tok="$(hermes_dashboard_token "$UI")"
if [[ -n "$tok" ]]; then
  pass "control UI" "$UI serving a session token"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Authorization: Bearer $tok" "$UI/api/sessions" 2>/dev/null)"
  [[ "$code" == 200 ]] && pass "gateway API" "/api/sessions -> 200" \
                       || fail "gateway API" "/api/sessions -> $code"
else
  if ss -tln 2>/dev/null | grep -q "127.0.0.1:${CONTROL_UI_PORT} "; then
    fail "control UI" "port ${CONTROL_UI_PORT} is BOUND but serves nothing -- dead forward"
  else
    fail "control UI" "nothing on ${CONTROL_UI_PORT}"
  fi
  printf '        %sFix: hermes-stack-restore%s\n' "$DIM" "$OFF"
fi

# --- 5b. the network-facing dashboard proxy survives a reboot ---------------
# It was started without a restart policy, and the reboot path never restarted
# it, so the published dashboard port stayed dead after every reboot.
DASH="hermes-dash-${SANDBOX_NAME}"
dpol="$(docker container inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$DASH" 2>/dev/null)" || true
if [[ -n "$dpol" ]]; then
  [[ "$dpol" == unless-stopped || "$dpol" == always ]] \
    && pass "dashboard proxy restart" "$dpol -- returns after a reboot" \
    || warn "dashboard proxy restart" "'$dpol' -- re-run ./scripts/expose-dashboard.sh (or hermes-stack-restore)"
fi

# --- 6. desktop app ----------------------------------------------------------
HROOT="${HERMES_HOST_ROOT:-$HOME/.hermes/hermes-agent}"
# The token the app actually reads is connections.json (v2 store); connection.json
# is the older file. Reading only the old one reported PASS while the app held a
# stale token (2026-10-27).
DCFG="${HERMES_DESKTOP_CONFIG_DIR:-$HOME/.config/Hermes}"
if [[ -f "$DCFG/connection.json" || -f "$DCFG/connections.json" ]] && [[ -n "$tok" ]]; then
  tstate="$(hermes_desktop_tokens_state "$tok" "$UI" "$DCFG/connections.json" "$DCFG/connection.json")"
  bad="$(grep -vE ' ok$' <<<"$tstate" | sed 's#.*/##' | tr '\n' ' ')"
  if [[ -n "$tstate" && -z "$bad" ]]; then
    pass "desktop token" "$(sed 's#.*/##; s/ ok$//' <<<"$tstate" | paste -sd, | sed 's/,/ and /') match the live token"
  else
    warn "desktop token" "stale or missing in: ${bad:-none found} -- the app will say 'session expired'"
    printf '        %sFix: hermes-desktop-token-sync%s\n' "$DIM" "$OFF"
  fi
elif [[ ! -f "$DCFG/connection.json" && ! -f "$DCFG/connections.json" ]]; then
  warn "desktop token" "no desktop app config in $DCFG"
fi

# The client must be built from the ref that matches the sandbox's hermes: a
# newer client sends fields the older gateway rejects ("title, preview: extra
# inputs are not permitted") and every prompt fails.
if [[ -d "$HROOT/.git" ]]; then
  sbx_ver="$(docker exec "$C" hermes --version 2>/dev/null | head -1)"
  want_tag="$(hermes_version_tag "$sbx_ver")"
  want_commit=""; [[ -n "$want_tag" ]] && want_commit="$(git -C "$HROOT" rev-parse -q --verify "${want_tag}^{commit}" 2>/dev/null)"
  built_commit="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('commit',''))" \
                    "$HROOT/apps/desktop/build/install-stamp.json" 2>/dev/null)"
  verdict "$(hermes_desktop_ref_verdict "${want_tag:-?}" "$want_commit" "$built_commit")" "desktop matches sandbox"

  # Electron cannot start without its SUID helper where unprivileged user
  # namespaces are restricted (the Ubuntu default).
  if cs="$(hermes_chrome_sandbox_path "$HROOT")"; then
    verdict "$(hermes_chrome_sandbox_verdict "$(stat -c '%U:%G' "$cs")" "$(stat -c '%a' "$cs")")" "desktop chrome-sandbox"
  else
    verdict "$(hermes_chrome_sandbox_verdict "" "")" "desktop chrome-sandbox"
  fi

  # The menu entry runs `hermes desktop`; the launcher must be the checkout's venv.
  lt="$(readlink -f "$HOME/.local/bin/hermes" 2>/dev/null)"
  if [[ "$lt" == "$(readlink -f "$HROOT/venv/bin/hermes" 2>/dev/null)" ]] && "$HOME/.local/bin/hermes" --version >/dev/null 2>&1; then
    pass "hermes launcher" "~/.local/bin/hermes runs from the checkout venv"
  else
    fail "hermes launcher" "~/.local/bin/hermes is not the checkout's venv hermes (-> ${lt:-missing}); 'hermes desktop' may fail. Fix: ./scripts/install-hermes-host.sh"
  fi
fi

# --- 7. reboot durability wiring --------------------------------------------
if [[ ! -S "$XDG_RUNTIME_DIR/bus" ]]; then
  warn "reboot recovery" "cannot reach the systemd user bus -- state unknown"
elif systemctl --user is-enabled hermes-stack-restore.service >/dev/null 2>&1; then
  pass "reboot recovery" "hermes-stack-restore.service enabled"
  [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == yes ]] \
    && pass "linger" "user services run without a login" \
    || fail "linger" "OFF -- user units will NOT run at boot. Fix: loginctl enable-linger $USER"
else
  warn "reboot recovery" "not enabled -- see host/README.md"
fi
# Enabled is not the same as runs: systemd breaks an ordering cycle at boot by
# deleting a job, logs it once, and `is-enabled` keeps saying enabled.
cyc="$(hermes_ordering_cycle_units | tr '\n' ' ')"
if [[ -n "$cyc" ]]; then
  fail "ordering cycle" "this boot, systemd deleted: ${cyc% } -- re-run ./scripts/install-host-services.sh"
else
  pass "ordering cycle" "none in this boot's journal"
fi

printf '\n  %s----------------------------------------------------------%s\n' "$DIM" "$OFF"
printf '  %d passed, %d failed, %d warnings\n\n' "$PASS" "$FAIL" "$WARN"
(( FAIL == 0 ))
