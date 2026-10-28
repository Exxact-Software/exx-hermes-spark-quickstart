#!/usr/bin/env bash
# Install the HOST half: the `hermes` CLI and the Electron desktop client.
#
#   ./scripts/install-hermes-host.sh [--skip-desktop] [--ref <git-ref>]
#
# This repo installs the CONTAINERIZED agent. The desktop client, however, ships
# with Hermes Agent's own host install -- and the promise of this repo is one
# command in, one command out. So it installs that too, rather than leaving a
# prerequisite in the README for a viewer to get wrong.
#
# Idempotent. The checkout is ALWAYS brought to the ref that matches the
# sandbox (see HERMES_HOST_REF_PIN in scripts/lib/common.sh), even when a
# working `hermes` already exists: a desktop client built from upstream HEAD
# runs ahead of the sandbox's gateway and every prompt is rejected. The desktop
# build is redone whenever it was not built from that ref.
# Nothing here touches the container or /sandbox/.hermes, so it cannot affect
# the config seal.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

UPSTREAM="${HERMES_UPSTREAM:-https://github.com/NousResearch/hermes-agent.git}"
ROOT="${HERMES_HOST_ROOT:-$HOME/.hermes/hermes-agent}"
REF=""; SKIP_DESKTOP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="${2:-}"; shift 2 ;;
    --skip-desktop) SKIP_DESKTOP=1; shift ;;
    *) shift ;;
  esac
done

# Which ref? Explicit --ref wins. Then the version of the sandbox that is
# already running (a re-run), because that is the thing the client must match.
# Then the pin, for a first install where the sandbox does not exist yet.
SANDBOX_NAME_FOR_REF="${HERMES_SANDBOX_NAME:-${SANDBOX_NAME:-hermes-demo}}"
if [[ -z "$REF" && -n "${HERMES_HOST_REF:-}" ]]; then REF="$HERMES_HOST_REF"; fi
if [[ -z "$REF" ]]; then
  _sc="$(docker ps --format '{{.Names}}' 2>/dev/null \
          | grep -E "^openshell-(.+--)?${SANDBOX_NAME_FOR_REF}-[0-9a-f-]{36}\$" | head -1)" || true
  if [[ -n "$_sc" ]]; then
    REF="$(hermes_version_tag "$(docker exec "$_sc" hermes --version 2>/dev/null)")" || true
    [[ -n "$REF" ]] && note "sandbox hermes version says the client must be built from $REF"
  fi
fi
[[ -n "$REF" ]] || REF="$HERMES_HOST_REF_PIN"

command -v git >/dev/null 2>&1 || die "git is required"
HAVE_CHECKOUT=0; [[ -d "$ROOT/.git" ]] && HAVE_CHECKOUT=1
HAVE_HERMES=0
if command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1; then HAVE_HERMES=1; fi

if (( HAVE_HERMES && ! HAVE_CHECKOUT )); then
  # Somebody's own Hermes, installed elsewhere. Not ours to re-pin.
  ok "hermes already installed ($(hermes --version 2>/dev/null | head -1))"
  note "not a checkout under $ROOT, so it is left as it is."
  note "remove it first if you want a clean install: ./scripts/uninstall-hermes-host.sh"
  ROOT_OWNED=0
else
  ROOT_OWNED=1
  if (( HAVE_CHECKOUT )); then
    note "checkout exists, fetching"
    git -C "$ROOT" fetch --quiet --tags origin || die "could not fetch $UPSTREAM"
  else
    mkdir -p "$(dirname "$ROOT")"
    echo "==> cloning Hermes Agent (this is a large repo; several minutes)"
    git clone --quiet "$UPSTREAM" "$ROOT" || die "clone failed: $UPSTREAM"
  fi
  PREV_HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  git -C "$ROOT" checkout --quiet "$REF" || die "no such ref: $REF"
  note "pinned to $REF -- matches the sandbox, so the desktop client speaks its RPC"
  NEW_HEAD="$(git -C "$ROOT" rev-parse HEAD)"
  ok "source at $ROOT ($(git -C "$ROOT" rev-parse --short HEAD))"

  # setup-hermes.sh builds the venv the CLI runs from. Run it on a fresh
  # checkout AND whenever the ref moved: after a switch to an older ref the
  # launcher failed with "No module named 'yaml'" until setup ran again.
  if (( ! HAVE_HERMES )) || [[ "$PREV_HEAD" != "$NEW_HEAD" ]] || [[ ! -x "$ROOT/venv/bin/hermes" ]]; then
    echo "==> running Hermes' own setup (venv + dependencies + CLI symlink)"
    # Its EXIT CODE is deliberately ignored. setup-hermes.sh installs correctly and
    # then runs an OPTIONAL configuration wizard, which detects no TTY under an
    # installer and exits non-zero -- after printing "✓ Setup complete!". Trusting
    # the status code here reported a perfectly good install as a failure.
    # Judge by the outcome instead: is there a working `hermes` on PATH.
    ( cd "$ROOT" && ./setup-hermes.sh </dev/null ) >"$HERMES_LOG_DIR"/hermes-host-setup.log 2>&1 || true
  fi
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true

  # setup-hermes.sh prints "✓ Symlinked hermes → ~/.local/bin/hermes" and the
  # symlink is sometimes simply not there afterwards -- observed on a clean user
  # 2026-08-28, where ~/.local/bin held the NemoClaw binaries but no hermes,
  # while $ROOT/hermes existed and ran fine. Rather than chase why someone
  # else's installer lost it, repair the outcome: we know where the real script
  # is. Same rule as everywhere else here -- do not trust the claim, check the
  # result, and fix it if it is wrong.
  #
  # The launcher must be the CHECKOUT'S VENV hermes. A generated launcher that
  # runs a bare `python -I` has no PyYAML: after a ref switch it failed with
  # "No module named 'yaml'" and the desktop menu entry (which runs
  # `hermes desktop`) would not start. The venv script is what setup-hermes.sh
  # intends, so point at it whenever it exists.
  if [[ -x "$ROOT/venv/bin/hermes" ]]; then
    install -d "$HOME/.local/bin"
    ln -sfn "$ROOT/venv/bin/hermes" "$HOME/.local/bin/hermes"
    hash -r 2>/dev/null || true
  elif ! command -v hermes >/dev/null 2>&1 && [[ -x "$ROOT/hermes" ]]; then
    install -d "$HOME/.local/bin"
    ln -sfn "$ROOT/hermes" "$HOME/.local/bin/hermes"
    hash -r 2>/dev/null || true
    note "setup did not leave a usable symlink; linked $ROOT/hermes -> ~/.local/bin/hermes"
  fi

  if ! command -v hermes >/dev/null 2>&1 || ! hermes --version >/dev/null 2>&1; then
    tail -25 "$HERMES_LOG_DIR"/hermes-host-setup.log >&2
    die "setup-hermes.sh did not produce a working 'hermes' on PATH -- "$HERMES_LOG_DIR"/hermes-host-setup.log"
  fi
  ok "hermes CLI installed ($(hermes --version 2>/dev/null | head -1))"
  note "its config wizard needs a TTY and is skipped; this repo configures the agent itself"
fi

export PATH="$HOME/.local/bin:$PATH"

# The desktop client. `hermes desktop --build-only` installs workspace node deps
# and builds the packaged Electron app without launching it -- which is what an
# unattended installer wants, and what makes the app available to launch later.
if (( SKIP_DESKTOP )); then
  note "skipping the desktop client (--skip-desktop)"
else
  # "Built" means built FROM THE PINNED REF, not merely present: the build stamp
  # records the commit it was built from.
  STAMP="$ROOT/apps/desktop/build/install-stamp.json"
  BUILT_COMMIT=""
  [[ -f "$STAMP" ]] && BUILT_COMMIT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('commit',''))" "$STAMP" 2>/dev/null || true)"
  WANT_COMMIT=""
  (( ROOT_OWNED )) && WANT_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  if [[ -d "$ROOT/apps/desktop/node_modules" && -d "$ROOT/apps/desktop/dist" ]] \
     && { (( ! ROOT_OWNED )) || [[ -n "$WANT_COMMIT" && "$BUILT_COMMIT" == "$WANT_COMMIT" ]]; }; then
    ok "desktop client already built${BUILT_COMMIT:+ from ${BUILT_COMMIT:0:10}}"
  else
    if [[ -n "$BUILT_COMMIT" && "$BUILT_COMMIT" != "$WANT_COMMIT" ]]; then
      note "the existing build is from ${BUILT_COMMIT:0:10}, not ${WANT_COMMIT:0:10} ($REF) -- rebuilding"
    fi
    # The Electron build needs node/npm, and a fresh machine has neither:
    #   "Desktop GUI requires Node.js/npm, but npm was not found on PATH."
    # Nothing in the chain provides it. On this machine node existed only because
    # Hermes had provisioned one inside a profile months earlier, which is why
    # this was invisible until a genuinely clean user tried it.
    if ! command -v npm >/dev/null 2>&1; then
      NODE_VER="${NODE_VERSION:-v22.23.1}"
      case "$(uname -m)" in
        aarch64|arm64) NODE_ARCH=linux-arm64 ;;
        x86_64)        NODE_ARCH=linux-x64 ;;
        *) die "no Node build for $(uname -m); install Node.js and re-run" ;;
      esac
      echo "==> installing Node.js $NODE_VER ($NODE_ARCH) -- required by the desktop build"
      TARBALL="node-${NODE_VER}-${NODE_ARCH}.tar.xz"
      TMP="$(mktemp -d)"
      # Its own prefix, not merged into ~/.local. Merging spread node's bin,
      # include, lib and share through a directory the user also owns, so the
      # uninstaller had no way to tell our files from theirs and left node
      # behind -- which then made the next install skip this step entirely and
      # stop exercising it.
      NODE_PREFIX="$HOME/.local/lib/hermes-quickstart/node"
      if curl -fsSL "https://nodejs.org/dist/${NODE_VER}/${TARBALL}" -o "$TMP/$TARBALL" \
         && tar -xJf "$TMP/$TARBALL" -C "$TMP"; then
        rm -rf "$NODE_PREFIX"
        install -d "$(dirname "$NODE_PREFIX")" "$HOME/.local/bin"
        mv "$TMP/node-${NODE_VER}-${NODE_ARCH}" "$NODE_PREFIX"
        for b in node npm npx; do
          [[ -e "$NODE_PREFIX/bin/$b" ]] && ln -sfn "$NODE_PREFIX/bin/$b" "$HOME/.local/bin/$b"
        done
        rm -rf "$TMP"
        export PATH="$HOME/.local/bin:$PATH"; hash -r 2>/dev/null || true
      else
        rm -rf "$TMP"
        die "could not install Node.js -- install it yourself and re-run"
      fi
      command -v npm >/dev/null 2>&1 \
        || die "installed Node.js but npm is still not on PATH"
      ok "node $(node --version 2>/dev/null) / npm $(npm --version 2>/dev/null)"
    fi

    echo "==> building the desktop client (Electron; several minutes)"
    # Run from the checkout's own venv, not whatever `hermes` is first on PATH.
    # --force-build because an older build of a different ref can look current.
    if (( ROOT_OWNED )) && [[ -x "$ROOT/venv/bin/python" ]]; then
      ( cd "$ROOT" && venv/bin/python -m hermes_cli.main desktop --build-only --force-build ) \
        >"$HERMES_LOG_DIR"/hermes-desktop-build.log 2>&1 \
        || { tail -25 "$HERMES_LOG_DIR"/hermes-desktop-build.log >&2; die "desktop build failed -- "$HERMES_LOG_DIR"/hermes-desktop-build.log"; }
    else
      hermes desktop --build-only >"$HERMES_LOG_DIR"/hermes-desktop-build.log 2>&1 \
        || { tail -25 "$HERMES_LOG_DIR"/hermes-desktop-build.log >&2; die "desktop build failed -- "$HERMES_LOG_DIR"/hermes-desktop-build.log"; }
    fi
    ok "desktop client built"
  fi

  # After EVERY build, not only the first: a rebuild recreates chrome-sandbox as
  # the user, 0755. Electron aborts at startup when kernel.apparmor_restrict_
  # unprivileged_userns=1 (the Ubuntu default on a Spark) and its SUID helper is
  # not root:root 4755. Needs sudo; the healthcheck flags it if this could not run.
  if CS="$(hermes_chrome_sandbox_path "$ROOT")"; then
    if [[ "$(stat -c '%U:%G %a' "$CS")" == "root:root 4755" ]]; then
      ok "chrome-sandbox already root:root 4755"
    elif hermes_chrome_sandbox_fix "$CS"; then
      ok "chrome-sandbox set root:root 4755 (Electron's SUID sandbox helper)"
    else
      warn "could not set chrome-sandbox root:root 4755 -- the desktop app will not start"
      note "run:  sudo chown root:root '$CS' && sudo chmod 4755 '$CS'"
    fi
  fi
  note "launch it with: hermes desktop"
fi
