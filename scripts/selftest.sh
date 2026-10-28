#!/usr/bin/env bash
# Self-test for the installer's configuration layer.
#
# Runs entirely against --print-config, so it starts no containers, touches no
# GPU, and cannot disturb a demo that is already running. Every check has a
# stated expectation; positive controls are included so that "nothing errored"
# cannot be mistaken for "the check ran".
#
#   ./scripts/selftest.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
WORK="$(mktemp -d -t hermes-selftest.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '%s  PASS%s  %-22s %s\n' "$GRN" "$OFF" "$1" "${2:-}"; }
fail() { FAIL=$((FAIL+1)); printf '%s  FAIL%s  %-22s %s\n' "$RED" "$OFF" "$1" "${2:-}"; }

strip() { sed 's/\x1b\[[0-9;]*m//g'; }
BASE="$REPO/profiles/spark-qwen38.conf"

# --- reserved gateway ports --------------------------------------------------
# NemoClaw rejects specific gateway ports outright. Walking to "the next free
# port" once landed on 8081, which is free and also refused, and the install
# died inside onboarding. Assert we still skip them.
( . scripts/lib/profile.sh 2>/dev/null
  NEMOCLAW_GATEWAY_PORT=8080 CONTROL_UI_PORT=18795 DASHBOARD_PUBLIC_PORT=18796
  _p_port_reserved 8081 NEMOCLAW_GATEWAY_PORT ) 2>/dev/null \
  && pass "reserved ports skipped" "8081 recognised as reserved" \
  || fail "reserved ports skipped" "8081 not treated as reserved"

# --- dangling-symlink handling -----------------------------------------------
# `[[ -e ]]` follows symlinks, so a BROKEN link tests false and gets skipped
# while `command -v` still finds it. That let a dead hermes wrapper survive a
# full uninstall. Assert the test that actually catches it is still present.
if grep -q '\[\[ -e "\$W" || -L "\$W" \]\]' scripts/uninstall-hermes-host.sh; then
  pass "dangling wrapper detected" "-L as well as -e"
else
  fail "dangling wrapper detected" "uninstall uses -e alone; a broken symlink will survive"
fi

# Guards against reading /proc entries that exit mid-scan.
if [[ "$(grep -c '\-r "/proc/\$p/' scripts/uninstall-hermes-host.sh)" -ge 2 ]]; then
  pass "proc scan guarded" "no noise from pids that exit mid-scan"
else
  fail "proc scan guarded" "unguarded /proc reads will spray errors"
fi

# --- secure by default -------------------------------------------------------
# The default bind address is a security posture, not a convenience setting, and
# it is the kind of thing a later "make it easier to reach" change quietly
# reverts. These fail if the default stops being loopback.
OUT="$(./install.sh --profile profiles/spark-qwen38.conf --print-config 2>&1 | strip)"
if grep -qE '^\s*BIND_IP\s+127\.0\.0\.1\s*$' <<<"$OUT"; then
  pass "binds loopback by default" "nothing published without asking"
else
  fail "binds loopback by default" "got: $(grep -E 'BIND_IP' <<<"$OUT" | head -1)"
fi

OUT2="$(./install.sh --profile profiles/spark-qwen38.conf --bind-ip 10.9.9.9 --print-config 2>&1 | strip)"
if grep -qE '^\s*BIND_IP\s+10\.9\.9\.9\s*$' <<<"$OUT2"; then
  pass "explicit --bind-ip honoured" "opt-in still works"
else
  fail "explicit --bind-ip honoured" "override ignored"
fi

# --- no re-duplication -------------------------------------------------------
# ok/note/warn/die were byte-identical in seven files and the dashboard-token
# scrape in four. Extracting them only helps if it stays extracted, and the
# natural pressure on a shell repo is to paste a helper back in rather than add
# a source line. These fail if that happens.
# Scoped to the scripts that share the library's exact helper signatures.
# install.sh and healthcheck.sh are deliberately excluded: install.sh's helpers
# take "$*" and use the top-level installer's own spacing, and healthcheck's
# warn/pass/fail increment result counters. Those are specialisations, not
# copy-paste, and forcing them into the shared file would make it worse.
LIB_USERS="scripts/attach-desktop.sh scripts/install-hermes-host.sh scripts/install-host-services.sh scripts/uninstall-hermes-host.sh"
DUP_HELPERS=0
for f in $LIB_USERS; do
  grep -qE '^(ok|note|warn|die)\(\)' "$f" 2>/dev/null && DUP_HELPERS=$((DUP_HELPERS+1))
done
if [[ "$DUP_HELPERS" -eq 0 ]]; then
  pass "helpers not duplicated" "4 scripts source lib/common.sh"
else
  fail "helpers not duplicated" "$DUP_HELPERS of 4 define ok/note/warn/die inline again"
fi

# Excludes this file, which necessarily names the pattern in order to check it.
DUP_TOKEN=0
for f in $(ls scripts/*.sh | grep -v selftest); do
  grep -qF '__HERMES_SESSION' "$f" 2>/dev/null && DUP_TOKEN=$((DUP_TOKEN+1))
done
if [[ "$DUP_TOKEN" -eq 0 ]]; then
  pass "token scrape centralised" "only lib/common.sh knows the regex"
else
  fail "token scrape centralised" "$DUP_TOKEN script(s) re-implement it"
fi


# --- seal-drift detector: positive AND negative control ------------------------
# healthcheck.sh's most important check is one that, on a healthy box, always
# passes -- which is exactly how a check rots into decoration. These exercise
# the comparison itself with known inputs, so a regression that made it always
# pass would be caught here rather than by a bricked machine weeks later.
# shellcheck source=scripts/lib/common.sh
. scripts/lib/common.sh
sv() { hermes_seal_verdict "$@" | cut -d' ' -f1; }
# Older NemoClaw: one root-owned anchor.
if [[ "$(sv abc123 '' abc123 '')" == match ]]; then
  pass "seal check: identical" "negative control -- healthy reads as match"
else
  fail "seal check: identical" "healthy config reported as drift"
fi
if [[ "$(sv abc123 '' def456 '')" == drift ]]; then
  pass "seal check: drifted" "positive control -- mismatch IS detected"
else
  fail "seal check: drifted" "DRIFT WENT UNDETECTED -- the detector is decorative"
fi
# NemoClaw 0.0.137: the guard reads /sandbox/.hermes/.config-hash; startup
# rewrites config.yaml and leaves /etc holding the pre-rewrite copy's hash.
if [[ "$(sv etcH live1 live1 etcH)" == match ]]; then
  pass "seal check: 0.0.137 rewrite" "/etc == pre-rewrite copy, guard == live"
else
  fail "seal check: 0.0.137 rewrite" "a healthy 0.0.137 sandbox reads as drifted"
fi
if [[ "$(sv etcH live1 live1 other)" == drift ]]; then
  pass "seal check: 0.0.137 anchor" "/etc matching neither copy IS drift"
else
  fail "seal check: 0.0.137 anchor" "an unexplained /etc anchor passed"
fi
if [[ "$(sv etcH guardH live1 etcH)" == drift ]]; then
  pass "seal check: 0.0.137 guard" "live != guard hash IS drift"
else
  fail "seal check: 0.0.137 guard" "the comparison the guard fails closed on passed"
fi
if [[ "$(sv '' '' '' '')" == unknown ]]; then
  pass "seal check: unreadable" "missing hashes are unknown, not match"
else
  fail "seal check: unreadable" "no hashes read as a verdict"
fi
if grep -q 'sha256sum /sandbox/.hermes/config.yaml' scripts/healthcheck.sh \
   && grep -q '/etc/nemoclaw/hermes.config-hash' scripts/healthcheck.sh; then
  pass "seal check: wired up" "healthcheck reads both anchor and live file"
  grep -q '/sandbox/.hermes/.config-hash' scripts/healthcheck.sh \
    && grep -q 'native-local-startup-config' scripts/healthcheck.sh \
    && grep -q 'hermes_seal_verdict' scripts/healthcheck.sh \
    && pass "seal check: both layouts" "guard hash + startup copy read" \
    || fail "seal check: both layouts" "0.0.137 guard layout not read"
else
  fail "seal check: wired up" "healthcheck no longer compares the seal"
fi

# --- 1. refuses to guess -----------------------------------------------------
OUT="$(./install.sh 2>&1)"; RC=$?
if (( RC == 2 )) && grep -q 'no --profile given' <<<"$(strip <<<"$OUT")"; then
  pass "no-profile refused" "exit 2, lists profiles"
else
  fail "no-profile refused" "exit $RC"
fi

# --- 2. positive control: the shipped profiles must all validate -------------
for p in "$REPO"/profiles/*.conf; do
  n="$(basename "$p" .conf)"
  OUT="$(./install.sh --profile "$p" --print-config 2>&1)"; RC=$?
  # a profile whose endpoint is unreachable from here legitimately fails;
  # only the configuration layer is under test, so accept a clean validate.
  if (( RC == 0 )) && grep -q 'is valid' <<<"$(strip <<<"$OUT")"; then
    pass "profile validates" "$n"
  else
    fail "profile validates" "$n (exit $RC)"
  fi
done

# --- 3. print-config must change nothing ------------------------------------
B="$(docker ps -q 2>/dev/null | wc -l)"
./install.sh --profile "$BASE" --print-config >/dev/null 2>&1
A="$(docker ps -q 2>/dev/null | wc -l)"
[[ "$B" == "$A" ]] && pass "print-config inert" "containers $B -> $A" \
                   || fail "print-config inert" "containers $B -> $A"

# --- 4. each invalid profile must be rejected -------------------------------
mk() { printf '%s\n' "$2" > "$WORK/$1.conf"; }
sed 's/^MAX_MODEL_LEN=.*/MAX_MODEL_LEN=32768/'                "$BASE" > "$WORK/low-ctx.conf"
sed 's/^TOOL_CALL_PARSER=.*/TOOL_CALL_PARSER=nosuchparser/'   "$BASE" > "$WORK/bad-parser.conf"
sed 's#^MODEL_DIR=.*#MODEL_DIR=/definitely/not/here#'         "$BASE" > "$WORK/no-model.conf"
sed 's/^AGENT_MAX_TOKENS=.*//'                                "$BASE" > "$WORK/missing-key.conf"
sed 's/^DASHBOARD_PUBLIC_PORT=.*/DASHBOARD_PUBLIC_PORT=18795/' "$BASE" > "$WORK/port-clash.conf"
sed 's/^INFERENCE_MODE=.*/INFERENCE_MODE=sideways/'           "$BASE" > "$WORK/bad-mode.conf"
sed 's/^GPU_MEMORY_UTILIZATION=.*/GPU_MEMORY_UTILIZATION=55/' "$BASE" > "$WORK/bad-gpu.conf"
sed 's/^MAX_MODEL_LEN=.*/MAX_MODEL_LEN=sixty/'                "$BASE" > "$WORK/nan-ctx.conf"
# VLLM_PORT is constrained by the local-inference policy preset (8000/8081/
# 11434/11435). Any other port builds and serves fine, then denies every chat
# with policy_denied at request time -- nowhere near the cause.
sed 's/^VLLM_PORT=.*/VLLM_PORT=8010/'                        "$BASE" > "$WORK/policy-port.conf"

for c in low-ctx bad-parser no-model missing-key port-clash bad-mode bad-gpu nan-ctx policy-port; do
  OUT="$(./install.sh --profile "$WORK/$c.conf" --print-config 2>&1)"; RC=$?
  if (( RC == 2 )); then
    pass "rejects $c" "$(strip <<<"$OUT" | grep -m1 '✗' | cut -c3-74)"
  else
    fail "rejects $c" "exit $RC -- an invalid profile was accepted"
  fi
done

# --- 5. a profile must not be able to execute code --------------------------
# A profile is data. If it can run commands, a reviewed config file becomes an
# unreviewed script.
SENTINEL="$WORK/executed"
cp "$BASE" "$WORK/inject.conf"
printf 'touch %s\n' "$SENTINEL" >> "$WORK/inject.conf"
OUT="$(./install.sh --profile "$WORK/inject.conf" --print-config 2>&1)"; RC=$?
if [[ -e "$SENTINEL" ]]; then
  fail "injection blocked" "profile executed a command"
elif (( RC == 2 )); then
  pass "injection blocked" "non-assignment line rejected, nothing ran"
else
  fail "injection blocked" "exit $RC and no sentinel -- unclear"
fi

# Every way a KEY=value line can still reach a shell. Each of these passes a
# naive "looks like an assignment" check, which is why each is tested.
i=0
for vector in \
    'PROFILE_NAME=$(touch @S@ && echo pwned)' \
    'PROFILE_NAME=`touch @S@`' \
    'PROFILE_NAME=ok; touch @S@' \
    'PROFILE_NAME=ok && touch @S@' \
    'PROFILE_NAME=$(<@S@)' \
    'PROFILE_NAME=ok | tee @S@' \
    'PROFILE_NAME=ok > @S@' \
    'MODEL_DIR=$HOME/../../$(touch @S@)' ; do
  i=$((i+1)); S="$WORK/exec_$i"
  cp "$BASE" "$WORK/inj_$i.conf"
  printf '%s\n' "${vector//@S@/$S}" >> "$WORK/inj_$i.conf"
  ./install.sh --profile "$WORK/inj_$i.conf" --print-config >/dev/null 2>&1
  if [[ -e "$S" ]]; then
    fail "shell escape $i" "EXECUTED: ${vector//@S@/<sentinel>}"
  else
    pass "shell escape $i" "refused: ${vector//@S@/<sentinel>}"
  fi
done

# Positive control for the parser: a legitimate $HOME value must still expand,
# otherwise the checks above could be passing because nothing loads at all.
OUT="$(./install.sh --profile "$BASE" --print-config 2>&1 | strip)"
if grep -qE "MODEL_DIR +${HOME}/models/" <<<"$OUT"; then
  pass "\$HOME still expands" "positive control"
else
  fail "\$HOME still expands" "parser rejects legitimate values too"
fi

# --- 5b. model completeness, including the size trap -------------------------
# metadata.total_size counts TENSOR bytes; the shard FILES are larger by their
# headers. An equality check calls a good model incomplete and sends someone
# re-downloading 18 GB. These cases exist so that cannot be reintroduced.
mkmodel() {  # dir, shard1_bytes, shard2_bytes, total_size
  local d="$1"; mkdir -p "$d"
  printf '{}' > "$d/config.json"
  head -c "$2" /dev/zero > "$d/model-00001-of-00002.safetensors"
  head -c "$3" /dev/zero > "$d/model-00002-of-00002.safetensors"
  cat > "$d/model.safetensors.index.json" <<JSON
{"metadata":{"total_size":$4},
 "weight_map":{"a":"model-00001-of-00002.safetensors",
               "b":"model-00002-of-00002.safetensors"}}
JSON
  sed -E "s#^MODEL_DIR=.*#MODEL_DIR=$d#" "$BASE" > "$d.conf"
}

# Files 2000 bytes total, index claims 1900 of tensors -> headers account for the
# difference. This is the REAL shape and must PASS.
mkmodel "$WORK/m_ok" 1000 1000 1900
if ./scripts/fetch-model.py check --profile "$WORK/m_ok.conf" --quiet >/dev/null 2>&1; then
  pass "model check: headers ok" "files larger than total_size passes"
else
  fail "model check: headers ok" "a valid model was called incomplete — the size trap"
fi

# Truncated: files smaller than the index claims must FAIL.
mkmodel "$WORK/m_short" 400 400 1900
if ./scripts/fetch-model.py check --profile "$WORK/m_short.conf" --quiet >/dev/null 2>&1; then
  fail "model check: truncation" "a truncated model was accepted"
else
  pass "model check: truncation" "shortfall detected"
fi

# A zero-byte shard is the classic interrupted download.
mkmodel "$WORK/m_zero" 0 1000 900
if ./scripts/fetch-model.py check --profile "$WORK/m_zero.conf" --quiet >/dev/null 2>&1; then
  fail "model check: zero shard" "zero-byte shard accepted"
else
  pass "model check: zero shard" "zero-byte shard detected"
fi

# A directory that merely EXISTS must not pass -- that was the original bug.
mkdir -p "$WORK/m_empty"
sed -E "s#^MODEL_DIR=.*#MODEL_DIR=$WORK/m_empty#" "$BASE" > "$WORK/m_empty.conf"
if ./scripts/fetch-model.py check --profile "$WORK/m_empty.conf" --quiet >/dev/null 2>&1; then
  fail "model check: empty dir" "an empty directory passed as a model"
else
  pass "model check: empty dir" "existence alone is not enough"
fi

# A download caught mid-flight: shards named "-of-2" but only one arrived and the
# index has not been fetched yet. This looked COMPLETE before, which would have
# let the installer proceed and fail at vLLM, and blocked `restore` from putting
# a stashed model back.
mkdir -p "$WORK/m_mid"
printf '{}' > "$WORK/m_mid/config.json"
head -c 500 /dev/zero > "$WORK/m_mid/model-00001-of-00002.safetensors"
sed -E "s#^MODEL_DIR=.*#MODEL_DIR=$WORK/m_mid#" "$BASE" > "$WORK/m_mid.conf"
if ./scripts/fetch-model.py check --profile "$WORK/m_mid.conf" --quiet >/dev/null 2>&1; then
  fail "model check: mid-download" "1-of-2 shards with no index accepted as complete"
else
  pass "model check: mid-download" "shard count from the filename catches it"
fi

# Single-file model: no -of- naming, so no index is expected and it must PASS.
mkdir -p "$WORK/m_single"
printf '{}' > "$WORK/m_single/config.json"
head -c 1000 /dev/zero > "$WORK/m_single/model.safetensors"
sed -E "s#^MODEL_DIR=.*#MODEL_DIR=$WORK/m_single#" "$BASE" > "$WORK/m_single.conf"
if ./scripts/fetch-model.py check --profile "$WORK/m_single.conf" --quiet >/dev/null 2>&1; then
  pass "model check: single file" "no index expected, accepted"
else
  fail "model check: single file" "a legitimate single-file model was rejected"
fi

# --- 6. secrets must not be committed ---------------------------------------
if git -C "$REPO" ls-files | grep -qiE 'password|htpasswd|\.env$'; then
  fail "no secrets tracked" "$(git -C "$REPO" ls-files | grep -iE 'password|htpasswd|\.env$' | tr '\n' ' ')"
else
  pass "no secrets tracked" "nothing password-shaped in git"
fi
if git -C "$REPO" grep -qiE '^[A-Z_]*(PASSWORD|SECRET|TOKEN)=[^[:space:]]' -- profiles 2>/dev/null; then
  fail "no secrets in profiles" "a profile assigns a credential"
else
  pass "no secrets in profiles" "profiles carry usernames only"
fi

# --- 7. host facts must be detected, not pinned in a profile ----------------
if grep -qE '^(HOST_BRIDGE_IP|BIND_IP)=' "$REPO"/profiles/*.conf; then
  fail "host facts not pinned" "a profile hardcodes a per-machine address"
else
  pass "host facts not pinned" "detected at runtime, overridable by flag"
fi

# --- 7b. reboot recovery: bus before enable, and no false success ----------
# A fresh-user run installed the units, failed daemon-reload with "No medium
# found", and still printed "reboot recovery installed". Two guards, because
# either half alone still ships a lie.
HS="$REPO"/scripts/install-host-services.sh
_linger=$(grep -n 'enable-linger' "$HS" | head -1 | cut -d: -f1)
_bus=$(grep -n 'XDG_RUNTIME_DIR:=' "$HS" | head -1 | cut -d: -f1)
_reload=$(grep -n 'systemctl --user daemon-reload' "$HS" | head -1 | cut -d: -f1)
if [[ -n "$_linger" && -n "$_bus" && -n "$_reload" ]] \
   && (( _linger < _bus && _bus < _reload )); then
  pass "user bus before systemctl" "linger -> bus -> daemon-reload"
else
  fail "user bus before systemctl" "enable runs before the bus is guaranteed"
fi

if grep -A2 'could not install host services' "$REPO"/install.sh \
     | grep -q 'ok "reboot recovery installed"'; then
  fail "no false reboot-recovery claim" "prints success right after the warning"
else
  pass "no false reboot-recovery claim" "success is conditional on the exit code"
fi

# --- 7c. port 8000 is checked before NemoClaw is installed ------------------
# NemoClaw onboarding hard-requires 8000 and aborts inside its own log. Without
# a preflight the user sees only "could not install NemoClaw".
_chk=$(grep -n 'dev/tcp/127.0.0.1/8000' "$REPO"/install.sh | head -1 | cut -d: -f1)
_inst=$(grep -n 'install-nemoclaw.sh' "$REPO"/install.sh | tail -1 | cut -d: -f1)
if [[ -n "$_chk" && -n "$_inst" ]] && (( _chk < _inst )); then
  pass "port 8000 preflight" "checked before NemoClaw install"
else
  fail "port 8000 preflight" "missing or runs after the install it protects"
fi

# --- 7d. factory reset must not skip supporting containers -----------------
# --everything uninstalls NemoClaw first, wiping the sandbox registry, so the
# teardown that follows has no targets. An early return there left the vLLM
# server and dashboard proxy up, still holding 8000 and 18796.
if python3 - "$REPO"/scripts/reset.py <<'PYCHK'
import ast, sys
src = open(sys.argv[1]).read()
fn = next(n for n in ast.parse(src).body
          if isinstance(n, ast.FunctionDef) and n.name == "cmd_down")
guard = fn.body[0]
ok = isinstance(guard, ast.If) and any(
    isinstance(x, ast.Return) and isinstance(x.value, ast.Constant)
    for x in ast.walk(guard))
# an unconditional `return 0` as the whole body is the regression
bad = ok and all(isinstance(x, (ast.Expr, ast.Return)) for x in guard.body) \
         and any(isinstance(x, ast.Return) for x in guard.body) \
         and not any(isinstance(x, ast.If) for x in guard.body)
sys.exit(1 if bad else 0)
PYCHK
then
  pass "factory reset cleans aux" "no unconditional early return in cmd_down"
else
  fail "factory reset cleans aux" "empty selection skips vLLM/dashboard teardown"
fi

# --- 7e. our vLLM must reclaim the port from NemoClaw's own ----------------
# NemoClaw onboarding starts a vLLM on the same port. On an established box its
# container had already exited, so this only bites a from-zero install.
if grep -q 'nemoclaw-vllm' "$REPO"/scripts/start-model.sh \
   && grep -q 'filter "publish=${VLLM_PORT}"' "$REPO"/scripts/start-model.sh; then
  pass "reclaims vLLM port" "NemoClaw's own vLLM is replaced, not fought"
else
  fail "reclaims vLLM port" "docker will refuse to publish an already-published port"
fi

# --- 7f. every message helper a script calls must exist in it --------------
# install.sh defines phase/ok/note/die but not warn, so `warn "..."` died at
# runtime with "command not found" -- after the check it was reporting on.
# bash -n cannot catch this; the call is valid syntax.
for f in "$REPO"/install.sh; do
  _missing=""
  for h in phase ok note die warn; do
    grep -qE "^[[:space:]]*$h " "$f" || continue
    grep -qE "^$h\\(\\)" "$f" || _missing="$_missing $h"
  done
  if [[ -z "$_missing" ]]; then
    pass "message helpers defined" "$(basename "$f")"
  else
    fail "message helpers defined" "$(basename "$f") calls but never defines:$_missing"
  fi
done

# --- 7g. pipefail + set -e: assignments from grep pipelines need || true ----
# `x=$(cmd | grep ...)` exits the whole script when grep matches nothing, because
# pipefail propagates grep's 1 and a failing assignment trips errexit. This
# reported reboot recovery as failed immediately after every check had passed.
_unguarded=""
for f in "$REPO"/install.sh "$REPO"/scripts/*.sh; do
  grep -qE '^set -[a-z]*e' "$f" || continue
  grep -qE 'pipefail' "$f" || continue
  while IFS= read -r ln; do
    [[ "$ln" == *"|| true"* ]] && continue
    [[ "$ln" == *"||"* ]] && continue
    _unguarded="$_unguarded $(basename "$f")"
  done < <(grep -hE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*\$\(.*\|[[:space:]]*grep' "$f")
done
if [[ -z "$_unguarded" ]]; then
  pass "grep pipelines in assignments" "guarded against pipefail exits"
else
  fail "grep pipelines in assignments" "unguarded in:$_unguarded"
fi

# --- 7h. OpenShell container names carry a profile segment -----------------
# Real names are openshell-<profile>--<sandbox>-<uuid>. Matching
# "openshell-<sandbox>-" found nothing, so healthcheck reported a healthy
# install as broken and reset.py only tore sandboxes down via its orphan sweep.
if grep -q 'openshell-(.+--)?' "$REPO"/scripts/healthcheck.sh \
   && grep -q 'openshell-(.+--)?' "$REPO"/scripts/reset.py; then
  pass "sandbox name matching" "optional profile segment handled"
else
  fail "sandbox name matching" "assumes openshell-<sandbox>-<uuid>"
fi

# --- 7i. any systemctl --user caller must set up the bus first --------------
for f in "$REPO"/scripts/healthcheck.sh "$REPO"/scripts/install-host-services.sh; do
  # Comment lines explaining the fix also contain the string; match code only.
  grep -qE '^[[:space:]]*[^#[:space:]].*systemctl --user' "$f" || continue
  _b=$(grep -n 'XDG_RUNTIME_DIR:=' "$f" | head -1 | cut -d: -f1)
  _u=$(grep -nE '^[[:space:]]*[^#[:space:]].*systemctl --user' "$f" | head -1 | cut -d: -f1)
  if [[ -n "$_b" ]] && (( _b < _u )); then
    pass "user bus set up first" "$(basename "$f")"
  else
    fail "user bus set up first" "$(basename "$f") calls systemctl --user with no XDG_RUNTIME_DIR"
  fi
done

# --- 7j. teardown must not report success after skipping steps -------------
# Run without ~/.local/bin on PATH, reset.py could not find nemohermes or
# openshell, swallowed the FileNotFoundError, removed nothing and exited 0.
if grep -q '_LOCAL_BIN' "$REPO"/scripts/reset.py \
   && grep -q 'except FileNotFoundError' "$REPO"/scripts/reset.py \
   && grep -q 'teardown INCOMPLETE' "$REPO"/scripts/reset.py; then
  pass "teardown reports skips" "PATH fixed and skipped steps fail the run"
else
  fail "teardown reports skips" "missing tools are swallowed and it still exits 0"
fi

# --- 7k. the Node we install must be removable -----------------------------
# Merged into ~/.local it was indistinguishable from the user's own files, so
# uninstall left it and the next install skipped the step, never testing it.
if grep -q 'lib/hermes-quickstart/node' "$REPO"/scripts/install-hermes-host.sh \
   && grep -q 'lib/hermes-quickstart/node' "$REPO"/scripts/uninstall-hermes-host.sh; then
  pass "installed Node is removable" "own prefix, uninstalled by prefix"
else
  fail "installed Node is removable" "merged into ~/.local and cannot be told apart"
fi

# --- 7l. pty uninstallers must not read from the terminal ------------------
# script -qec gives these uninstallers the tty they demand, but with stdin left
# on the terminal a backgrounded teardown takes SIGTTIN and stops forever.
_bad=""
for f in "$REPO"/scripts/uninstall-nemoclaw.sh "$REPO"/scripts/uninstall-hermes-host.sh; do
  while IFS= read -r ln; do
    [[ "$ln" == *"</dev/null"* ]] || _bad="$_bad $(basename "$f")"
  done < <(grep -h 'script -qec' "$f")
done
if [[ -z "$_bad" ]]; then
  pass "pty uninstall is detachable" "stdin redirected, no SIGTTIN stall"
else
  fail "pty uninstall is detachable" "stdin left on the terminal in:$_bad"
fi

# --- 7m. reinstall after teardown must not hit a stale onboarding session ---
# NemoClaw keeps a saved onboarding session that outlives its own uninstaller.
# The second install on a machine then refuses to onboard, which defeats the
# entire reset-and-reinstall cycle.
if grep -q 'NC_FRESH' "$REPO"/scripts/install-nemoclaw.sh \
   && grep -q 'state/nemoclaw' "$REPO"/scripts/uninstall-nemoclaw.sh; then
  pass "reinstall survives stale session" "--fresh retry and state dir removed"
else
  fail "reinstall survives stale session" "second install will refuse to onboard"
fi

# --- 7n. root-owned HF cache must be repaired before onboarding ------------
# NemoClaw's vLLM container runs as root and leaves root-owned files in the
# user's ~/.cache/huggingface, which blocks every later install.
if grep -q 'HF_CACHE' "$REPO"/scripts/install-nemoclaw.sh \
   && grep -q 'chown -R' "$REPO"/scripts/install-nemoclaw.sh; then
  pass "HF cache ownership repaired" "reinstall not blocked by root-owned files"
else
  fail "HF cache ownership repaired" "second install will abort as not writable"
fi

# --- 7n2. NemoClaw must install for Hermes with onboarding deferred --------
# Unattended and with no agent selected, NVIDIA's installer onboards its own
# OpenClaw sandbox plus a ~50 GB vLLM, and that sandbox takes the gateway's only
# inference route, so the route preflight refuses to install Hermes.
_nc="$REPO"/scripts/install-nemoclaw.sh
if grep -q 'NEMOCLAW_AGENT=hermes' "$_nc" && grep -q -- '--defer-onboarding' "$_nc" \
   && grep -q 'NVIDIA_API_KEY' "$_nc" && grep -q 'NEMOCLAW_INSTALL_TAG=' "$_nc"; then
  pass "NemoClaw onboard deferred" "hermes agent, credentials scrubbed, tag pinned"
else
  fail "NemoClaw onboard deferred" "installer would onboard its own sandbox + vLLM"
fi

# --- 7o. a failed dashboard phase must not print the success banner --------
# expose-dashboard.sh fails closed and removes the proxy. install.sh caught that
# with `|| EXPOSED=0` and still printed "Done" plus the dashboard URL.
if grep -q 'dashboard is NOT up' "$REPO"/install.sh; then
  pass "degraded install is reported" "no success banner without a dashboard"
else
  fail "degraded install is reported" "prints Done and a URL that does not serve"
fi

# --- 7p. NemoClaw 0.0.137 layout: MCP line retired, gateway owns restarts ---
mcpv() { hermes_mcp_verdict "$1" | cut -d' ' -f1; }
[[ "$(mcpv $'aaa  config.yaml\nbbb  .env')" == na ]] \
  && pass "MCP digest: retired" "two-line anchor reports n/a, not WARN" \
  || fail "MCP digest: retired" "two-line anchor not treated as n/a"
[[ "$(mcpv $'aaa\nbbb\nmcp intended=x1 applied=x1')" == pass ]] \
  && [[ "$(mcpv $'aaa\nbbb\nmcp intended=x1 applied=x2')" == fail ]] \
  && pass "MCP digest: older layout" "match passes, mismatch fails" \
  || fail "MCP digest: older layout" "intended/applied comparison broken"
rv() { hermes_restart_verdict "$1" "$2" | cut -d' ' -f1; }
[[ "$(rv no 1)" == pass && "$(rv no 0)" == fail && "$(rv unless-stopped 0)" == pass ]] \
  && pass "restart policy verdict" "'no' passes only with the shutdown hook" \
  || fail "restart policy verdict" "no=$(rv no 1)/$(rv no 0) unless-stopped=$(rv unless-stopped 0)"
# The old verdict claimed the gateway user service brings the sandbox back. A
# real reboot (2026-10-23) disproved it: the sandbox came back in Phase: Error.
if grep -q 'brings it back' scripts/lib/common.sh scripts/healthcheck.sh; then
  fail "no gateway-restart claim" "healthcheck still says the gateway unit restarts the sandbox"
else
  pass "no gateway-restart claim" "disproved claim removed"
fi

# --- 7t. reboot survival on NemoClaw 0.0.137 --------------------------------
# (a) Ordering cycle. The gateway unit is After=default.target; the restore unit
# is WantedBy=default.target; ordering restore After=gateway closed the loop and
# systemd deleted the restore job at boot -- it never ran.
_ru=host/hermes-stack-restore.service
if grep -E '^After=' "$_ru" | grep -q 'nemoclaw-openshell-gateway'; then
  fail "no ordering cycle" "$_ru is ordered After= the gateway unit (cycle via default.target)"
elif ! grep -q '^WantedBy=default.target' "$_ru"; then
  fail "no ordering cycle" "$_ru no longer WantedBy=default.target -- will not start at boot"
else
  pass "no ordering cycle" "restore is not ordered after the gateway"
fi
# (b) Shutdown hook: stop order is the reverse of start order, so it must be
# After= docker AND the user manager (the gateway lives there) to run first.
_su=host/hermes-sandbox-shutdown.service
if grep -E '^After=' "$_su" | grep -q 'docker.service' \
   && grep -E '^After=' "$_su" | grep -q 'user@@UID@.service' \
   && grep -q '^RemainAfterExit=yes' "$_su" \
   && grep -q '^ExecStop=.*hermes-sandbox-stop' "$_su" \
   && grep -q "$_su\|SHUTDOWN_UNIT=hermes-sandbox-shutdown.service" scripts/install-host-services.sh; then
  pass "shutdown hook ordered" "stops the sandbox before docker and the gateway"
else
  fail "shutdown hook ordered" "sandbox is killed by docker at shutdown -> Phase: Error"
fi
_r=$(sed -e 's|@USER@|u|g' -e 's|@UID@|1000|g' -e 's|@HOME@|/home/u|g' \
         -e 's|@SANDBOX@|sb|g' -e 's|@AGENT_CLI@|nemohermes|g' "$_su")
grep -qE '@[A-Z_]+@' <<<"$(grep -v '^#' <<<"$_r")" \
  && fail "shutdown unit renders" "placeholder left after rendering" \
  || pass "shutdown unit renders" "every @...@ placeholder filled"
# (c) The hook must not stop a live demo when someone runs systemctl stop.
grep -q 'is-system-running' host/hermes-sandbox-stop \
  && pass "hook only at shutdown" "manual stop leaves the sandbox alone" \
  || fail "hook only at shutdown" "systemctl stop would stop the live sandbox"
# (d) Restore starts a Stopped sandbox with the vendor command, and refuses to
# pretend about Error.
_rs=host/hermes-stack-restore
if grep -q '"$AGENT_CLI" "$SANDBOX" start' "$_rs" && grep -q 'Error)' "$_rs" \
   && grep -q 'stopped-for-shutdown' "$_rs" && grep -q 'stopped-for-shutdown' host/hermes-sandbox-stop; then
  pass "restore starts Stopped" "vendor start after a shutdown stop; Error reported"
else
  fail "restore starts Stopped" "a cleanly stopped sandbox would stay down after boot"
fi
# (e) Phase parser handles OpenShell's colour codes, and only Ready is healthy.
_ph=$(printf '\033[1m\033[36mSandbox:\033[39m\033[0m\n  \033[2mName:\033[0m sb\n  \033[2mPhase:\033[0m Error\n' | hermes_parse_phase)
[[ "$_ph" == Error ]] && grep -q 'pass "sandbox Ready"' scripts/healthcheck.sh \
  && pass "phase parsed" "ANSI table -> '$_ph'; healthcheck requires Ready" \
  || fail "phase parsed" "got '$_ph'"
# The phase probe runs under set -e -o pipefail in hermes-stack-restore. A
# reader that exited at the first match SIGPIPE'd the pipeline and killed the
# restore unit (status 4) the first time it saw a Stopped sandbox.
_pp=$(bash -c 'set -euo pipefail; . scripts/lib/common.sh
  openshell() { printf "  Phase: Stopped\n"; yes filler | head -50000; }
  a="$(hermes_sandbox_phase sb)"; openshell() { return 3; }
  b="$(hermes_sandbox_phase sb)"; echo "$a|$b|ok"' 2>/dev/null)
[[ "$_pp" == "Stopped||ok" ]] \
  && pass "phase probe set -e safe" "long output and a failing CLI do not abort the caller" \
  || fail "phase probe set -e safe" "got '$_pp' -- would kill hermes-stack-restore"
# (f) Cycle detector.
_cy=$(journalctl() { printf '%s\n' 'systemd[1]: default.target: Job hermes-stack-restore.service/start deleted to break ordering cycle starting with default.target/start'; }
      hermes_ordering_cycle_units | head -1)
[[ "$_cy" == hermes-stack-restore.service ]] \
  && pass "cycle detector" "deleted job named from the journal" \
  || fail "cycle detector" "got '$_cy'"

# --- 7q. the network dashboard proxy survives a reboot ----------------------
# It was started with no restart policy and nothing restarted it, so the
# published dashboard port was dead after every reboot.
if grep -A1 'docker run -d --name "$PROXY_NAME"' scripts/expose-dashboard.sh \
     | grep -q -- '--restart unless-stopped' \
   && grep -q 'docker start "$DASH"' host/hermes-stack-restore; then
  pass "dashboard proxy restarts" "restart policy + reboot path starts it"
else
  fail "dashboard proxy restarts" "the :${DASHBOARD_PUBLIC_PORT:-18796} proxy stays down after a reboot"
fi

# --- 7r. factory reset: exact rc blocks only --------------------------------
if python3 - "$REPO"/scripts/reset.py <<'PYCHK'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("reset", sys.argv[1])
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
user = "# mine\nalias ll='ls -l'\nexport NVM_DIR=\"$HOME/.nvm-custom\"\n"
nvm = ('\nexport NVM_DIR="$HOME/.nvm"\n'
       '[ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"  # This loads nvm\n'
       '[ -s "$NVM_DIR/bash_completion" ] && \\. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion\n')
nc = '\n# NemoClaw PATH setup\nexport PATH="/home/u/.local/bin:$PATH"\n# end NemoClaw PATH setup\n'
npm = '\n# Added by NemoClaw installer\nexport PATH="$HOME/.npm-global/bin:$PATH"\n'
tail = "echo after\n"
blocks = r.NEMOCLAW_RC_BLOCKS + [r.NVM_RC_BLOCK]
out, found = r.strip_rc_blocks(user + nvm + nc + npm + tail, blocks)
assert out == user + tail, repr(out)
assert sorted(l for l, _ in found) == sorted(["nvm loader", "NemoClaw PATH setup",
                                              "NemoClaw npm-global PATH"]), found
# A near-miss (edited by the user) must survive untouched.
edited = user + nvm.replace("# This loads nvm\n", "# my nvm\n", 1) + tail
out2, found2 = r.strip_rc_blocks(edited, [r.NVM_RC_BLOCK])
assert out2 == edited and not found2, repr(out2)
# No blank line before the block: the previous line must not be joined.
out3, _ = r.strip_rc_blocks("a\n" + nc.lstrip("\n") + "b\n", blocks)
assert out3 == "a\nb\n", repr(out3)
PYCHK
then
  pass "rc blocks: exact match" "installer lines removed, user lines byte-identical"
else
  fail "rc blocks: exact match" "would remove or mangle lines it did not add"
fi

# --- 7s. factory reset dry run: finds residue, keeps the user's, changes nothing
# Runs reset.py against a throwaway HOME, so nothing on this machine is read
# from or written to the real home directory. Dry run only: no --yes.
FH="$WORK/fakehome"; mkdir -p "$FH/.npm" "$FH/.local/bin" "$FH/.local/state"
printf 'export EDITOR=vi\n' > "$FH/.bashrc"
# A stub docker first on PATH: this machine's real images and build cache must
# not decide what a test expects. It reports what STUB_BUILD_CACHE (record count)
# and STUB_LOGS (a file served as `docker logs`) say, and nothing else.
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/docker" <<'STUBDOCKER'
#!/bin/sh
case "$1" in
  logs) [ -n "$STUB_LOGS" ] && cat "$STUB_LOGS" ;;
  system) [ -n "$STUB_BUILD_CACHE" ] && printf 'Images\t5\t1GB\nBuild Cache\t%s\t33.2GB\n' "$STUB_BUILD_CACHE" ;;
  builder) echo "$*" >> "${STUB_LOG:-/dev/null}" ;;
esac
exit 0
STUBDOCKER
chmod +x "$STUB/docker"
rhome() { env -u HF_HOME HOME="$FH" XDG_STATE_HOME="$FH/.local/state" \
            PATH="$STUB:/usr/local/bin:/usr/bin:/bin" python3 "$REPO"/scripts/reset.py "$@" 2>&1 | strip; }
rhome record-preinstall >/dev/null
REC="$FH/.local/state/hermes-quickstart/preinstall.json"
# ...then what an install adds on top of the machine it found:
mkdir -p "$FH/.nvm/versions" "$FH/.config/openshell" "$FH/flashinfer-cache/x" \
         "$FH/models/unsloth_Qwen3.8-27B-NVFP4" "$FH/.config/systemd/user"
: > "$FH/.local/bin/nemoclaw-acp"
printf '# NEMOCLAW_MANAGED_OPENSHELL_GATEWAY=1\n[Service]\n' \
  > "$FH/.config/systemd/user/nemoclaw-openshell-gateway.service"
cat >> "$FH/.bashrc" <<'RC'

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
RC
before="$(cd "$FH" && find . | sort | md5sum; md5sum .bashrc)"
OUT="$(rhome down --everything)"
after="$(cd "$FH" && find . | sort | md5sum; md5sum .bashrc)"
_miss=""
for want in "rm $FH/.local/bin/nemoclaw-acp" \
            "systemctl --user disable --now nemoclaw-openshell-gateway.service" \
            "rm -r $FH/.config/openshell" "rm -r $FH/flashinfer-cache" \
            "rm -r $FH/models/unsloth_Qwen3.8-27B-NVFP4" "rm -r $FH/.nvm" \
            "remove 'nvm loader' block" "keep $FH/.npm -- existed before"; do
  grep -qF -- "$want" <<<"$OUT" || _miss="$_miss [$want]"
done
if [[ -f "$REC" && -z "$_miss" ]]; then
  pass "factory reset residue" "install-created items listed, pre-existing kept"
else
  fail "factory reset residue" "missing:${_miss:- (no install record written)}"
fi
[[ "$before" == "$after" ]] && grep -qE 'dry run|nothing selected' <<<"$OUT" \
  && pass "factory reset dry run inert" "fake HOME unchanged" \
  || fail "factory reset dry run inert" "a dry run changed files"
# Without a record, shared tools are the user's until proven otherwise.
rm -f "$REC"
OUT="$(rhome down --everything)"
grep -qF "keep $FH/.nvm -- no install record" <<<"$OUT" \
  && ! grep -qF "remove 'nvm loader' block" <<<"$OUT" \
  && pass "no record keeps shared tools" "~/.nvm and its rc lines kept" \
  || fail "no record keeps shared tools" "would remove ~/.nvm with no proof the install made it"
OUT="$(rhome doctor)"
grep -q 'INSTALL RESIDUE' <<<"$OUT" \
  && pass "doctor reports residue" "leftovers flagged once NemoClaw is gone" \
  || fail "doctor reports residue" "leftovers not reported"

# --- 7s2. a record is evidence only if taken on an untouched machine ---------
# The 2026-10-25 failure: a record taken after an install had begun listed that
# install's own ~/.nvm, ~/.npm and OpenShell config as "existed before", so a
# factory reset kept them all and doctor's advice (re-run the reset) was circular.
# Recorded below on a machine that already has install residue.
rec_json() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"; }
FH2="$WORK/fakehome2"
mkdir -p "$FH2/.nvm" "$FH2/.npm" "$FH2/.config/openshell" "$FH2/flashinfer-cache" \
         "$FH2/models/unsloth_Qwen3.8-27B-NVFP4" "$FH2/.local/state"
printf 'export EDITOR=vi\n' > "$FH2/.bashrc"
cat >> "$FH2/.bashrc" <<'RC'

# NemoClaw PATH setup
export PATH="/home/u/.local/bin:$PATH"
# end NemoClaw PATH setup

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
RC
rhome2() { env -u HF_HOME HOME="$FH2" XDG_STATE_HOME="$FH2/.local/state" \
             PATH="$STUB:/usr/local/bin:/usr/bin:/bin" python3 "$REPO"/scripts/reset.py "$@" 2>&1 | strip; }
REC2="$FH2/.local/state/hermes-quickstart/preinstall.json"
rhome2 record-preinstall >/dev/null
if [[ "$(rec_json "$REC2" bare)" == "False" ]]; then
  pass "record: untrusted when late" "taken over install residue -> bare=false"
else
  fail "record: untrusted when late" "a record over install residue claims the machine was bare"
fi
OUT="$(rhome2 down --everything)"
_miss=""
for want in "rm -r $FH2/.config/openshell" "rm -r $FH2/flashinfer-cache" \
            "remove 'NemoClaw PATH setup' block" \
            "keep $FH2/.nvm -- the install record was taken after an install had begun" \
            "keep $FH2/.npm -- the install record was taken after an install had begun" \
            "--assume-bare-origin"; do
  grep -qF -- "$want" <<<"$OUT" || _miss="$_miss [$want]"
done
[[ -z "$_miss" ]] \
  && pass "untrusted record: no guessing" "installer-only residue removed; shared tools kept, with the flag named" \
  || fail "untrusted record: no guessing" "missing:$_miss"
OUT="$(rhome2 doctor)"
grep -q 'CANNOT BE ATTRIBUTED' <<<"$OUT" && grep -q -- '--assume-bare-origin' <<<"$OUT" \
  && pass "doctor: advice not circular" "names the flag, not 're-run reset'" \
  || fail "doctor: advice not circular" "untrusted record gave no actionable advice"
OUT="$(rhome2 down --everything --assume-bare-origin)"
_miss=""
for want in "rm -r $FH2/.nvm" "rm -r $FH2/.npm" "rm -r $FH2/models/unsloth_Qwen3.8-27B-NVFP4" \
            "remove 'nvm loader' block"; do
  grep -qF -- "$want" <<<"$OUT" || _miss="$_miss [$want]"
done
[[ -z "$_miss" ]] \
  && pass "--assume-bare-origin" "shared tools, weights and loader lines now listed" \
  || fail "--assume-bare-origin" "missing:$_miss"
# ...and a TRUSTED record outranks the flag: what it says pre-existed stays.
FH3="$WORK/fakehome3"; mkdir -p "$FH3/.npm" "$FH3/.local/state"
printf 'export EDITOR=vi\n' > "$FH3/.bashrc"
rhome3() { env -u HF_HOME HOME="$FH3" XDG_STATE_HOME="$FH3/.local/state" \
             PATH="$STUB:/usr/local/bin:/usr/bin:/bin" python3 "$REPO"/scripts/reset.py "$@" 2>&1 | strip; }
rhome3 record-preinstall >/dev/null
[[ "$(rec_json "$FH3/.local/state/hermes-quickstart/preinstall.json" bare)" == "True" ]] \
  && pass "record: trusted when bare" "taken on an untouched machine -> bare=true" \
  || fail "record: trusted when bare" "a record on a bare machine is not marked bare"
mkdir -p "$FH3/.nvm"
OUT="$(rhome3 down --everything --assume-bare-origin)"
grep -qF "keep $FH3/.npm -- existed before the install" <<<"$OUT" \
  && grep -qF "rm -r $FH3/.nvm" <<<"$OUT" \
  && pass "trusted record wins" "pre-existing ~/.npm kept even with --assume-bare-origin" \
  || fail "trusted record wins" "a pre-existing directory would be deleted"
# An untrusted record is replaced once the machine is bare again.
FH4="$WORK/fakehome4"; mkdir -p "$FH4/.local/state"
rhome4() { env -u HF_HOME HOME="$FH4" XDG_STATE_HOME="$FH4/.local/state" \
             PATH="$STUB:/usr/local/bin:/usr/bin:/bin" python3 "$REPO"/scripts/reset.py "$@" 2>&1 | strip; }
mkdir -p "$FH4/.local/state/hermes-quickstart"
printf '{"recorded":"old","paths":{"nvm":true,"openshell-config":true},"rc_blocks":{}}\n' \
  > "$FH4/.local/state/hermes-quickstart/preinstall.json"
rhome4 record-preinstall >/dev/null
[[ "$(rec_json "$FH4/.local/state/hermes-quickstart/preinstall.json" bare)" == "True" ]] \
  && pass "stale record replaced" "an untrusted legacy record is re-taken on a bare machine" \
  || fail "stale record replaced" "the stale record was kept"
# ...but not while it still vouches for something that is here: a fresh record
# would then call that thing pre-existing for good (the circularity).
mkdir -p "$FH4/.nvm"
printf '{"recorded":"old","paths":{"nvm":true,"openshell-config":true},"rc_blocks":{}}\n' \
  > "$FH4/.local/state/hermes-quickstart/preinstall.json"
OUT="$(rhome4 record-preinstall)"
[[ "$(rec_json "$FH4/.local/state/hermes-quickstart/preinstall.json" recorded)" == "old" ]] \
  && pass "unresolved record kept" "an untrusted record is not replaced while ~/.nvm it vouches for remains" \
  || fail "unresolved record kept" "a fresh record would call the install's ~/.nvm pre-existing"
OUT="$(rhome2 down --everything)"
grep -qF "keep $FH2/.local/state/hermes-quickstart/preinstall.json -- items above are still unattributed" <<<"$OUT" \
  && pass "reset keeps the record" "kept while unattributed items remain, so the next install cannot launder them" \
  || fail "reset keeps the record" "reset deletes the record and leaves the items to be re-recorded as pre-existing"
# Docker build cache: removed only if the record shows there was none before.
FH5="$WORK/fakehome5"; mkdir -p "$FH5/.local/state"; : > "$FH5/.bashrc"
rhome5() { env -u HF_HOME HOME="$FH5" XDG_STATE_HOME="$FH5/.local/state" \
             PATH="$STUB:/usr/local/bin:/usr/bin:/bin" python3 "$REPO"/scripts/reset.py "$@" 2>&1 | strip; }
rhome5 record-preinstall >/dev/null               # no build cache at record time
OUT="$(STUB_BUILD_CACHE=47 rhome5 down --everything)"
grep -qF "docker builder prune --all --force  (docker build cache (33.2GB))" <<<"$OUT" \
  && pass "build cache removed" "none before the install, 47 records after -> pruned" \
  || fail "build cache removed" "the install's build cache survives --everything"
rm -f "$FH5/.local/state/hermes-quickstart/preinstall.json"
STUB_BUILD_CACHE=3 rhome5 record-preinstall >/dev/null   # the user already had one
OUT="$(STUB_BUILD_CACHE=47 rhome5 down --everything --assume-bare-origin)"
grep -qF "keep docker build cache (33.2GB) -- existed before the install" <<<"$OUT" \
  && ! grep -qF "builder prune" <<<"$OUT" \
  && pass "build cache: user's kept" "present at record time -> never pruned" \
  || fail "build cache: user's kept" "would prune a build cache the user already had"

# --- 7v. vLLM exit-time SIGSEGV: retried, but only for exactly that signature --
# The NGC torch segfaults in an atexit finalizer after vLLM's model-inspection
# subprocess has already answered; vLLM reads the exit status and gives up. A
# retry must fire for that, and for nothing else (a real failure must stay loud).
printf '%s\n' "(APIServer pid=1) ERROR subprocess.CalledProcessError: Command '['/usr/bin/python', '-m', 'vllm.model_executor.models.registry']' died with <Signals.SIGSEGV: 11>." \
  > "$WORK/vllm-segv.log"
printf '%s\n' "(EngineCore pid=9) torch.OutOfMemoryError: CUDA out of memory" > "$WORK/vllm-oom.log"
printf '%s\n' "Command '['/usr/bin/python', '-m', 'something.else']' died with <Signals.SIGSEGV: 11>." > "$WORK/vllm-other.log"
_crashed() { ( PATH="$STUB:$PATH"; . scripts/lib/common.sh; STUB_LOGS="$1" hermes_vllm_inspect_crashed c ) 2>/dev/null; }
if _crashed "$WORK/vllm-segv.log" && ! _crashed "$WORK/vllm-oom.log" && ! _crashed "$WORK/vllm-other.log"; then
  pass "vLLM crash signature" "SIGSEGV in the registry inspection matches; OOM and other crashes do not"
else
  fail "vLLM crash signature" "retry would fire on the wrong failure, or miss the right one"
fi
if grep -q 'hermes_vllm_inspect_crashed' scripts/start-model.sh \
   && grep -q 'START_ATTEMPT < HERMES_VLLM_START_ATTEMPTS' scripts/start-model.sh \
   && grep -q 'hermes_vllm_inspect_crashed' host/hermes-stack-restore \
   && grep -q 'VLLM_START" -lt "\$HERMES_VLLM_START_ATTEMPTS' host/hermes-stack-restore \
   && [[ "$(grep -c '↻\|hit the known NVIDIA-image' scripts/start-model.sh)" -ge 1 ]]; then
  pass "vLLM start retry wired" "installer and boot restore both retry, bounded"
else
  fail "vLLM start retry wired" "start-model.sh or hermes-stack-restore lacks the bounded retry"
fi

# --- 7u. the active OpenShell gateway must be one that listens ---------------
# 2026-10-23: a sandbox-only reinstall walked off 8080 (held by OUR gateway) to
# 8082, NemoClaw made nemoclaw-8082 active, and after the next shutdown nothing
# served it. Every openshell call was refused; the hook read "no phase" as
# "nothing to stop" and docker SIGKILLed the sandbox.
GH="$WORK/gwhome"; GC="$GH/.config/openshell"; mkdir -p "$GC/gateways" "$GH/.nemoclaw/gateways/8082"
_lsn="$WORK/listen.port"
python3 -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(8)
open(sys.argv[1],"w").write(str(s.getsockname()[1])); time.sleep(120)' "$_lsn" &
_lsn_pid=$!
for _ in $(seq 1 50); do [[ -s "$_lsn" ]] && break; sleep 0.1; done
LIVE="$(cat "$_lsn" 2>/dev/null)"
DEAD="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
mkgw() { mkdir -p "$GC/gateways/$1"; printf '{"name":"%s","gateway_endpoint":"https://127.0.0.1:%s","auth_mode":"mtls"}\n' "$1" "$2" > "$GC/gateways/$1/metadata.json"; }
mkgw nemoclaw "$LIVE"; mkgw nemoclaw-8082 "$DEAD"
printf 'nemoclaw-8082\n' > "$GC/active_gateway"
printf '{"sandboxes":{"sb":{"name":"sb","gatewayName":"nemoclaw-8082","gatewayPort":8082}}}\n' \
  > "$GH/.nemoclaw/gateways/8082/sandboxes.json"
gwsh() { HOME="$GH" XDG_CONFIG_HOME="$GH/.config" NEMOCLAW_HOME="$GH/.nemoclaw" \
           bash -c '. scripts/lib/common.sh; unset OPENSHELL_GATEWAY; '"$1" 2>/dev/null; }
_v="$(gwsh 'hermes_gateway_verdict nemoclaw')"
[[ "$_v" == fail*"nemoclaw-8082"*"expected 'nemoclaw'"* ]] \
  && pass "gateway: wrong active" "nemoclaw-8082 active -> fail" \
  || fail "gateway: wrong active" "got '$_v'"
_v="$(gwsh 'hermes_gateway_verdict')"
[[ "$_v" == fail*"not listening"* ]] \
  && pass "gateway: dead active" "nothing on the active endpoint -> fail" \
  || fail "gateway: dead active" "got '$_v'"
printf 'nemoclaw\n' > "$GC/active_gateway"
_v="$(gwsh 'hermes_gateway_verdict nemoclaw')"
[[ "$_v" == pass* ]] && pass "gateway: positive control" "listening nemoclaw -> pass" \
                     || fail "gateway: positive control" "got '$_v'"
printf 'nemoclaw-8082\n' > "$GC/active_gateway"
_v="$(gwsh 'hermes_sandbox_gateway sb; g=$(hermes_gateway_pin sb); echo "$g|$OPENSHELL_GATEWAY"' | tr '\n' ' ')"
[[ "$_v" == "nemoclaw-8082 nemoclaw|" || "$_v" == "nemoclaw-8082 nemoclaw| " ]] \
  && pass "gateway pin" "per-port registry read; dead gateway skipped for a live one" \
  || fail "gateway pin" "got '$_v'"
_v="$(gwsh 'g=$(hermes_gateway_pin sb) && export OPENSHELL_GATEWAY=$g; echo "$OPENSHELL_GATEWAY"')"
[[ "$_v" == nemoclaw ]] && pass "gateway pin exports" "OPENSHELL_GATEWAY=nemoclaw" \
                        || fail "gateway pin exports" "got '$_v'"

# The port walk must keep a port held by our own gateway, and still walk away
# from a stranger (positive control).
_pw() { ( . scripts/lib/profile.sh 2>/dev/null
  ss() { [[ "$*" == *p* ]] && echo 'LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:(("x",pid=1,fd=3))' \
                           || echo 'LISTEN 0 128 127.0.0.1:8080 0.0.0.0:*'; }
  systemctl() { return "$1"; }
  NEMOCLAW_GATEWAY_PORT=8080 CONTROL_UI_PORT=18795 DASHBOARD_PUBLIC_PORT=18796
  XDG_CONFIG_HOME="$2"
  systemctl() { return "$_sc"; }; _sc="$1"
  profile_resolve_free_ports 2>/dev/null; echo "$NEMOCLAW_GATEWAY_PORT" ) ; }
mkdir -p "$WORK/gwenv/openshell"; printf 'OPENSHELL_SERVER_PORT=8080\n' > "$WORK/gwenv/openshell/gateway.env"
_a="$(_pw 0 "$WORK/gwenv")"; _b="$(_pw 0 "$WORK/nowhere")"; _c="$(_pw 1 "$WORK/gwenv")"
[[ "$_a" == 8080 && "$_b" == 8082 && "$_c" == 8082 ]] \
  && pass "own gateway port kept" "ours: 8080 kept; stranger: 8082 (8081 reserved)" \
  || fail "own gateway port kept" "ours=$_a stranger=$_b unit-down=$_c (want 8080/8082/8082)"

# reset.py sees the per-port registry, flags the dead active gateway, and its
# teardown plans the documented fix.
rgw() { env -u HF_HOME HOME="$GH" XDG_STATE_HOME="$GH/.local/state" XDG_CONFIG_HOME="$GH/.config" \
          PATH=/usr/local/bin:/usr/bin:/bin python3 "$REPO"/scripts/reset.py "$@" 2>&1 | strip; }
OUT="$(rgw doctor)"
grep -q 'ACTIVE GATEWAY NOT LISTENING' <<<"$OUT" && grep -q 'SANDBOX ON A NON-DEFAULT GATEWAY' <<<"$OUT" \
  && pass "doctor: gateway" "dead active gateway and 8082 sandbox reported" \
  || fail "doctor: gateway" "not reported"
OUT="$(rgw down --sandbox sb)"
grep -qF 'NEMOCLAW_GATEWAY_PORT=8082 nemohermes sb destroy' <<<"$OUT" \
  && grep -qF 'openshell gateway remove nemoclaw-8082' <<<"$OUT" \
  && grep -qF 'openshell gateway select nemoclaw' <<<"$OUT" \
  && ! grep -q 'is not registered' <<<"$OUT" \
  && pass "down: stale gateway" "destroy on 8082, remove nemoclaw-8082, select nemoclaw" \
  || fail "down: stale gateway" "$(grep -E 'registered|gateway' <<<"$OUT" | head -3 | tr '\n' ' ')"

# The shutdown hook must not read "no phase" as "nothing to stop".
SH="$WORK/hookhome"; mkdir -p "$SH/bin" "$SH/.local/lib/hermes-quickstart"
cp scripts/lib/common.sh "$SH/.local/lib/hermes-quickstart/"
printf '#!/bin/sh\nexit 1\n' > "$SH/bin/openshell"
printf '#!/bin/sh\necho "$*" >> "%s/nh.calls"\n' "$SH" > "$SH/bin/nemohermes"
chmod +x "$SH/bin/openshell" "$SH/bin/nemohermes"
OUT="$(HOME="$SH" XDG_CONFIG_HOME="$SH/.config" XDG_STATE_HOME="$SH/.state" PATH="$SH/bin:$PATH" \
        HERMES_SANDBOX_NAME=sb HERMES_STOP_POLL_INTERVAL=0 bash host/hermes-sandbox-stop --force 2>&1)"; _rc=$?
if (( _rc != 0 )) && grep -q 'ERROR' <<<"$OUT" && grep -qx 'sb stop' "$SH/nh.calls" 2>/dev/null \
   && ! grep -q 'nothing to stop' <<<"$OUT"; then
  pass "hook: unknown phase" "logs ERROR, still runs 'nemohermes sb stop', exits $_rc"
else
  fail "hook: unknown phase" "rc=$_rc: $(tr '\n' ' ' <<<"$OUT" | cut -c1-120)"
fi
# Restore refuses to run blind: no gateway -> ERROR + exit, never "continue".
grep -q 'ERROR: no OpenShell gateway answered' host/hermes-stack-restore \
  && grep -q 'hermes_gateway_pin' host/hermes-stack-restore \
  && pass "restore: gateway pinned" "talks to a listening gateway or fails loudly" \
  || fail "restore: gateway pinned" "unknown phase would be treated as fine"
# Heal must never restart a restore that is still running.
grep -qE '^ExecCondition=.*SubState.*hermes-stack-restore.service.*!= running' host/hermes-stack-heal.service \
  && grep -q 'restore.pid' host/hermes-stack-restore \
  && pass "heal spares running restore" "ExecCondition on SubState running + pid lock" \
  || fail "heal spares running restore" "timer would SIGTERM an in-progress restore"
if command -v systemd-analyze >/dev/null; then
  cp host/hermes-stack-heal.service "$WORK/hermes-stack-heal.service"
  _sa="$(systemd-analyze verify "$WORK/hermes-stack-heal.service" 2>&1 | grep -iE 'ExecCondition|parse|invalid' )"
  [[ -z "$_sa" ]] && pass "heal unit parses" "systemd-analyze: ExecCondition accepted" \
                  || fail "heal unit parses" "$_sa"
fi
# The restore must not hold default.target: the gateway unit is
# After=default.target, and a oneshot restore waiting for the gateway kept the
# gateway from starting until the restore gave up (2026-10-23 16:20 reboot).
grep -q '^Type=exec' host/hermes-stack-restore.service \
  && grep -q '^RemainAfterExit=yes' host/hermes-stack-restore.service \
  && pass "restore does not block boot" "Type=exec: default.target, then the gateway, are reached" \
  || fail "restore does not block boot" "oneshot restore holds default.target; gateway waits behind it"
# Healthcheck: both container layouts, any state.
_hp="^openshell-(.+--)?sb-[0-9a-f-]{36}"
grep -qE "${_hp}\|" <<<'openshell-default--sb-f6f0a0ca-67a9-48bf-9513-c09661ce4601|Exited (137)' \
  && grep -qE "${_hp}\|" <<<'openshell-sb-f6f0a0ca-67a9-48bf-9513-c09661ce4601|Up 1 hour' \
  && ! grep -qE "${_hp}\|" <<<'openshell-default--sbx-f6f0a0ca-67a9-48bf-9513-c09661ce4601|Up' \
  && grep -q 'docker ps -a' scripts/healthcheck.sh && grep -q '"OpenShell gateway"' scripts/healthcheck.sh \
  && pass "healthcheck container match" "default-- and bare layouts, exited reported; gateway checked" \
  || fail "healthcheck container match" "pattern or gateway check wrong"
kill "$_lsn_pid" 2>/dev/null; wait "$_lsn_pid" 2>/dev/null

# --- 9. v1.1: desktop pinned to the sandbox's Hermes -------------------------
# A client built from upstream HEAD (v0.22.5) against a 0.21.3 sandbox sent
# prompt.submit with extra fields and every prompt failed. Behavioural test
# against a throwaway local "upstream": the checkout must land on the TAG, not
# the tip, and must be re-pinned on a re-run even though `hermes` now exists.
. scripts/lib/common.sh
[[ "$(hermes_version_tag 'Hermes Agent v0.21.3 (2026.9.14)')" == v2026.9.14 ]] \
  && [[ -z "$(hermes_version_tag 'Hermes Agent v0.21.3')" ]] \
  && pass "hermes tag from version" "(2026.9.14) -> v2026.9.14; none when absent" \
  || fail "hermes tag from version" "wrong tag derivation"
[[ "$HERMES_HOST_REF_PIN" =~ ^v20[0-9]{2}\.[0-9]+\.[0-9]+$ ]] \
  && pass "pin is a release tag" "$HERMES_HOST_REF_PIN" || fail "pin is a release tag" "HERMES_HOST_REF_PIN='$HERMES_HOST_REF_PIN'"

UP="$WORK/pin/upstream"; mkdir -p "$UP" "$WORK/pin/home" "$WORK/pin/bin"
( cd "$UP" && git init -q . && git config user.email t@t && git config user.name t
  cat > setup-hermes.sh <<'SETUP'
#!/usr/bin/env bash
mkdir -p venv/bin
printf '#!/bin/sh\necho "Hermes Agent v0.21.3 (2026.9.14)"\n' > venv/bin/hermes
printf '#!/bin/sh\nexit 0\n' > venv/bin/python
chmod +x venv/bin/hermes venv/bin/python
SETUP
  chmod +x setup-hermes.sh; echo one > f; git add -A; git commit -qm one; git tag v2026.9.14
  echo two > f; git commit -qam two ) >/dev/null 2>&1
PIN_ENV=(env -i HOME="$WORK/pin/home" PATH="$WORK/pin/bin:/usr/bin:/bin" HERMES_UPSTREAM="$UP"
         HERMES_HOST_ROOT="$WORK/pin/root" HERMES_SANDBOX_NAME=selftest-none)
"${PIN_ENV[@]}" ./scripts/install-hermes-host.sh --skip-desktop >"$WORK/pin/run1.log" 2>&1
tag_sha="$(git -C "$UP" rev-parse v2026.9.14^{commit})"; tip_sha="$(git -C "$UP" rev-parse HEAD)"
[[ "$(git -C "$WORK/pin/root" rev-parse HEAD 2>/dev/null)" == "$tag_sha" && "$tag_sha" != "$tip_sha" ]] \
  && pass "host checkout pinned" "fresh install lands on the tag, not upstream tip" \
  || fail "host checkout pinned" "HEAD=$(git -C "$WORK/pin/root" rev-parse --short HEAD 2>/dev/null) want ${tag_sha:0:7}; $(tail -3 "$WORK/pin/run1.log")"
# the launcher must be the checkout venv's hermes ("No module named 'yaml'")
[[ "$(readlink -f "$WORK/pin/home/.local/bin/hermes" 2>/dev/null)" == "$(readlink -f "$WORK/pin/root/venv/bin/hermes")" ]] \
  && pass "launcher is the venv hermes" "~/.local/bin/hermes -> checkout venv/bin/hermes" \
  || fail "launcher is the venv hermes" "$(readlink -f "$WORK/pin/home/.local/bin/hermes" 2>&1)"
# a re-run, with hermes already installed and the checkout moved off the tag
git -C "$WORK/pin/root" checkout -q "$tip_sha" 2>/dev/null
PIN_ENV2=(env -i HOME="$WORK/pin/home" PATH="$WORK/pin/home/.local/bin:$WORK/pin/bin:/usr/bin:/bin" HERMES_UPSTREAM="$UP"
          HERMES_HOST_ROOT="$WORK/pin/root" HERMES_SANDBOX_NAME=selftest-none)
"${PIN_ENV2[@]}" ./scripts/install-hermes-host.sh --skip-desktop >"$WORK/pin/run2.log" 2>&1
[[ "$(git -C "$WORK/pin/root" rev-parse HEAD)" == "$tag_sha" ]] \
  && pass "re-run re-pins" "checkout moved off the tag goes back, though hermes already exists" \
  || fail "re-run re-pins" "$(tail -3 "$WORK/pin/run2.log")"
"${PIN_ENV[@]}" ./scripts/install-hermes-host.sh --skip-desktop --ref "$tip_sha" >/dev/null 2>&1
[[ "$(git -C "$WORK/pin/root" rev-parse HEAD)" == "$tip_sha" ]] \
  && pass "--ref overrides the pin" "explicit ref wins" || fail "--ref overrides the pin" "ignored"
# desktop build verdict: compares the stamp commit with the tag's commit
[[ "$(hermes_desktop_ref_verdict v2026.9.14 aaaa1111 aaaa1111)" == pass* \
   && "$(hermes_desktop_ref_verdict v2026.9.14 aaaa1111 bbbb2222)" == fail* \
   && "$(hermes_desktop_ref_verdict v2026.9.14 aaaa1111 '')" == warn* ]] \
  && pass "desktop/sandbox verdict" "match passes, mismatch fails, no stamp warns" \
  || fail "desktop/sandbox verdict" "verdicts wrong"
grep -q '"desktop matches sandbox"' scripts/healthcheck.sh && grep -q 'install-stamp.json' scripts/healthcheck.sh \
  && pass "healthcheck: desktop ref" "compares the build stamp with the sandbox version" \
  || fail "healthcheck: desktop ref" "check missing"
grep -q 'venv/bin/python -m hermes_cli.main desktop --build-only --force-build' scripts/install-hermes-host.sh \
  && pass "desktop built from the venv" "checkout venv python, forced rebuild" \
  || fail "desktop built from the venv" "builds with whatever hermes is on PATH"

# --- 9b. chrome-sandbox setuid -------------------------------------------------
# Without root:root 4755 Electron aborts where unprivileged userns is restricted.
[[ "$(hermes_chrome_sandbox_verdict root:root 4755)" == pass* \
   && "$(hermes_chrome_sandbox_verdict exx:exx 755)" == fail* \
   && "$(hermes_chrome_sandbox_verdict root:root 755)" == fail* \
   && "$(hermes_chrome_sandbox_verdict '' '')" == warn* ]] \
  && pass "chrome-sandbox verdict" "only root:root 4755 passes" || fail "chrome-sandbox verdict" "verdicts wrong"
mkdir -p "$WORK/cs/apps/desktop/release/linux-arm64-unpacked"; : > "$WORK/cs/apps/desktop/release/linux-arm64-unpacked/chrome-sandbox"
[[ "$(hermes_chrome_sandbox_path "$WORK/cs")" == "$WORK/cs/apps/desktop/release/linux-arm64-unpacked/chrome-sandbox" ]] \
  && ! hermes_chrome_sandbox_path "$WORK/none" >/dev/null \
  && pass "chrome-sandbox located" "finds the unpacked helper, none when unbuilt" || fail "chrome-sandbox located" "path lookup wrong"
grep -q 'hermes_chrome_sandbox_fix' scripts/install-hermes-host.sh && grep -q '"desktop chrome-sandbox"' scripts/healthcheck.sh \
  && pass "chrome-sandbox set + checked" "installer fixes it after every build; healthcheck reads it" \
  || fail "chrome-sandbox set + checked" "installer or healthcheck lacks it"

# --- 9c. token sync: both files, idempotent, others preserved --------------------
cat > "$WORK/dash.py" <<'PY'
import http.server, sys
TOK = "live-token-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/sessions"):
            ok = self.headers.get("Authorization") == "Bearer " + TOK
            self.send_response(200 if ok else 401); self.end_headers(); self.wfile.write(b"[]"); return
        self.send_response(200); self.end_headers()
        self.wfile.write(('<script>window.__HERMES_SESSION_TOKEN__="%s";</script>' % TOK).encode())
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
python3 "$WORK/dash.py" > "$WORK/dash.port" 2>/dev/null & _dash_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$WORK/dash.port" ]] && break; sleep 0.3; done
DPORT="$(cat "$WORK/dash.port")"; DURL="http://127.0.0.1:$DPORT"
mkdir -p "$WORK/hc"
cat > "$WORK/hc/connection.json" <<EOF
{"mode":"remote","remote":{"url":"$DURL","authMode":"token","token":{"encoding":"plain","value":"OLD-1"}},"profiles":{}}
EOF
cat > "$WORK/hc/connections.json" <<EOF
{"version":2,"primary":"mine","connections":[{"id":"local","kind":"local","label":"This device"},{"id":"mine","kind":"remote","url":"$DURL","authMode":"token","token":{"encoding":"plain","value":"OLD-2"}},{"id":"other","kind":"remote","url":"http://other.example:9","authMode":"token","token":{"encoding":"plain","value":"OTHER-KEEP"}}]}
EOF
SYNC=(env HERMES_DESKTOP_CONFIG_DIR="$WORK/hc" HERMES_CONTROL_UI_URL="$DURL" HERMES_TOKEN_SYNC_TRIES=2 ./host/hermes-desktop-token-sync)
LIVE="live-token-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
st0="$(hermes_desktop_tokens_state "$LIVE" "$DURL" "$WORK/hc/connections.json" "$WORK/hc/connection.json" | sed 's#.*/##' | tr '\n' ';')"
"${SYNC[@]}" >"$WORK/hc/run1.log" 2>&1
m1="$(stat -c %Y.%y "$WORK/hc/connection.json" "$WORK/hc/connections.json" | tr '\n' ' ')"
sleep 1.1
"${SYNC[@]}" >"$WORK/hc/run2.log" 2>&1
m2="$(stat -c %Y.%y "$WORK/hc/connection.json" "$WORK/hc/connections.json" | tr '\n' ' ')"
st1="$(hermes_desktop_tokens_state "$LIVE" "$DURL" "$WORK/hc/connections.json" "$WORK/hc/connection.json" | sed 's#.*/##' | tr '\n' ';')"
python3 - "$WORK/hc" "$LIVE" "$DURL" <<'PY' && tk=1 || tk=0
import json, sys
d, live, url = sys.argv[1:4]
a = json.load(open(d + "/connection.json")); b = json.load(open(d + "/connections.json"))
ents = {c["id"]: c for c in b["connections"]}
assert a["remote"]["token"]["value"] == live
assert ents["mine"]["token"]["value"] == live
assert ents["other"]["token"]["value"] == "OTHER-KEEP", "other entry changed"
assert ents["local"] == {"id": "local", "kind": "local", "label": "This device"}
assert b["primary"] == "mine" and b["version"] == 2
PY
[[ "$st0" == "connections.json stale;connection.json stale;" ]] && [[ "$st1" == "connections.json ok;connection.json ok;" ]] \
  && pass "token state reads both files" "stale before sync, ok after; healthcheck would see connections.json" \
  || fail "token state reads both files" "before: $st0 after: $st1"
(( tk )) && pass "token-sync updates both" "connection.json and connections.json carry the live token; other entries kept" \
         || fail "token-sync updates both" "$(cat "$WORK/hc/run1.log")"
[[ "$m1" == "$m2" ]] && grep -q 'token unchanged' "$WORK/hc/run2.log" \
  && pass "token-sync idempotent" "second run rewrites nothing" \
  || fail "token-sync idempotent" "mtimes changed or no 'unchanged': $(cat "$WORK/hc/run2.log")"
grep -q 'hermes_desktop_tokens_state' scripts/healthcheck.sh && grep -q 'connections.json' scripts/healthcheck.sh \
  && pass "healthcheck: connections.json" "desktop-token check reads the file the app reads" \
  || fail "healthcheck: connections.json" "still reads connection.json only"
kill "$_dash_pid" 2>/dev/null; wait "$_dash_pid" 2>/dev/null

# --- 9d. dashboard after an unclean boot: the restore starts what is missing -----
# The in-sandbox repair script, run against stubbed tools: it must start the
# dashboard (nemoclaw-start's argv) and both bridges when absent, and start
# NOTHING when they are all there.
sed -n "/^SBX_HEAL_SCRIPT='/,/^'\$/p" host/hermes-stack-restore | sed '1d;$d' > "$WORK/heal.sh"
mkdir -p "$WORK/stub"
cat > "$WORK/stub/curl" <<'STUB'
#!/bin/sh
case "$*" in *19119*) printf '%s' "${FAKE_DASH_CODE:-000}" ;; *) printf 000 ;; esac
STUB
cat > "$WORK/stub/pgrep" <<'STUB'
#!/bin/sh
# usage: pgrep -f <pattern>; the "processes" are the lines of $FAKE_PROCS
for pat in "$@"; do :; done
grep -E -- "$(printf '%s' "$pat" | sed 's/\[\(.\)\]/\1/g')" "$FAKE_PROCS" 2>/dev/null | cut -d' ' -f1
[ -s "$FAKE_PROCS" ] && grep -qE -- "$(printf '%s' "$pat" | sed 's/\[\(.\)\]/\1/g')" "$FAKE_PROCS"
STUB
printf '#!/bin/sh\necho "nohup $*" >> "$FAKE_LOG"\n' > "$WORK/stub/nohup"
printf '#!/bin/sh\nexit 0\n' > "$WORK/stub/sleep"; printf '#!/bin/sh\necho "kill $*" >> "$FAKE_LOG"\n' > "$WORK/stub/kill"
chmod +x "$WORK/stub/"*
heal() { # <dash code> <procs...>  -> prints what the script started
  : > "$WORK/heal.log"; printf '%s\n' "${@:2}" > "$WORK/heal.procs"
  PATH="$WORK/stub:/usr/bin:/bin" FAKE_LOG="$WORK/heal.log" FAKE_PROCS="$WORK/heal.procs" FAKE_DASH_CODE="$1" \
    sh "$WORK/heal.sh" 19119 18795 8642 18642 2>&1 | grep started | tr '\n' ';'
}
h_none="$(heal 000 '')"; h_all="$(heal 200 '1 TCP-LISTEN:18795,bind' '2 TCP-LISTEN:8642,bind')"; h_api="$(heal 200 '1 TCP-LISTEN:18795,bind')"
grep -q 'nohup /usr/local/bin/hermes dashboard --host 127.0.0.1 --port 19119 --skip-build --no-open --isolated' "$WORK/heal.log" 2>/dev/null; had_argv=$?
[[ "$h_none" == *"dashboard started"*"dashboard bridge 18795 started"*"API bridge 8642 started"* ]] \
  && pass "restore: starts a missing dashboard" "dashboard + 18795 bridge + 8642 bridge all started when absent" \
  || fail "restore: starts a missing dashboard" "got: $h_none"
h_none2="$(heal 000 '')"; grep -q -- '--skip-build --no-open --isolated' "$WORK/heal.log" \
  && pass "restore: nemoclaw-start's args" "dashboard --host 127.0.0.1 --port 19119 --skip-build --no-open --isolated" \
  || fail "restore: nemoclaw-start's args" "$(cat "$WORK/heal.log")"
[[ -z "$h_all" ]] && pass "restore: idempotent" "starts nothing when dashboard and both bridges are up" \
                  || fail "restore: idempotent" "started: $h_all"
[[ "$h_api" == "API bridge 8642 started;" ]] \
  && pass "restore: restarts a missing 8642 bridge" "only the API socat is started" \
  || fail "restore: restarts a missing 8642 bridge" "got: $h_api"
# order inside step 4: repair before judging, and again after `recover`
_ln_heal1="$(grep -n '^sandbox_heal || true' host/hermes-stack-restore | head -1 | cut -d: -f1)"
_ln_rec="$(grep -n 'recover' host/hermes-stack-restore | grep -n 'timeout 600' | head -1 | cut -d: -f1)"
(( $(grep -c '^\s*sandbox_heal || true' host/hermes-stack-restore) >= 2 )) && grep -q 'openshell sandbox exec' host/hermes-stack-restore \
  && ! grep -q 'docker exec .*dashboard' host/hermes-stack-restore \
  && pass "restore: heal before and after recover" "runs via openshell sandbox exec (the sandbox's own network namespace)" \
  || fail "restore: heal before and after recover" "sandbox_heal not wired in twice, or uses docker exec"
grep -q 'ExecStart=/usr/bin/systemctl --user restart hermes-stack-restore.service' host/hermes-stack-heal.service \
  && pass "heal timer reaches the repair" "timer -> restarts the restore, which now starts the dashboard" \
  || fail "heal timer reaches the repair" "timer no longer restarts the restore unit"

# --- 9e. NemoClaw licence: prompt at a terminal, flag without one -------------------
mkdir -p "$WORK/lic/home" "$WORK/lic/bin"
LIC_OUT="$(env -i HOME="$WORK/lic/home" PATH="$WORK/lic/bin:/usr/bin:/bin" ./scripts/install-nemoclaw.sh </dev/null 2>&1; echo "rc=$?")"
[[ "$LIC_OUT" == *"rc=1"* && "$LIC_OUT" == *"--accept-nemoclaw-license"* && "$LIC_OUT" == *"No terminal"* ]] \
  && pass "licence: no terminal needs the flag" "exits 1 and names --accept-nemoclaw-license" \
  || fail "licence: no terminal needs the flag" "$LIC_OUT"
if command -v script >/dev/null 2>&1; then
  ask() { printf '%s\n' "$1" | script -qec ". scripts/lib/common.sh; hermes_licence_prompt" /dev/null >/dev/null 2>&1; echo $?; }
  [[ "$(ask y)" == 0 && "$(ask YES)" == 0 && "$(ask n)" == 1 && "$(ask '')" == 1 && "$(ask maybe)" == 1 ]] \
    && pass "licence: prompt at a terminal" "y/yes accept; n, Enter and anything else decline" \
    || fail "licence: prompt at a terminal" "y=$(ask y) YES=$(ask YES) n=$(ask n) enter=$(ask '') maybe=$(ask maybe)"
  DECL="$(printf 'n\n' | script -qec "env -i HOME=$WORK/lic/home PATH=$WORK/lic/bin:/usr/bin:/bin ./scripts/install-nemoclaw.sh; echo rc=\$?" /dev/null 2>&1)"
  [[ "$DECL" == *"Accept? [y/N]"* && "$DECL" == *"Not accepted"* && "$DECL" == *"rc=1"* ]] \
    && pass "licence: declined at the prompt" "shows the notice, asks, exits 1 without installing" \
    || fail "licence: declined at the prompt" "$DECL"
else
  pass "licence: prompt at a terminal" "skipped (no script(1) to fake a terminal)"
fi
grep -q 'accept-nemoclaw-license' README.md \
  && pass "licence: README documents the flag" "--accept-nemoclaw-license is in the README" \
  || fail "licence: README documents the flag" "README never mentions it"

# --- 9f. thinking off for the demo profile -------------------------------------------
# Server-side, via vLLM, because the sandbox config is sealed.
OUTV="$(./install.sh --profile profiles/spark-video.conf --print-config 2>&1 | strip)"
OUTQ="$(./install.sh --profile profiles/spark-qwen38.conf --print-config 2>&1 | strip)"
grep -qE '^\s*AGENT_THINKING\s+off\s*$' <<<"$OUTV" && ! grep -q 'AGENT_THINKING' <<<"$OUTQ" \
  && pass "thinking: demo profile only" "spark-video sets AGENT_THINKING=off; spark-qwen38 does not" \
  || fail "thinking: demo profile only" "video: $(grep AGENT_THINKING <<<"$OUTV") qwen: $(grep AGENT_THINKING <<<"$OUTQ")"
grep -rq 'AGENT_THINKING' profiles/spark-gemma26.conf && fail "thinking: other profiles untouched" "gemma26 sets it" \
  || pass "thinking: other profiles untouched" "only the demo profile"
sed 's/^AGENT_THINKING=.*/AGENT_THINKING=sometimes/' profiles/spark-video.conf > "$WORK/bad-think.conf"
./install.sh --profile "$WORK/bad-think.conf" --print-config >/dev/null 2>&1 \
  && fail "thinking: bad value rejected" "AGENT_THINKING=sometimes accepted" \
  || pass "thinking: bad value rejected" "only default | off"
# What the launch really passes: run launch_vllm's argument building with docker stubbed.
sed -n '/^launch_vllm() {/,/^}/p' scripts/start-model.sh > "$WORK/launch.sh"
docker() { printf '%s\n' "$@" > "$WORK/docker.args"; }
(  AGENT_THINKING=off; VLLM_CONTAINER=c SERVED_MODEL_NAME=m MAX_MODEL_LEN=65536 GPU_MEMORY_UTILIZATION=.5 MEM_CAP=1g
   VLLM_PORT=8000 MODEL_DIR=/m VLLM_IMAGE=img TOOL_CALL_PARSER=qwen3_coder VLLM_EXTRA_ARGS='--reasoning-parser qwen3' HOME=/h
   . "$WORK/launch.sh"; launch_vllm ) >/dev/null 2>&1
if grep -qx -- '--default-chat-template-kwargs' "$WORK/docker.args" && grep -qxF -- '{"enable_thinking": false}' "$WORK/docker.args" \
   && grep -qx -- '--reasoning-parser' "$WORK/docker.args"; then
  pass "thinking: vLLM launch flag" "AGENT_THINKING=off adds --default-chat-template-kwargs {enable_thinking:false}, keeps the reasoning parser"
else
  fail "thinking: vLLM launch flag" "$(cat "$WORK/docker.args" 2>&1 | tr '\n' ' ')"
fi
(  AGENT_THINKING=default; VLLM_CONTAINER=c SERVED_MODEL_NAME=m MAX_MODEL_LEN=65536 GPU_MEMORY_UTILIZATION=.5 MEM_CAP=1g
   VLLM_PORT=8000 MODEL_DIR=/m VLLM_IMAGE=img TOOL_CALL_PARSER=qwen3_coder VLLM_EXTRA_ARGS='' HOME=/h
   . "$WORK/launch.sh"; launch_vllm ) >/dev/null 2>&1
grep -q 'enable_thinking' "$WORK/docker.args" \
  && fail "thinking: default leaves vLLM alone" "flag present with AGENT_THINKING=default" \
  || pass "thinking: default leaves vLLM alone" "no flag unless the profile asks"
unset -f docker

# --- 8. every script parses -------------------------------------------------
for f in install.sh scripts/*.sh scripts/lib/*.sh host/hermes-stack-restore host/hermes-desktop-token-sync host/hermes-sandbox-stop; do
  bash -n "$f" 2>/dev/null && pass "parses" "$f" || fail "parses" "$f"
done

printf '\n%s----------------------------------------------------------%s\n' "$DIM" "$OFF"
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
