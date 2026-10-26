#!/usr/bin/env bash
# Install NemoClaw, which provides the `nemohermes` CLI this repo drives.
#
#   ./scripts/install-nemoclaw.sh [--skip-verify]
#
# ⚠ DO NOT "SIMPLIFY" THIS TO `npm install -g nemoclaw`.
#
# There IS a package called `nemoclaw` on the public npm registry, at version
# 0.1.0 -- the same version string as NVIDIA's. It is NOT the same software:
#
#     npm nemoclaw@0.1.0      NVIDIA's nemoclaw@0.1.0
#     maintainer jacobtomlinson   repository github.com/NVIDIA/NemoClaw
#     no repository field         bin: nemoclaw, nemohermes, nemo-deepagents
#     no description              "run OpenClaw inside OpenShell with NVIDIA inference"
#     NO bin entries              (the CLI this repo needs)
#
# Installing it would put an unrelated person's package on a customer's machine
# and still leave `nemohermes` missing. Checked 2026-08-27.
#
# The install path below is NVIDIA's own, documented for DGX Spark in
# spark-install.md in their repository. The URL 302s to
# raw.githubusercontent.com/NVIDIA/NemoClaw/refs/heads/main/install.sh -- a thin
# Apache-2.0 bootstrap that selects a ref, clones it, and runs the installer
# from that clone. It defaults to the `lkg` (last-known-good) tag, not main.
#
# Pinned to a tag (NEMOCLAW_INSTALL_TAG, overridable). `lkg` moves, and the
# installer's defaults moved with it: around v0.0.137 an unattended install
# with no agent selected onboards an OpenClaw sandbox of its own, which claims
# the gateway's only inference route and blocks Hermes. The flags below were
# checked against this exact tag's installer source. To try a newer NemoClaw:
#     NEMOCLAW_INSTALL_TAG=lkg ./install.sh ...
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

NEMOCLAW_INSTALLER="${NEMOCLAW_INSTALLER_URL:-https://www.nvidia.com/nemoclaw.sh}"
NEMOCLAW_INSTALL_TAG="${NEMOCLAW_INSTALL_TAG:-v0.0.137}"
ACCEPT_LICENSE="${NEMOCLAW_ACCEPT_LICENSE:-0}"
for a in "$@"; do case "$a" in --accept-license) ACCEPT_LICENSE=1 ;; esac; done

export PATH="$HOME/.local/bin:$PATH"
if command -v nemohermes >/dev/null 2>&1 && nemohermes --version >/dev/null 2>&1; then
  ok "nemohermes already installed ($(nemohermes --version 2>/dev/null | head -1))"
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required to install NemoClaw"

# NVIDIA's installer stops at a licence prompt:
#   Type 'yes' to accept the NemoClaw license and third-party software notice
# Unattended, that hangs forever -- it burned two hours in the first fresh-user
# test before a timeout killed it.
#
# It offers --non-interactive and --yes-i-accept-third-party-software, and it
# would be easy to pass those always. We do not, on purpose: that would mean
# this repo silently accepting NVIDIA's third-party software notice on someone
# else's machine, which is not ours to do. Accepting is one explicit flag.
if [[ "$ACCEPT_LICENSE" != 1 ]]; then
  printf '\n%s  NemoClaw requires accepting NVIDIA'"'"'s licence and third-party notice.%s\n' "$YEL" "$OFF" >&2
  cat >&2 <<'MSG'

    That notice covers software this installer RETRIEVES but does not
    distribute -- OpenClaw, OpenShell and container images -- each under its
    own terms. Review it, then re-run with:

        ./install.sh --profile <profile> --accept-nemoclaw-license

    Or install NemoClaw yourself first, interactively:

        curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash

    Docs: https://build.nvidia.com/spark/nemoclaw/instructions
MSG
  exit 1
fi

# Kept although onboarding is now deferred (below): deferral is conditional,
# and caches left by earlier installs are still root-owned.
#
# NemoClaw's onboarding runs vLLM in a container as root, and that container
# writes into the user's own ~/.cache/huggingface. The files it leaves are
# root-owned, so the NEXT install cannot write there and onboarding aborts with
#   vLLM install failed: Hugging Face cache path .../.no_exist is not writable
# That blocks reinstall-after-teardown entirely, and no amount of --fresh helps
# because the problem is on disk, not in the saved session.
#
# Repaired with docker rather than sudo: docker access is already a
# prerequisite, and this asks for no privilege the user did not already have.
# Ownership only -- the cache itself is kept, since re-downloading it is 22 GB.
HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}"
if [[ -d "$HF_CACHE" ]] && [[ -n "$(find "$HF_CACHE" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]]; then
  note "repairing root-owned files in $HF_CACHE (left by a containerised vLLM)"
  if docker run --rm -v "$HF_CACHE:/hf" alpine:3 \
       chown -R "$(id -u):$(id -g)" /hf >/dev/null 2>&1; then
    ok "Hugging Face cache is writable again"
  else
    warn "could not repair it; onboarding will likely fail"
    note "run:  sudo chown -R $(id -un): $HF_CACHE"
  fi
fi

# Only matters if NemoClaw onboards despite the deferral below, but cheap.
# NemoClaw's onboarding starts a vLLM of its own and needs host port 8000 free.
# Our model server publishes that same port, and phase 2 recreates it a few
# minutes later regardless, so stopping it here costs nothing. Leaving it up
# made onboarding abort with "port 8000 is already in use by another process"
# whenever NemoClaw was reinstalled while the rest of the stack kept running.
# install.sh's preflight deliberately lets our own container through to this
# point; this is where it is dealt with.
P8K="$(docker ps --filter publish=8000 --format '{{.Names}}' 2>/dev/null | head -1)" || true
case "${P8K:-}" in
  "") ;;
  nemoclaw-vllm|hermes-*-vllm)
    note "stopping $P8K so onboarding can bind port 8000 (phase 2 recreates it)"
    docker rm -f "$P8K" >/dev/null 2>&1 || true
    ;;
  *)
    warn "port 8000 is held by container '$P8K', which is not ours"
    note "NemoClaw onboarding needs it. Free it and re-run: docker rm -f $P8K"
    ;;
esac

echo "==> installing NemoClaw (NVIDIA's installer; several minutes)"
note "$NEMOCLAW_INSTALLER"
note "third-party notice accepted via --accept-nemoclaw-license"
note "NemoClaw ref: $NEMOCLAW_INSTALL_TAG"
export NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1
export NEMOCLAW_INSTALL_TAG
# Install the CLI only; onboarding is this repo's job (scripts/onboard-agent.sh).
#
# Without NEMOCLAW_AGENT the installer "defaulted to OpenClaw" and, non-
# interactively on a Spark, onboarded its own `my-assistant` with provider
# install-vllm: a ~30 GB vLLM image, a ~22 GB Qwen3.6 checkpoint, a
# `nemoclaw-vllm` container on :8000 -- and the gateway's single inference
# route, so reset.py's preflight then (correctly) refused to install Hermes.
#
# NEMOCLAW_DEFER_ONBOARDING=1 skips onboarding entirely, but NVIDIA only honours
# it when ALL of these hold; otherwise it onboards anyway:
#   - agent is hermes (its manifest has deferred_onboarding: true)
#   - provider unset/build/routed, and no local model profile
#   - no sandbox registered yet
#   - no hosted credential in the environment: NVIDIA_API_KEY,
#     NVIDIA_INFERENCE_API_KEY, or a key-shaped NEMOCLAW_PROVIDER_KEY
# So those variables are removed from the installer's environment only. This
# repo's own onboarding sets its provider explicitly later.
export NEMOCLAW_AGENT=hermes NEMOCLAW_DEFER_ONBOARDING=1
NC_SCRUB=(-u NVIDIA_API_KEY -u NVIDIA_INFERENCE_API_KEY -u NEMOCLAW_PROVIDER_KEY
          -u NEMOCLAW_PROVIDER -u NEMOCLAW_MODEL
          -u NEMOCLAW_ENABLE_LOCAL_MODEL_PROFILE -u NEMOCLAW_LOCAL_MODEL_RUNTIME)
# Retried: the installer pulls the OpenShell release from GitHub with no retry
# of its own, and a single "curl: (28) SSL connection timeout" killed an
# otherwise healthy unattended run. Its own steps are resumable and re-running
# skips what already completed, so another attempt is cheap and safe.
# Each attempt's log is kept -- overwriting them hid why the first one died.
NEMOCLAW_ATTEMPTS="${NEMOCLAW_ATTEMPTS:-3}"
NC_LOG="$HERMES_LOG_DIR"/nemoclaw-install.log
: >"$NC_LOG"
NC_OK=0
for attempt in $(seq 1 "$NEMOCLAW_ATTEMPTS"); do
  (( attempt > 1 )) && note "retry $attempt/$NEMOCLAW_ATTEMPTS after a transient failure"
  {
    printf '\n===== attempt %s/%s at %s =====\n' \
      "$attempt" "$NEMOCLAW_ATTEMPTS" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  } >>"$NC_LOG"
  if curl -fsSL "$NEMOCLAW_INSTALLER" \
       | env "${NC_SCRUB[@]}" bash -s -- --non-interactive \
             --yes-i-accept-third-party-software --defer-onboarding \
             ${NC_FRESH:+--fresh} >>"$NC_LOG" 2>&1; then
    NC_OK=1; break
  fi
  # A saved onboarding session outlives our uninstall, so the SECOND install on
  # a machine refuses to onboard at all:
  #   [ERROR] Previous onboarding session failed. To discard it and start over,
  #           run ... --fresh
  # That breaks reinstall-after-teardown, which is the whole point of being able
  # to reset. NVIDIA names the remedy, so take it on the next attempt.
  if grep -q "Previous onboarding session" "$NC_LOG" 2>/dev/null && [[ -z "${NC_FRESH:-}" ]]; then
    note "a previous onboarding session is blocking this; retrying with --fresh"
    NC_FRESH=1
  fi
  (( attempt < NEMOCLAW_ATTEMPTS )) && sleep $(( attempt * 15 ))
done
if (( ! NC_OK )); then
  tail -25 "$NC_LOG" >&2
  die "NemoClaw install failed after $NEMOCLAW_ATTEMPTS attempts -- full log: $NC_LOG
    Manual instructions: https://build.nvidia.com/spark/nemoclaw/instructions"
fi

# Judge the outcome, not the exit code -- the same rule this repo applies to
# containers, forwards and setup-hermes.sh.
export PATH="$HOME/.local/bin:$PATH"
hash -r 2>/dev/null || true
if ! command -v nemohermes >/dev/null 2>&1 || ! nemohermes --version >/dev/null 2>&1; then
  tail -25 "$HERMES_LOG_DIR"/nemoclaw-install.log >&2
  die "installer finished but 'nemohermes' does not answer --version.
    Check PATH includes ~/.local/bin, or see "$HERMES_LOG_DIR"/nemoclaw-install.log"
fi
ok "nemohermes installed ($(nemohermes --version 2>/dev/null | head -1))"

# Deferral is conditional (see above), so confirm it happened. NVIDIA prints
# "... onboarding did not run." when it defers. If it onboarded anyway, say so
# here: the sandbox it made holds the inference route, and the preflight that
# runs next will refuse with a reason that does not mention this installer.
if grep -q "onboarding did not run" "$NC_LOG" 2>/dev/null; then
  ok "NemoClaw onboarding deferred (no NVIDIA vLLM image or model downloaded)"
elif grep -qE "Running (nemoclaw|nemohermes) onboard" "$NC_LOG" 2>/dev/null; then
  warn "NemoClaw ran its own onboarding instead of deferring it"
  note "it may have registered a sandbox (often 'my-assistant') that holds the"
  note "gateway's inference route. See:  ./scripts/reset.py status"
  note "remove it with:  ./scripts/reset.py down --sandbox <name> --yes"
fi
