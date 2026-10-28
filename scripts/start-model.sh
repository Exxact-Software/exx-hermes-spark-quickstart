#!/usr/bin/env bash
# Container 1 -- serve the model locally on the Spark's GPU.
#
# ⚠ DO NOT convert this to docker compose. On DGX Spark every model fails to
#   launch under compose with an opaque int('') error. A plain
#   `docker run --entrypoint vllm` is the working path. This is a reproduced
#   platform quirk, not a style preference.
#
# ⚠ On the vLLM image: the profile default is a community aarch64 build. Before
#   shipping to anyone outside, either substitute an official image or build
#   your own -- do not ask users to pull an unvetted third-party container.
#
# Configuration comes from a profile, not from this file. See profiles/.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib/profile.sh
. scripts/lib/profile.sh
set -euo pipefail
profile_bootstrap "$@"
# shellcheck source=scripts/lib/common.sh
. scripts/lib/common.sh
set -euo pipefail

[[ "${INFERENCE_MODE:-local}" == local ]] || {
  echo "profile '$PROFILE_NAME' uses remote inference -- nothing to serve here" >&2; exit 0; }

[[ -d "$MODEL_DIR" ]] || { echo "model dir not found: $MODEL_DIR" >&2; exit 1; }

# Build the image if the profile asks for one we ship a Dockerfile for and it is
# not present. Without this a fresh clone dies here with "image not found":
# spark-qwen38 and spark-video both reference exx-vllm-spark, which exists only
# on machines that have built it. That is precisely the kind of works-on-my-box
# gap this repo exists to eliminate.
if ! docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
  case "$VLLM_IMAGE" in
    exx-vllm-spark:*)
      echo "==> building $VLLM_IMAGE from images/Dockerfile.vllm-spark"
      echo "    (first run pulls a ~22 GB NVIDIA base; later runs are seconds)"
      docker build -f images/Dockerfile.vllm-spark -t "$VLLM_IMAGE" . \
        || { echo "failed to build $VLLM_IMAGE" >&2; exit 1; }
      ;;
    *)
      echo "==> pulling $VLLM_IMAGE"
      docker pull "$VLLM_IMAGE" || { echo "failed to pull $VLLM_IMAGE" >&2; exit 1; }
      ;;
  esac
fi

docker rm -f "$VLLM_CONTAINER" >/dev/null 2>&1 || true

# NemoClaw's onboarding installs and STARTS a vLLM of its own, publishing the
# same port we need. Ours replaces it at the same endpoint -- that is the whole
# design, NemoClaw points the agent at localhost:$VLLM_PORT and we decide what
# answers there -- but docker will not let two containers publish one port, so
# this failed with "driver failed programming external connectivity".
#
# It went unnoticed for a long time because on an established box NemoClaw's
# container had exited weeks earlier and left the port free. Only a from-zero
# install, where its vLLM is still healthy, hits it.
#
# Only containers we recognise are removed. Anything else on the port is the
# user's and we stop rather than take it.
PORT_OWNER="$(docker ps --filter "publish=${VLLM_PORT}" --format '{{.Names}}' 2>/dev/null | head -1)" || true
if [[ -n "$PORT_OWNER" ]]; then
  case "$PORT_OWNER" in
    nemoclaw-vllm|"$VLLM_CONTAINER")
      echo "port ${VLLM_PORT} held by $PORT_OWNER (NemoClaw's own vLLM); replacing it with ours"
      docker rm -f "$PORT_OWNER" >/dev/null 2>&1 || true
      ;;
    *)
      echo "port ${VLLM_PORT} is published by container '$PORT_OWNER', which is not ours." >&2
      echo "Stop it and re-run:  docker rm -f $PORT_OWNER" >&2
      exit 1
      ;;
  esac
fi

# One launch of the container. A function so the wait loop below can launch it
# again when -- and only when -- vLLM dies of the known inspection crash
# (hermes_vllm_inspect_crashed in scripts/lib/common.sh).
launch_vllm() {
  # AGENT_THINKING=off (profile knob): the model's thinking phase is off unless a
  # request asks for it. A server-side default, outside the sandbox's sealed
  # config, so it survives a sandbox stop/start and a reboot.
  local think_args=()
  [[ "${AGENT_THINKING:-default}" == off ]] \
    && think_args=(--default-chat-template-kwargs '{"enable_thinking": false}')
  docker run -d --name "$VLLM_CONTAINER" \
    --gpus all --ipc=host \
    --memory="$MEM_CAP" --memory-swap="$MEM_CAP" \
    -e VLLM_NVFP4_GEMM_BACKEND=marlin \
    -e MAX_JOBS=4 -e NVCC_THREADS=1 \
    -p "${VLLM_PORT}:${VLLM_PORT}" \
    -v "${MODEL_DIR}:/models/m:ro" \
    -v "${HOME}/flashinfer-cache:/root/.cache/flashinfer" \
    --entrypoint vllm "$VLLM_IMAGE" \
    serve /models/m \
      --served-model-name "$SERVED_MODEL_NAME" \
      --max-model-len "$MAX_MODEL_LEN" \
      --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
      --trust-remote-code --host 0.0.0.0 --port "$VLLM_PORT" \
      --enable-auto-tool-choice --tool-call-parser "$TOOL_CALL_PARSER" \
      ${think_args[@]+"${think_args[@]}"} \
      ${VLLM_EXTRA_ARGS:-} >/dev/null
}

START_ATTEMPT=1
echo "starting $VLLM_CONTAINER ($SERVED_MODEL_NAME, ${MAX_MODEL_LEN} ctx)..."
LAUNCHED_AT="$(date +%s)"
launch_vllm

# Notes on the flags above, each of which cost real debugging time:
#   VLLM_NVFP4_GEMM_BACKEND=marlin  FlashInfer JIT fails to build on SM121
#   MAX_JOBS / NVCC_THREADS         parallel nvcc spikes trip the RAM guard
#   flashinfer-cache mount          compile once, reuse across restarts
#   --served-model-name             without it the API reports "/models/m"
#   --memory cap                    a bad load kills the container, not the box
#   VLLM_EXTRA_ARGS                 optional, per-profile. Deliberately unquoted
#                                   so it word-splits into separate flags. The
#                                   profile loader already refuses any character
#                                   that could reach a shell, so this cannot
#                                   smuggle a command. Added 2026-08-21: models
#                                   differ in what they need, and Qwen3.8-27B
#                                   (Qwen3_5ForCausalLM) cannot torch.compile in
#                                   this image -- AOTAutogradCache raises
#                                   PicklingError on its launcher -- so it needs
#                                   --enforce-eager. Gemma does not.

echo -n "waiting for the model to serve (~4m30s with a warm compile cache; 20+ min if torch.compile runs -- a single graph can take 60s. NOT hung)"
for _ in $(seq 1 80); do
  if curl -sSf --max-time 4 "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
    echo; echo "✓ serving:"
    curl -sS "http://127.0.0.1:${VLLM_PORT}/v1/models"; echo

    # Prove the TOOL PARSER works, not just that the model answers.
    #
    # This is the failure that cost the most and showed the least: with the
    # wrong --tool-call-parser the model looks completely healthy -- it replies,
    # it is fast -- but every tool call is emitted as ordinary text and silently
    # does nothing. An agent whose tools never fire reads as a stupid model, not
    # as a misconfiguration, so nobody thinks to check the parser. Verified for
    # real: Qwen3.8 emits Qwen XML, `hermes` expects JSON, and tool calls just
    # vanished. Checking /v1/models would never have caught it.
    echo -n "verifying tool calls parse with --tool-call-parser ${TOOL_CALL_PARSER}... "
    tool_probe="$(curl -sS --max-time 120 \
      "http://127.0.0.1:${VLLM_PORT}/v1/chat/completions" \
      -H 'Content-Type: application/json' -d '{
        "model": "'"$SERVED_MODEL_NAME"'", "max_tokens": 200, "tool_choice": "auto",
        "messages": [{"role":"user","content":"List the files in /tmp. Use the tool."}],
        "tools": [{"type":"function","function":{
          "name":"run_command","description":"Run a shell command",
          "parameters":{"type":"object","properties":{"command":{"type":"string"}},
          "required":["command"]}}}]}' 2>/dev/null)"

    if printf '%s' "$tool_probe" | grep -q '"tool_calls"'; then
      echo "ok"
    else
      echo "FAILED"
      echo "  The model served, but it did not emit a parseable tool call." >&2
      echo "  This almost always means TOOL_CALL_PARSER is wrong for this model." >&2
      echo "  The agent will look like it works and silently do nothing useful." >&2
      echo "  Valid parsers: ${PROFILE_VALID_PARSERS:-gemma4 llama3_json hermes qwen3_coder}" >&2
      echo "  What the model actually returned:" >&2
      printf '%s\n' "$tool_probe" | head -c 600 >&2; echo >&2
      exit 1
    fi
    exit 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER}$"; then
    if hermes_vllm_inspect_crashed "$VLLM_CONTAINER" "$LAUNCHED_AT" \
       && (( START_ATTEMPT < HERMES_VLLM_START_ATTEMPTS )); then
      echo
      echo "↻ vLLM start ${START_ATTEMPT}/${HERMES_VLLM_START_ATTEMPTS} hit the known NVIDIA-image exit-time SIGSEGV (model inspection); starting it again"
      START_ATTEMPT=$((START_ATTEMPT + 1))
      docker rm -f "$VLLM_CONTAINER" >/dev/null 2>&1 || true
      LAUNCHED_AT="$(date +%s)"
      launch_vllm
      echo -n "waiting for the model to serve"
      continue
    fi
    echo; echo "✗ container exited. Logs:" >&2; docker logs --tail 40 "$VLLM_CONTAINER" >&2; exit 1
  fi
  echo -n .; sleep 15
done
echo; echo "✗ timed out. docker logs -f $VLLM_CONTAINER" >&2; exit 1
