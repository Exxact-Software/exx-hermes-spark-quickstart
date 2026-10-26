#!/usr/bin/env python3
"""Make sure the model is on disk. Never download it twice.

WHY THIS EXISTS
---------------
The installer required the model as a prerequisite and told you to run
`huggingface-cli download`. Two problems with that:

  1. `huggingface-cli` is not installed on the target machine, and neither is
     `huggingface_hub`. The documented command did not work on the very box
     meant to demonstrate the process.
  2. `install.sh` only checked that MODEL_DIR *existed*. A half-finished
     download leaves a directory that passes that check, and then vLLM dies
     four minutes later with an error that says nothing about it.

So this does the job with **curl and python3 only** -- both already present --
and it verifies completeness rather than existence.

THE SIZE TRAP, worth knowing before you "fix" the check
-------------------------------------------------------
`model.safetensors.index.json` carries `metadata.total_size`, which counts
TENSOR bytes. The shard files on disk are slightly LARGER because each carries a
safetensors header. On this model that is a 6 MB difference on 18 GB:

    total_size          18,782,360,732
    sum of shard files  18,788,485,588

An equality check therefore reports a perfectly good model as incomplete, and
the consequence is someone re-downloading eighteen gigabytes for no reason. The
check below requires sum >= total_size with a small ceiling instead.

    fetch-model.py check --profile profiles/spark-default.conf
    fetch-model.py fetch --profile profiles/spark-default.conf
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

HF = "https://huggingface.co"
C = {"b": "\033[1m", "d": "\033[2m", "r": "\033[31m",
     "g": "\033[32m", "y": "\033[33m", "0": "\033[0m"}

# Small files a usable checkout needs beyond the weights themselves.
REQUIRED_AUX = ["config.json"]


def read_profile(path: Path) -> dict:
    text = path.read_text()
    out = {}
    for k in ("MODEL_DIR", "MODEL_REPO", "SERVED_MODEL_NAME", "INFERENCE_MODE"):
        m = re.search(rf"^{k}=(.*)$", text, re.M)
        if m:
            v = m.group(1).strip().strip('"').strip("'")
            v = v.replace("$HOME", os.path.expanduser("~"))
            v = v.replace("${HOME}", os.path.expanduser("~"))
            if v.startswith("~"):
                v = os.path.expanduser(v)
            out[k] = v
    return out


def human(n: float) -> str:
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} TB"


# ---------------------------------------------------------------------------
# completeness


def check(model_dir: Path, verbose: bool = True) -> tuple[bool, str]:
    if not model_dir.is_dir():
        return False, f"directory does not exist: {model_dir}"

    idx = model_dir / "model.safetensors.index.json"
    if not idx.is_file():
        shards = sorted(model_dir.glob("*.safetensors"))
        if not shards:
            return False, "no index and no .safetensors files — nothing downloaded"
        if any(s.stat().st_size == 0 for s in shards):
            return False, "a .safetensors file is zero bytes — partial download"

        # A name like model-00001-of-00002.safetensors STATES the shard count, so
        # a multi-shard model is never legitimately index-less. Without this, a
        # download caught mid-flight -- one shard arrived, index not yet fetched --
        # looks complete, and the installer proceeds to fail at vLLM instead.
        expected = 0
        for s in shards:
            m = re.search(r"-of-(\d+)\.safetensors$", s.name)
            if m:
                expected = max(expected, int(m.group(1)))
        if expected:
            if len(shards) < expected:
                return False, (f"{len(shards)} of {expected} shard(s) present "
                               f"(the filenames say {expected}) — partial download")
            return False, ("shards are present but model.safetensors.index.json is "
                           "missing — a multi-shard model needs it; partial download")

        # Genuinely single-file: no -of- naming, so there is nothing to cross-check.
        return True, f"{len(shards)} shard(s), single-file model, no index expected"

    try:
        meta = json.loads(idx.read_text())
    except Exception as e:
        return False, f"index is unreadable ({e}) — partial download"

    want = sorted(set(meta.get("weight_map", {}).values()))
    total = meta.get("metadata", {}).get("total_size")

    missing = [s for s in want if not (model_dir / s).is_file()]
    if missing:
        return False, f"{len(missing)} of {len(want)} shard(s) missing: {', '.join(missing[:3])}"

    sizes = {s: (model_dir / s).stat().st_size for s in want}
    empty = [s for s, n in sizes.items() if n == 0]
    if empty:
        return False, f"zero-byte shard(s): {', '.join(empty)}"

    got = sum(sizes.values())
    if total:
        # Files are LARGER than total_size by their headers -- never smaller.
        # A shortfall means truncation.
        if got < total:
            return False, (f"shards total {human(got)} but the index expects at least "
                           f"{human(total)} — truncated by {human(total - got)}")
        # The excess is a safetensors header PER SHARD: a roughly fixed number of
        # bytes, not a proportion. A percentage ceiling is the wrong shape -- it
        # is loose on an 18 GB model and far too tight on a small one, which is
        # how a valid model gets reported as incomplete. Allow a fixed per-shard
        # budget, or 2% for models large enough that that is the bigger number.
        slack = max(64 * 1024 * 1024 * len(want), int(total * 0.02))
        if got - total > slack:
            return False, (f"shards total {human(got)}, exceeding the index's "
                           f"{human(total)} by {human(got - total)} — more than the "
                           f"{human(slack)} of header overhead expected for "
                           f"{len(want)} shard(s)")

    aux_missing = [a for a in REQUIRED_AUX if not (model_dir / a).is_file()]
    if aux_missing:
        return False, f"missing {', '.join(aux_missing)}"

    detail = f"{len(want)} shard(s), {human(got)}"
    if total:
        detail += f" (index expects {human(total)} of tensors + headers)"
    return True, detail


# ---------------------------------------------------------------------------
# fetch


def hf_files(repo: str) -> list[dict]:
    url = f"{HF}/api/models/{repo}"
    req = urllib.request.Request(url, headers={"User-Agent": "exx-hermes-quickstart"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.loads(r.read())
    out = []
    for s in data.get("siblings", []):
        name = s.get("rfilename")
        if not name or name.startswith(".") or "/" in name:
            # Skip dotfiles and nested paths; this model layout is flat.
            if not name or name.startswith("."):
                continue
        out.append({"name": name})
    return out


def hf_size(repo: str, name: str) -> int | None:
    """Content-Length from a HEAD on the resolve URL. Used to decide whether an
    existing file is complete, so a resumed run does not re-fetch 10 GB."""
    url = f"{HF}/{repo}/resolve/main/{urllib.parse.quote(name)}"
    try:
        req = urllib.request.Request(url, method="HEAD",
                                     headers={"User-Agent": "exx-hermes-quickstart"})
        with urllib.request.urlopen(req, timeout=60) as r:
            n = r.headers.get("Content-Length")
            return int(n) if n else None
    except Exception:
        return None


def fetch(model_dir: Path, repo: str) -> int:
    model_dir.mkdir(parents=True, exist_ok=True)
    print(f"{C['b']}fetching {repo}{C['0']}  ->  {model_dir}")
    print(f"{C['d']}  curl with resume; files already complete are skipped{C['0']}\n")

    try:
        files = hf_files(repo)
    except Exception as e:
        print(f"{C['r']}could not list {repo}: {e}{C['0']}")
        print("  If this machine has no internet access, copy the model directory "
              "in by hand instead.")
        return 1

    if not files:
        print(f"{C['r']}{repo} listed no files{C['0']}")
        return 1

    failed = []
    for f in files:
        name = f["name"]
        dest = model_dir / name
        remote = hf_size(repo, name)
        local = dest.stat().st_size if dest.is_file() else 0

        if remote is not None and local == remote:
            print(f"  {C['g']}have{C['0']}     {name}  ({human(local)})")
            continue
        if local and remote is not None and local < remote:
            print(f"  {C['y']}resume{C['0']}   {name}  "
                  f"({human(local)} of {human(remote)})")
        else:
            print(f"  {C['b']}get{C['0']}      {name}"
                  + (f"  ({human(remote)})" if remote else ""))

        url = f"{HF}/{repo}/resolve/main/{urllib.parse.quote(name)}"
        # -C - resumes; --retry survives a flaky link on an 18 GB file.
        rc = subprocess.run(
            ["curl", "-L", "--fail", "-C", "-", "--retry", "5",
             "--retry-delay", "5", "--progress-bar", "-o", str(dest), url]
        ).returncode
        if rc != 0:
            # curl exits 33 when the server cannot resume and the file is done.
            if rc == 33 and remote is not None and dest.is_file() \
               and dest.stat().st_size == remote:
                print(f"  {C['g']}already complete{C['0']}")
                continue
            print(f"  {C['r']}failed (curl rc={rc}){C['0']}")
            failed.append(name)

    if failed:
        print(f"\n{C['r']}{len(failed)} file(s) failed: {', '.join(failed)}{C['0']}")
        print("  Re-run; completed files are skipped and partials resume.")
        return 1

    ok, why = check(model_dir)
    print()
    if ok:
        print(f"{C['g']}model complete — {why}{C['0']}")
        return 0
    print(f"{C['r']}download finished but the check failed: {why}{C['0']}")
    return 1


STASH_SUFFIX = ".demo-stash"
# Older versions used a different suffix, `.fil*-stash`; `restore` still finds a
# stash made with it (matched by pattern so the old name is not repeated here).
LEGACY_STASH_GLOB = ".fil*-stash"


def stash(model_dir: Path) -> int:
    """Move the model aside so a download can be demonstrated for real.

    A rename on the same filesystem, so 18 GB moves instantly and nothing is
    copied. This exists because demonstrating the download and not re-downloading
    18 GB are in tension: the fetch only runs when the model is absent. Run a
    genuine download for a minute, interrupt it, then `restore`.
    """
    dest = Path(str(model_dir) + STASH_SUFFIX)
    if dest.exists():
        print(f"{C['r']}a stash already exists: {dest}{C['0']}")
        print("  restore it first, or move it out of the way by hand.")
        return 1
    if not model_dir.is_dir():
        print(f"{C['y']}nothing to stash — {model_dir} does not exist{C['0']}")
        return 0
    ok, why = check(model_dir)
    if not ok:
        print(f"{C['y']}warning: what you are stashing is not a complete model "
              f"({why}){C['0']}")
    if dest.parent != model_dir.parent:
        print(f"{C['r']}refusing: stash would cross filesystems{C['0']}")
        return 1
    model_dir.rename(dest)
    print(f"{C['g']}stashed{C['0']}  {model_dir}")
    print(f"         -> {dest}")
    print(f"\n{C['d']}  The installer will now see no model and will fetch it.\n"
          f"  Show what you need, interrupt with Ctrl-C, then:\n"
          f"    ./scripts/fetch-model.py restore --profile <profile>{C['0']}")
    return 0


def restore(model_dir: Path) -> int:
    """Put the real model back, discarding whatever the demo download left."""
    src = Path(str(model_dir) + STASH_SUFFIX)
    if not src.is_dir():
        legacy = sorted(p for p in model_dir.parent.glob(model_dir.name + LEGACY_STASH_GLOB)
                        if p.is_dir())
        if legacy:
            src = legacy[0]
    if not src.is_dir():
        print(f"{C['r']}no stash found at {src}{C['0']}")
        return 1

    if model_dir.exists():
        # Whatever is here is a partial from the demo run. Only remove it if it
        # is NOT a complete model -- refusing otherwise means a mistake cannot
        # silently destroy a good download.
        ok, why = check(model_dir)
        if ok:
            print(f"{C['r']}refusing: {model_dir} already holds a COMPLETE model "
                  f"({why}){C['0']}")
            print(f"  The stash at {src} was not restored. Resolve by hand so "
                  f"nothing good is deleted.")
            return 1
        n = sum(1 for _ in model_dir.rglob("*"))
        size = sum(f.stat().st_size for f in model_dir.rglob("*") if f.is_file())
        print(f"{C['y']}discarding the partial download{C['0']}  "
              f"({n} entries, {human(size)}) — {why}")
        import shutil
        shutil.rmtree(model_dir)

    src.rename(model_dir)
    ok, why = check(model_dir)
    if ok:
        print(f"{C['g']}restored{C['0']}  {model_dir}  ({why})")
        return 0
    print(f"{C['r']}restored but the check fails: {why}{C['0']}")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["check", "fetch", "stash", "restore"])
    ap.add_argument("--profile", required=True, type=Path)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    p = read_profile(args.profile)
    if p.get("INFERENCE_MODE") == "remote":
        print("profile uses remote inference — no local model needed")
        return 0

    model_dir = Path(p.get("MODEL_DIR", ""))
    if not str(model_dir):
        print(f"{C['r']}no MODEL_DIR in {args.profile}{C['0']}")
        return 2

    if args.mode == "stash":
        return stash(model_dir)
    if args.mode == "restore":
        return restore(model_dir)

    ok, why = check(model_dir)
    if args.mode == "check":
        if ok:
            if not args.quiet:
                print(f"{C['g']}model present — {why}{C['0']}")
            return 0
        print(f"{C['y']}model not usable — {why}{C['0']}")
        return 1

    if ok:
        # Explicit requirement: if the model is already present, do not
        # re-download it.
        print(f"{C['g']}model already present — {why}{C['0']}")
        print(f"{C['d']}  nothing to download{C['0']}")
        return 0

    repo = p.get("MODEL_REPO")
    if not repo:
        print(f"{C['r']}model is missing and no MODEL_REPO is set in "
              f"{args.profile}{C['0']}")
        print(f"  reason: {why}")
        return 2
    print(f"{C['y']}model not usable — {why}{C['0']}\n")
    return fetch(model_dir, repo)


if __name__ == "__main__":
    sys.exit(main())
