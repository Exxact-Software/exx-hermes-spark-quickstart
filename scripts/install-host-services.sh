#!/usr/bin/env bash
# Install the host-side services that make the stack survive a reboot.
#
#   ./scripts/install-host-services.sh
#
# These lived in host/README.md as instructions, which meant every install
# depended on somebody reading and following them. They are mechanical, so the
# installer does them.
#
# What does NOT come back on its own after a reboot:
#   * the vLLM container      (docker RestartPolicy=no)
#   * both ssh forwards       (openshell ssh-proxy, orphaned to the user manager)
#   * Hermes INSIDE the sandbox -- the container returns, the agent does not
#   * the desktop session token, which rotates on every dashboard restart
#   * the sandbox itself on NemoClaw 0.0.137: restart policy 'no', and a
#     container killed by the shutdown leaves OpenShell in Phase: Error, which
#     nothing clears. hermes-sandbox-shutdown.service (a SYSTEM unit, needs
#     sudo) stops it cleanly first; hermes-stack-restore starts it at boot.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

install -d "$HOME/.local/bin" "$HOME/.config/systemd/user" \
            "$HOME/.local/lib/hermes-quickstart"
# The installed host scripts source this; without it they fall back to
# self-contained copies, which is the duplication this removes.
install -m644 scripts/lib/common.sh "$HOME/.local/lib/hermes-quickstart/common.sh"
install -m755 host/hermes-stack-restore host/hermes-desktop-token-sync \
               host/hermes-sandbox-stop "$HOME/.local/bin/"
install -m644 host/hermes-stack-restore.service \
              host/hermes-stack-heal.service host/hermes-stack-heal.timer \
              "$HOME/.config/systemd/user/"
ok "installed recovery scripts and units"

# The shutdown hook is the one piece that must be a SYSTEM unit: it has to be
# ordered against docker.service, and user units cannot be. See
# host/hermes-sandbox-shutdown.service for the ordering argument.
SHUTDOWN_UNIT=hermes-sandbox-shutdown.service
_sb="${HERMES_SANDBOX_NAME:-${SANDBOX_NAME:-hermes-demo}}"
_rendered="$(sed -e "s|@USER@|$USER|g" -e "s|@UID@|$(id -u)|g" -e "s|@HOME@|$HOME|g" \
                 -e "s|@SANDBOX@|$_sb|g" -e "s|@AGENT_CLI@|${HERMES_AGENT_CLI:-nemohermes}|g" \
                 "host/$SHUTDOWN_UNIT")"
if printf '%s\n' "$_rendered" | sudo -n tee "/etc/systemd/system/$SHUTDOWN_UNIT" >/dev/null 2>&1 \
   && sudo -n systemctl daemon-reload >/dev/null 2>&1 \
   && sudo -n systemctl enable --now "$SHUTDOWN_UNIT" >/dev/null 2>&1; then
  ok "$SHUTDOWN_UNIT enabled (stops '$_sb' cleanly before Docker at shutdown)"
else
  warn "could not install $SHUTDOWN_UNIT (needs sudo) -- a reboot will leave the sandbox in Phase: Error"
  note "run:  sudo -v && $0"
fi

# Linger is the difference between "the unit is enabled" and "the unit runs".
# Without it user units do not start until the user logs in, so a headless
# reboot comes back with no agent and no obvious reason why.
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == yes ]]; then
  ok "linger already on"
elif loginctl enable-linger "$USER" >/dev/null 2>&1; then
  ok "enabled linger (user services now run without a login)"
else
  warn "could not enable linger -- user units will NOT run at boot"
  note "run:  sudo loginctl enable-linger $USER"
fi

# `systemctl --user` needs the user's own bus, and a login shell is not the only
# way this script runs. Under `sudo -u` -- and on a brand-new account whose user
# manager has never been started -- XDG_RUNTIME_DIR is unset, daemon-reload dies
# with "Failed to connect to bus: No medium found", and every enable below is
# silently skipped. The units land on disk and nothing survives a reboot.
# Linger (above) is what starts that manager, so this has to come after it.
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
[[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] \
  || export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -S "$XDG_RUNTIME_DIR/bus" ]] && break
  sleep 1
done
if [[ ! -S "$XDG_RUNTIME_DIR/bus" ]]; then
  warn "no systemd user bus at $XDG_RUNTIME_DIR/bus -- units installed but NOT enabled"
  note "log in as $USER once, then run:  systemctl --user enable --now hermes-stack-heal.timer"
  exit 1
fi


systemctl --user daemon-reload \
  || warn "systemctl --user daemon-reload failed"
systemctl --user enable hermes-stack-restore.service >/dev/null 2>&1 \
  && ok "hermes-stack-restore.service enabled (heals at boot)" \
  || warn "could not enable hermes-stack-restore.service"
systemctl --user enable --now hermes-stack-heal.timer >/dev/null 2>&1 \
  && ok "hermes-stack-heal.timer enabled (heals every 15 min)" \
  || warn "could not enable hermes-stack-heal.timer"

# Prove the timer is genuinely scheduled. `enable --now` reporting success is
# not the same thing: two separate systemd quirks (RemainAfterExit making start
# a no-op, and OnUnitActiveSec never firing for a oneshot) each produced a timer
# that looked armed and never ran.
# Retried, not sampled once: OnUnitInactiveSec has no reference point until the
# oneshot has gone inactive at least once, so for a second or two after
# `enable --now` the NEXT column is legitimately empty. Reading it immediately
# printed "it will not fire" on a timer that fires fine.
_next=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  # `|| true` is load-bearing: grep returns 1 when NEXT is not populated yet,
  # pipefail propagates it, and a failing assignment under `set -e` exits the
  # script -- which reported the whole step as failed after every check passed.
  _next=$(systemctl --user list-timers hermes-stack-heal.timer --no-pager 2>/dev/null \
            | grep -E '^[A-Z][a-z]{2} ' | head -1) || true
  [[ -n "$_next" ]] && break
  sleep 1
done
if [[ -n "$_next" ]]; then
  ok "timer scheduled: $(awk '{print $1,$2,$3}' <<<"$_next")"
else
  warn "timer is enabled but shows no next run -- it will not fire"
fi
