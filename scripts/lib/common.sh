# Shared output helpers and Hermes probes.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# WHY THIS EXISTS
# ---------------
# ok/note/warn/die and the colour codes were byte-identical copy-paste across
# seven files, and the dashboard-token scrape appeared in four -- in three
# slightly different forms. That regex depends on how Hermes embeds the token in
# its dashboard HTML. When that changes it is one upstream change and, before
# this file, four separate edits with three chances to miss one.
#
# ⚠ THE CONSTRAINT that produced the duplication in the first place: host/
# scripts are INSTALLED to ~/.local/bin and run detached from this repo, so they
# cannot source a repo-relative path. They look for this file in both places --
# see hermes_common_load() usage in host/. install-host-services.sh installs it
# to ~/.local/lib/hermes-quickstart/common.sh so that lookup succeeds.

# Guard against double-sourcing when one script sources another.
[ -n "${_HERMES_COMMON_LOADED:-}" ] && return 0
_HERMES_COMMON_LOADED=1

# Logs go in a PER-USER directory, not fixed /tmp/<name>.log paths.
#
# They were fixed paths, and on a shared machine that means the first user to
# run owns the file: a second user cannot write it, and -- worse -- the failure
# message points them at someone else's log. Chasing that on 2026-08-28 cost
# real time and produced a false alarm about a contaminated home directory.
: "${HERMES_LOG_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/hermes-quickstart}"
mkdir -p "$HERMES_LOG_DIR" 2>/dev/null || HERMES_LOG_DIR="$(mktemp -d)"
export HERMES_LOG_DIR

GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'
BOLD=$'\033[1m'; OFF=$'\033[0m'

ok()   { printf '%s    ✓%s %s\n' "$GRN" "$OFF" "$1"; }
note() { printf '%s      %s%s\n' "$DIM" "$1" "$OFF"; }
warn() { printf '%s    ! %s%s\n' "$YEL" "$1" "$OFF"; }
die()  { printf '%s    ✗ %s%s\n' "$RED" "$1" "$OFF" >&2; exit 1; }

# --- Hermes probes ---------------------------------------------------------
# The dashboard mints its session token in memory at startup and injects it into
# the SPA HTML, so it ROTATES on every dashboard restart. `Host: localhost` is
# required -- the vhost check rejects other Host headers.
hermes_dashboard_token() {
    local url="${1:?usage: hermes_dashboard_token <control-ui-url>}"
    curl -s --max-time "${2:-8}" -H 'Host: localhost' "$url/" 2>/dev/null \
      | grep -oP '__HERMES_SESSION_TOKEN__\s*=\s*"\K[^"]+' | head -1
}

# Judge the control UI by what it SERVES, never by a bound port. After a sandbox
# restart the forward can be listening while pointing at a dead ssh session --
# `ss` shows the port bound and nothing works. That cost hours once.
hermes_dashboard_ok() {
    [ -n "$(hermes_dashboard_token "${1:?}" "${2:-6}")" ]
}

# Rebuild a forward. `forward start` errors when one already exists, which is
# success, not failure -- hence the stop first and the swallowed status.
hermes_forward_restart() {
    local port="${1:?}" sandbox="${2:?}"
    timeout 60 openshell forward stop "$port" "$sandbox" >/dev/null 2>&1 || true
    timeout 120 openshell forward start --background "$port" "$sandbox" >/dev/null 2>&1 || true
}

# --- healthcheck verdicts --------------------------------------------------
# Pure functions, kept here rather than inline in healthcheck.sh so that
# selftest.sh exercises the SAME comparison the healthcheck runs, not a copy of
# it that can drift. Each prints "<verdict> <detail>".

# The config seal. Two NemoClaw layouts exist:
#
#   older   one anchor, root-owned /etc/nemoclaw/hermes.config-hash, compared
#           against the live /sandbox/.hermes/config.yaml.
#   0.0.137 the runtime guard checks the live file against line 1 of
#           /sandbox/.hermes/.config-hash. At startup NemoClaw rewrites
#           config.yaml (a cosmetic YAML reformat plus a refreshed local
#           credential reference), keeps the pre-rewrite copy as
#           .native-local-startup-config, and updates ONLY the /sandbox hash --
#           it cannot write the root-owned /etc one. So /etc legitimately holds
#           the hash of that pre-rewrite copy, and comparing it to the live file
#           reports drift on every healthy 0.0.137 sandbox.
#
#   hermes_seal_verdict <etc-hash> <sandbox-hash> <live-hash> <native-hash>
#     -> match | drift | unknown
hermes_seal_verdict() {
    local etc="$1" sbx="$2" live="$3" native="$4"
    [ -n "$live" ] || { echo "unknown live config unreadable"; return; }
    if [ -z "$sbx" ]; then
        # Older layout: the /etc anchor is the only one.
        [ -n "$etc" ] || { echo "unknown no hash anchor found"; return; }
        [ "$etc" = "$live" ] && echo "match sealed anchor == live" \
                             || echo "drift sealed ${etc:0:12}... vs live ${live:0:12}..."
        return
    fi
    # Newer layout: the guard's own comparison first -- this is what fails closed.
    [ "$sbx" = "$live" ] \
        || { echo "drift guard hash ${sbx:0:12}... vs live ${live:0:12}..."; return; }
    if [ -z "$etc" ] || [ "$etc" = "$live" ]; then
        echo "match guard hash == live"
    elif [ -n "$native" ] && [ "$etc" = "$native" ]; then
        echo "match guard hash == live; root anchor == pre-rewrite startup copy"
    else
        echo "drift root anchor ${etc:0:12}... matches neither live nor the startup copy"
    fi
}

# MCP digest, line 3 of the hash anchor. NemoClaw 0.0.137 retired it ("no
# separate MCP digest"), leaving a two-line file -- not a missing check.
#   hermes_mcp_verdict <anchor-file-contents> -> pass | fail | na | warn
hermes_mcp_verdict() {
    local body="$1" n line3 i ap
    n="$(printf '%s\n' "$body" | sed '/^$/d' | wc -l | tr -d ' ')"
    line3="$(printf '%s\n' "$body" | sed -n 3p)"
    if [ "$n" -le 2 ] && [ "$n" -ge 1 ]; then
        echo "na anchor has no MCP line (retired by newer NemoClaw)"
    elif [ -z "$line3" ]; then
        echo "warn not found in the anchor"
    elif [ "${line3#*intended=}" != "$line3" ]; then
        i="${line3#*intended=}"; i="${i%% *}"; ap="${line3#*applied=}"; ap="${ap%% *}"
        [ "$i" = "$ap" ] && echo "pass intended == applied" \
                         || echo "fail intended ${i:0:12}... != applied ${ap:0:12}..."
    else
        echo "warn line 3 is not an intended/applied digest"
    fi
}

# Sandbox restart policy. Older NemoClaw set unless-stopped and docker brought
# the sandbox back. 0.0.137 sets 'no', and NOTHING restarts it on its own:
# the nemoclaw-openshell-gateway user service starts the gateway, not
# sandboxes. Worse, a sandbox whose container is killed by the host shutdown
# (exit 143) is marked Phase: Error by OpenShell, and Error is terminal -- start
# needs Stopped, stop needs Ready, recover skips it. Verified on a real reboot
# 2026-10-23. The only clean path is a graceful stop BEFORE docker stops the
# container, which is what hermes-sandbox-shutdown.service does; the restore
# unit then runs `<agent> <sandbox> start` at boot.
#   hermes_restart_verdict <policy> <shutdown-hook-enabled 0|1> -> pass | fail | warn
hermes_restart_verdict() {
    case "$1" in
        unless-stopped|always) echo "pass $1 -- returns after a reboot" ;;
        no|"")
            if [ "$2" = 1 ]; then
                echo "pass '${1:-no}' -- hermes-sandbox-shutdown.service stops it cleanly; hermes-stack-restore starts it"
            else
                echo "fail '${1:-no}' and no shutdown hook -- a reboot leaves the sandbox in Phase: Error (rebuild needed)"
            fi ;;
        *) echo "warn '$1' -- may not return after a reboot" ;;
    esac
}

# OpenShell's view of the sandbox: Ready, Stopped, Error, Provisioning, ...
# A running container is NOT a Ready sandbox: after the failed 2026-10-23
# reboot `docker start` brought the container up while OpenShell kept it in
# Error, and every NemoClaw command refused it.
#   hermes_sandbox_phase <name>  -> prints the phase, or nothing if unknown
hermes_sandbox_phase() {
    # Never fails: callers run under set -e -o pipefail, and an early-exiting
    # reader here once killed hermes-stack-restore with SIGPIPE.
    { openshell sandbox get "${1:?}" 2>/dev/null | hermes_parse_phase; } || true
}
# Reads `openshell sandbox get` table output on stdin (ANSI colour allowed).
hermes_parse_phase() {
    sed 's/\x1b\[[0-9;]*m//g' | awk '$1 == "Phase:" && !p { print $2; p = 1 }'
}

# Did systemd break an ordering cycle in THIS boot by deleting one of our jobs?
# It logs the cycle once at boot and then runs as if the unit did not exist --
# `is-enabled` still says enabled. That is how hermes-stack-restore silently
# never ran on 2026-10-23.
#   hermes_ordering_cycle_units  -> prints the deleted unit names, one per line
hermes_ordering_cycle_units() {
    { journalctl --user -b 0 --no-pager -q 2>/dev/null
      journalctl -b 0 --no-pager -q 2>/dev/null; } \
      | grep -oE 'Job [^ ]+ deleted to break ordering cycle' \
      | awk '{print $2}' | sed 's|/.*||' | sort -u
}

# --- the vLLM exit-time crash ------------------------------------------------
# Before it loads weights, vLLM inspects the model class in a throwaway python
# subprocess (vllm/model_executor/models/registry.py, _run_in_subprocess). On the
# NVIDIA NGC image (torch 2.13.0a0+nv26.07) that subprocess intermittently
# SEGFAULTS AT INTERPRETER EXIT -- after it has already produced its answer:
#
#   torch/library.py:663  _del_library  -> _clear_torch_ops_cache
#   torch/_ops.py:1412    _get_packet   -> torch._C._jit_get_operation
#   UnicodeDecodeError: 'utf-8' codec can't decode byte 0x.. (a different byte
#   every run -- a use-after-free in an atexit finalizer)
#
# vLLM only looks at the exit status, calls the inspection failed, and the whole
# server exits within seconds: "died with <Signals.SIGSEGV: 11>" followed by
# "Model architectures [...] failed to be inspected". The same image, flags and
# model start fine on the next attempt (3 failures in 4 starts on one cold
# run, then 6 clean starts in a row on the same box), so this is a bounded
# retry, not a fix to the image. vLLM's own on-disk model-info cache would skip the subprocess, but it is
# only written after a SUCCESSFUL inspection, so it cannot help a first start.
#
#   hermes_vllm_inspect_crashed <container> [since-unix-time]
# True only for this exact signature, so a real failure (bad flags, OOM, a
# missing model) is never retried.
hermes_vllm_inspect_crashed() {
    local logs
    logs="$(docker logs ${2:+--since "$2"} "${1:?}" 2>&1)" || true
    grep -qE "vllm\.model_executor\.models\.registry.*died with <Signals\.SIGSEGV" <<<"$logs"
}
# How many times a start is attempted in total (1 = never retry).
HERMES_VLLM_START_ATTEMPTS="${HERMES_VLLM_START_ATTEMPTS:-3}"

# --- which OpenShell gateway ----------------------------------------------
# Every `openshell` call goes to the ACTIVE gateway (~/.config/openshell/
# active_gateway) unless OPENSHELL_GATEWAY names another. If that profile points
# at a port nothing listens on, every call fails "connection refused" -- and the
# phase probe above prints NOTHING, which callers used to read as "not Ready".
# That is how the 2026-10-23 shutdown hook logged "phase before shutdown:
# unknown -> nothing to stop" and let docker SIGKILL the sandbox: a sandbox-only
# reinstall had registered a second gateway, nemoclaw-8082, and made it active,
# while the only gateway that comes back at boot (the nemoclaw-openshell-gateway
# user unit) listens on 8080.
_hermes_os_dir() { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/openshell"; }
hermes_gateway_active() {
    head -1 "$(_hermes_os_dir)/active_gateway" 2>/dev/null | tr -d '[:space:]'
}
# Stored endpoint of a gateway profile, e.g. https://127.0.0.1:8080
hermes_gateway_endpoint() {
    sed -n 's/.*"gateway_endpoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$(_hermes_os_dir)/gateways/${1:?}/metadata.json" 2>/dev/null | head -1
}
hermes_gateway_names() {
    local d
    for d in "$(_hermes_os_dir)"/gateways/*/metadata.json; do
        [ -r "$d" ] && basename "$(dirname "$d")"
    done
    return 0
}
# Does anything accept a TCP connection at <scheme>://host:port ?
hermes_endpoint_listening() {
    local hp="${1#*://}" host port
    hp="${hp%%/*}"; host="${hp%:*}"; port="${hp##*:}"
    [ -n "$host" ] && [ "$port" != "$hp" ] || return 1
    timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$host" "$port" 2>/dev/null
}
hermes_gateway_listening() {
    local ep; ep="$(hermes_gateway_endpoint "${1:?}")"
    [ -n "$ep" ] && hermes_endpoint_listening "$ep"
}
# The gateway NemoClaw recorded for a sandbox (registry field gatewayName), from
# the default registry or a per-port one (~/.nemoclaw/gateways/<port>/).
hermes_sandbox_gateway() {
    local f home="${NEMOCLAW_HOME:-$HOME/.nemoclaw}" fb
    for f in "$home/sandboxes.json" "$home"/gateways/*/sandboxes.json; do
        [ -r "$f" ] || continue
        case "$f" in "$home/sandboxes.json") fb=nemoclaw ;;
                     *) fb="nemoclaw-$(basename "$(dirname "$f")")" ;; esac
        python3 -c 'import json,sys
s=(json.load(open(sys.argv[1])).get("sandboxes") or {}).get(sys.argv[2])
if s: print(s.get("gatewayName") or sys.argv[3])' "$f" "${1:?}" "$fb" 2>/dev/null \
            | grep . && return 0
    done
    return 0
}
# Pin OPENSHELL_GATEWAY to a gateway that is actually listening, preferring the
# one the sandbox was registered with, then the active one, then the default
# `nemoclaw`. Prints the chosen name; returns 1 if none answers.
#   hermes_gateway_pin [sandbox]
hermes_gateway_pin() {
    local g seen=" "
    for g in ${OPENSHELL_GATEWAY:-} ${1:+$(hermes_sandbox_gateway "$1")} \
             "$(hermes_gateway_active)" nemoclaw $(hermes_gateway_names); do
        [ -n "$g" ] || continue
        case "$seen" in *" $g "*) continue ;; esac
        seen="$seen$g "
        if hermes_gateway_listening "$g"; then
            export OPENSHELL_GATEWAY="$g"; printf '%s\n' "$g"; return 0
        fi
    done
    return 1
}
# The active gateway, judged: present, expected name, listening.
#   hermes_gateway_verdict [expected-name] -> "pass|fail <detail>"
hermes_gateway_verdict() {
    local want="${1:-}" act ep
    act="$(hermes_gateway_active)"
    [ -n "$act" ] || { echo "fail no active OpenShell gateway"; return; }
    ep="$(hermes_gateway_endpoint "$act")"
    [ -n "$ep" ] || { echo "fail active gateway '$act' has no stored endpoint"; return; }
    if [ -n "$want" ] && [ "$act" != "$want" ]; then
        echo "fail active gateway is '$act' ($ep), expected '$want' -- openshell gateway select $want"
        return
    fi
    hermes_endpoint_listening "$ep" \
        || { echo "fail active gateway '$act' ($ep) is not listening -- every openshell call will be refused"; return; }
    echo "pass $act ($ep) listening"
}
# Gateway name NemoClaw uses for a port (src/lib/onboard/gateway-binding/identity.ts).
hermes_gateway_name_for_port() {
    [ "${1:?}" = 8080 ] && echo nemoclaw || echo "nemoclaw-$1"
}

# --- the desktop app must match the backend --------------------------------
# The Desktop client is built from a host checkout of hermes-agent; the agent
# itself runs INSIDE the sandbox at whatever version NemoClaw's image carries.
# The two speak a versioned RPC and the gateway validates strictly: a client
# built from upstream HEAD (v0.22.5) against a 0.21.3 sandbox sent
# prompt.submit with extra fields (title, preview) and every prompt failed with
# "invalid params ... Extra inputs are not permitted" (2026-10-27).
#
# So the checkout is pinned to the tag that matches the sandbox. Upstream tags
# releases as v<date>, and `hermes --version` prints that date in brackets, so
# the tag is derivable from the sandbox. At phase 1 no sandbox exists yet, so
# this constant is the pin for the NemoClaw tag this repo installs (v0.0.137,
# hermes 0.21.3). Change it together with NEMOCLAW_INSTALL_TAG.
: "${HERMES_HOST_REF_PIN:=v2026.9.14}"

#   hermes_version_tag "<hermes --version output>"  -> v2026.9.14, or nothing
hermes_version_tag() {
    local d
    d="$(printf '%s\n' "${1:-}" | grep -oE '\(20[0-9]{2}\.[0-9]{1,2}\.[0-9]{1,2}\)' | head -1 | tr -d '()')" || true
    [ -n "$d" ] && printf 'v%s\n' "$d"
    return 0
}

#   hermes_desktop_ref_verdict <want-tag> <want-commit> <built-commit>
# <built-commit> is the commit the desktop build's install stamp recorded.
hermes_desktop_ref_verdict() {
    local tag="${1:-}" want="${2:-}" built="${3:-}"
    if [ -z "$built" ]; then
        echo "warn no desktop build stamp -- is the desktop client built? (./scripts/install-hermes-host.sh)"
    elif [ -z "$want" ]; then
        echo "warn cannot resolve ${tag:-the sandbox hermes tag} in the host checkout (git fetch --tags)"
    elif [ "$built" = "$want" ]; then
        echo "pass desktop built from ${tag} (${built:0:10}), matching the sandbox"
    else
        echo "fail desktop built from ${built:0:10} but the sandbox runs ${tag} (${want:0:10}) -- prompts will be rejected. Fix: ./scripts/install-hermes-host.sh --ref ${tag}"
    fi
}

# Electron aborts at startup when kernel.apparmor_restrict_unprivileged_userns=1
# (the Ubuntu default on a Spark) and its SUID sandbox helper is not root-owned
# and setuid: "The SUID sandbox helper binary was found, but is not configured
# correctly" (setuid_sandbox_host.cc). A fresh build leaves it as the user, 0755.
#   hermes_chrome_sandbox_verdict <owner:group> <octal-mode>
hermes_chrome_sandbox_verdict() {
    if [ -z "${1:-}" ]; then
        echo "warn no chrome-sandbox found -- desktop client not built"
    elif [ "$1" = root:root ] && [ "${2:-}" = 4755 ]; then
        echo "pass chrome-sandbox root:root 4755"
    else
        echo "fail chrome-sandbox is ${1} ${2:-?}, want root:root 4755 -- Electron will not start. Fix: sudo chown root:root <it> && sudo chmod 4755 <it>"
    fi
}

#   hermes_chrome_sandbox_path <hermes-checkout-root> -> path of the helper, if built
hermes_chrome_sandbox_path() {
    local f
    for f in "${1:?}"/apps/desktop/release/linux-*unpacked/chrome-sandbox; do
        [ -e "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

# Set the helper's ownership and mode. Tries passwordless sudo first, then an
# interactive one when a terminal is attached. Returns non-zero when it could not.
hermes_chrome_sandbox_fix() {
    local f="${1:?}"
    if sudo -n chown root:root "$f" 2>/dev/null && sudo -n chmod 4755 "$f" 2>/dev/null; then return 0; fi
    if [ -t 0 ] || [ -r /dev/tty ]; then
        sudo chown root:root "$f" && sudo chmod 4755 "$f" && return 0
    fi
    return 1
}

# Which desktop token file holds what. The app boots from connections.json (the
# v2 store: a "connections" list, id 127-0-0-1-<port>); connection.json is the
# older single-connection file. Both must carry the live token for OUR url.
# Entries for other urls are not ours and are ignored. Prints one
# "<file> <state>" line per file that exists, state = ok | stale | missing |
# unreadable ("missing" = the file has no entry for this url).
#   hermes_desktop_tokens_state <live-token> <control-ui-url> <file>...
hermes_desktop_tokens_state() {
    local tok="${1:?}" url="${2:?}"; shift 2
    python3 - "$tok" "$url" "$@" <<'PY'
import json, os, sys
tok, url = sys.argv[1], sys.argv[2].rstrip("/")
for path in sys.argv[3:]:
    if not os.path.exists(path):
        continue
    try:
        cfg = json.load(open(path))
    except Exception:
        print(f"{path} unreadable"); continue
    vals = []
    def walk(o):
        if isinstance(o, dict):
            t = o.get("token")
            if str(o.get("url", "")).rstrip("/") == url and isinstance(t, dict) and isinstance(t.get("value"), str):
                vals.append(t["value"])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(cfg)
    state = "missing" if not vals else ("ok" if all(v == tok for v in vals) else "stale")
    print(f"{path} {state}")
PY
}

# --- the NemoClaw licence prompt --------------------------------------------
# Asks on the terminal and returns 0 only for an explicit y / yes. Anything else
# (a bare Enter, EOF, or no terminal at all) is "no": accepting a third-party
# licence is not ours to do for the user. The prompt goes to stderr so it
# survives an installer phase that tees stdout.
hermes_licence_prompt() {
    [ -t 0 ] || return 1
    local ans=""
    printf '\n    Accept? [y/N] ' >&2
    IFS= read -r ans || return 1
    case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}
