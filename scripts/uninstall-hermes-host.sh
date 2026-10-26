#!/usr/bin/env bash
# Remove the HOST half: the `hermes` CLI, its checkout, and the desktop client.
#
#   ./scripts/uninstall-hermes-host.sh [--keep-data] [--yes]
#
# Default removes EVERYTHING under ~/.hermes, including chat history.
# --keep-data leaves ~/.hermes config/data and removes only the code.
#
# ⚠ THE CHECK THAT MATTERS is the dependency scan below. On 2026-08-27 a full
# uninstall on this machine deleted ~/.hermes/profiles/mara/node/bin/node, which
# an unrelated service (T3 Code's runtime) executes. The running process kept
# working because it held the inode; a restart would have failed with an error
# pointing nowhere near Hermes. Nothing warned. So this refuses to proceed when
# a live process outside Hermes is running a binary from under ~/.hermes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

KEEP_DATA=0; ASSUME_YES=0
for a in "$@"; do case "$a" in --keep-data) KEEP_DATA=1 ;; --yes|-y) ASSUME_YES=1 ;; esac; done

HHOME="${HERMES_HOME:-$HOME/.hermes}"
[[ -d "$HHOME" ]] || { ok "nothing to remove ($HHOME absent)"; exit 0; }

# --- dependency scan --------------------------------------------------------
# Anything running an executable from under ~/.hermes that is NOT Hermes itself.
echo "==> checking whether anything else depends on $HHOME"
FOREIGN=()
for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
  [[ -r "/proc/$p/exe" ]] 2>/dev/null || continue
  exe=$(readlink -f "/proc/$p/exe" 2>/dev/null) || continue
  case "$exe" in "$HHOME"/*) ;; *) continue ;; esac
  cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
  case "$cmd" in *hermes_cli*|*hermes-agent/venv*|*electron*) continue ;; esac
  FOREIGN+=("$p|$exe|$(printf '%.70s' "$cmd")")
done
if (( ${#FOREIGN[@]} )); then
  warn "${#FOREIGN[@]} process(es) outside Hermes are running binaries from $HHOME:"
  for f in "${FOREIGN[@]}"; do
    IFS='|' read -r pid exe cmd <<<"$f"
    printf '        pid %-8s %s\n' "$pid" "$exe"
    printf '        %s%s%s\n' "$DIM" "$cmd" "$OFF"
  done
  note "removing $HHOME will break these on their next restart."
  note "Move them off ~/.hermes first, or re-run with --keep-data."
  (( ASSUME_YES )) || die "refusing to continue (pass --yes to override)"
  warn "continuing anyway because --yes was given"
else
  ok "nothing outside Hermes depends on $HHOME"
fi

# --- stop Hermes' own processes --------------------------------------------
# Left running, these hold deleted binaries and keep ports bound.
STOPPED=0
for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
  # The pid can exit between listing /proc and reading it, and without both the
  # guard and the redirect the teardown sprays "No such file or directory" for
  # processes that simply finished. Noise in a documented process reads as
  # breakage.
  [[ -r "/proc/$p/cmdline" ]] 2>/dev/null || continue
  cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
  case "$cmd" in
    *hermes_cli.main*|*hermes-agent/apps/desktop*) kill "$p" 2>/dev/null && STOPPED=$((STOPPED+1)) ;;
  esac
done
(( STOPPED )) && ok "stopped $STOPPED Hermes process(es)" || ok "no Hermes processes running"
sleep 2

# --- remove -----------------------------------------------------------------
export PATH="$HOME/.local/bin:$PATH"
# `hermes uninstall` REFUSES to run without a terminal:
#   "requires an interactive terminal. It cannot be run through a pipe or
#    non-interactive subprocess."
# So `reset.py down --everything --yes` silently removed nothing of the host
# half -- the claim "one command removes everything" was false in any scripted
# context, which is every context that matters here. script(1) allocates a pty,
# which satisfies it. Verified 2026-08-28 on a clean user.
run_hermes_uninstall() {
  local args="$1"
  if command -v script >/dev/null 2>&1; then
    script -qec "hermes uninstall $args" /dev/null >"$HERMES_LOG_DIR"/hermes-host-uninstall.log 2>&1 </dev/null || true
  else
    hermes uninstall $args >"$HERMES_LOG_DIR"/hermes-host-uninstall.log 2>&1 || true
  fi
}

if command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1; then
  if (( KEEP_DATA )); then
    run_hermes_uninstall "--yes"
    ok "removed code and services, kept $HHOME data"
  else
    run_hermes_uninstall "--full --yes"
    ok "removed Hermes (full)"
  fi
fi

# Whether the CLI ran or not, verify the outcome and finish the job by hand.
# A half-finished uninstall leaves a broken CLI that cannot uninstall itself --
# observed on a test user, where hermes died with an ImportError on
# hermes_cli.main and every later attempt was hopeless.
if (( KEEP_DATA )); then
  [[ -d "$HHOME/hermes-agent" ]] && { rm -rf "$HHOME/hermes-agent"; note "removed the checkout by hand"; }
else
  [[ -d "$HHOME" ]] && { rm -rf "$HHOME"; note "removed $HHOME by hand"; }
fi

# `hermes uninstall --full` deletes ~/.hermes and leaves ~/.local/bin/hermes
# behind. Two ways that bites, and the first version of this check caught
# neither:
#
#   * a leftover real file is still executable, so it stays on PATH while
#     exec'ing a venv that no longer exists;
#   * a leftover SYMLINK is now dangling -- and `[[ -e ]]` FOLLOWS symlinks, so
#     a broken one tests false and was silently skipped, while `command -v`
#     still finds it and reports hermes as installed.
#
# Hence -L as well as -e, and the test is whether it RUNS, not whether it exists.
W="$HOME/.local/bin/hermes"
if [[ -e "$W" || -L "$W" ]]; then
  if ! "$W" --version >/dev/null 2>&1; then
    rm -f "$W"
    ok "removed the leftover hermes wrapper (it no longer ran)"
  fi
fi
# The Node this repo installed for the Electron build, and only that one. It
# lives under its own prefix precisely so this can be exact -- a system node, or
# one the user installed, is untouched because it is not in that directory.
NODE_PREFIX="$HOME/.local/lib/hermes-quickstart/node"
if [[ -d "$NODE_PREFIX" ]]; then
  for b in node npm npx; do
    L="$HOME/.local/bin/$b"
    if [[ -L "$L" && "$(readlink -f "$L" 2>/dev/null)" == "$NODE_PREFIX"/* ]]; then
      rm -f "$L"
    fi
  done
  rm -rf "$NODE_PREFIX"
  rmdir "$HOME/.local/lib/hermes-quickstart" 2>/dev/null || true
  ok "removed the Node.js this quickstart installed"
fi

hash -r 2>/dev/null || true
if command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1; then
  warn "a working 'hermes' is still on PATH: $(command -v hermes)"
else
  ok "hermes is gone"
fi
