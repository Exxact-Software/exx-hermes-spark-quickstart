# Hermes Agent on a DGX Spark — quickstart

From a DGX Spark with Docker to a running AI agent you can chat with from
another machine, in one command. The model runs on the Spark, so nothing you
type leaves it.

```bash
git clone https://github.com/Exxact-Software/exx-hermes-spark-quickstart.git
cd exx-hermes-spark-quickstart
./install.sh --profile profiles/spark-qwen38.conf
```

Roughly ten minutes on a warm box; longer the first time, because the agent
image is built locally.

**You will be asked to accept NVIDIA's NemoClaw licence and third-party
notice.** The installer retrieves NemoClaw from NVIDIA, and accepting its terms
is yours to do, not ours. At a terminal it shows the notice and asks
`Accept? [y/N]`; answer `y` and the install continues. With no terminal (CI,
`ssh -T`, a pipe) there is nothing to ask, so pass the flag instead:

```bash
./install.sh --profile profiles/spark-qwen38.conf --accept-nemoclaw-license
```

Without a terminal and without the flag the install stops at phase 0 and
changes nothing.

---

## Configuration lives in profiles

There is **no default profile and no `.env`.** You name the configuration you
want, every time:

```bash
./install.sh --list-profiles
./install.sh --profile profiles/spark-qwen38.conf --print-config   # resolve and show, change nothing
./install.sh --profile profiles/spark-qwen38.conf                  # install
```

| Profile | What it is |
| --- | --- |
| `profiles/spark-qwen38.conf` | The shipped configuration. What a bare install means. |
| `profiles/spark-video.conf` | Same policy, own ports and sandbox. ⚠ Cannot run *alongside* another install — see below. |

**Why not `.env`?** Because `.env` is gitignored by convention, which meant the
configuration that produced a given machine was unrecoverable — you could not
answer *"what settings did this box get?"*. Profiles are committed and
reviewable. Copy one, edit it, keep it in the repo.

### Three classes of value, kept apart on purpose

| Class | Where | Examples |
| --- | --- | --- |
| **Policy** | in the profile | model, context length, token caps, image, ports |
| **Host fact** | detected at runtime | docker bridge gateway, dashboard bind address |
| **Forced value** | in the scripts, not configurable | provider wiring, onboard flags, `marlin`, no-compose |

Host facts are detected rather than committed because they differ per machine —
a profile that pinned the bridge IP would be silently wrong on some Sparks.
Override with `--host-bridge-ip` / `--bind-ip` if detection ever picks wrong.

Forced values each have exactly one correct setting, listed in the "not
configurable" section of `--print-config` so you can see what you are not being
offered, and why.

### Profiles are data, not scripts

A profile is **parsed, never sourced.** `KEY=$(command)`, backticks, `;`, pipes
and redirections are **rejected**, not escaped — a configuration file that ships
with a machine must not be able to run anything. The single exception is a
leading `$HOME`, expanded by hand. `scripts/selftest.sh` proves this against
eight escape vectors.

---

## Two commands

```bash
./install.sh --profile profiles/spark-qwen38.conf      # installs EVERYTHING
./scripts/reset.py down --everything --yes             # removes EVERYTHING
```

**Everything** means the Hermes host install and the desktop client *and* the
containerized agent, model server and dashboard. Install once, tear down once,
repeat as often as you like — the install is meant to be run many times, so it
is verified repeatable (two consecutive factory-reset cycles, 410 s and 392 s,
both green).

`--skip-host-install` if the `hermes` CLI and desktop client are already there.
Drop `--yes` from the teardown to see every command it would run, and change
nothing.

> The teardown **refuses** if a process outside Hermes is executing a binary
> from under `~/.hermes`. That is not hypothetical: a full uninstall once
> deleted a `node` binary an unrelated service was running, and the failure only
> appeared at its next restart, pointing nowhere near Hermes.

---

## What this changes on your machine

One command doing a lot is convenient right up until it surprises you, so here
is everything it touches outside this directory.

| It does this | Where | Why |
| --- | --- | --- |
| Adds a line to `/etc/hosts` (**one `sudo`**) | `host.openshell.internal` | so one URL resolves on the host *and* matches the sandbox's egress policy — this is what removed a post-install config edit that used to break the agent on its next reboot |
| Installs two scripts | `~/.local/bin/` | `hermes-stack-restore`, `hermes-desktop-token-sync` |
| Installs three systemd **user** units and enables a timer | `~/.config/systemd/user/` | brings the stack back after a reboot, and re-heals every 15 min |
| Enables **linger** for your user | `loginctl` | without it user units do not run until you log in, so a headless reboot comes back dead |
| Writes the desktop app's config | `~/.config/Hermes/connection.json` | points the client at the container (backed up first) |
| Clones Hermes Agent | `~/.hermes/hermes-agent` | the desktop client ships with it; skip via `--skip-host-install` |
| Builds/pulls container images | Docker | a vLLM image and a per-sandbox agent image |
| Downloads model weights | `MODEL_DIR` in the profile | ~18–22 GB, resumable, never re-fetched |
| Installs NemoClaw (NVIDIA's installer) | `~/.nemoclaw`, `~/.nvm` if Node is missing, `~/.config/openshell`, a `nemoclaw-openshell-gateway` user unit, a few lines in `~/.bashrc` | provides the `nemohermes` CLI the agent is built with |
| Records what was already there | `~/.local/state/hermes-quickstart/preinstall.json` | so a factory reset removes only what the install created |

`./scripts/reset.py down --everything --yes` reverses all of it except the
`/etc/hosts` line, and prints every command first if you drop `--yes`. That
includes the model weights (`--keep-models` keeps them) and what NemoClaw's
installer adds, and the Docker build cache — see [Teardown](#teardown).

### Network exposure is opt-in

**By default the dashboard binds to `127.0.0.1` — nothing is published to your
network.** The desktop client works regardless: it talks over a loopback forward
and never puts credentials on the wire.

To publish it deliberately:

```bash
./install.sh --profile <profile> --bind-ip auto        # Tailscale, else your LAN address
./install.sh --profile <profile> --bind-ip 10.0.0.5    # exactly that address
```

⚠ **If you do publish it**, the dashboard uses **HTTP basic auth** — the password
crosses the network **in cleartext**. Reasonable over a Tailscale/WireGuard
network or an isolated bench; **not** reasonable on a shared corporate LAN. The
generated password is written to `~/.hermes-quickstart/dashboard.password`
(mode 600) and printed when the install finishes.

---

## Prerequisites

- A DGX Spark with a working GPU, and **Docker usable by your user** — the
  installer checks `docker info` and tells you about the `docker` group rather
  than failing three phases later
- **~45 GB free** where `MODEL_DIR` points: weights ~18–22 GB, vLLM image ~22 GB,
  sandbox image ~2 GB. Checked before the download starts, not during it.
- `systemd --user` with **linger** (for reboot survival), and **`sudo` once** —
  the installer adds `host.openshell.internal` to `/etc/hosts` so one URL works
  both on the host and inside the sandbox
- **NemoClaw is NOT a prerequisite any more** — `install.sh` installs it, using
  NVIDIA's own documented installer for DGX Spark, pinned to a tested tag
  (override with `NEMOCLAW_INSTALL_TAG`). The version floor is still enforced
  afterwards. It is installed with `NEMOCLAW_AGENT=hermes` and onboarding
  deferred, so NVIDIA's installer does **not** create its own sandbox or pull
  its own vLLM image and model (~50 GB on current releases); this repo onboards
  the agent itself.

  > ⚠ If you install it yourself, use NVIDIA's installer:
  > `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash`
  >
  > **Do not `npm install -g nemoclaw`.** A package of that name and version
  > exists on npm, published by an unrelated maintainer, with no repository and
  > **no binaries** — it will not give you `nemohermes`.
- **Hermes Agent on the host is NOT a prerequisite any more** — `install.sh`
  installs it (phase 1/5) and builds the desktop client. Pass
  `--skip-host-install` if you already have it.

**The desktop client is pinned to the sandbox's Hermes version.** The agent runs
inside the sandbox at the version NemoClaw ships (Hermes 0.21.3, tag
`v2026.9.14` for the pinned NemoClaw tag); the desktop client is built on the
host. A client built from upstream HEAD is *ahead* of that gateway, which
validates strictly, so every prompt fails with `title, preview: Extra inputs
are not permitted`. `install-hermes-host.sh` therefore checks the host checkout
out at the matching tag (derived from the running sandbox when there is one,
else the pin `HERMES_HOST_REF_PIN` in `scripts/lib/common.sh`; `--ref` overrides)
and rebuilds the client when its build stamp is from another commit. The
healthcheck compares the two. After every build it sets `chrome-sandbox` to
`root:root 4755`, which Electron needs where unprivileged user namespaces are
restricted (this uses `sudo`).

### Why the host Hermes install is a prerequisite

The Electron desktop client ships with the Hermes host install; this repo does
not install it, and cannot — it is Nous Research's software, not ours. What this
repo does is point that client at the **containerized** agent instead of the
host one.

So the shape is:

1. Install Hermes Agent on the host. You get the `hermes` CLI and, through
   `hermes desktop`, the desktop app.
2. Run this installer. It builds the containerized agent, serves the model
   locally, and configures the desktop app to talk to the container.
3. **The host agent stays disabled.** It is here for its desktop client, not to
   serve the model. Nothing you type leaves the machine either way, but only the
   container is sandboxed.

Skip step 1 and everything still works — you just get the web dashboard instead
of the desktop app, and the installer tells you so rather than failing.

**The model is fetched for you, and never twice.** `install.sh` checks whether
the model is already complete and skips the download if it is; otherwise it
fetches it (~18 GB) with `curl` and resume, so an interrupted run continues
rather than restarting.

```bash
./scripts/fetch-model.py check --profile profiles/spark-qwen38.conf   # is it here?
./scripts/fetch-model.py fetch --profile profiles/spark-qwen38.conf   # get it
```

Completeness is verified, not assumed. The old instruction here was
`huggingface-cli download`, which **does not work** — that CLI is not installed
on the target machine. And the old check was only that the directory *existed*,
which a half-finished download passes; vLLM then fails minutes later with an
error that says nothing about it.

---

## One host serves one inference route

The OpenShell gateway has a **single** inference route shared by every registered
sandbox — and **stopped sandboxes still hold their claim**, as do pending
reservations left behind by a *failed* onboard. So two profiles cannot be live on
one machine, and separate ports buy nothing at the gateway layer.

`install.sh` checks this at phase 0, in about a second, because the same conflict
otherwise surfaces after a four-and-a-half minute model load:

| Situation | What happens |
| --- | --- |
| Registered route matches the profile | **adopt** it and carry on — reuse, not stacking |
| A different route is registered | **refuse**, naming each conflict and the exact fix |
| A ghost reservation from a failed onboard | reported separately; `--clear-stale` clears it |

### Reset and do it again

```bash
./scripts/reset.py status          # what is installed, including ghosts
./scripts/reset.py doctor          # what is wrong, and the fix for each
./scripts/reset.py down --all --yes   # tear it all down (~7s)
./install.sh --profile profiles/spark-qwen38.conf
```

`down --all` keeps NemoClaw, the host install, images and weights, so the next
install is warm. For a cold, from-zero run use `down --everything` — see
[Teardown](#teardown).

`nemohermes list` is **not** the source of truth — `~/.nemoclaw/sandboxes.json`
is, and a failed onboard can leave an entry there with no container, no image and
no listing that blocks installs indefinitely. `nemohermes destroy` cannot clear
it either, because there is no sandbox to destroy. `reset.py` handles it.

---

## The dashboard is password-protected

`install.sh` puts an authenticated nginx proxy in front of the dashboard and
prints the URL, username and password-file path.

- The password is **generated** into `~/.hermes-quickstart/dashboard.password`
  (mode 0600) and is **never** in the repo. Only the username is policy.
- The installer verifies **both** directions before declaring success: no
  credentials must give 401, valid credentials must give 200. If either check
  fails it removes the proxy rather than leave an unverified dashboard exposed.

⚠ Basic auth over plain HTTP on a trusted network is the intended scope. Put it
behind TLS before it crosses anything you do not control.

---

## What was installed

Every successful install writes `~/.hermes-quickstart/install-manifest.json`:
profile name, version, path and sha256, the repo commit, the resolved
configuration, detected host facts, image digest, tool versions, and whether the
agent actually answered. No secrets.

```bash
cat ~/.hermes-quickstart/install-manifest.json
```

That turns *"which configuration does this machine have?"* into a `cat` instead
of an investigation.

---

## Verifying without a browser

```bash
./scripts/selftest.sh        # configuration layer: 36 checks, starts nothing
```

The installer's own final step asks the agent to reply `READY` over the gateway
API — the same path the dashboard uses, not the CLI, which passes even when chat
is broken.

---

## The four traps

Each of these cost real debugging time and each is handled in the scripts.

1. **Context below 64000** — Hermes refuses to start the agent. The profile is
   validated against this floor before anything launches.
2. **No output cap** — Hermes asks for the whole context window. Supplied
   **before** the config is sealed, via `NEMOCLAW_MAX_TOKENS`.
3. **Egress policy** — the sandbox blocks outbound by default; the local
   inference endpoint has to be allowed explicitly.
4. ~~**Two correct addresses for one endpoint**~~ — **closed at the source
   2026-08-21.** Onboarding validation runs on the *host*, which could not
   resolve `host.openshell.internal`, so it used a literal IP and the in-sandbox
   config was switched to the hostname afterwards. That "afterwards" was the
   problem — see [The seal](#the-seal-never-configure-after-onboarding). The
   installer now teaches the host to resolve the name, so **one** URL validates
   on the host *and* matches the egress policy in the sandbox.

And a fifth, for anyone running the scripts by hand: `nemohermes onboard`
requires `--non-interactive` **and closed stdin**. With `--yes` alone it still
prompts for the base URL; from a script with no TTY that prompt hits EOF and the
install reports "Installation cancelled".

---

## The seal: never configure after onboarding

**The single rule that matters most in this repo.**

`nemohermes onboard` bakes the agent's configuration into the sandbox image and
records a hash of it. NemoClaw's container entrypoint re-checks that hash on
**every** start, and it fails **closed**: on a mismatch it sets
`HERMES_RESTART_FAILURE_CODE=mcp-integrity` and drops into a sleep loop that
never respawns the gateway.

So a post-onboarding `hermes config set` does not break anything you can see. It
arms the container to **quarantine itself on its next start** — which, because
the sandbox runs `unless-stopped`, means the next time the machine reboots.
Install works, demo works, and days later the box comes up permanently dead.

This repo did exactly that until 2026-08-21. Everything the agent needs is now
supplied **before** the seal, as build ARGs, via `NEMOCLAW_*` environment
variables.

> **Do not add `hermes config set`, or any other mutation of `/sandbox/.hermes`,
> after `onboard`.** If you need a new setting, pass it pre-seal.

To check a running sandbox:

```bash
C=$(docker ps --format '{{.Names}}' | grep openshell-hermes-demo)
docker exec "$C" sh -lc 'sed -n 1p /etc/nemoclaw/hermes.config-hash; sha256sum /sandbox/.hermes/config.yaml'
```
Both `config.yaml` hashes must match. (The `.env` line of the two anchor files
*will* differ — that is by design, one hashes the file with the generated
`API_SERVER_KEY` stripped.)

NemoClaw 0.0.137 changed the layout: its guard checks the live file against
line 1 of `/sandbox/.hermes/.config-hash`, and at startup it reformats
`config.yaml`, keeps the pre-rewrite copy as
`/sandbox/.hermes/.native-local-startup-config`, and updates only the
`/sandbox` hash. There, `/etc/nemoclaw/hermes.config-hash` matches the
pre-rewrite copy, not the live file, and that is healthy.
`./scripts/healthcheck.sh` handles both layouts.

---

## Tool calling is the thing to verify

An agent that answers questions but never calls a tool is useless, and it does
**not** look broken — it looks like a weak model. That happens whenever
`TOOL_CALL_PARSER` does not match the model's actual output format: the model
emits a perfectly good tool call, the server fails to parse it, and it is
returned as ordinary prose.

`start-model.sh` therefore ends by making the model call a real tool and
asserting the response contains `tool_calls`. **A green install means tools
work**, not merely that the model replies.

Valid parsers: `gemma4`, `llama3_json`, `hermes`, `qwen3_coder`. Getting this
wrong is the most likely failure when adding a model.

---

## Adding your own model

Copy a profile and change these. **No code changes.**

| Key | How to choose it |
| --- | --- |
| `MODEL_DIR` / `MODEL_REPO` | the checkpoint |
| `SERVED_MODEL_NAME` | any label; what clients request |
| `TOOL_CALL_PARSER` | must match the model's tool-call format — see above |
| `MAX_MODEL_LEN` | **≥ 64000**, enforced |
| `VLLM_IMAGE` | some checkpoints need a specific build |
| `VLLM_EXTRA_ARGS` | escape hatch for per-model flags, e.g. `--reasoning-parser qwen3` |
| `AGENT_THINKING` | optional, `default` or `off`. `off` starts vLLM with `--default-chat-template-kwargs '{"enable_thinking": false}'`, so a reasoning model answers without its thinking phase unless a request asks for it. Only `profiles/spark-video.conf` sets it |

`VLLM_EXTRA_ARGS` exists because the profile is *not* always sufficient on its
own: `profiles/spark-qwen38.conf` needs a reasoning parser that Gemma does not.
Expect a genuinely new model to need one more thing, and put it there.

Because the gateway serves **one** inference route, changing model needs a
teardown first:

```bash
./scripts/reset.py down --sandbox hermes-demo --yes
./install.sh --profile profiles/<new>.conf
```

---

## Surviving a reboot

Not automatic. See [`host/`](host/) — two scripts and a systemd user unit,
plus the three traps found rehearsing it (a listening port is not a working
forward; the container returns but the agent does not; `RemainAfterExit` is
load-bearing).

Rehearsed on a Spark 2026-08-21: unattended recovery in **4m26s**.

### vLLM sometimes dies at startup, and is started again

Before it loads weights, vLLM inspects the model class in a throwaway Python
subprocess. In NVIDIA's NGC vLLM image (torch `2.13.0a0+nv26.07`) that
subprocess intermittently segfaults **at interpreter exit** — after it has
already answered — in torch's `_del_library` finalizer. vLLM only looks at the
exit status, so the whole server exits within seconds:
`... vllm.model_executor.models.registry ... died with <Signals.SIGSEGV: 11>`,
preceded by a `UnicodeDecodeError` on a different byte every run. It is a
property of the image, not of the model, flags or this repo; the same start
works on the next attempt.

`start-model.sh` (and so the install) and the boot-time `hermes-stack-restore`
(and so the heal timer) therefore start it again, up to 3 attempts in total
(`HERMES_VLLM_START_ATTEMPTS`), printing one line per retry
(`↻ vLLM start 1/3 hit the known NVIDIA-image exit-time SIGSEGV ...`). Only that exact signature is retried; any other failure
(out of memory, bad flags, a missing model) still stops at once with the logs.
vLLM has its own on-disk cache of this inspection that would skip the
subprocess, but it is written only after a successful inspection, so it cannot
help a first start.

---

## Why there is no `docker-compose.yml`

The obvious shape for this repo is a compose file. **Neither half can use one.**

1. **The agent half is not a container definition.** `nemohermes onboard`
   *builds* a per-sandbox image and registers it with the OpenShell gateway, a
   host process. There is nothing to declare.
2. **The model half fails under compose on this hardware** — every model dies
   with an opaque `int('')`. A plain `docker run --entrypoint vllm` is the
   working path.

So this repo ships scripts, and says why here and in the script headers —
otherwise the next person tidies it into a compose file and it breaks.

---

## The scripts

`install.sh` runs the whole thing; these are the pieces, usable on their own.

| Script | What it does |
| --- | --- |
| `scripts/healthcheck.sh` | **Is this install healthy?** 11 checks: the config seal, tool calls actually parsing, the control UI, the desktop token, reboot wiring. Exits non-zero when something is wrong. Run this first when anything feels off. |
| `scripts/attach-desktop.sh` | Points the Hermes desktop app at the container. Host-side only — never touches the sandbox, so it cannot break the seal. |
| `scripts/install-host-services.sh` | Installs the reboot-recovery scripts, units and heal timer, enables linger, and verifies the timer really is scheduled. |
| `scripts/start-model.sh` | Serves the model. Builds or pulls the profile's image if absent, then proves a tool call parses before reporting success. |
| `scripts/expose-dashboard.sh` | Puts the dashboard on the network, with or without a password. |
| `scripts/fetch-model.py` | Downloads weights, with resume and real completeness verification. |
| `scripts/reset.py` | Inventory, diagnose, tear down. See Teardown. |
| `scripts/selftest.sh` | Config-layer self-test. Starts nothing, touches no GPU — safe while a demo is running. |

```bash
./scripts/healthcheck.sh --profile profiles/spark-qwen38.conf
```

---

## Teardown

**Full factory reset**, back to a machine that has never seen this repo:

```bash
./scripts/reset.py down --everything                 # dry run: every command, nothing changed
./scripts/reset.py down --everything --yes           # do it
./scripts/reset.py down --everything --keep-models --yes   # same, but keep ~20 GB of weights
```

Without `--yes` it is a dry run that prints every command it would execute,
including each `~/.bashrc` line it would remove.

| Flag | Removes |
| --- | --- |
| *(none)* | sandboxes, their containers and images, supporting containers |
| `--host` | desktop config, recovery scripts, systemd units and timer, forwards |
| `--drop-images` | locally-built `exx-vllm-spark` images |
| `--wipe-creds` | the generated dashboard password |
| `--hermes-host` | NemoClaw (`nemohermes`) and the Hermes host install + desktop client |
| `--everything` | all of the above, plus the install residue below |
| `--keep-models` | with `--everything`: keep model weights and the Hugging Face cache |
| `--assume-bare-origin` | with `--everything`: treat shared tools, weights, caches and images as installer-created even though no trustworthy install record says so (see below) |

**Install residue** (`--everything` only). Only what the install created is
removed:

- always: the NemoClaw/OpenShell images (`ghcr.io/nvidia/nemoclaw/*`,
  `ghcr.io/nvidia/openshell*`), `~/.local/bin/nemoclaw-acp`, the
  `nemoclaw-openshell-gateway` user unit (only if NemoClaw-marked),
  `~/.config/openshell`, `~/.local/state/openshell`, the root-owned
  `~/flashinfer-cache` (removed through a throwaway `alpine` container, not
  sudo), the shipped profiles' `MODEL_DIR`s, and NemoClaw's exact
  `# NemoClaw PATH setup` / `# Added by NemoClaw installer` blocks in
  `~/.bashrc`, `~/.zshrc`, `~/.profile` (backed up first)
- **only if the install record shows the install created them**: `~/.nvm` and
  nvm's three-line loader in `~/.bashrc`, `~/.npm`, `~/.npm-global`,
  `~/.cache/huggingface`, `~/models` (if empty), generic base images
  (`nvcr.io/nvidia/vllm`, `nginx:alpine`, `alpine:3`, `node:22-trixie*`), and
  the Docker build cache (`docker builder prune --all`, which `--drop-images`
  does not touch; it is dropped whole, so only if there was none before)

`install.sh` writes that record before it changes anything, and the record
carries its own verdict. A record taken on a machine the install had not
touched is **trusted**: what it says existed first is kept, everything else
the install made is removed, and `--assume-bare-origin` cannot override it.
A record taken after an install had already begun (OpenShell config, the
flashinfer cache, NemoClaw's shell lines or images already present) is
**untrusted**, because it would list the install's own `~/.nvm` as "existed
before". Then the installer-only items above are still removed, but the shared
ones are kept and listed, and `doctor` names the way out: if this machine was
bare before the first install, run `down --everything --assume-bare-origin`.
An untrusted record is kept, not deleted, until those items are gone, so the
next install cannot record them as pre-existing. With no record at all the
shared items are kept too — remove them by hand if they are not yours.
`reset.py status` and `doctor` report leftovers once NemoClaw itself is gone.

Model weights survive every teardown **except** `--everything`; without it,
delete `MODEL_DIR` by hand to exercise the cold-download path.

The `/etc/hosts` entry for `host.openshell.internal` is also kept: it needs
root, and it is a fact about the machine rather than about an install.



**Use `reset.py`.** It is idempotent, it finds state the commands below miss
(orphaned images, pending route reservations), and it takes ~7s:

```bash
./scripts/reset.py status            # what is installed, including ghosts
./scripts/reset.py doctor            # what is wrong, and the exact fix for each
./scripts/reset.py down --all        # dry run
./scripts/reset.py down --all --yes  # do it
```

The manual sequence below is kept for reference, but it is **incomplete** --
`nemohermes destroy` leaves the dashboard container running, and orphaned
sandbox images (1.72 GB each) accumulate silently:

```bash
./scripts/expose-dashboard.sh --profile profiles/spark-qwen38.conf --stop
docker rm -f hermes-spark-vllm
nemohermes hermes-demo destroy --yes
```

> 🔴 **Never `docker network rm openshell-docker`, and never remove the NemoClaw
> gateway.** Both are *shared* infrastructure that `destroy` preserves on
> purpose. Removing the network makes the next install fail with
> `ContainerStartFailed ... network openshell-docker not found`, and the only
> honest diagnostic for that lives in
> `journalctl --user -u nemoclaw-openshell-gateway` -- not in the installer
> output, and not in `~/.nemoclaw/onboard-failures/`, which is written empty.

### Recovering a sandbox that will not come back

`nemohermes <name> start` and `nemohermes <name> recover` have both been observed
failing to restore a sandbox that is `Phase: Ready` but whose Hermes gateway
process is not running (dashboard 502). **`reset.py down --all --yes` followed by
a fresh `install.sh` is the reliable path.**

---

## Third-party software

`profiles/spark-qwen38.conf` uses **`exx-vllm-spark`**, built here from
[`images/Dockerfile.vllm-spark`](images/Dockerfile.vllm-spark): NVIDIA's own NGC
vLLM, pinned by digest and published with a cosign signature, plus **one** patch
(`xgrammar==0.2.1`, because the base pins a version missing a symbol its own
tool-parser code imports — which silently breaks every tool call).

```bash
docker build -f images/Dockerfile.vllm-spark -t exx-vllm-spark:0.24.0-xgrammar021 .
```

⚠ **`profiles/spark-gemma26.conf` (Gemma) still points at a third-party
community aarch64 build**, used with `--trust-remote-code`. Gemma does not load
on the image above — it fails in `gemma4_mm.py` on a torch 2.13 custom-op
lookup. This is a community-built image pulled by digest and run with
`--trust-remote-code`; we have validated it works for this profile, but it is
not an Exxact-built artifact. An in-house Gemma-capable build is planned
(blocked today on the `gemma4_mm.py` issue above). If your security policy
forbids third-party images with `--trust-remote-code`, use
`spark-qwen38.conf`, which runs Exxact's own `exx-vllm-spark` build.

---

## License

**Apache-2.0** — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Chosen to match [NemoClaw](https://github.com/NVIDIA/NemoClaw), which this
tooling drives, and for its explicit patent grant. Hermes Agent is MIT (Nous
Research) and flows into Apache-2.0 downstream without conflict.

This repository is **installer and teardown tooling only**. It does not
redistribute NemoClaw, Hermes Agent, vLLM, container images or model weights —
it fetches them from their publishers, and each is governed by its own licence.
Container image provenance, stated precisely rather than as a blanket claim:

| Profile | Image | Pinned how |
| --- | --- | --- |
| `spark-qwen38`, `spark-video` | `exx-vllm-spark` | built here from [`images/Dockerfile.vllm-spark`](images/Dockerfile.vllm-spark), whose `FROM` is an NVIDIA NGC **digest** |
| `spark-gemma26` | `ghcr.io/bjk110/vllm-spark` | **digest**, `sha256:2c52c885…` |

So nothing resolves through a mutable tag: the two we build are reproducible
from a digest-pinned base you can inspect, and the third-party one is pinned
directly. That third-party image is a real, auditable build — public Apache-2.0
source, publisher active on GitHub since 2013 — but it is **not signed and has no
CI**, which is the honest limit of how far it has been vetted.
