#!/usr/bin/env python3
"""Inventory, diagnose and tear down a Hermes install so it can be redone.

WHY THIS EXISTS
---------------
Demoing the install means running it several times. A run that goes sideways
must cost a minute, not an afternoon, and the box must return to a known state
every time. That needs three things this repo did not have:

  * DETECTION  -- what is actually installed right now, including things that
                  do not appear in `nemohermes list`
  * TEARDOWN   -- remove it, all of it, idempotently
  * DIAGNOSIS  -- name the weird states and print the exact fix

THE THING THAT MAKES DETECTION NON-OBVIOUS
------------------------------------------
`nemohermes list` is not the source of truth. `~/.nemoclaw/sandboxes.json` is,
and it can hold a **pending route reservation** -- an entry left behind by a
FAILED onboard, with no container, no image, and no listing:

    "demo-test": { "pendingRouteReservation": true, ... }

The OpenShell gateway serves ONE inference route shared by every registered
sandbox, and a pending reservation counts. So a failed onboard from eleven days
ago silently blocks every future install that wants a different endpoint, and
nothing surfaces it. That is the state this tool exists to find.

    reset.py status                 # what is installed
    reset.py doctor                 # what is wrong, and the fix for each
    reset.py down --all             # dry run of a full teardown
    reset.py down --all --yes       # do it
    reset.py down --profile <p> --yes
    reset.py snapshot               # record the current state before a demo
    reset.py down --everything      # dry run of a factory reset, residue included
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

NEMO_DIR = Path.home() / ".nemoclaw"
SANDBOXES = NEMO_DIR / "sandboxes.json"
CRED_DIR = Path(os.environ.get("HERMES_CRED_DIR", Path.home() / ".hermes-quickstart"))
SNAP_DIR = NEMO_DIR / "quickstart-snapshots"

C = {
    "b": "\033[1m", "d": "\033[2m", "r": "\033[31m",
    "g": "\033[32m", "y": "\033[33m", "0": "\033[0m",
}


# The tools this script drives install into ~/.local/bin, which only a login
# shell puts on PATH. Run from anything else -- a capture harness, cron, a
# systemd unit -- and every nemohermes/openshell call raised FileNotFoundError,
# was swallowed below, and the teardown reported success having removed nothing.
_LOCAL_BIN = str(Path.home() / ".local" / "bin")
if _LOCAL_BIN not in os.environ.get("PATH", "").split(os.pathsep):
    os.environ["PATH"] = _LOCAL_BIN + os.pathsep + os.environ.get("PATH", "")

# systemctl --user needs the user's own bus, which a non-login shell does not
# advertise; without it every disable below fails quietly.
os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
os.environ.setdefault("DBUS_SESSION_BUS_ADDRESS",
                      f"unix:path={os.environ['XDG_RUNTIME_DIR']}/bus")

# Steps that could not run at all. A teardown that skipped work is not a
# teardown, so this is reported at the end and changes the exit code.
SKIPPED: list[str] = []


def sh(*cmd, check=False) -> str:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if check and p.returncode != 0:
            print(f"{C['r']}  ! {' '.join(cmd)} -> rc={p.returncode}{C['0']}")
            if p.stderr.strip():
                print(f"{C['d']}    {p.stderr.strip()[:200]}{C['0']}")
        return p.stdout.strip()
    except FileNotFoundError:
        SKIPPED.append(cmd[0])
        print(f"{C['r']}  ! {cmd[0]} not found -- step skipped{C['0']}")
        return ""
    except Exception as e:
        SKIPPED.append(cmd[0])
        print(f"{C['r']}  ! {' '.join(cmd[:2])} failed: {e}{C['0']}")
        return ""


# ---------------------------------------------------------------------------
# detection


def load_registry(path: Path = SANDBOXES) -> dict:
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception as e:
        print(f"{C['r']}cannot parse {path}: {e}{C['0']}")
        return {}


def registries() -> list[tuple[Path, int | None]]:
    """Every NemoClaw sandbox registry: the default one, plus one per
    non-default gateway port (~/.nemoclaw/gateways/<port>/sandboxes.json).

    ⚠ NemoClaw scopes its whole home by NEMOCLAW_GATEWAY_PORT. A sandbox
    onboarded on 8082 is invisible in the default registry -- this script used
    to report "none registered" about a live one, and `down --sandbox` skipped
    it as "not registered"."""
    out: list[tuple[Path, int | None]] = [(SANDBOXES, None)]
    for f in sorted((NEMO_DIR / "gateways").glob("*/sandboxes.json")):
        if f.parent.name.isdigit():
            out.append((f, int(f.parent.name)))
    return out


# --- OpenShell gateway profiles --------------------------------------------
# Every `openshell` call goes to the ACTIVE profile unless told otherwise. A
# profile whose endpoint nothing listens on makes every call fail "connection
# refused" -- the 2026-10-23 reboot failure. See scripts/lib/common.sh.
OS_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "openshell"
DEFAULT_GATEWAY = "nemoclaw"


def gateway_profiles() -> dict[str, str]:
    out = {}
    for m in sorted((OS_DIR / "gateways").glob("*/metadata.json")):
        try:
            out[m.parent.name] = json.loads(m.read_text()).get("gateway_endpoint") or ""
        except Exception:
            out[m.parent.name] = ""
    return out


def active_gateway() -> str:
    try:
        return (OS_DIR / "active_gateway").read_text().strip()
    except OSError:
        return ""


def endpoint_listening(endpoint: str) -> bool:
    import socket
    from urllib.parse import urlparse
    u = urlparse(endpoint)
    if not u.hostname or not u.port:
        return False
    try:
        with socket.create_connection((u.hostname, u.port), timeout=2):
            return True
    except OSError:
        return False


def gateway_state() -> dict:
    profs = gateway_profiles()
    return {
        "active": active_gateway(),
        "profiles": {n: {"endpoint": e, "listening": endpoint_listening(e) if e else False}
                     for n, e in profs.items()},
    }


def stale_gateways(gs: dict, inv: dict) -> list[str]:
    """Non-default nemoclaw-<port> profiles that nothing listens on and that no
    sandbox is registered against. Left behind when an install drifted onto a
    second port; they are what an `openshell` call lands on if one is active."""
    used = {i["gateway"] for i in inv["items"]}
    return [n for n, p in gs["profiles"].items()
            if re.fullmatch(r"nemoclaw-\d+", n) and not p["listening"] and n not in used]


def reconcile_gateways(inv: dict, apply: bool) -> None:
    """Remove stale gateway profiles and make the active gateway one that
    answers -- `openshell gateway remove` / `openshell gateway select`, the
    commands NemoClaw's own messages give for this."""
    gs = gateway_state()
    for n in stale_gateways(gs, inv):
        print(f"  stale gateway profile {n} ({gs['profiles'][n]['endpoint']}, not listening)")
        print(f"  openshell gateway remove {n}")
        if apply:
            sh("openshell", "gateway", "remove", n, check=True)
    act = gs["active"]
    act_ok = gs["profiles"].get(act, {}).get("listening", False)
    dflt_ok = gs["profiles"].get(DEFAULT_GATEWAY, {}).get("listening", False)
    if (not act_ok or act in stale_gateways(gs, inv)) and act != DEFAULT_GATEWAY and dflt_ok:
        print(f"  active gateway '{act or '-'}' does not answer; selecting {DEFAULT_GATEWAY}")
        print(f"  openshell gateway select {DEFAULT_GATEWAY}")
        if apply:
            sh("openshell", "gateway", "select", DEFAULT_GATEWAY, check=True)


def docker_rows(fmt: str, *args) -> list[str]:
    out = sh("docker", *args, "--format", fmt)
    return [l for l in out.splitlines() if l.strip()]


def inventory() -> dict:
    reg = load_registry()
    sandboxes = {}
    where: dict[str, tuple[Path, int | None]] = {}
    for path, port in registries():
        for n, s in ((load_registry(path).get("sandboxes") or {}).items()):
            sandboxes[n] = s
            where[n] = (path, port)

    containers = {}
    for line in docker_rows("{{.Names}}\t{{.Status}}", "ps", "-a"):
        name, _, status = line.partition("\t")
        containers[name] = status

    images = {}
    for line in docker_rows("{{.Repository}}:{{.Tag}}\t{{.Size}}", "images"):
        ref, _, size = line.partition("\t")
        images[ref] = size

    items = []
    for name, s in sandboxes.items():
        # Container names are openshell-<profile>--<name>-<uuid>; the profile
        # segment is optional and the uuid is not recorded in sandboxes.json, so
        # match on a pattern rather than a prefix. A plain "openshell-<name>-"
        # prefix matched nothing, and teardown only worked because these then
        # fell through to the orphan sweep.
        cpat = re.compile(rf"^openshell-(.+--)?{re.escape(name)}-[0-9a-f-]{{36}}$")
        ctr = next((c for c in containers if cpat.match(c)), None)
        items.append({
            "name": name,
            "pending": bool(s.get("pendingRouteReservation")),
            "provider": s.get("provider"),
            "model": s.get("model"),
            "endpoint": s.get("endpointUrl"),
            "image": s.get("imageTag"),
            "image_present": bool(s.get("imageTag") in images),
            "image_size": images.get(s.get("imageTag") or "", ""),
            "dashboard_port": s.get("dashboardPort"),
            "container": ctr,
            "container_status": containers.get(ctr) if ctr else None,
            "created": s.get("createdAt"),
            "registry": str(where[name][0]),
            "gateway_port": where[name][1],
            "gateway": s.get("gatewayName") or (
                f"nemoclaw-{where[name][1]}" if where[name][1] else DEFAULT_GATEWAY),
        })

    # Containers belonging to this quickstart that are NOT sandboxes.
    aux = {}
    for c, st in containers.items():
        if re.match(r"^(hermes-.*-vllm|hermes-spark-vllm|hermes-video-vllm)$", c) \
           or re.match(r"^hermes-dash(-|board-proxy)", c):
            aux[c] = st

    orphan_ctrs = [
        c for c in containers
        if c.startswith("openshell-")
        and not any(c == i["container"] for i in items)
    ]
    orphan_imgs = [
        r for r in images
        if r.startswith("nemoclaw-sandbox-local:")
        and not any(i["image"] == r for i in items)
    ]

    return {
        "default": reg.get("defaultSandbox"),
        "items": items, "aux": aux,
        "orphan_containers": orphan_ctrs,
        "orphan_images": orphan_imgs,
        "images": images,
    }


# ---------------------------------------------------------------------------
# status


def cmd_status(inv: dict) -> int:
    srcs = ", ".join(str(p) for p, _ in registries() if p.is_file()) or str(SANDBOXES)
    print(f"{C['b']}registered sandboxes{C['0']}  (source: {srcs})")
    if not inv["items"]:
        print("  none")
    for i in inv["items"]:
        if i["pending"]:
            tag, col = "GHOST", C["r"]
        elif not i["container"]:
            tag, col = "no container", C["y"]
        elif i["container_status"] and i["container_status"].startswith("Up"):
            tag, col = "running", C["g"]
        else:
            tag, col = "stopped", C["y"]
        star = " *" if i["name"] == inv["default"] else "  "
        print(f"{star}{col}{i['name']:<14}{C['0']} {col}{tag:<13}{C['0']} "
              f"{str(i['provider']):<20} {str(i['model'])[:30]:<31} "
              f"{i['endpoint'] or '-'}")
        if i["container"]:
            print(f"    container  {i['container'][:58]}  ({i['container_status']})")
        if i["image"]:
            present = "present" if i["image_present"] else "MISSING"
            print(f"    image      {i['image']}  {i['image_size']} ({present})")
        if i["dashboard_port"]:
            print(f"    dashboard  127.0.0.1:{i['dashboard_port']}")

    gs = gateway_state()
    print(f"\n{C['b']}openshell gateways{C['0']}  (active: {gs['active'] or '-'})")
    if not gs["profiles"]:
        print("  none")
    stale = set(stale_gateways(gs, inv))
    for n, p in gs["profiles"].items():
        col = C["g"] if p["listening"] else C["y"]
        tag = "listening" if p["listening"] else "NOT listening"
        star = " *" if n == gs["active"] else "  "
        extra = "  (stale)" if n in stale else ""
        print(f"{star}{col}{n:<16}{C['0']} {p['endpoint'] or '-':<26} {col}{tag}{C['0']}{extra}")

    print(f"\n{C['b']}supporting containers{C['0']}")
    if not inv["aux"]:
        print("  none")
    for c, st in sorted(inv["aux"].items()):
        col = C["g"] if st.startswith("Up") else C["y"]
        print(f"  {col}{c:<32}{C['0']} {st}")

    if inv["orphan_containers"] or inv["orphan_images"]:
        print(f"\n{C['b']}orphans{C['0']}")
        for c in inv["orphan_containers"]:
            print(f"  {C['y']}container not tied to any registration: {c}{C['0']}")
        for r in inv["orphan_images"]:
            print(f"  {C['y']}image not tied to any registration: {r} "
                  f"({inv['images'][r]}){C['0']}")

    print(f"\n{C['b']}credentials{C['0']}")
    if CRED_DIR.is_dir():
        for f in sorted(CRED_DIR.iterdir()):
            print(f"  {f}  mode {oct(f.stat().st_mode)[-3:]}")
    else:
        print(f"  {CRED_DIR} does not exist")

    print(f"\n{C['b']}install record{C['0']}")
    rec = load_preinstall()
    if rec:
        verdict = ("trusted: taken on an untouched machine" if record_trusted(rec)
                   else f"UNTRUSTED: taken after an install had begun "
                        f"({', '.join(record_evidence(rec)[:3])})")
        print(f"  {PREINSTALL}  (recorded {rec.get('recorded', '?')}; {verdict})")
    else:
        print("  none -- a factory reset keeps shared tools and caches")
    left, unknown = residue_leftovers()
    if left or unknown:
        print(f"\n{C['b']}leftovers from a previous install{C['0']}  "
              f"(NemoClaw is not installed)")
        for x in left:
            print(f"  {C['y']}{x}{C['0']}")
        for x in unknown:
            print(f"  {C['d']}{x}  (cannot attribute; kept){C['0']}")
    return 0


# ---------------------------------------------------------------------------
# doctor


def routes_in_conflict(inv: dict) -> list[dict]:
    """Anything holding a claim on the single shared inference route."""
    return [i for i in inv["items"] if i["pending"] or i["endpoint"] or i["provider"]]


def cmd_doctor(inv: dict) -> int:
    problems = []

    for i in inv["items"]:
        if i["pending"]:
            problems.append((
                "GHOST ROUTE RESERVATION",
                f"'{i['name']}' holds a pending route reservation with no completed "
                f"install. Left by a failed onboard. It blocks every install wanting "
                f"a different endpoint, and does not appear in `nemohermes list`.",
                f"./scripts/reset.py down --sandbox {i['name']} --yes",
            ))
        elif i["container"] and not i["container_status"].startswith("Up"):
            problems.append((
                "STOPPED BUT STILL CLAIMING",
                f"'{i['name']}' container is {i['container_status'].lower()} yet still "
                f"holds the shared inference route -- stopping frees nothing.",
                f"./scripts/reset.py down --sandbox {i['name']} --yes",
            ))
        elif not i["container"]:
            problems.append((
                "REGISTERED WITHOUT A CONTAINER",
                f"'{i['name']}' is registered but has no container.",
                f"./scripts/reset.py down --sandbox {i['name']} --yes",
            ))
        if i["image"] and not i["image_present"]:
            problems.append((
                "IMAGE MISSING",
                f"'{i['name']}' references image {i['image']} which is not present; "
                f"a restart would have to rebuild.",
                "rebuild via install.sh, or tear the sandbox down",
            ))

    endpoints = {
        (i["provider"], i["model"], i["endpoint"])
        for i in inv["items"] if not i["pending"]
    }
    if len(endpoints) > 1:
        problems.append((
            "MULTIPLE ROUTES REGISTERED",
            f"{len(endpoints)} distinct provider/model/endpoint combinations are "
            f"registered, but the gateway serves ONE shared route. Any install that "
            f"does not match the existing one will be refused.",
            "./scripts/reset.py down --all --yes   # then install a single profile",
        ))

    gs = gateway_state()
    act = gs["active"]
    if act and not gs["profiles"].get(act, {}).get("listening", False):
        problems.append((
            "ACTIVE GATEWAY NOT LISTENING",
            f"the active OpenShell gateway '{act}' "
            f"({gs['profiles'].get(act, {}).get('endpoint', '?')}) does not answer. "
            f"Every openshell call -- the shutdown hook, the boot restore, "
            f"`nemohermes status` -- is refused.",
            f"openshell gateway select {DEFAULT_GATEWAY}   # or ./scripts/reset.py down ... --yes",
        ))
    for n in stale_gateways(gs, inv):
        problems.append((
            "STALE GATEWAY PROFILE",
            f"'{n}' ({gs['profiles'][n]['endpoint']}) is registered with OpenShell, "
            f"nothing listens there, and no sandbox uses it.",
            f"openshell gateway remove {n}",
        ))
    unit_port = None
    try:
        m = re.search(r"^OPENSHELL_SERVER_PORT=(\d+)$",
                      (OS_DIR / "gateway.env").read_text(), re.M)
        unit_port = int(m.group(1)) if m else None
    except OSError:
        pass
    for i in inv["items"]:
        if i.get("gateway_port") and i["gateway_port"] != unit_port:
            problems.append((
                "SANDBOX ON A NON-DEFAULT GATEWAY",
                f"'{i['name']}' was onboarded on gateway {i['gateway']}. Only the "
                f"nemoclaw-openshell-gateway user unit comes back at boot; a gateway "
                f"started by an install session dies with that session.",
                f"./scripts/reset.py down --sandbox {i['name']} --yes && ./install.sh --profile <profile>",
            ))

    for c in inv["orphan_containers"]:
        problems.append(("ORPHAN CONTAINER",
                         f"{c} matches no registration.",
                         f"docker rm -f {c}"))
    for r in inv["orphan_images"]:
        problems.append(("ORPHAN IMAGE",
                         f"{r} ({inv['images'][r]}) matches no registration.",
                         f"docker rmi {r}"))

    # Host-side residue. Added 2026-08-24: doctor knew only about containers and
    # the registry, so a machine whose containers were gone but whose desktop
    # config and recovery units still pointed at them reported "no problems"
    # while being in exactly the state that makes a reinstall behave oddly.
    home = Path.home()
    live_sandboxes = {i["name"] for i in inv["items"]}
    conn = home / ".config/Hermes/connection.json"
    if conn.exists() and not live_sandboxes:
        problems.append(("STALE DESKTOP CONFIG",
                         f"{conn} points at a container gateway, but no sandbox is "
                         f"registered. The desktop app will fail to connect.",
                         "./scripts/reset.py down --all --host --yes   # or reinstall"))
    for unit in ("hermes-stack-restore.service", "hermes-stack-heal.timer"):
        installed = (home / ".config/systemd/user" / unit).exists()
        if installed and not live_sandboxes:
            problems.append(("ORPHAN RECOVERY UNIT",
                             f"{unit} is installed but no sandbox is registered; it "
                             f"will keep trying to heal something that is gone.",
                             f"systemctl --user disable --now {unit}"))
    if (Path("/etc/systemd/system") / SHUTDOWN_UNIT).exists() and not live_sandboxes:
        problems.append(("ORPHAN RECOVERY UNIT",
                         f"{SHUTDOWN_UNIT} is installed but no sandbox is registered.",
                         f"sudo systemctl disable --now {SHUTDOWN_UNIT} && "
                         f"sudo rm /etc/systemd/system/{SHUTDOWN_UNIT}"))
    if live_sandboxes and (home / ".config/systemd/user/hermes-stack-heal.timer").exists():
        nxt = sh("systemctl", "--user", "list-timers", "hermes-stack-heal.timer",
                 "--no-pager") or ""
        if not re.search(r"^[A-Z][a-z]{2} ", nxt, re.M):
            problems.append(("HEAL TIMER NOT SCHEDULED",
                             "hermes-stack-heal.timer is installed but shows no next "
                             "run, so it will never fire.",
                             "systemctl --user restart hermes-stack-heal.timer"))

    left, unknown = residue_leftovers()
    if left:
        problems.append(("INSTALL RESIDUE",
                         f"NemoClaw is not installed, but {len(left)} thing(s) an "
                         f"earlier install created are still here, so the next install "
                         f"will not start cold: {', '.join(left[:4])}"
                         + (" ..." if len(left) > 4 else ""),
                         "./scripts/reset.py down --everything   # dry run lists each; "
                         "add --yes"))
    if unknown:
        rec = load_preinstall()
        why = ("there is no install record" if rec is None else
               f"the install record ({rec.get('recorded', '?')}) was taken after an "
               f"install had begun ({', '.join(record_evidence(rec)[:3])})")
        problems.append(("INSTALL RESIDUE THAT CANNOT BE ATTRIBUTED",
                         f"{len(unknown)} shared thing(s) are kept because {why}, so "
                         f"nothing proves the install made them: "
                         f"{', '.join(unknown[:4])}" + (" ..." if len(unknown) > 4 else ""),
                         "if this machine was bare before the first install:  "
                         "./scripts/reset.py down --everything --assume-bare-origin   "
                         "# dry run lists each; add --yes"))

    if not problems:
        print(f"{C['g']}no problems found{C['0']}")
        return 0

    print(f"{C['b']}{len(problems)} problem(s){C['0']}\n")
    for kind, why, fix in problems:
        print(f"{C['y']}{kind}{C['0']}")
        print(f"  {why}")
        print(f"  {C['d']}fix:{C['0']} {fix}\n")
    return 1


# ---------------------------------------------------------------------------
# teardown


def backup_registry() -> Path | None:
    first = None
    stamp = time.strftime('%Y%m%d-%H%M%S')
    for path, port in registries():
        if not path.is_file():
            continue
        SNAP_DIR.mkdir(parents=True, exist_ok=True)
        dest = SNAP_DIR / (f"sandboxes-{stamp}.json" if port is None
                           else f"sandboxes-{port}-{stamp}.json")
        shutil.copy2(path, dest)
        first = first or dest
    return first


def drop_registrations(names: list[str]) -> None:
    """Remove entries from sandboxes.json. This is what releases the shared
    route for ghosts, which have no sandbox for `nemohermes destroy` to act on."""
    for path, _port in registries():
        reg = load_registry(path)
        sandboxes = reg.get("sandboxes", {}) or {}
        changed = [n for n in names if n in sandboxes]
        for n in changed:
            del sandboxes[n]
        if reg.get("defaultSandbox") in names:
            reg["defaultSandbox"] = next(iter(sandboxes), None)
        if changed:
            path.write_text(json.dumps(reg, indent=2) + "\n")
            os.chmod(path, 0o600)
            print(f"  released route registration(s): {', '.join(changed)}  ({path})")


def cmd_host_teardown(apply: bool, drop_images: bool, everything: bool = False) -> int:
    """Remove the HOST-side half of an install.

    reset.py originally knew only about containers, images and the sandbox
    registry, because that was all an install created. Since 2026-08-24 the
    installer also writes host state -- the desktop app's connection.json,
    recovery scripts in ~/.local/bin, systemd user units and a timer, and a
    locally-built vLLM image. A teardown that leaves those behind is not a
    teardown: the next install inherits a stale desktop token and units
    pointing at a sandbox that no longer exists, which is exactly the kind of
    residue that makes a second take behave differently from the first.

    Deliberately NOT removed here:
      * model weights -- tens of GB and a long re-download; orthogonal to a
        reinstall, and `fetch-model.py check` already verifies them. Only
        `--everything` removes them (see cmd_factory_residue), and
        `--keep-models` opts out of that.
      * the /etc/hosts entry for host.openshell.internal -- needs root, and is
        correct to keep: it is a fact about this machine, not about an install.
      * the Hermes HOST install -- not ours to remove.
    """
    home = Path.home()
    units = ["hermes-stack-heal.timer", "hermes-stack-heal.service",
             "hermes-stack-restore.service"]
    print(f"{C['b']}host-side{C['0']}")

    for u in units:
        print(f"  systemctl --user disable --now {u}")
        if apply:
            sh("systemctl", "--user", "disable", "--now", u)
            (home / ".config/systemd/user" / u).unlink(missing_ok=True)
    if apply:
        sh("systemctl", "--user", "daemon-reload")

    # The shutdown hook is a SYSTEM unit (it must be ordered against
    # docker.service), so it needs sudo. `disable --now` is safe: its ExecStop
    # only acts while the host is actually shutting down.
    sysunit = Path("/etc/systemd/system") / SHUTDOWN_UNIT
    if sysunit.exists():
        print(f"  sudo systemctl disable --now {SHUTDOWN_UNIT}; sudo rm {sysunit}")
        if apply:
            sh("sudo", "-n", "systemctl", "disable", "--now", SHUTDOWN_UNIT)
            sh("sudo", "-n", "rm", "-f", str(sysunit))
            sh("sudo", "-n", "systemctl", "daemon-reload")
            if sysunit.exists():
                print(f"  {C['y']}could not remove {sysunit} (sudo needed): "
                      f"sudo systemctl disable --now {SHUTDOWN_UNIT} && sudo rm {sysunit}{C['0']}")

    for f in ["hermes-stack-restore", "hermes-desktop-token-sync", "hermes-sandbox-stop"]:
        t = home / ".local/bin" / f
        if t.exists():
            print(f"  rm {t}")
            if apply:
                t.unlink()

    # install-host-services.sh ships common.sh here for the recovery scripts to
    # source. Removing the scripts but not their library left the directory
    # behind on a "factory reset".
    lib = home / ".local/lib/hermes-quickstart"
    if lib.is_dir():
        print(f"  rm -r {lib}")
        if apply:
            shutil.rmtree(lib, ignore_errors=True)

    conn_dir = home / ".config/Hermes"
    if conn_dir.is_dir():
        for f in sorted(conn_dir.glob("connection.json*")):
            print(f"  rm {f}")
            if apply:
                f.unlink()

    # Forwards are per-sandbox ssh processes; stopping them is idempotent.
    for port in ("18795", "8642"):
        print(f"  openshell forward stop {port} (if present)")
        if apply:
            for name in ("hermes-demo",):
                sh("openshell", "forward", "stop", port, name)

    if drop_images:
        out = sh("docker", "images", "--format", "{{.Repository}}:{{.Tag}}") or ""
        for ref in [r for r in out.splitlines() if r.startswith("exx-vllm-spark:")]:
            print(f"  docker rmi {ref}")
            if apply:
                sh("docker", "rmi", ref)
    else:
        print(f"{C['d']}  locally-built images kept; pass --drop-images to remove{C['0']}")

    if not everything:
        print(f"{C['d']}  model weights kept (tens of GB); --everything removes "
              f"them, or delete MODEL_DIR by hand{C['0']}")

    # Exit non-zero when steps were skipped. A run that could not find
    # nemohermes printed a couple of warnings, left the CLIs and the sandbox in
    # place, and still exited 0 -- so a scripted teardown-then-reinstall looked
    # like it had worked.
    if apply and SKIPPED:
        missing = ", ".join(sorted(set(SKIPPED)))
        print(f"\n{C['r']}  teardown INCOMPLETE -- could not run: {missing}{C['0']}")
        print(f"{C['d']}  these live in ~/.local/bin; add it to PATH and re-run{C['0']}")
        return 1
    return 0


# ---------------------------------------------------------------------------
# factory-reset residue (--everything)
#
# A cold install with NemoClaw 0.0.137 on a fresh machine, followed by
# `down --everything --yes`, still left behind: the images the install pulled
# or built, the model weights and caches, nvm/npm and the lines they append to
# ~/.bashrc, OpenShell's config and gateway user unit, a NemoClaw shim, and a
# root-owned ~/flashinfer-cache. The next "fresh" install then started warm,
# which is exactly what a factory reset exists to prevent.
#
# THE RULE: remove only what the install created. Some of these are
# unambiguous (a NemoClaw-marked unit, this repo's model dirs). Others -- ~/.nvm,
# ~/.npm, the Hugging Face cache, generic base images, the Docker build cache --
# are just as likely to be the user's own. For those, install.sh records what
# already existed before it ran (`reset.py record-preinstall`), and anything that
# predates the install is kept.
#
# ⚠ A RECORD IS ONLY EVIDENCE WHILE IT WAS TAKEN ON A MACHINE THE INSTALL HAD NOT
# TOUCHED. Until 2026-10-25 it was "written once, never refreshed", so a record
# taken while an earlier install was already half in place (or after a reset
# that left residue behind) listed that install's own ~/.nvm, ~/.npm, OpenShell
# config and model as "existed before the install". Reset then kept all of it,
# `doctor` said "re-run reset", and the re-run kept it again. So a record now
# carries its own verdict (`bare`, plus the `evidence` of an install it found),
# and a record taken on a machine that already showed install evidence is
# UNTRUSTED:
#   * things only the installer creates (OpenShell config and state, the
#     flashinfer cache) are removed -- no record can make them the user's;
#   * shared things (nvm, npm, the HF cache, weights, generic images, the build
#     cache) are kept, because nothing proves who made them, and doctor says so,
#     with the one flag that settles it: --assume-bare-origin ("this machine was
#     bare before the first install").
# A trusted record still wins over that flag: what it says pre-existed is kept.

STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) \
    / "hermes-quickstart"
PREINSTALL = STATE_DIR / "preinstall.json"
REPO = Path(__file__).resolve().parent.parent
HF_CACHE = Path(os.environ.get("HF_HOME", Path.home() / ".cache/huggingface"))
GATEWAY_UNIT = "nemoclaw-openshell-gateway.service"
SHUTDOWN_UNIT = "hermes-sandbox-shutdown.service"
GATEWAY_MARKER = "NEMOCLAW_MANAGED_OPENSHELL_GATEWAY=1"

# Paths whose prior existence is recorded before an install.
TRACKED = {
    "nvm": ".nvm", "npm": ".npm", "npm-global": ".npm-global",
    "openshell-config": ".config/openshell", "openshell-state": ".local/state/openshell",
    "flashinfer-cache": "flashinfer-cache", "models": "models",
}
RC_FILES = (".bashrc", ".zshrc", ".profile")
# Created only by this stack's installer, so finding one is proof an install
# has already begun, and no record can make it "the user's".
INSTALLER_ONLY = ("openshell-config", "openshell-state", "flashinfer-cache")
RECORD_SCHEMA = 2

# Exactly what the installers append, and nothing else. Anchored at a line
# start, consuming at most one preceding blank line, so the neighbouring lines
# are never joined or touched.
_LS = r"(?:(?<=\n)|\A)\n?"
NEMOCLAW_RC_BLOCKS = [
    # NemoClaw's install.sh: ensure ~/.local/bin is on PATH.
    ("NemoClaw PATH setup", re.compile(
        _LS + r"# NemoClaw PATH setup\n"
        r"(?:(?:export PATH=|fish_add_path |setenv PATH )[^\n]*\n){1,2}"
        r"# end NemoClaw PATH setup\n")),
    # NemoClaw's install.sh, when the npm global prefix is not writable.
    ("NemoClaw npm-global PATH", re.compile(
        _LS + r"# Added by NemoClaw installer\n"
        r'export PATH="\$HOME/\.npm-global/bin:\$PATH"\n')),
]
# nvm's install.sh (run by NemoClaw's installer when node is missing).
NVM_RC_BLOCK = ("nvm loader", re.compile(
    _LS + r'export NVM_DIR="\$HOME/\.nvm"\n'
    r'\[ -s "\$NVM_DIR/nvm\.sh" \] && \\\. "\$NVM_DIR/nvm\.sh"  # This loads nvm\n'
    r'(?:\[ -s "\$NVM_DIR/bash_completion" \] && \\\. "\$NVM_DIR/bash_completion"'
    r"  # This loads nvm bash_completion\n)?"))

# Images. OURS are named for this stack and removed outright (exx-vllm-spark is
# handled by --drop-images, sandbox images by the per-sandbox teardown).
# GENERIC are public images a user may well have for their own reasons, so they
# go only if the install record shows they arrived with the install.
IMAGES_OURS = (r"^ghcr\.io/nvidia/nemoclaw/", r"^ghcr\.io/nvidia/openshell")
IMAGES_GENERIC = (r"^nvcr\.io/nvidia/vllm:", r"^nginx:alpine$", r"^alpine:3$",
                  r"^node:22-trixie")


def strip_rc_blocks(text: str, blocks) -> tuple[str, list[tuple[str, str]]]:
    """Remove each exact installer block. Returns (new text, [(label, matched)])."""
    found = []
    for label, pat in blocks:
        for m in pat.finditer(text):
            found.append((label, m.group(0)))
        text = pat.sub("", text)
    return text, found


def profile_model_dirs() -> list[Path]:
    """MODEL_DIR of every shipped profile -- the weights this repo downloads."""
    home = Path.home()
    out = []
    for conf in sorted((REPO / "profiles").glob("*.conf")):
        m = re.search(r"^MODEL_DIR=(.*)$", conf.read_text(), re.M)
        if not m:
            continue
        v = m.group(1).strip().strip('"')
        if v.startswith("$HOME/"):
            v = str(home / v[len("$HOME/"):])
        p = Path(v)
        # Never a bare top-level or home-level directory, whatever a profile says.
        if p.is_absolute() and len(p.parts) >= 3 and p not in (home, home / "models") \
           and p not in out:
            out.append(p)
    return out


def docker_images_full() -> list[tuple[str, str]]:
    """[(repo:tag, image id)]"""
    rows = docker_rows("{{.Repository}}:{{.Tag}}\t{{.ID}}", "images")
    return [tuple(r.split("\t", 1)) for r in rows if "\t" in r]


def _image_ids_or_none() -> list[str] | None:
    try:
        p = subprocess.run(["docker", "images", "-q", "--no-trunc"],
                           capture_output=True, text=True, timeout=60)
    except Exception:
        return None
    if p.returncode != 0:
        return None
    ids = {l.strip() for l in p.stdout.splitlines() if l.strip()}
    return sorted(ids | {i.split(":", 1)[-1][:12] for i in ids})


def build_cache() -> tuple[int | None, str]:
    """(number of build-cache records, their total size) from `docker system df`;
    (None, "") when docker could not be asked."""
    try:
        p = subprocess.run(["docker", "system", "df", "--format",
                            "{{.Type}}\t{{.TotalCount}}\t{{.Size}}"],
                           capture_output=True, text=True, timeout=60)
    except Exception:
        return None, ""
    if p.returncode != 0:
        return None, ""
    for line in p.stdout.splitlines():
        typ, _, rest = line.partition("\t")
        if typ.strip() == "Build Cache":
            n, _, size = rest.partition("\t")
            try:
                return int(n), size.strip()
            except ValueError:
                return None, ""
    return 0, "0B"


def live_install_evidence() -> list[str]:
    """Proof, on THIS machine now, that an install has already begun."""
    home = Path.home()
    ev = [f"~/{TRACKED[k]}" for k in INSTALLER_ONLY if (home / TRACKED[k]).exists()]
    if shutil.which("nemohermes"):
        ev.append("nemohermes on PATH")
    if NEMO_DIR.exists():
        ev.append("~/.nemoclaw")
    for f in RC_FILES:
        p = home / f
        if p.is_file():
            _, found = strip_rc_blocks(p.read_text(errors="replace"), NEMOCLAW_RC_BLOCKS)
            ev += [f"~/{f}: {label}" for label in sorted({l for l, _ in found})]
    try:
        out = subprocess.run(["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"],
                             capture_output=True, text=True, timeout=60).stdout
    except Exception:
        out = ""
    ev += [f"image {r}" for r in out.splitlines()
           if any(re.search(x, r) for x in IMAGES_OURS) or r.startswith("exx-vllm-spark:")]
    return ev


def record_evidence(rec: dict) -> list[str]:
    """The install evidence a record was taken in the presence of. Records from
    before RECORD_SCHEMA did not say, so it is rebuilt from what they hold."""
    if rec.get("schema", 1) >= 2:
        return list(rec.get("evidence") or [])
    ev = [f"~/{TRACKED[k]}" for k in INSTALLER_ONLY if rec.get("paths", {}).get(k)]
    for f, labels in (rec.get("rc_blocks") or {}).items():
        ev += [f"~/{f}: {l}" for l in labels if l.startswith("NemoClaw")]
    return ev


def record_trusted(rec: dict | None) -> bool | None:
    """True: taken on an untouched machine. False: taken after an install had
    begun. None: there is no record."""
    return None if rec is None else not record_evidence(rec)


def still_claimed(rec: dict) -> list[str]:
    """Shared things an (untrusted) record says existed first, and that are still
    here. A fresh record taken while they remain would call them pre-existing for
    good -- the circularity this exists to break -- so the old record stays until
    they are gone (or a reset with --assume-bare-origin removes them)."""
    home = Path.home()
    out = [f"~/{TRACKED[k]}" for k in TRACKED
           if k not in INSTALLER_ONLY and rec.get("paths", {}).get(k)
           and (home / TRACKED[k]).exists()]
    if rec.get("hf_cache", {}).get("existed") and HF_CACHE.exists():
        out.append(str(HF_CACHE))
    out += [d for d, e in (rec.get("model_dirs") or {}).items() if e and Path(d).exists()]
    return out


def preinstall_snapshot() -> dict:
    home = Path.home()
    evidence = live_install_evidence()
    records, size = build_cache()
    rc = {}
    for f in RC_FILES:
        p = home / f
        if p.is_file():
            _, found = strip_rc_blocks(p.read_text(errors="replace"),
                                       NEMOCLAW_RC_BLOCKS + [NVM_RC_BLOCK])
            rc[f] = sorted({label for label, _ in found})
    return {
        "schema": RECORD_SCHEMA,
        "recorded": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
        # The record's own verdict: was this machine untouched when it was taken?
        "bare": not evidence,
        "evidence": evidence,
        "build_cache": {"records": records, "size": size},
        "paths": {k: (home / v).exists() for k, v in TRACKED.items()},
        "hf_cache": {"path": str(HF_CACHE), "existed": HF_CACHE.exists()},
        "model_dirs": {str(d): d.exists() for d in profile_model_dirs()},
        "rc_blocks": rc,
        # None, not [], when docker could not be asked: an empty list would make
        # every generic image look like it arrived with the install.
        "image_ids": _image_ids_or_none(),
    }


def load_preinstall() -> dict | None:
    try:
        return json.loads(PREINSTALL.read_text())
    except Exception:
        return None


def cmd_record_preinstall() -> int:
    """Called by install.sh before it changes anything.

    A trusted record is never overwritten: on a re-install over an existing
    install, the FIRST record is the one that knows what the machine had before
    any of this arrived. An UNTRUSTED one (taken after an install had begun) is
    replaced as soon as the machine is bare again -- keeping it would make the
    next install's own files look like the user's, which is the bug this fixes.
    """
    rec = load_preinstall()
    if rec is not None and record_trusted(rec):
        print(f"install record kept: {PREINSTALL}")
        return 0
    snap = preinstall_snapshot()
    if rec is not None and (not snap["bare"] or still_claimed(rec)):
        print(f"install record kept: {PREINSTALL} (untrusted: taken after an install "
              f"had begun, and this machine is not bare, so it cannot be replaced)")
        return 0
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    PREINSTALL.write_text(json.dumps(snap, indent=2) + "\n")
    if snap["bare"]:
        print(f"install record -> {PREINSTALL}")
    else:
        print(f"install record -> {PREINSTALL} (UNTRUSTED: an install had already "
              f"begun: {', '.join(snap['evidence'][:3])}; a factory reset will keep "
              f"shared tools unless told --assume-bare-origin)")
    return 0


def plan_residue(keep_models: bool, assume_bare: bool = False) -> list[dict]:
    """Everything --everything would remove beyond the sandboxes, host units and
    CLIs, plus everything it deliberately keeps, each with a reason.

    Every shared item gets one of three verdicts from origin():
      pre      the install record proves it existed first -> kept
      ours     the install created it                      -> removed
      unknown  nothing proves who made it                  -> kept, and said so
    """
    home = Path.home()
    rec = load_preinstall()
    trusted = record_trusted(rec)      # True / False / None (no record)
    plan: list[dict] = []

    def keep(target, why):
        plan.append({"op": "keep", "target": str(target), "why": why})

    UNTRUSTED = ("the install record was taken after an install had begun, so it "
                 "cannot say who made this; --assume-bare-origin if this machine "
                 "was bare before the first install")
    NO_RECORD = "no install record, so it may be yours; remove by hand if not"

    def origin(existed_before: bool, installer_only: bool = False) -> tuple[str, str]:
        """(pre|ours|unknown, why-if-kept)."""
        if rec is not None and not existed_before:
            # "It was not there" stays true whatever the record's age; only a
            # claim that it WAS there can be an install's own doing.
            return "ours", ""
        if trusted:
            return "pre", "existed before the install"
        if installer_only:
            return "ours", ""          # no record can make these the user's
        if assume_bare:
            return "ours", ""
        return "unknown", (UNTRUSTED if trusted is False else NO_RECORD)

    def verdict(item, existed_before, installer_only, target, extra_ok=True):
        o, why = origin(existed_before, installer_only)
        if o == "ours":
            return True
        keep(target, why)
        if o == "unknown":
            plan[-1]["unknown"] = True
        return False

    def existed(key: str) -> bool:
        return bool((rec or {}).get("paths", {}).get(key, False))

    def path_item(key: str):
        p = home / TRACKED[key]
        if not (p.exists() or p.is_symlink()):
            return
        if verdict(key, existed(key), key in INSTALLER_ONLY, p):
            plan.append({"op": "rm", "target": str(p)})

    # NemoClaw / OpenShell leftovers.
    shim = home / ".local/bin/nemoclaw-acp"
    if shim.exists() or shim.is_symlink():
        plan.append({"op": "rm", "target": str(shim)})
    unit = home / ".config/systemd/user" / GATEWAY_UNIT
    if unit.is_file():
        if GATEWAY_MARKER in unit.read_text(errors="replace"):
            plan.append({"op": "unit", "target": str(unit)})
        else:
            keep(unit, f"not marked {GATEWAY_MARKER}")
    path_item("openshell-config")
    path_item("openshell-state")

    # This repo's own caches and weights.
    path_item("flashinfer-cache")
    mrec = (rec or {}).get("model_dirs", {})
    for d in profile_model_dirs():
        if not d.exists():
            continue
        if keep_models:
            keep(d, "--keep-models")
        elif verdict("model", bool(mrec.get(str(d))), False, d):
            plan.append({"op": "rm", "target": str(d)})
    models = home / "models"
    if models.is_dir() and not keep_models and (
            (rec is not None and not existed("models")) or assume_bare):
        plan.append({"op": "rmdir", "target": str(models)})

    # Shared tools and caches.
    path_item("nvm")
    path_item("npm")
    path_item("npm-global")
    if HF_CACHE.exists():
        hrec = (rec or {}).get("hf_cache", {})
        if keep_models:
            keep(HF_CACHE, "--keep-models")
        elif verdict("hf", bool(hrec.get("existed", True)), False, HF_CACHE):
            plan.append({"op": "rm", "target": str(HF_CACHE)})

    # Shell rc blocks.
    nvm_ours = home.joinpath(TRACKED["nvm"]).exists() and \
        origin(existed("nvm"))[0] == "ours"
    for f in RC_FILES:
        p = home / f
        if not p.is_file():
            continue
        text = p.read_text(errors="replace")
        pre = set((rec or {}).get("rc_blocks", {}).get(f, [])) if trusted else set()
        blocks = [b for b in NEMOCLAW_RC_BLOCKS if b[0] not in pre]
        if nvm_ours and NVM_RC_BLOCK[0] not in pre:
            blocks.append(NVM_RC_BLOCK)
        elif NVM_RC_BLOCK[1].search(text):
            keep(f"{p} ({NVM_RC_BLOCK[0]})",
                 "~/.nvm is kept, so its loader is too" if (home / ".nvm").exists()
                 else "no install record says the install added it")
        _, found = strip_rc_blocks(text, blocks)
        if found:
            plan.append({"op": "rc", "target": str(p), "blocks": found,
                         "labels": [b[0] for b in blocks]})

    # Images. Removed last: the root-owned-file fallback above uses alpine:3.
    pre_ids = (rec or {}).get("image_ids")
    for ref, iid in docker_images_full():
        target = iid if ref.endswith(":<none>") else ref
        if any(re.search(p, ref) for p in IMAGES_OURS):
            plan.append({"op": "rmi", "target": target, "ref": ref})
        elif any(re.search(p, ref) for p in IMAGES_GENERIC):
            if pre_ids is None and trusted:
                keep(f"image {ref}", "no record of the images present before the "
                                     "install, so it may be yours")
            elif verdict("image", iid in (pre_ids or []), False, f"image {ref}"):
                plan.append({"op": "rmi", "target": target, "ref": ref})

    # The Docker build cache. `docker build` of exx-vllm-spark fills it (33 GB on
    # a full install) and --drop-images does not touch it, so the next "cold"
    # build is served from it in under a second. Pruned whole, so it goes only if
    # the record shows there was none before: a user's own build cache is not
    # ours to drop.
    n, size = build_cache()
    if n:
        bc = (rec or {}).get("build_cache", {}).get("records")
        if verdict("build-cache", bool(bc) if bc is not None else True, False,
                   f"docker build cache ({size})"):
            plan.append({"op": "buildcache", "target": f"docker build cache ({size})"})
    return plan


def residue_leftovers(assume_bare: bool = False) -> tuple[list[str], list[str]]:
    """(what --everything would still remove, what it cannot attribute and so
    keeps). Only once NemoClaw itself is gone -- on a live install the same
    paths are the install, not residue."""
    if shutil.which("nemohermes") or NEMO_DIR.exists():
        return [], []
    ours, unknown = [], []
    for a in plan_residue(keep_models=False, assume_bare=assume_bare):
        if a["op"] == "rc":
            ours.append(f"{a['target']} ({', '.join(l for l, _ in a['blocks'])})")
        elif a["op"] == "keep":
            if a.get("unknown"):
                unknown.append(a["target"])
        else:
            ours.append(a.get("ref", a["target"]))
    return ours, unknown


def _rm_path(p: Path) -> None:
    if p.is_symlink() or p.is_file():
        p.unlink(missing_ok=True)
        return
    shutil.rmtree(p, ignore_errors=True)
    if not p.exists():
        return
    # Files written by a root container (vLLM's flashinfer cache, NemoClaw's
    # vLLM in the HF cache) cannot be deleted by this user. Same remedy as the
    # HF ownership repair in install-nemoclaw.sh: docker, which is already a
    # prerequisite, rather than sudo.
    print(f"{C['d']}    root-owned files remain; removing them via a throwaway "
          f"container{C['0']}")
    sh("docker", "run", "--rm", "-v", f"{p}:/x", "alpine:3",
       "find", "/x", "-mindepth", "1", "-delete", check=True)
    try:
        p.rmdir()
    except OSError as e:
        print(f"{C['r']}  ! could not remove {p}: {e}{C['0']}")


def cmd_factory_residue(apply: bool, keep_models: bool, assume_bare: bool = False) -> int:
    plan = plan_residue(keep_models, assume_bare)
    print(f"{C['b']}install residue{C['0']}")
    if not plan:
        print("  none found")
    for a in plan:
        op, t = a["op"], a["target"]
        if op == "keep":
            print(f"{C['d']}  keep {t} -- {a['why']}{C['0']}")
        elif op == "rm":
            p = Path(t)
            print(f"  rm -r {t}" if p.is_dir() and not p.is_symlink() else f"  rm {t}")
            if apply:
                _rm_path(p)
        elif op == "rmdir":
            print(f"  rmdir {t}  (only if empty)")
            if apply:
                try:
                    Path(t).rmdir()
                except OSError:
                    print(f"{C['d']}    not empty -- kept{C['0']}")
        elif op == "unit":
            u = Path(t)
            print(f"  systemctl --user disable --now {u.name}; rm {u}")
            if apply:
                sh("systemctl", "--user", "disable", "--now", u.name)
                u.unlink(missing_ok=True)
                # disable needs the user bus; a dangling wants-link otherwise
                # survives and systemd logs a missing unit on every boot.
                for w in u.parent.glob(f"*.wants/{u.name}"):
                    w.unlink(missing_ok=True)
                sh("systemctl", "--user", "daemon-reload")
        elif op == "rc":
            p = Path(t)
            for label, text in a["blocks"]:
                print(f"  edit {t}: remove '{label}' block:")
                for line in text.strip("\n").splitlines():
                    print(f"{C['d']}      - {line}{C['0']}")
            if apply:
                bak = p.with_name(f"{p.name}.hermes-quickstart-{time.strftime('%Y%m%d-%H%M%S')}.bak")
                shutil.copy2(p, bak)
                blocks = [b for b in NEMOCLAW_RC_BLOCKS + [NVM_RC_BLOCK]
                          if b[0] in a["labels"]]
                new, _ = strip_rc_blocks(p.read_text(errors="replace"), blocks)
                p.write_text(new)
                print(f"{C['d']}    backup -> {bak}{C['0']}")
        elif op == "rmi":
            print(f"  docker rmi {a['ref']}" + (f"  ({t})" if t != a["ref"] else ""))
            if apply:
                sh("docker", "rmi", t, check=True)
        elif op == "buildcache":
            print(f"  docker builder prune --all --force  ({t})")
            if apply:
                sh("docker", "builder", "prune", "--all", "--force", check=True)

    n_unknown = sum(1 for a in plan if a.get("unknown"))
    if n_unknown:
        print(f"{C['y']}  {n_unknown} item(s) kept because nothing proves the install made "
              f"them. If this machine was bare before the first install, run again "
              f"with --assume-bare-origin.{C['0']}")
    if PREINSTALL.is_file() and n_unknown:
        # Deleting it would let the next install record the kept items as
        # "existed before", for good. It stays until they are removed.
        print(f"{C['d']}  keep {PREINSTALL} -- items above are still unattributed{C['0']}")
    elif PREINSTALL.is_file():
        # Removed with everything else, so the next install records afresh.
        print(f"  rm {PREINSTALL}  (install record)")
        if apply:
            PREINSTALL.unlink(missing_ok=True)
    else:
        print(f"{C['d']}  no install record ({PREINSTALL}): shared tools and caches "
              f"are kept{C['0']}")
    return 0


def cmd_down(inv: dict, targets: list[str], apply: bool, keep_creds: bool) -> int:
    # No targets is NOT nothing to do. --everything uninstalls NemoClaw first,
    # which deletes the sandbox registry, so by the time we get here there are no
    # sandboxes to select -- and returning early skipped the aux cleanup below,
    # leaving the vLLM server and the dashboard proxy running and still holding
    # ports 8000 and 18796 after a "factory reset". Only the per-sandbox loop
    # needs a selection; supporting containers are found from docker directly.
    if not targets:
        if not (inv["aux"] or inv["orphan_containers"]):
            print("nothing selected")
            return 0
        print(f"{C['d']}  no registered sandboxes; cleaning up supporting "
              f"containers{C['0']}")

    sel = [i for i in inv["items"] if i["name"] in targets]
    unknown = [t for t in targets if not any(i["name"] == t for t in [] ) and
               not any(i["name"] == t for i in inv["items"])]
    for u in unknown:
        print(f"{C['y']}  '{u}' is not registered — skipping{C['0']}")

    verb = "" if apply else "[dry run] "
    print(f"{C['b']}{verb}tearing down: {', '.join(i['name'] for i in sel)}{C['0']}\n")

    for i in sel:
        print(f"{C['b']}{i['name']}{C['0']}")
        if i["pending"]:
            print("  ghost — no sandbox to destroy; only the registration exists")
        else:
            port = i.get("gateway_port")
            envp = f"NEMOCLAW_GATEWAY_PORT={port} " if port else ""
            print(f"  {envp}nemohermes {i['name']} destroy --yes")
            if apply:
                if port:
                    os.environ["NEMOCLAW_GATEWAY_PORT"] = str(port)
                try:
                    sh("nemohermes", i["name"], "destroy", "--yes", check=True)
                finally:
                    os.environ.pop("NEMOCLAW_GATEWAY_PORT", None)
        if i["container"]:
            print(f"  docker rm -f {i['container'][:52]}")
            if apply:
                sh("docker", "rm", "-f", i["container"])
        if i["image"] and i["image_present"]:
            print(f"  docker rmi {i['image']}")
            if apply:
                sh("docker", "rmi", i["image"])

    # Supporting containers: vLLM servers and dashboard proxies.
    for c in sorted(inv["aux"]):
        print(f"{C['b']}{c}{C['0']}\n  docker rm -f {c}")
        if apply:
            sh("docker", "rm", "-f", c)

    for c in inv["orphan_containers"]:
        print(f"{C['b']}orphan {c}{C['0']}\n  docker rm -f {c}")
        if apply:
            sh("docker", "rm", "-f", c)
    for r in inv["orphan_images"]:
        print(f"{C['b']}orphan {r}{C['0']}\n  docker rmi {r}")
        if apply:
            sh("docker", "rmi", r)

    if apply:
        b = backup_registry()
        if b:
            print(f"\n  registry backed up -> {b}")
        drop_registrations([i["name"] for i in sel])

    # The gateway profile outlives the sandbox. Left pointing at a port nothing
    # serves, the NEXT install and every openshell call inherit it.
    print(f"\n{C['b']}openshell gateways{C['0']}")
    reconcile_gateways(inventory() if apply else
                       {"items": [i for i in inv["items"] if i not in sel]}, apply)

    if not keep_creds and CRED_DIR.is_dir():
        # The password is regenerated on the next install, so keeping it across
        # takes is usually what you want -- hence this is opt-in, not default.
        print(f"\n{C['d']}credentials left in place ({CRED_DIR}); "
              f"pass --wipe-creds to remove{C['0']}")

    if not apply:
        print(f"\n{C['y']}dry run — nothing was changed. Add --yes to act.{C['0']}")
    else:
        print(f"\n{C['g']}teardown complete.{C['0']} Verify with: ./scripts/reset.py status")
    return 0


def profile_route(path: Path) -> tuple[str, str]:
    """The (model, validation-endpoint) a profile will ask the gateway for.

    Compared on model + endpoint URL rather than on `provider`, because the
    provider string the registry records ("compatible-endpoint") is not the one
    onboard is given ("custom") -- comparing those would report a conflict
    against an install that actually matches.
    """
    text = path.read_text()
    def get(k, default=""):
        m = re.search(rf"^{k}=(.*)$", text, re.M)
        return m.group(1).strip() if m else default
    model = get("SERVED_MODEL_NAME")
    if get("INFERENCE_MODE") == "remote":
        return model, get("REMOTE_ENDPOINT_URL")
    # MUST match what onboard-agent.sh actually registers, or this pre-check
    # reports a conflict against an install that is identical to what is being
    # asked for. Since 2026-08-21 that is the HOSTNAME form: the host is taught
    # to resolve host.openshell.internal so one URL validates on the host and
    # also matches the sandbox egress policy, which removed the post-seal
    # `hermes config set` that used to break the config seal.
    #
    # It was the bridge IP before that change. Anything installed by an older
    # revision of this repo therefore registers the IP form and will look like a
    # conflict here -- correctly, because it also has a broken seal and wants
    # reinstalling.
    return model, f"http://host.openshell.internal:{get('VLLM_PORT', '8000')}/v1"


def cmd_preflight(inv: dict, profile: Path, clear_stale: bool, apply: bool) -> int:
    """Refuse-by-default route check, run BEFORE anything expensive starts.

    The policy, chosen deliberately:

      ADOPT   the existing route already matches what this profile wants ->
              proceed and reuse it. This is the "something is already installed
              here" case, and reuse is the correct answer, not stacking.
      REFUSE  a different route is registered -> stop, name every conflicting
              sandbox, print the exact teardown command. Same principle as
              refusing to guess a profile: no silent default.
      EVICT   only behind an explicit flag, never inferred.

    Stale reservations are called out separately from live conflicts, because a
    ghost with no container and no image can never be functional -- it is
    unambiguous garbage and needs one flag, not a decision.
    """
    want_model, want_ep = profile_route(profile)
    print(f"  route wanted: model={want_model} endpoint={want_ep}")

    ghosts = [i for i in inv["items"] if i["pending"]]
    live = [i for i in inv["items"] if not i["pending"]]
    conflicts = [i for i in live
                 if (i["model"] or "") != want_model or (i["endpoint"] or "") != want_ep]
    matches = [i for i in live if i not in conflicts]

    if ghosts and clear_stale:
        names = [g["name"] for g in ghosts]
        print(f"  {C['y']}clearing stale reservation(s): {', '.join(names)}{C['0']}")
        if apply:
            backup_registry()
            drop_registrations(names)
        ghosts = []

    if not ghosts and not conflicts:
        if matches:
            print(f"  {C['g']}ADOPT — '{matches[0]['name']}' already serves this "
                  f"exact route; reusing it{C['0']}")
        else:
            print(f"  {C['g']}clear — no route is registered{C['0']}")
        return 0

    print(f"\n{C['r']}REFUSING — the gateway serves ONE inference route and it is "
          f"already claimed.{C['0']}")
    for g in ghosts:
        print(f"  {C['y']}stale reservation{C['0']}  '{g['name']}' — failed onboard, "
              f"no container, no image. Never functional.")
        print(f"                     fix: re-run with --clear-stale")
    for c in conflicts:
        state = c["container_status"] or "no container"
        print(f"  {C['y']}conflict{C['0']}  '{c['name']}' ({state}) wants "
              f"model={c['model']} endpoint={c['endpoint'] or '-'}")
    if conflicts:
        names = " ".join(f"--sandbox {c['name']}" for c in conflicts)
        print(f"\n  Tear the conflicting one(s) down, then install again:")
        print(f"    ./scripts/reset.py down {names} --yes")
    print(f"\n  {C['d']}Nothing was started. This check runs before the model load "
          f"precisely so a conflict costs a second, not five minutes.{C['0']}")
    return 3


def cmd_snapshot(inv: dict) -> int:
    SNAP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = SNAP_DIR / f"inventory-{stamp}.json"
    dest.write_text(json.dumps(inv, indent=2, default=str) + "\n")
    reg = backup_registry()
    print(f"inventory -> {dest}")
    if reg:
        print(f"registry  -> {reg}")
    print("\nThis records what existed; it is a reference for rebuilding, not an\n"
          "automatic restore. Sandboxes are rebuilt by install.sh, not by copying\n"
          "a JSON file back into place.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("status", help="what is installed right now")
    sub.add_parser("doctor", help="what is wrong, and the fix for each")
    sub.add_parser("snapshot", help="record current state for reference")
    sub.add_parser("record-preinstall",
                   help="(install.sh) record what existed before installing, so a "
                        "factory reset removes only what the install created")
    pf = sub.add_parser("preflight", help="route check; run before anything expensive")
    pf.add_argument("--profile", required=True, type=Path)
    pf.add_argument("--clear-stale", action="store_true",
                    help="drop pending reservations from failed onboards")
    pf.add_argument("--yes", action="store_true",
                    help="permit --clear-stale to write; without it, report only")
    d = sub.add_parser("down", help="tear down")
    d.add_argument("--all", action="store_true", help="every registered sandbox")
    d.add_argument("--sandbox", action="append", default=[], help="by name (repeatable)")
    d.add_argument("--profile", help="the sandbox named by a profile file")
    d.add_argument("--yes", action="store_true", help="actually do it")
    d.add_argument("--hermes-host", action="store_true",
                   help="also uninstall the Hermes HOST install (CLI + desktop "
                        "client) via scripts/uninstall-hermes-host.sh")
    d.add_argument("--everything", action="store_true",
                   help="one flag for a true factory reset: --all --host "
                        "--drop-images --wipe-creds --hermes-host, plus the install "
                        "residue (images, model weights, Docker build cache, caches, "
                        "nvm/npm, OpenShell config and gateway unit, shell rc lines) "
                        "the install created")
    d.add_argument("--keep-models", action="store_true",
                   help="with --everything, keep model weights and the Hugging Face "
                        "cache (saves a ~20 GB re-download)")
    d.add_argument("--assume-bare-origin", action="store_true",
                   help="with --everything: treat shared tools, weights, caches and "
                        "images as installer-created even though no trustworthy "
                        "install record says so (use when this machine was bare "
                        "before the first install). A trusted record still wins: "
                        "what it says pre-existed is kept.")
    d.add_argument("--host", action="store_true",
                   help="also remove host-side state: desktop config, recovery "
                        "scripts, systemd units, forwards")
    d.add_argument("--drop-images", action="store_true",
                   help="with --host, also remove locally-built exx-vllm-spark images")
    d.add_argument("--wipe-creds", action="store_true",
                   help="also remove the generated dashboard password")
    args = ap.parse_args()

    if not args.cmd:
        ap.print_help()
        return 2

    inv = inventory()
    if args.cmd == "status":
        return cmd_status(inv)
    if args.cmd == "doctor":
        return cmd_doctor(inv)
    if args.cmd == "snapshot":
        return cmd_snapshot(inv)
    if args.cmd == "record-preinstall":
        return cmd_record_preinstall()
    if args.cmd == "preflight":
        return cmd_preflight(inv, args.profile, args.clear_stale, args.yes)

    if args.everything:
        args.all = args.host = args.drop_images = args.wipe_creds = True
        args.hermes_host = True

    targets = list(args.sandbox)
    if args.all:
        targets = [i["name"] for i in inv["items"]]
    if args.profile:
        m = re.search(r"^SANDBOX_NAME=(.*)$",
                      Path(args.profile).read_text(), re.M)
        if not m:
            print(f"no SANDBOX_NAME in {args.profile}")
            return 2
        targets.append(m.group(1).strip())

    if args.wipe_creds and args.yes and CRED_DIR.is_dir():
        shutil.rmtree(CRED_DIR)
        print(f"removed {CRED_DIR}")

    rc = cmd_down(inv, targets, args.yes, keep_creds=not args.wipe_creds)

    # Host teardown runs AFTER the containers are gone: stopping forwards first
    # would only have them re-established by a heal timer that is still enabled.
    if args.host:
        print()
        rc = cmd_host_teardown(args.yes, args.drop_images, args.everything) or rc

    # The Hermes host install is removed LAST: the steps above use the `hermes`
    # and `openshell` CLIs, and removing them first would strand the teardown
    # half-done. Delegated to a script rather than inlined, because it carries a
    # dependency scan -- a full uninstall once deleted a node binary an
    # unrelated service was executing, and nothing warned.
    if args.hermes_host:
        print()
        # NemoClaw first: hermes' uninstaller does not touch it, and the install
        # side has a phase for it, so a teardown that skips it leaves ~800 MB and
        # a CLI on PATH -- which is what made a second run behave unlike the first.
        nc = Path(__file__).resolve().parent / "uninstall-nemoclaw.sh"
        if args.yes:
            subprocess.call([str(nc), "--yes"])
        else:
            print(f"{C['b']}nemoclaw{C['0']}\n  {nc} --yes")
        script = Path(__file__).resolve().parent / "uninstall-hermes-host.sh"
        cmd = [str(script)] + (["--yes"] if args.yes else [])
        if not args.yes:
            print(f"{C['b']}hermes host{C['0']}\n  {' '.join(cmd)} --yes")
        else:
            rc = subprocess.call(cmd) or rc
        # Residue goes LAST of all: the gateway unit and OpenShell state must
        # outlive the sandbox teardown, and NVIDIA's uninstaller may remove some
        # of this itself -- whatever it leaves is found afresh here.
        if args.everything:
            print()
            rc = cmd_factory_residue(args.yes, args.keep_models, args.assume_bare_origin) or rc
    elif args.yes:
        print(f"\n{C['d']}host-side state (desktop config, recovery units, forwards) "
              f"left in place; pass --host to remove it too{C['0']}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
