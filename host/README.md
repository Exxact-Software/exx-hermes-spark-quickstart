# Host-side durability helpers

`install.sh` installs these; to (re)install them by hand:

```bash
./scripts/install-host-services.sh
```

It installs the recovery scripts to `~/.local/bin`, the user units below,
enables linger (user units do not run at boot without it), and — with `sudo` —
the one **system** unit, `hermes-sandbox-shutdown.service`.

## How a reboot is survived (NemoClaw 0.0.137)

NemoClaw does not handle host reboots: its troubleshooting guide treats them as
a manual reconnect, and its gateway user service starts the gateway, not
sandboxes. Two things have to happen:

1. **At shutdown, stop the sandbox cleanly.** If Docker kills the container
   instead (exit 143), OpenShell marks the sandbox `Phase: Error`, which is
   terminal: `start` needs `Stopped`, `stop` needs `Ready`, `recover` skips it,
   and `docker start` runs the container while the phase stays `Error`. The only
   way out is destroying and re-onboarding the sandbox.
   `hermes-sandbox-shutdown.service` is a system unit ordered `After=` both
   `docker.service` and `user@<uid>.service`; stop order is the reverse of start
   order, so its `ExecStop` (`hermes-sandbox-stop`) runs `nemohermes <sb> stop`
   while Docker and the gateway are still up, leaving the sandbox `Stopped`. It
   acts only while the host is shutting down, so `systemctl stop` by hand does
   not stop a live demo.
2. **At boot, start it with the vendor command.** `hermes-stack-restore` sees
   `Stopped` (plus the marker the shutdown hook left) and runs
   `nemohermes <sb> start`, which is NemoClaw's documented path for a stopped
   sandbox. A sandbox someone stopped by hand is left alone. `Error` is
   reported with the recovery command, never papered over.

`hermes-stack-restore.service` is **not** ordered after
`nemoclaw-openshell-gateway.service`: that unit is `After=default.target` and
ours is `WantedBy=default.target`, so the ordering was a cycle and systemd
silently deleted our job at boot. The script waits for the gateway itself.
`healthcheck.sh` fails if the current boot's journal shows a deleted job.

**Both scripts talk to a gateway that is actually listening.** Every `openshell`
call goes to the *active* gateway profile. If that profile points at a port
nothing serves, every call is refused and the phase probe prints nothing. On
2026-10-23 a sandbox-only reinstall had onboarded onto a second gateway
(`nemoclaw-8082`) that lived only as long as the installing session; at the
next shutdown the hook read "no phase" as "nothing to stop" and Docker killed
the sandbox. Now the hook and the restore pin `OPENSHELL_GATEWAY` to the
sandbox's registered gateway, the active one or the default `nemoclaw`,
whichever answers, and an unknown phase is logged as an `ERROR`. The hook still
attempts the stop. The installer keeps a port held by its own gateway instead
of moving off it, `onboard-agent.sh` fails if the active gateway is not the
expected one or is not listening, and `reset.py down` removes stale gateway
profiles and re-selects `nemoclaw`.

The heal timer never restarts a restore that is still running: its
`ExecCondition` skips the run while `hermes-stack-restore.service` is in
SubState `running`. At boot the restore waits minutes for the model, and the
`OnBootSec=2min` heal used to SIGTERM it mid-wait.

The restore is `Type=exec`, not `oneshot`. A target waits for every unit it
`Wants=`, and a oneshot stays `activating` until its script exits, so
`default.target` waited for the restore. The gateway unit is
`After=default.target`, so it could not start until the restore stopped waiting
for it. Recovery then waited 15 minutes for the next heal.

## Why there are two units and a timer for one script

Recovery used to be wired to a single trigger: boot. If the agent died at 2pm it
stayed dead until somebody noticed. The script is idempotent and returns in
milliseconds when the dashboard answers, so running it on a schedule costs
nothing — but wiring that up hit two systemd traps worth knowing:

- **The timer cannot point at `hermes-stack-restore.service`.** That unit needs
  `RemainAfterExit=yes` (see below), which makes `start` a no-op once it is
  active — and a timer issues `start`. Pointed straight at it the timer fires on
  schedule and does **nothing**, reporting success every time. So the timer
  starts `hermes-stack-heal.service`, whose only job is to issue an explicit
  `restart`.
- **`OnUnitActiveSec` never schedules for a oneshot** that goes inactive the
  instant it finishes — `NEXT` stays empty and the timer silently never fires.
  It is `OnUnitInactiveSec`.

Both were caught by checking `systemctl --user list-timers` actually showed a
NEXT time, rather than trusting that `enable --now` meant it was working.

## What does not survive a reboot

| Component | Why |
| --- | --- |
| `hermes-spark-vllm` | docker `RestartPolicy=no` |
| both ssh forwards | `openshell ssh-proxy`, orphaned to the user manager |
| **Hermes inside the sandbox** | the container returns, the agent does not |
| desktop session token | minted in memory, rotates on every dashboard restart |
| `hermes-dash-<sandbox>` proxy | installs made before it was given `--restart unless-stopped`; `hermes-stack-restore` now sets the policy and starts it |
| **the sandbox** (NemoClaw 0.0.137) | docker `RestartPolicy=no`, and nothing in NemoClaw starts it at boot — see above |

## Three things that cost real debugging time

**A listening port is not a working forward.** After a restart `ss` shows
`127.0.0.1:18795` bound while the forward points at a dead ssh session. Probe
the endpoint, never the port. `hermes-stack-restore` judges only by whether the
dashboard actually serves a token.

**`RemainAfterExit=yes` is load-bearing.** Without it systemd tears down the
unit's cgroup when `ExecStart` returns and **kills the forwards it just
created** — the unit reports success and everything is gone 30 seconds later.
Running the same script by hand works, because a login shell is not in that
cgroup. Cost of the flag: re-run with `systemctl --user restart`, not `start`.

**`nemohermes <name> recover` is necessary but not always sufficient.** It
restarts the agent, and may still need the forwards rebuilt afterwards. The
script escalates in that order and fails loudly with the manual command.

## Verified

Rehearsed on a DGX Spark 2026-08-21 by stopping vLLM, killing both forwards and
restarting the sandbox container — **without rebooting the host**. Unattended
recovery took **4m26s**, after which the agent answered, tool calls parsed, the
desktop token was back in sync and the config seal was intact.
