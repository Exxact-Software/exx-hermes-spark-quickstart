#!/usr/bin/env bash
# One command. Walk away. Come back to a running agent.
#
#   ./install.sh --profile profiles/spark-qwen38.conf
#
# Serves a model, builds a Hermes agent pointed at it, puts an authenticated
# dashboard on the network, and prints a URL. No prompts.
#
# There is deliberately NO default profile. A tool whose purpose is
# reproducibility must not guess its own configuration -- that is how you end up
# with a running agent and no idea what produced it.
#
# Takes ~10 minutes on a warm box, longer the first time (image build).
#
# PHASE OUTPUT IS SHOWN BY DEFAULT. It used to be redirected to log files, which
# meant 97% of the install was a blank screen: measured on a real run, 14 output
# events across 339 seconds, with a 285s silence during the model load and a 43s
# silence during the image build. That is bad for a viewer and worse for a user --
# five minutes of silence is indistinguishable from a hang. `--quiet` restores it.
set -euo pipefail

# Run a phase, showing its output unless --quiet, and always keeping the log.
run_phase() {
  local log="$1"; shift
  if (( QUIET )); then
    "$@" >"$log" 2>&1
  else
    "$@" 2>&1 | tee "$log"
    return "${PIPESTATUS[0]}"
  fi
}

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_ROOT="$PWD"
# shellcheck source=scripts/lib/profile.sh
. "$REPO_ROOT/scripts/lib/profile.sh"
set -euo pipefail   # profile.sh relaxes errexit for sourcing; restore it

BOLD=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; OFF=$'\033[0m'
START=$SECONDS
phase() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$OFF"; }
ok()    { printf '%s    ✓ %s%s\n' "$GRN" "$*" "$OFF"; }
note()  { printf '%s      %s%s\n' "$DIM" "$*" "$OFF"; }
die()   { printf '\n%s✗ %s%s\n' "$RED" "$*" "$OFF" >&2; exit 1; }
warn()  { printf '%s    ! %s%s\n' "$YEL" "$*" "$OFF"; }
mins()  { printf '%dm%02ds' $(( (SECONDS-START)/60 )) $(( (SECONDS-START)%60 )); }

list_profiles() {
  local f
  printf 'available profiles:\n'
  for f in "$REPO_ROOT"/profiles/*.conf; do
    [[ -f "$f" ]] || continue
    printf '  %-44s %s\n' "profiles/$(basename "$f")" \
      "$(grep -m1 '^PROFILE_NAME=' "$f" | cut -d= -f2-)"
  done
}

usage() {
  cat <<USAGE
usage: ./install.sh --profile <path> [options]

  --profile <path>        configuration to install. REQUIRED -- there is no default.
  --print-config          resolve profile + host facts, print, and do nothing else
  --list-profiles         list the profiles in this repo
  --recreate              destroy an existing sandbox of the same name first
  --skip-host-install     assume the hermes CLI + desktop client are already installed
  --accept-nemoclaw-license  accept NVIDIA's licence + third-party notice (required
                          for an unattended install; see scripts/install-nemoclaw.sh)
  --clear-stale           drop pending route reservations left by failed onboards
  --quiet                 hide phase output; log only (the old behaviour)
  --host-bridge-ip <ip>   override the detected docker bridge gateway
  --bind-ip <ip>          override the detected dashboard bind address
  -h, --help              this

$(list_profiles)
USAGE
}

: "${HERMES_LOG_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/hermes-quickstart}"
mkdir -p "$HERMES_LOG_DIR" 2>/dev/null || HERMES_LOG_DIR="$(mktemp -d)"
export HERMES_LOG_DIR

PROFILE_ARG="" PRINT_ONLY=0 RECREATE=0 CLEAR_STALE=0 QUIET=0 SKIP_HOST_INSTALL=0 ACCEPT_NEMOCLAW_LICENSE=0
while (( $# )); do
  case "$1" in
    --profile)         PROFILE_ARG="${2:-}"; shift 2 ;;
    --profile=*)       PROFILE_ARG="${1#*=}"; shift ;;
    --print-config)    PRINT_ONLY=1; shift ;;
    --list-profiles)   list_profiles; exit 0 ;;
    --recreate)        RECREATE=1; shift ;;
    --skip-host-install) SKIP_HOST_INSTALL=1; shift ;;
    --accept-nemoclaw-license) ACCEPT_NEMOCLAW_LICENSE=1; shift ;;
    --clear-stale)     CLEAR_STALE=1; shift ;;
    --quiet)           QUIET=1; shift ;;
    --host-bridge-ip)  HOST_BRIDGE_IP="${2:-}"; shift 2 ;;
    --bind-ip)         BIND_IP="${2:-}"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 printf '%sunknown argument: %s%s\n\n' "$RED" "$1" "$OFF" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$PROFILE_ARG" ]]; then
  printf '%s✗ no --profile given, and there is no default.%s\n\n' "$RED" "$OFF" >&2
  printf 'Pick one explicitly so the install is reproducible:\n\n' >&2
  list_profiles >&2
  printf '\n  ./install.sh --profile profiles/spark-qwen38.conf\n\n' >&2
  exit 2
fi

phase "0/5  Checking the configuration"
profile_load "$PROFILE_ARG"
profile_resolve_host_facts
profile_validate
ok "profile '$PROFILE_NAME' v$PROFILE_VERSION is valid"

if (( PRINT_ONLY )); then
  printf '\n'; profile_print
  printf '\n%s  Nothing was started. Drop --print-config to install.%s\n\n' "$DIM" "$OFF"
  exit 0
fi

# Record what this machine already has -- nvm, npm, caches, model dirs, shell rc
# lines, docker images -- BEFORE anything is installed, so that
# `reset.py down --everything` removes only what this install created and
# never the user's own copies. The record is taken on a machine the install has not
# touched and kept across re-installs (reset.py explains what makes one trustworthy).
REC_OUT="$(./scripts/reset.py record-preinstall 2>&1)" \
  || note "could not record the pre-install state; a factory reset will keep shared tools"
# A record taken over an install that had already begun cannot say what was the
# user's, so a factory reset will keep shared tools; tell the user now, not at reset.
case "$REC_OUT" in *UNTRUSTED*|*untrusted*) note "$(printf '%s' "$REC_OUT" | tail -1)";; esac

# The whole install is driven by the nemohermes CLI, and its behaviour is NOT
# stable across releases -- between two NemoClaw builds tested on 2026-08-24 the
# bundled vLLM, the torch version, the tool-parser module layout and even which
# models would load all changed. An install against an unexpected CLI fails in
# ways that look like a problem with this repo. Checked here, in a second,
# rather than diagnosed later.
#
# MIN is the oldest release this repo has actually been run against end to end.
# Newer is allowed and only noted, because refusing to run on an untested-but-
# newer CLI would age this file into a blocker.
# Docker has to be usable by THIS user, not merely installed. Without this the
# first failure is a permission-denied from some docker call three phases in,
# which reads as a bug in this repo rather than "you are not in the docker
# group".
docker info >/dev/null 2>&1 \
  || die "cannot talk to Docker as $(id -un).
    Is the daemon running, and are you in the 'docker' group?
      sudo systemctl start docker
      sudo usermod -aG docker $(id -un)   # then log out and back in"
ok "docker usable"

# Free space, checked BEFORE the ~18-22 GB model download rather than during it.
# Running out mid-download leaves a partial model that the old existence-only
# check would have called present; fetch-model.py catches that now, but failing
# up front is cheaper than failing after twenty minutes.
if [[ "${INFERENCE_MODE:-local}" == local ]]; then
  NEED_GB=45
  FREE_GB="$(df -BG --output=avail "$(dirname "${MODEL_DIR:-$HOME}")" 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [[ -n "$FREE_GB" ]] && (( FREE_GB < NEED_GB )); then
    die "only ${FREE_GB} GB free where the model goes; about ${NEED_GB} GB is needed
    (model weights ~18-22 GB, vLLM image ~22 GB, sandbox image ~2 GB).
    Free some space, or point MODEL_DIR at a bigger disk."
  fi
  [[ -n "$FREE_GB" ]] && ok "disk: ${FREE_GB} GB free (need ~${NEED_GB})"
fi

  # Move claimed ports out of the way -- but ONLY for a genuinely new install.
  # If a sandbox is already registered, the gateway port it was onboarded with is
  # recorded in the registry, so shifting would aim this run at a gateway that
  # sandbox does not use. In the adopt case a port is "busy" because it is OURS,
  # which is exactly right.
  #
  # 8080 is the one that bites: a second user, a dev server, anything. Without
  # this the install failed deep inside NemoClaw onboarding with
  # "gateway.port.uncontested", which tells you almost nothing about what to do.
# The registry file is the source of truth, NOT `nemohermes list` -- which is
# also unrunnable here, because this must run BEFORE NemoClaw is installed. Using
# the command meant a clean box took the "existing install" branch and kept a
# port that was already taken, then died inside onboarding.
NEMOCLAW_REGISTRY="${NEMOCLAW_HOME:-$HOME/.nemoclaw}/sandboxes.json"
if [[ ! -s "$NEMOCLAW_REGISTRY" ]] || ! grep -q '"name"' "$NEMOCLAW_REGISTRY" 2>/dev/null; then
  profile_resolve_free_ports
else
  note "existing install detected; keeping its ports"
fi

# NemoClaw's onboarding installs its own vLLM and hard-requires host port 8000.
# It aborts with "port 8000 is already in use", buried in its own log, and all
# the caller sees is "could not install NemoClaw". 8000 is a popular port -- and
# our own model container takes it in phase 2, so a second account on the same
# Docker host hits this every time even though nothing is wrong with the box.
# Checked here, with the one owner that is legitimately ours spelled out.
# /dev/tcp rather than nc, which is not installed on a stock Ubuntu server.
if (( ! SKIP_HOST_INSTALL )) \
   && (exec 3<>/dev/tcp/127.0.0.1/8000) 2>/dev/null; then
  PORT8000_OWNER="$(docker ps --filter publish=8000 --format '{{.Names}}' 2>/dev/null | head -1)" || true
  # nemoclaw-vllm counts as fine: its presence means onboarding already
  # succeeded, and start-model.sh replaces it with ours in phase 2.
  if [[ "$PORT8000_OWNER" == "${VLLM_CONTAINER:-}" || "$PORT8000_OWNER" == nemoclaw-vllm ]] \
     && [[ -n "$PORT8000_OWNER" ]]; then
    note "port 8000 held by $PORT8000_OWNER (ours to replace) -- continuing"
  else
    warn "port 8000 is in use${PORT8000_OWNER:+ by container $PORT8000_OWNER}"
    note "NemoClaw's onboarding requires it. Free it, then re-run:"
    if [[ -n "$PORT8000_OWNER" ]]; then
      note "  docker rm -f $PORT8000_OWNER"
    else
      note "  sudo ss -lptn 'sport = :8000'"
    fi
    die "cannot install NemoClaw while port 8000 is taken"
  fi
fi

# NemoClaw provides nemohermes, which every later phase drives. Installed here
# rather than listed as a prerequisite: a fresh user has neither it nor node,
# and "clone this and run one command" has to be true for a stranger.
if (( SKIP_HOST_INSTALL )); then
  note "--skip-host-install given; assuming nemohermes is present"
else
  NEMOCLAW_ARGS=(); (( ACCEPT_NEMOCLAW_LICENSE )) && NEMOCLAW_ARGS+=(--accept-license)
  run_phase "$HERMES_LOG_DIR"/hermes-install-nemoclaw.log ./scripts/install-nemoclaw.sh "${NEMOCLAW_ARGS[@]}" \
    || die "could not install NemoClaw -- see "$HERMES_LOG_DIR"/hermes-install-nemoclaw.log"
fi
export PATH="$HOME/.local/bin:$PATH"; hash -r 2>/dev/null || true

NEMOHERMES_MIN="0.0.103"
command -v nemohermes >/dev/null 2>&1 \
  || die "nemohermes not found on PATH -- https://github.com/NVIDIA/NemoClaw"
# Without the `|| true` below this line, the empty-version branch that follows
# is unreachable: grep returns 1 when the version string does not match,
# pipefail propagates it, and errexit kills the script before it can print
# its own "continuing unchecked" note.
NEMOHERMES_VER="$(nemohermes --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || true
if [[ -z "$NEMOHERMES_VER" ]]; then
  note "could not read the nemohermes version -- continuing unchecked"
elif [[ "$(printf '%s\n%s\n' "$NEMOHERMES_MIN" "$NEMOHERMES_VER" | sort -V | head -1)" != "$NEMOHERMES_MIN" ]]; then
  die "nemohermes $NEMOHERMES_VER is older than the minimum this repo is tested against ($NEMOHERMES_MIN).
    Upgrade NemoClaw with NVIDIA's installer, then re-run. (scripts/install-nemoclaw.sh
    leaves an existing nemohermes in place, so it will not upgrade it for you.)"
elif [[ "$NEMOHERMES_VER" != "$NEMOHERMES_MIN" ]]; then
  note "nemohermes $NEMOHERMES_VER (tested against $NEMOHERMES_MIN) -- newer, untested"
else
  ok "nemohermes $NEMOHERMES_VER"
fi

# The gateway serves ONE inference route shared by every registered sandbox, and
# stopped sandboxes -- plus pending reservations left by failed onboards -- still
# hold their claim. That conflict used to surface at phase 2, AFTER a ~5 minute
# cold model load. It is knowable in about a second, so it is checked here.
#
# Deliberately AFTER the --print-config exit: inspecting a profile must report
# what the profile says, not depend on what happens to be installed on this box.
# Gating --print-config on live state made it environment-dependent, and the
# self-test caught it.
PREFLIGHT_ARGS=(preflight --profile "$PROFILE_ARG")
(( CLEAR_STALE )) && PREFLIGHT_ARGS+=(--clear-stale --yes)
if ! ./scripts/reset.py "${PREFLIGHT_ARGS[@]}"; then
  printf '\n%s  See what is installed:  ./scripts/reset.py status%s\n' "$DIM" "$OFF" >&2
  printf '%s  Diagnose it:            ./scripts/reset.py doctor%s\n\n' "$DIM" "$OFF" >&2
  exit 3
fi

CRED_DIR="${HERMES_CRED_DIR:-$HOME/.hermes-quickstart}"
mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
export CRED_DIR

if (( RECREATE )) && nemohermes "$SANDBOX_NAME" dashboard-url >/dev/null 2>&1; then
  note "--recreate: destroying existing sandbox '$SANDBOX_NAME'"
  nemohermes "$SANDBOX_NAME" destroy --yes >/dev/null 2>&1 || true
fi

# The model used to be a prerequisite documented as `huggingface-cli download`,
# which does not work: that CLI is not installed on the target machine. And the
# only check was that MODEL_DIR existed, which a half-finished download passes --
# then vLLM dies minutes later saying nothing useful. Both are handled here, and
# a model already on disk is NEVER re-downloaded.
if [[ "$INFERENCE_MODE" == local ]]; then
  phase "0.5  Making sure the model is on disk"
  if ./scripts/fetch-model.py check --profile "$PROFILE_ARG" --quiet; then
    ok "model already present — nothing to download"
  else
    note "fetching the model (~18 GB, resumable — safe to interrupt)"
    ./scripts/fetch-model.py fetch --profile "$PROFILE_ARG" \
      || die "could not obtain the model. Re-run: completed files are skipped and partials resume."
    ok "model fetched and verified  [$(mins)]"
  fi

fi

# --- 1/5  the host half ----------------------------------------------------
# The desktop client ships with Hermes' own host install. This repo used to list
# that as a prerequisite in the README, which meant "clone this and you have
# Hermes with a desktop client" was not true -- a viewer had to get a separate,
# undocumented-here process right first. One command in, one command out is the
# whole point, so the installer does it.
if (( SKIP_HOST_INSTALL )); then
  phase "1/5  Hermes host + desktop client   (skipped)"
  note "--skip-host-install given"
else
  phase "1/5  Hermes host + desktop client   (~10 min first run)"
  run_phase "$HERMES_LOG_DIR"/hermes-install-host.log ./scripts/install-hermes-host.sh \
    || die "host Hermes install failed -- full log: "$HERMES_LOG_DIR"/hermes-install-host.log"
  ok "hermes CLI and desktop client ready"
fi

if [[ "$INFERENCE_MODE" == local ]]; then
  phase "2/5  Serving the model on the GPU   (~5 min warm, 20+ min cold)"
  run_phase "$HERMES_LOG_DIR"/hermes-install-model.log ./scripts/start-model.sh \
    || { tail -30 "$HERMES_LOG_DIR"/hermes-install-model.log >&2; die "model failed to start -- full log: "$HERMES_LOG_DIR"/hermes-install-model.log"; }
  ok "model serving  [$(mins)]"
else
  phase "2/5  Using remote inference (skipping local model)"
  curl -sSf --max-time 10 "${REMOTE_ENDPOINT_URL%/v1}/v1/models" >/dev/null 2>&1 \
    || die "remote endpoint not reachable: $REMOTE_ENDPOINT_URL"
  ok "remote endpoint reachable  [$(mins)]"
fi

phase "3/5  Building the agent             (~5 min first run)"
run_phase "$HERMES_LOG_DIR"/hermes-install-agent.log ./scripts/onboard-agent.sh \
  || { tail -30 "$HERMES_LOG_DIR"/hermes-install-agent.log >&2; die "agent build failed -- full log: "$HERMES_LOG_DIR"/hermes-install-agent.log"; }
ok "agent built and configured  [$(mins)]"

if [[ "${DASHBOARD_AUTH:-basic}" == basic ]]; then
  phase "4/5  Putting an authenticated dashboard on the network"
else
  phase "4/5  Putting the dashboard on the network"
fi
EXPOSED=1
run_phase "$HERMES_LOG_DIR"/hermes-install-expose.log ./scripts/expose-dashboard.sh || EXPOSED=0
if (( EXPOSED )); then
  URL="$(grep -oE 'http://[0-9.]+:[0-9]+' "$HERMES_LOG_DIR"/hermes-install-expose.log | head -1)"
  if [[ "${DASHBOARD_AUTH:-basic}" == basic ]]; then
    ok "reachable from other machines, password required"
  else
    ok "reachable from other machines"
  fi
else
  URL="http://127.0.0.1:${CONTROL_UI_PORT}"
  note "! could not expose it on the network -- loopback only"
  note "  see "$HERMES_LOG_DIR"/hermes-install-expose.log"
fi

# Prove it end to end before claiming success. This uses the gateway API, the
# same path the dashboard uses -- not the CLI, which passes even when chat is
# broken.
# --- 4/4  the desktop app -------------------------------------------------
# Added 2026-08-24: the scope now ends at a working DESKTOP client, not a
# browser tab. Non-fatal by design -- the desktop app ships with the Hermes
# host install, which this repo does not install, so a host without it should
# still finish with a working containerized agent and a dashboard.
phase "5/5  Host integration: reboot survival and the desktop app"
# Reported honestly: this used to print the warning and then "reboot recovery
# installed" on the very next line regardless, so a fresh user was told the
# thing worked while the units sat on disk unenabled.
if run_phase "$HERMES_LOG_DIR"/hermes-install-hostsvc.log ./scripts/install-host-services.sh; then
  ok "reboot recovery installed"
else
  warn "reboot recovery NOT active -- the stack works now but will not return"
  note "see $HERMES_LOG_DIR/hermes-install-hostsvc.log"
fi

if command -v hermes >/dev/null 2>&1; then
  DESKTOP=1
  run_phase "$HERMES_LOG_DIR"/hermes-install-desktop.log ./scripts/attach-desktop.sh || DESKTOP=0
  if (( DESKTOP )); then
    ok "desktop app configured -- launch it with: hermes desktop"
  else
    note "! could not configure the desktop app -- see "$HERMES_LOG_DIR"/hermes-install-desktop.log"
    note "  the container agent is fine; this only affects the desktop client"
  fi
else
  DESKTOP=0
  note "! 'hermes' CLI not found -- skipping the desktop step"
  note "  the desktop client ships with the Hermes host install:"
  note "  https://hermes-agent.nousresearch.com"
fi

phase "Verifying"
REPLY="$(nemohermes "$SANDBOX_NAME" exec -- sh -c '
  K=$(grep "^API_SERVER_KEY=" /sandbox/.hermes/.env | cut -d= -f2-)
  curl -sS --max-time 180 -X POST http://127.0.0.1:18642/v1/chat/completions \
    -H "Content-Type: application/json" -H "Authorization: Bearer $K" \
    -d "{\"model\":\"hermes-agent\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: READY\"}]}"' 2>/dev/null || true)"
AGENT_OK=0
if grep -q '"content"' <<<"$REPLY"; then AGENT_OK=1; ok "the agent answered"; else
  printf '%s    ! could not get a reply from the agent%s\n' "$RED" "$OFF"
  note "$(head -c 300 <<<"$REPLY")"
fi

# --- provenance -----------------------------------------------------------
# Without this, "which configuration does this machine have?" is an
# investigation instead of a `cat`.
MANIFEST="$CRED_DIR/install-manifest.json"
GIT_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY="$( [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]] && echo true || echo false )"
VLLM_DIGEST="$(docker image inspect "${VLLM_IMAGE:-}" -f '{{index .RepoDigests 0}}' 2>/dev/null || echo none)"
export GIT_COMMIT GIT_DIRTY VLLM_DIGEST AGENT_OK
python3 - "$MANIFEST" <<'PY' || note "could not write manifest"
import json, os, subprocess, sys, datetime
def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception: return ""
g = os.environ.get
keys = ["PROFILE_NAME","PROFILE_VERSION","PROFILE_PATH","PROFILE_SHA256","INFERENCE_MODE",
        "MODEL_DIR","SERVED_MODEL_NAME","TOOL_CALL_PARSER","REMOTE_ENDPOINT_URL",
        "MAX_MODEL_LEN","AGENT_MAX_TOKENS","MEM_CAP","GPU_MEMORY_UTILIZATION","VLLM_IMAGE",
        "VLLM_CONTAINER","VLLM_PORT","SANDBOX_NAME","CONTROL_UI_PORT",
        "DASHBOARD_PUBLIC_PORT","NEMOCLAW_GATEWAY_PORT","DASHBOARD_AUTH_USER"]
doc = {
    "installed_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "host": sh("hostname"),
    "repo": {"commit": g("GIT_COMMIT"), "dirty": g("GIT_DIRTY") == "true"},
    "profile": {k: g(k) for k in keys if g(k)},
    "host_facts": {"HOST_BRIDGE_IP": g("HOST_BRIDGE_IP"), "BIND_IP": g("BIND_IP")},
    "images": {"vllm_digest": g("VLLM_DIGEST")},
    "versions": {
        "nemohermes": sh("nemohermes --version") or "unknown",
        "docker": sh("docker --version"),
        "kernel": sh("uname -r"),
    },
    "verified": {"agent_answered": g("AGENT_OK") == "1"},
    "note": "Secrets are never recorded here. The dashboard password lives beside this file, mode 0600.",
}
with open(sys.argv[1], "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.chmod(sys.argv[1], 0o600)
PY
[[ -f "$MANIFEST" ]] && ok "recorded what was installed -> $MANIFEST"

# No credential lines at all when auth is off -- an empty "Pass:" label on screen
# is worse than no label, and the demo profile has no password by design.
if [[ "${DASHBOARD_AUTH:-basic}" == basic ]]; then
  CRED_LINES="    User:  ${BOLD}${DASHBOARD_AUTH_USER}${OFF}
    Pass:  $(cat "$CRED_DIR/dashboard.password" 2>/dev/null || echo "<see $CRED_DIR/dashboard.password>")
"
else
  CRED_LINES=""
fi

# Desktop client. REWRITTEN 2026-08-24: this used to print a URL, username and
# password for signing in by hand through Settings > Gateways, against the
# dashboard's `basic` auth provider. That provider is gone -- enabling it inside
# the sandbox broke the config seal and quarantined the container on its next
# start, so it was disabled in onboard-agent.sh and is not coming back.
#
# Phase 4 now writes the app's connection.json directly, on the host, with a
# token it has already verified. So there is nothing to type: the correct
# instruction is a single command.
if (( ${DESKTOP:-0} )); then
  DESKTOP_LINES="
${BOLD}    Desktop app${OFF} -- already pointed at this container:
      ${BOLD}hermes desktop${OFF}
${DIM}      If it ever says the gateway session expired, the token rotated.
      Run: hermes-desktop-token-sync${OFF}
"
else
  DESKTOP_LINES="
${DIM}    Desktop app: not configured. It ships with the Hermes host install
      (https://hermes-agent.nousresearch.com); install it, then run
      ./scripts/attach-desktop.sh --profile <profile>${OFF}
"
fi

CLAIM="The model is running on this machine. Nothing you type leaves it."
[[ "$INFERENCE_MODE" == remote ]] && \
  CLAIM="Inference runs at $REMOTE_ENDPOINT_URL -- on your network, not on this box."

# A failed phase 4 used to set EXPOSED=0 and fall through to this banner, which
# then told the user to open a dashboard that expose-dashboard.sh had just torn
# down for failing its own auth check. The banner said "Done"; the dashboard did
# not exist. Say so instead, and exit non-zero so a scripted run notices.
if (( ! EXPOSED )); then
  cat >&2 <<DEGRADED

${RED}  Finished in $(mins), but the dashboard is NOT up.${OFF}

${DIM}      expose-dashboard.sh refused to leave an unverified dashboard exposed
      and removed the proxy. The agent itself is running -- use the desktop app.
      Log: $HERMES_LOG_DIR/hermes-install-expose.log
      Retry: ./scripts/expose-dashboard.sh --profile <profile>${OFF}
${DESKTOP_LINES}
DEGRADED
  exit 1
fi

cat <<BANNER

${BOLD}  Done in $(mins).${OFF}

    Open:  ${BOLD}${URL}${OFF}
${CRED_LINES}
    Then click ${BOLD}New chat${OFF}.
${DESKTOP_LINES}

    ${CLAIM}

${DIM}    Tear down:  docker rm -f ${VLLM_CONTAINER:-<none>} && nemohermes ${SANDBOX_NAME} destroy --yes
                ./scripts/expose-dashboard.sh --stop${OFF}
BANNER
