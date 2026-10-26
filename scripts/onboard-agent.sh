#!/usr/bin/env bash
# Container 2 -- build the Hermes sandbox and point it at the model.
#
# This half cannot be expressed as a container definition: `nemohermes onboard`
# builds a per-sandbox image and registers it with the OpenShell gateway.
#
# Configuration comes from a profile, not from this file. See profiles/.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib/profile.sh
. scripts/lib/profile.sh
# shellcheck source=scripts/lib/common.sh
. scripts/lib/common.sh
set -euo pipefail
profile_bootstrap "$@"

command -v nemohermes >/dev/null || { echo "nemohermes not found: https://github.com/NVIDIA/NemoClaw" >&2; exit 1; }

# Where the agent will reach inference. ONE url, valid in BOTH namespaces.
#
# CHANGED 2026-08-21 -- this used to be two urls: a literal address for host-side
# onboarding validation, and the hostname for the in-sandbox config (the egress
# policy matches on hostname). The hostname form was applied AFTER onboarding
# with `hermes config set`, which happens AFTER nemoclaw seals the config -- so
# every install shipped a broken seal and quarantined itself on first reboot.
# (A config mutated after the seal fails NemoClaw's integrity check at the next start.)
#
# The fix is to make the host resolve host.openshell.internal too, so one url
# validates on the host AND matches the egress policy in the sandbox. NemoClaw
# then bakes it into the image as ARG NEMOCLAW_INFERENCE_BASE_URL *before* the
# seal (src/lib/onboard/dockerfile-patch.ts:321), and nothing is mutated after.
if [[ "${INFERENCE_MODE:-local}" == local ]]; then
  curl -sSf --max-time 5 "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null 2>&1 \
    || { echo "model is not serving on :${VLLM_PORT} -- run scripts/start-model.sh first" >&2; exit 1; }

  # Idempotent: teach the HOST the name the sandbox uses.
  if ! getent hosts host.openshell.internal >/dev/null 2>&1; then
    echo "==> adding host.openshell.internal -> ${HOST_BRIDGE_IP} to /etc/hosts (needs sudo)"
    printf '%s\thost.openshell.internal\n' "$HOST_BRIDGE_IP" | sudo tee -a /etc/hosts >/dev/null
  fi
  getent hosts host.openshell.internal >/dev/null 2>&1 \
    || { echo "host cannot resolve host.openshell.internal -- add it to /etc/hosts" >&2; exit 1; }

  SANDBOX_URL="http://host.openshell.internal:${VLLM_PORT}/v1"
  VALIDATE_URL="$SANDBOX_URL"
  TRUSTED="${HOST_BRIDGE_IP},127.0.0.1,host.openshell.internal"
else
  VALIDATE_URL="$REMOTE_ENDPOINT_URL"
  SANDBOX_URL="$REMOTE_ENDPOINT_URL"
  REMOTE_HOST="$(sed -E 's#^https?://##; s#[:/].*$##' <<<"$REMOTE_ENDPOINT_URL")"
  TRUSTED="${REMOTE_HOST},${HOST_BRIDGE_IP},127.0.0.1"
fi

export NEMOCLAW_GATEWAY_PORT
export NEMOCLAW_PROVIDER=custom
export NEMOCLAW_ENDPOINT_URL="$VALIDATE_URL"
export NEMOCLAW_PROVIDER_KEY=local-no-auth
export NEMOCLAW_MODEL="$SERVED_MODEL_NAME"
# Baked into the image as ARG NEMOCLAW_MAX_TOKENS at build time -- i.e. BEFORE
# the config seal (src/lib/onboard/dockerfile-patch.ts:362). Replaces the
# post-onboard `hermes config set model.max_tokens`, which broke the seal.
export NEMOCLAW_MAX_TOKENS="$AGENT_MAX_TOKENS"
# The SSRF preflight refuses RFC1918 endpoints unless explicitly trusted.
export NEMOCLAW_TRUSTED_PRIVATE_INFERENCE_HOSTS="$TRUSTED"

if nemohermes "$SANDBOX_NAME" dashboard-url >/dev/null 2>&1; then
  echo "==> sandbox '${SANDBOX_NAME}' already exists -- reusing it"
  echo "    (pass --recreate to install.sh to destroy and rebuild instead)"
else
  echo "==> onboarding sandbox '${SANDBOX_NAME}' (first run builds an image, ~5 min)"
  # --non-interactive AND closed stdin are both required. With --yes alone,
  # onboard still prompts for the base URL; run from a script with no TTY that
  # prompt hits EOF and the whole install reports "Installation cancelled".
  nemohermes onboard \
    --agent hermes --name "$SANDBOX_NAME" \
    --control-ui-port "$CONTROL_UI_PORT" \
    --non-interactive --yes --yes-i-accept-third-party-software \
    --no-ollama-autostart < /dev/null
fi

echo "==> allowing inference egress (README trap 3)"
nemohermes "$SANDBOX_NAME" policy add local-inference --yes

# 🔴 DO NOT re-add `hermes config set` here, or anywhere after onboarding.
# The config is sealed at image build time; any post-seal mutation makes the
# container fail closed on its NEXT start (HERMES_RESTART_FAILURE_CODE=
# mcp-integrity, then an unrecoverable sleep loop). base_url and max_tokens are
# now supplied pre-seal via NEMOCLAW_* above. README traps 2 and 4 are closed
# at the source, not patched afterwards.

echo "==> verifying sandbox health (seal must be intact)"
nemohermes "$SANDBOX_NAME" doctor || {
  echo "doctor reported problems -- do NOT reboot until the seal is clean" >&2
  exit 1
}

# --- desktop client sign-in ------------------------------------------------
# 🔴 DISABLED pending a reboot-safe mechanism. DO NOT re-enable without
# confirming the container survives a restart with it on (see below).
#
# `hermes plugins enable basic` inside the sandbox works while the container is
# running, but poisons the NEXT container start:
#   [SECURITY] Hermes config hash does not match persisted inputs
#   [SECURITY] HERMES_MCP_CONFIG_DRIFT: MCP intent cannot be matched to the
#              persisted gateway state; rebuild the sandbox from its registry
# -> the sandbox crash-loops in Error phase and `start` cannot recover it.
# Reproduced twice (auth in the gateway config, and in the dashboard profile).
#
# Additionally the dashboard runs under an isolated HERMES_DASHBOARD_HOME
# (/sandbox/.hermes/profiles/dashboard-home) which nemoclaw-start RE-SEEDS on
# every launch, so config written to the gateway home is wiped anyway.
#
# A correct fix must make the plugin part of the image / NemoClaw registry
# state (e.g. `nemohermes onboard --from <Dockerfile>`), not a post-onboard
# mutation.
# --- original block below, gated off by DESKTOP_CLIENT_AUTH=none ---------------------------------------------------------
# The Desktop app's Remote Gateway does not use a bearer token you can invent:
# it signs in against a dashboard *auth provider*. With none configured the
# dashboard advertises `auth_providers: []`, the app has nothing to sign into,
# and every /api/* call returns 401 -- with or without an Authorization header.
# Enabling the bundled `basic` provider is what makes the desktop client work
# out of the box. Docs: hermes-agent.nousresearch.com/docs/user-guide/desktop
#
# NOTE: use `nemohermes exec` (runs as user `sandbox`, HOME=/sandbox), never
# `docker exec` -- that runs as root and writes /root/.hermes/config.yaml,
# which the dashboard never reads.
if [[ "${DESKTOP_CLIENT_AUTH:-basic}" == basic ]]; then
  echo "==> enabling desktop-client sign-in (dashboard auth provider 'basic')"
  DESKTOP_USER="${DASHBOARD_AUTH_USER:-hermes}"
  DESKTOP_CRED_DIR="${CRED_DIR:-$HOME/.hermes-quickstart}"
  mkdir -p "$DESKTOP_CRED_DIR"; chmod 700 "$DESKTOP_CRED_DIR"
  DESKTOP_PASS_FILE="$DESKTOP_CRED_DIR/desktop.password"
  if [[ ! -s "$DESKTOP_PASS_FILE" ]]; then
    openssl rand -base64 18 | tr -d '/+=' | head -c 20 > "$DESKTOP_PASS_FILE"
    chmod 600 "$DESKTOP_PASS_FILE"
  fi
  DESKTOP_PASS="$(cat "$DESKTOP_PASS_FILE")"

  nemohermes "$SANDBOX_NAME" exec -- hermes plugins enable basic
  nemohermes "$SANDBOX_NAME" exec -- hermes config set dashboard.basic_auth.username "$DESKTOP_USER"
  nemohermes "$SANDBOX_NAME" exec -- hermes config set dashboard.basic_auth.password "$DESKTOP_PASS"
  nemohermes "$SANDBOX_NAME" exec -- hermes config set dashboard.basic_auth.secret "$(openssl rand -base64 32)"

  # Restart ONLY the dashboard process.
  #
  # Do NOT use `nemohermes <name> stop && start` here. Measured 2026-08-20:
  # it reverted /sandbox/.hermes/config.yaml to the image copy (losing the keys
  # just written) AND left the sandbox crash-looping in Error phase
  # (`reason=ContainerRestarting`). An in-place dashboard bounce is both
  # sufficient (the plugin only needs a fresh dashboard process) and safe.
  #
  # Relaunch with the *observed* argv rather than hardcoded flags, so this keeps
  # working if the port or profile flags change.
  echo "==> restarting the dashboard so the auth plugin loads"
  nemohermes "$SANDBOX_NAME" exec -- sh -lc '
    pid="$(pgrep -f "hermes_cli.main .* dashboard --port" | head -1)"
    [ -n "$pid" ] || { echo "no dashboard process found" >&2; exit 1; }
    argv="$(tr "\0" " " < "/proc/$pid/cmdline")"
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    nohup $argv >> "$HERMES_LOG_DIR"/dashboard.log 2>&1 &
    sleep 2
  '

  # Verify the provider is actually advertised. This is the single check that
  # separates "desktop client works" from "desktop client returns 401", so it is
  # FATAL: an install that silently prints unusable desktop credentials is worse
  # than one that has no desktop support at all.
  DASH_LOOPBACK="$(nemohermes "$SANDBOX_NAME" dashboard-url --quiet 2>/dev/null | tr -d '\r\n')"
  DESKTOP_OK=0
  for _ in $(seq 1 40); do
    if curl -fsS --max-time 4 "${DASH_LOOPBACK%/}/api/status" 2>/dev/null \
         | grep -q '"basic"'; then
      DESKTOP_OK=1; break
    fi
    sleep 3
  done
  if [[ "$DESKTOP_OK" == 1 ]]; then
    echo "    ✓ desktop sign-in ready -- auth_providers advertises 'basic'"
  else
    echo "    ✗ desktop sign-in NOT ready -- ${DASH_LOOPBACK%/}/api/status does not" >&2
    echo "      advertise 'basic'. The printed desktop credentials would not work." >&2
    echo "      Check: nemohermes $SANDBOX_NAME exec -- hermes plugins list" >&2
    exit 1
  fi
fi

# The gateway this sandbox lives on must be the one every later openshell call
# reaches -- and the one that comes back at boot. On 2026-10-23 a reinstall
# onboarded onto a second gateway (nemoclaw-8082) that only lived as long as
# the installing session; the shutdown hook, the boot restore and
# `nemohermes status` then all talked to a dead port. Fatal, not a warning.
GW_WANT="$(hermes_gateway_name_for_port "$NEMOCLAW_GATEWAY_PORT")"
GW_V="$(hermes_gateway_verdict "$GW_WANT")"
if [[ "${GW_V%% *}" != pass ]]; then
  echo "    ✗ OpenShell gateway: ${GW_V#* }" >&2
  echo "      Registered gateways: $(hermes_gateway_names | tr '\n' ' ')" >&2
  exit 1
fi
echo "    ✓ OpenShell gateway: ${GW_V#* }"

echo
echo "✓ done. Dashboard (loopback):"
nemohermes "$SANDBOX_NAME" dashboard-url || true
echo
echo "   Click 'New chat' -- existing sessions keep the config they were created with."
