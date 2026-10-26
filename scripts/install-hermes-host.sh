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
# Idempotent: if a working `hermes` CLI is already present this exits early.
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

if command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1; then
  ok "hermes already installed ($(hermes --version 2>/dev/null | head -1))"
  note "remove it first if you want a clean install: ./scripts/uninstall-hermes-host.sh"
else
  command -v git >/dev/null 2>&1 || die "git is required"
  if [[ -d "$ROOT/.git" ]]; then
    note "checkout exists, fetching"
    git -C "$ROOT" fetch --quiet origin || die "could not fetch $UPSTREAM"
  else
    mkdir -p "$(dirname "$ROOT")"
    echo "==> cloning Hermes Agent (this is a large repo; several minutes)"
    git clone --quiet "$UPSTREAM" "$ROOT" || die "clone failed: $UPSTREAM"
  fi
  [[ -n "$REF" ]] && { git -C "$ROOT" checkout --quiet "$REF" || die "no such ref: $REF"; note "pinned to $REF"; }
  ok "source at $ROOT ($(git -C "$ROOT" rev-parse --short HEAD))"

  echo "==> running Hermes' own setup (venv + dependencies + CLI symlink)"
  # Its EXIT CODE is deliberately ignored. setup-hermes.sh installs correctly and
  # then runs an OPTIONAL configuration wizard, which detects no TTY under an
  # installer and exits non-zero -- after printing "✓ Setup complete!". Trusting
  # the status code here reported a perfectly good install as a failure.
  # Judge by the outcome instead: is there a working `hermes` on PATH.
  ( cd "$ROOT" && ./setup-hermes.sh </dev/null ) >"$HERMES_LOG_DIR"/hermes-host-setup.log 2>&1 || true
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true

  # setup-hermes.sh prints "✓ Symlinked hermes → ~/.local/bin/hermes" and the
  # symlink is sometimes simply not there afterwards -- observed on a clean user
  # 2026-08-28, where ~/.local/bin held the NemoClaw binaries but no hermes,
  # while $ROOT/hermes existed and ran fine. Rather than chase why someone
  # else's installer lost it, repair the outcome: we know where the real script
  # is. Same rule as everywhere else here -- do not trust the claim, check the
  # result, and fix it if it is wrong.
  if ! command -v hermes >/dev/null 2>&1; then
    if [[ -x "$ROOT/hermes" ]]; then
      install -d "$HOME/.local/bin"
      ln -sfn "$ROOT/hermes" "$HOME/.local/bin/hermes"
      hash -r 2>/dev/null || true
      note "setup did not leave a usable symlink; linked $ROOT/hermes -> ~/.local/bin/hermes"
    fi
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
  if [[ -d "$ROOT/apps/desktop/node_modules" && -d "$ROOT/apps/desktop/dist" ]]; then
    ok "desktop client already built"
  else
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
    hermes desktop --build-only >"$HERMES_LOG_DIR"/hermes-desktop-build.log 2>&1 \
      || { tail -25 "$HERMES_LOG_DIR"/hermes-desktop-build.log >&2; die "desktop build failed -- "$HERMES_LOG_DIR"/hermes-desktop-build.log"; }
    ok "desktop client built"
  fi
  note "launch it with: hermes desktop"
fi
