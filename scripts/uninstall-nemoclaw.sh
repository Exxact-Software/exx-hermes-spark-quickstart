#!/usr/bin/env bash
# Remove NemoClaw (the nemohermes CLI), using NVIDIA's own uninstaller.
#
#   ./scripts/uninstall-nemoclaw.sh [--yes]
#
# The install side grew a phase for NemoClaw but the teardown never removed it,
# so `down --everything` left ~800 MB of ~/.nemoclaw and the CLI on PATH. A
# teardown that does not undo an install is not a teardown -- and it is exactly
# what makes a second test run behave differently from the first.
#
# NVIDIA ship uninstall.sh in their repo:
#   Usage: ./uninstall.sh [--yes] [--keep-openshell] [--delete-models] [--destroy-user-data]
# --delete-models is deliberately NOT passed: model weights are tens of GB, are
# not ours to discard, and this repo never removes them anywhere else.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ASSUME_YES=0
for a in "$@"; do case "$a" in --yes|-y) ASSUME_YES=1 ;; esac; done
export PATH="$HOME/.local/bin:$PATH"

SRC="${NEMOCLAW_SOURCE_DIR:-$HOME/.nemoclaw/source}"
UNINSTALLER=""
[[ -x "$SRC/uninstall.sh" ]] && UNINSTALLER="$SRC/uninstall.sh"

if [[ -z "$UNINSTALLER" ]] && ! command -v nemohermes >/dev/null 2>&1 && [[ ! -d "$HOME/.nemoclaw" ]]; then
  ok "NemoClaw not installed"
  exit 0
fi

if [[ -n "$UNINSTALLER" ]]; then
  (( ASSUME_YES )) || { warn "refusing without --yes"; exit 1; }
  # Same pty treatment as hermes: these installers tend to want a terminal.
  if command -v script >/dev/null 2>&1; then
    # `</dev/null` matters: these uninstallers need a pty, which `script`
    # provides, but with stdin still attached to a terminal the process group
    # gets SIGTTIN the moment the teardown runs in the background -- from a
    # capture harness, cron, or a systemd unit. The whole tree then sits in
    # state T forever, having removed nothing, with no error and no timeout.
    script -qec "$UNINSTALLER --yes" /dev/null >"$HERMES_LOG_DIR"/nemoclaw-uninstall.log 2>&1 </dev/null || true
  else
    "$UNINSTALLER" --yes >"$HERMES_LOG_DIR"/nemoclaw-uninstall.log 2>&1 || true
  fi
  ok "ran NVIDIA's uninstaller"
else
  note "no uninstall.sh found; removing by hand"
fi

# Verify and finish by hand. Judged by outcome, like everything else here.
for f in nemoclaw nemohermes nemo-deepagents nemoclaw-acp openshell openshell-gateway openshell-sandbox; do
  W="$HOME/.local/bin/$f"
  [[ -e "$W" || -L "$W" ]] && rm -f "$W"
done
rm -rf "$HOME/.local/lib/node_modules/nemoclaw" 2>/dev/null || true
# ~/.nemoclaw holds the sandbox registry. Removing it while sandboxes are still
# running orphans their containers: `nemohermes list` then reports none while
# openshell-*-<sandbox>-<uuid> keeps running, holding its forwards and ports,
# and nothing can address it by name any more. reset.py destroys sandboxes
# before calling this; running it directly skips that, so say so.
if [[ -s "$HOME/.nemoclaw/sandboxes.json" ]] \
   && grep -q '"name"' "$HOME/.nemoclaw/sandboxes.json" 2>/dev/null; then
  warn "sandboxes are still registered -- their containers will be orphaned"
  note "for a clean teardown use:  python3 scripts/reset.py down --everything --yes"
fi
[[ -d "$HOME/.nemoclaw" ]] && { rm -rf "$HOME/.nemoclaw"; note "removed ~/.nemoclaw"; }
# Gateway state accumulates a directory per port across installs, and a saved
# onboarding session lives alongside it. NVIDIA's uninstaller touches neither,
# so both survived a "factory reset" -- and the stale session made the SECOND
# install on a machine refuse to onboard at all.
[[ -d "$HOME/.local/state/nemoclaw" ]] \
  && { rm -rf "$HOME/.local/state/nemoclaw"; note "removed ~/.local/state/nemoclaw"; }
hash -r 2>/dev/null || true
command -v nemohermes >/dev/null 2>&1 && warn "nemohermes still on PATH: $(command -v nemohermes)" || ok "NemoClaw is gone"
