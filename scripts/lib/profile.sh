#!/usr/bin/env bash
# Profile loading, validation, and host-fact resolution.
#
# WHY THIS EXISTS: configuration used to live in an untracked `.env` that
# install.sh silently created from an example when missing. That made the
# configuration which produced any given running agent unrecoverable -- you
# could not answer "what settings did this machine get?". Profiles are
# committed, named, and passed explicitly.
#
# TWO CLASSES OF VALUE, and keeping them apart is the whole point:
#
#   POLICY     lives in the profile. Same on every machine. Model, context
#              length, token caps, image, ports.
#   HOST FACT  detected at runtime. Differs per machine. Bridge IP, bind
#              address. A profile that pinned these would be wrong on some
#              machines and the person it broke for would not know why.
#
# A third class -- FORCED MOVES -- is deliberately NOT configurable. Those
# values have exactly one correct setting, each discovered the hard way, and
# promoting them to knobs invites someone to change one and file a bug. They
# stay in the scripts, and each profile's header says so.

set -uo pipefail

PROFILE_REQUIRED_KEYS=(
  PROFILE_NAME PROFILE_VERSION INFERENCE_MODE
  SERVED_MODEL_NAME TOOL_CALL_PARSER
  MAX_MODEL_LEN AGENT_MAX_TOKENS
  SANDBOX_NAME CONTROL_UI_PORT DASHBOARD_PUBLIC_PORT
  NEMOCLAW_GATEWAY_PORT DASHBOARD_AUTH DASHBOARD_AUTH_USER
)

# Extra keys required only when this host serves the model itself.
PROFILE_REQUIRED_KEYS_LOCAL=(
  MODEL_DIR MEM_CAP GPU_MEMORY_UTILIZATION VLLM_IMAGE VLLM_CONTAINER VLLM_PORT
)

# Extra keys required only when inference lives on another machine.
PROFILE_REQUIRED_KEYS_REMOTE=(
  REMOTE_ENDPOINT_URL
)

# vLLM only registers these. A typo here fails at tool-call time, not startup,
# which is the worst place to find it.
PROFILE_VALID_PARSERS="gemma4 llama3_json hermes qwen3_coder"

# Hermes refuses to start the agent below this. Not a preference.
PROFILE_MIN_MODEL_LEN=64000

# The `local-inference` policy preset allowlists these ports and no others
# (nemoclaw-blueprint/policies/presets/local-inference.yaml). Serving on any
# other port builds and serves perfectly, then denies every chat at request time
# with "policy_denied" -- the failure lands nowhere near the cause. So VLLM_PORT
# is not a free choice, and this is checked before anything starts.
PROFILE_POLICY_PORTS="8000 8081 11434 11435"

_p_die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 2; }
_p_warn() { printf '\033[2m  ! %s\033[0m\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# load
# ---------------------------------------------------------------------------

# A profile is PARSED, never sourced.
#
# Sourcing was the original approach and it was wrong: `KEY=$(command)` and
# `KEY=x; command` both look like assignments, pass any line-shape check, and
# then execute the moment the file is read. That turns a reviewed configuration
# file into an unreviewed script -- and profiles are meant to be reviewable
# artifacts that ship with a machine. So we read key/value pairs ourselves and
# allow exactly one expansion, $HOME, done by hand.
profile_load() {
  local path="${1:-}"
  [[ -n "$path" ]] || _p_die "profile_load: no path given"
  [[ -f "$path" ]] || _p_die "profile not found: $path"
  [[ -r "$path" ]] || _p_die "profile not readable: $path"

  PROFILE_PATH="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
  PROFILE_SHA256="$(sha256sum "$PROFILE_PATH" | cut -d' ' -f1)"

  local lineno=0 line key val rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    [[ -z "${line//[[:space:]]/}" ]] && continue     # blank
    [[ "$line" =~ ^[[:space:]]*# ]] && continue      # comment

    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] \
      || _p_die "$PROFILE_PATH:$lineno is not a KEY=value assignment:
    $line
    Profiles are data, not scripts."

    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"

    # Strip one layer of matching quotes, if present.
    if   [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
    elif [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
    fi
    val="${val%"${val##*[![:space:]]}"}"             # trim trailing space

    # Exactly one expansion is supported, and only at the start.
    rest="$val"
    case "$val" in
      '$HOME'/*|'$HOME')     rest="${val#\$HOME}" ;;
      '${HOME}'/*|'${HOME}') rest="${val#\$\{HOME\}}" ;;
      '~/'*|'~')             rest="${val#\~}" ;;
    esac

    # Anything that could reach a shell is refused outright. This is what stops
    # $(...), backticks, `;`, pipes and redirections from ever being evaluated --
    # they are not escaped, they are rejected.
    [[ "$rest" =~ ^[A-Za-z0-9._:/@,=+\ -]*$ ]] \
      || _p_die "$PROFILE_PATH:$lineno value for '$key' contains characters that are not allowed in a profile:
    $key=$val
    Allowed: letters, digits, and . _ : / @ , = + - space, plus a leading \$HOME.
    Refused so that a configuration file can never execute a command."

    # Now expand, ourselves, with no shell involved.
    case "$val" in
      '$HOME'*|'${HOME}'*) val="${HOME}${rest}" ;;
      '~'*)                val="${HOME}${rest}" ;;
    esac

    printf -v "$key" '%s' "$val"
    export "${key?}"
  done < "$PROFILE_PATH"
}

# Let the phase scripts run standalone. install.sh exports everything, so when
# called from it this is a no-op; called by hand, it accepts --profile so you
# are never guessing which configuration a bare `./scripts/start-model.sh` used.
profile_bootstrap() {
  if [[ -n "${PROFILE_NAME:-}" ]]; then
    return 0   # already loaded by install.sh
  fi
  if [[ "${1:-}" == --profile && -n "${2:-}" ]]; then
    profile_load "$2"
    profile_resolve_host_facts
    return 0
  fi
  _p_die "no configuration loaded.
    Run this through the installer:  ./install.sh --profile profiles/<name>.conf
    Or pass one directly:            $(basename "${BASH_SOURCE[1]:-script}") --profile profiles/<name>.conf"
}

# ---------------------------------------------------------------------------
# host facts -- detected, never committed
# ---------------------------------------------------------------------------

profile_resolve_host_facts() {
  # Docker bridge gateway. Onboarding validation runs on the HOST, which cannot
  # resolve host.openshell.internal, so it needs a literal IP. This is a
  # property of the machine, not of the configuration.
  if [[ -z "${HOST_BRIDGE_IP:-}" ]]; then
    HOST_BRIDGE_IP="$(docker network inspect bridge \
      -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
    [[ -n "$HOST_BRIDGE_IP" ]] \
      || _p_die "could not detect the docker bridge gateway -- pass --host-bridge-ip"
  fi
  export HOST_BRIDGE_IP

  # Address the dashboard proxy binds. Prefer a tailnet: it is a network the
  # operator controls, which a default-route LAN address is not.
  # DEFAULT IS LOOPBACK. Changed 2026-08-27, deliberately.
  #
  # This used to auto-detect: Tailscale address first, then whatever local
  # address reaches the internet. Convenient, and wrong as a default for a
  # repository other people run. It meant `./install.sh` published an agent onto
  # whatever network the machine happened to be plugged into, behind basic auth
  # over cleartext HTTP -- and you only learned the address, and that there was
  # a password at all, after it had already happened.
  #
  # Exposure is now something you ASK for:
  #
  #   (default)             127.0.0.1  -- reachable only from this machine
  #   --bind-ip auto        detect Tailscale, else the primary LAN address
  #   --bind-ip <address>   exactly that address
  #
  # The desktop client is unaffected either way: it talks over a loopback
  # forward and never puts credentials on the wire.
  if [[ -z "${BIND_IP:-}" ]]; then
    BIND_IP="127.0.0.1"
  elif [[ "$BIND_IP" == auto ]]; then
    BIND_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    [[ -z "$BIND_IP" ]] && BIND_IP="$(ip -4 route get 1.1.1.1 2>/dev/null \
      | grep -oP 'src \K[0-9.]+' | head -1 || true)"
    [[ -n "$BIND_IP" ]] \
      || _p_die "--bind-ip auto found no Tailscale or routable address -- pass one explicitly"
  fi
  export BIND_IP
}

# ---------------------------------------------------------------------------
# validate -- everything checkable, before anything is started
# ---------------------------------------------------------------------------

# Move a claimed port out of the way if something else already holds it.
#
# 8080 in particular is one of the most contested ports there is -- a second
# user on the same box, a dev server, anything. The install used to fail deep
# inside NemoClaw onboarding with "gateway.port.uncontested", which tells you
# almost nothing about what to do.
#
# ⚠ ONLY safe when nothing of ours is already installed. If a sandbox is
# registered, the port it was onboarded with is recorded in the registry, and
# shifting would point this run at a gateway the sandbox does not use. Callers
# must skip this when adopting an existing install.
# NemoClaw REJECTS certain gateway ports outright. Taken verbatim from its own
# installer (scripts/install.sh, the NEMOCLAW_GATEWAY_PORT validation):
#
#   8000, 8081, 11434, 11435, 11436, 11437   reserved inference / runtime-adapter
#   18789-18799                              reserved dashboard range
#
# Walking naively to "the next free port" landed on 8081 and the install died
# with "must not overlap a reserved inference or runtime-adapter port" -- a
# perfectly free port that NemoClaw will not accept.
_p_port_reserved() {
  local port="$1" var="$2"
  [[ "$var" == NEMOCLAW_GATEWAY_PORT ]] || return 1
  (( port >= 18789 && port <= 18799 )) && return 0
  case "$port" in 8000|8081|11434|11435|11436|11437) return 0 ;; esac
  return 1
}

# Is <port> held by OUR OpenShell gateway -- the NemoClaw-managed user unit,
# which outlives a sandbox-only `reset.py down`? Then the port is busy because
# it is ours, and must be reused, not walked away from.
#
# ⚠ 2026-10-23: `reset.py down --sandbox` emptied the registry, so the next
# install.sh took the "new install" branch below, found 8080 held by our own
# gateway, skipped the reserved 8081 and onboarded on 8082. NemoClaw named that
# gateway nemoclaw-8082, ran it as a process of the installing login session
# (not the user unit), and made it the ACTIVE gateway. The next shutdown killed
# that session first; the hook then asked a dead gateway for the phase, got
# nothing, and let docker SIGKILL the sandbox. After boot only 8080 came back.
_p_port_is_our_gateway() {
  local port="$1" env="${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateway.env"
  grep -qx "OPENSHELL_SERVER_PORT=${port}" "$env" 2>/dev/null || return 1
  ss -tlnp 2>/dev/null | grep ":${port} " | grep -q 'openshell-gatew' && return 0
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    systemctl --user is-active --quiet nemoclaw-openshell-gateway.service 2>/dev/null
}

profile_resolve_free_ports() {
  local var port taken
  for var in NEMOCLAW_GATEWAY_PORT CONTROL_UI_PORT DASHBOARD_PUBLIC_PORT; do
    port="${!var:-}"
    [[ -n "$port" ]] || continue
    ss -tln 2>/dev/null | grep -q ":${port} " || continue
    if [[ "$var" == NEMOCLAW_GATEWAY_PORT ]] && _p_port_is_our_gateway "$port"; then
      printf '%s      %s %s is held by this install'"'"'s OpenShell gateway; reusing it%s\n' \
        "${C_D:-}" "$var" "$port" "${C_0:-}" >&2
      continue
    fi
    taken="$port"
    while ss -tln 2>/dev/null | grep -q ":${port} " || _p_port_reserved "$port" "$var"; do
      port=$((port + 1))
      (( port > taken + 50 )) && _p_die "no free port near $taken for $var -- free one, or set $var in the profile"
    done
    printf '%s      %s %s is in use; using %s instead%s\n' "${C_D:-}" "$var" "$taken" "$port" "${C_0:-}" >&2
    printf -v "$var" '%s' "$port"
    export "${var?}"
  done
}

profile_validate() {
  local missing=() k

  local required=("${PROFILE_REQUIRED_KEYS[@]}")
  case "${INFERENCE_MODE:-}" in
    local)  required+=("${PROFILE_REQUIRED_KEYS_LOCAL[@]}") ;;
    remote) required+=("${PROFILE_REQUIRED_KEYS_REMOTE[@]}") ;;
    '')     _p_die "INFERENCE_MODE is not set in $PROFILE_PATH (expected: local | remote)" ;;
    *)      _p_die "INFERENCE_MODE='$INFERENCE_MODE' is not valid (expected: local | remote)" ;;
  esac

  for k in "${required[@]}"; do
    [[ -n "${!k:-}" ]] || missing+=("$k")
  done
  if (( ${#missing[@]} )); then
    _p_die "profile $PROFILE_PATH is missing required keys: ${missing[*]}"
  fi

  # The floor that Hermes enforces. Fail here with a reason rather than let
  # onboard fail later with none.
  [[ "$MAX_MODEL_LEN" =~ ^[0-9]+$ ]] \
    || _p_die "MAX_MODEL_LEN='$MAX_MODEL_LEN' is not a number"
  (( MAX_MODEL_LEN >= PROFILE_MIN_MODEL_LEN )) \
    || _p_die "MAX_MODEL_LEN=$MAX_MODEL_LEN is below $PROFILE_MIN_MODEL_LEN -- Hermes refuses to start the agent below this"

  [[ "$AGENT_MAX_TOKENS" =~ ^[0-9]+$ ]] \
    || _p_die "AGENT_MAX_TOKENS='$AGENT_MAX_TOKENS' is not a number"

  grep -qw -- "$TOOL_CALL_PARSER" <<<"$PROFILE_VALID_PARSERS" \
    || _p_die "TOOL_CALL_PARSER='$TOOL_CALL_PARSER' is not one of: $PROFILE_VALID_PARSERS"

  case "$DASHBOARD_AUTH" in
    none|basic) ;;
    *) _p_die "DASHBOARD_AUTH='$DASHBOARD_AUTH' is not valid (expected: none | basic)" ;;
  esac

  local p
  for p in CONTROL_UI_PORT DASHBOARD_PUBLIC_PORT NEMOCLAW_GATEWAY_PORT; do
    [[ "${!p}" =~ ^[0-9]+$ ]] || _p_die "$p='${!p}' is not a number"
  done

  if [[ "$INFERENCE_MODE" == local ]]; then
    [[ "$VLLM_PORT" =~ ^[0-9]+$ ]] || _p_die "VLLM_PORT='$VLLM_PORT' is not a number"
    grep -qw -- "$VLLM_PORT" <<<"$PROFILE_POLICY_PORTS" \
      || _p_die "VLLM_PORT=$VLLM_PORT is not permitted by the local-inference policy.
    Allowed: $PROFILE_POLICY_PORTS
    The sandbox would build and the model would serve, then every chat would be
    refused with 'policy_denied' at request time -- far from the cause."
    # NOT a hard failure. The model may legitimately be absent on a fresh
    # machine -- install.sh fetches it in the phase after this one. Dying here
    # would make a first install impossible, which is exactly the case the
    # installer exists for. What IS checked is that the path is creatable.
    if [[ ! -d "$MODEL_DIR" ]]; then
      local parent; parent="$(dirname "$MODEL_DIR")"
      [[ -d "$parent" && -w "$parent" ]] || mkdir -p "$MODEL_DIR" 2>/dev/null \
        || _p_die "MODEL_DIR does not exist and cannot be created: $MODEL_DIR"
      _p_warn "MODEL_DIR is empty or absent -- it will be fetched: $MODEL_DIR"
    fi
    [[ "$GPU_MEMORY_UTILIZATION" =~ ^0?\.[0-9]+$|^1(\.0+)?$ ]] \
      || _p_die "GPU_MEMORY_UTILIZATION='$GPU_MEMORY_UTILIZATION' should be a fraction between 0 and 1"
  fi

  command -v docker >/dev/null || _p_die "docker not found"

  # nemohermes is deliberately NOT required here. Validating a PROFILE is a
  # question about a config file, not about what is installed -- and since
  # 2026-08-27 install.sh installs NemoClaw itself, in a phase that necessarily
  # runs after this. Requiring it here made a fresh machine fail before the step
  # that would have fixed it. The scripts that actually invoke the CLI check for
  # it themselves (onboard-agent.sh), and install.sh enforces the version floor
  # right after installing it.

  [[ "$CONTROL_UI_PORT" != "$DASHBOARD_PUBLIC_PORT" ]] \
    || _p_die "CONTROL_UI_PORT and DASHBOARD_PUBLIC_PORT must differ (both $CONTROL_UI_PORT)"
}

# Ports the installer is about to claim. Warned, not fatal: a re-run legitimately
# finds its own containers holding them.
profile_check_ports() {
  local p busy=()
  for p in "${@}"; do
    if ss -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"; then busy+=("$p"); fi
  done
  if (( ${#busy[@]} )); then
    _p_warn "already listening: ${busy[*]} -- a previous install, or something else"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# print -- resolve and show, change nothing
# ---------------------------------------------------------------------------

profile_print() {
  local k
  printf 'profile      %s\n' "$PROFILE_PATH"
  printf 'sha256       %s\n' "$PROFILE_SHA256"
  printf '\n-- policy (from the profile) --\n'
  for k in PROFILE_NAME PROFILE_VERSION INFERENCE_MODE \
           MODEL_DIR SERVED_MODEL_NAME TOOL_CALL_PARSER REMOTE_ENDPOINT_URL \
           MAX_MODEL_LEN AGENT_MAX_TOKENS MEM_CAP GPU_MEMORY_UTILIZATION \
           VLLM_IMAGE VLLM_CONTAINER VLLM_PORT VLLM_EXTRA_ARGS SANDBOX_NAME \
           CONTROL_UI_PORT DASHBOARD_PUBLIC_PORT NEMOCLAW_GATEWAY_PORT \
           DASHBOARD_AUTH DASHBOARD_AUTH_USER; do
    [[ -n "${!k:-}" ]] && printf '  %-24s %s\n' "$k" "${!k}"
  done
  printf '\n-- host facts (detected on this machine) --\n'
  for k in HOST_BRIDGE_IP BIND_IP; do
    printf '  %-24s %s\n' "$k" "${!k:-<unresolved>}"
  done
  printf '\n-- not configurable (forced values, see scripts) --\n'
  printf '  %-24s %s\n' "provider"        "custom / local-no-auth"
  printf '  %-24s %s\n' "onboard"         "--non-interactive --yes, stdin closed"
  printf '  %-24s %s\n' "egress policy"   "local-inference, then base_url -> host.openshell.internal"
  printf '  %-24s %s\n' "vllm gemm"       "VLLM_NVFP4_GEMM_BACKEND=marlin"
  printf '  %-24s %s\n' "build threads"   "MAX_JOBS=4 NVCC_THREADS=1"
  printf '  %-24s %s\n' "compose"         "never -- fails with int('') on this hardware"
}
