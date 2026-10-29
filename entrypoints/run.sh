#!/bin/sh
# Strata NVFP4 service wrapper. Called by systemd strata-nvfp4.service.
# Actions: start | stop | restart
#
# Every parameter is explicit below, so an operator can read the whole
# configuration of the service in one place before it goes live.

set -e

# --- what to run -------------------------------------------------------------
CONTAINER_NAME="strata-nvfp4"
IMAGE="strata-nvfp4:sm120-v020"          # the new fork (sergqwer/strata-nvfp4 @ 586dc5e)
ENTRYPOINT_SRC="/opt/rtx-5090-strata-nvfp4-fresh/entrypoints/strata-start-v020.sh"
DATA_DIR="/opt/strata-data"              # the model files (158 GB), mounted read-write at /data
LOG_DIR="/var/log/strata-nvfp4"
ENV_FILE="/opt/strata-nvfp4.service.d/env"

# --- the card ----------------------------------------------------------------
# The host's nvidia-smi lists the RTX 5080 as index 0 (reserved for ComfyUI)
# and the RTX 5090 as index 1. This service is the LLM, so it gets the 5090.
# Inside the container the 5090 is the only visible GPU, so it is index 0 there.
GPU_DEVICE="1"

# --- the port ----------------------------------------------------------------
HOST_PORT=8081

# --- the model ---------------------------------------------------------------
# FAMILY=qwen-nvfp4-mix  the NVFP4 + Q8_0 mix (the fork's own family)
# CONTEXT=262144        256K tokens
# KV=int8                8-bit K/V cache
# VISION=yes             images on (the encoder runs on the CPU, the VRAM stays with the experts)
# UNCENSORED=on          this fork's refusal-direction projection
# LOW_RAM=off            all 103 GiB of experts live in RAM
FAMILY="qwen-nvfp4-mix"
CONTEXT="262144"
KV="int8"
VISION="yes"
UNCENSORED="on"
LOW_RAM="off"
VRAM_RESERVE_MIB="768"    # free VRAM for other programs (the engine's LOW threshold is 512 MiB)
HOST="0.0.0.0"
PORT="8080"

is_running() {
    docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true
}

# Load the env file (HF_TOKEN, API_KEY) into the shell.
# The file is root-only (chmod 600), so nothing untrusted flows in here.
load_env() {
    if [ -f "$ENV_FILE" ]; then
        . "$ENV_FILE"
    else
        echo "WARNING: $ENV_FILE not found" >&2
        echo "Create it with HF_TOKEN and API_KEY (chmod 600)" >&2
    fi
}

cmd_start() {
    if is_running; then
        echo "Already running"
        return 0
    fi

    load_env

    if [ ! -f "$ENTRYPOINT_SRC" ]; then
        echo "ERROR: $ENTRYPOINT_SRC not found" >&2
        echo "Clone: git clone --recurse-submodules https://github.com/vaskes/rtx-5090-strata-nvfp4.git /opt/rtx-5090-strata-nvfp4-fresh" >&2
        exit 1
    fi

    mkdir -p "$LOG_DIR"

    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "ERROR: $IMAGE not found" >&2
        echo "Build: docker build -f Dockerfile.zen5-v020 -t $IMAGE /opt/strata-nvfp4/build-0.2.0" >&2
        exit 1
    fi

    if [ ! -d "$DATA_DIR/models" ]; then
        echo "ERROR: $DATA_DIR/models not found - the model files are missing" >&2
        exit 1
    fi

    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    # The escaped quotes around "device=1" reach docker correctly because we
    # use eval. API_KEY/HF_TOKEN come from the env file (loaded by load_env).
    #
    # Security note: eval is safe here because all values are quoted or come
    # from a file we own (chmod 600, root-only). No untrusted input flows into
    # the eval string.
    #
    # shellcheck disable=SC2086
    eval docker run -d \
        --name "${CONTAINER_NAME}" \
        --gpus '\"device='"${GPU_DEVICE}"'\"' \
        -p "${HOST_PORT}:8080" \
        --ulimit memlock=-1 \
        -v "${DATA_DIR}:/data" \
        -v "${ENTRYPOINT_SRC}:/custom-entrypoint.sh:ro" \
        -v "${LOG_DIR}:/var/log/strata-nvfp4" \
        -e FAMILY="${FAMILY}" \
        -e CONTEXT="${CONTEXT}" \
        -e KV="${KV}" \
        -e VISION="${VISION}" \
        -e UNCENSORED="${UNCENSORED}" \
        -e LOW_RAM="${LOW_RAM}" \
        -e VRAM_RESERVE_MIB="${VRAM_RESERVE_MIB}" \
        -e HOST="${HOST}" \
        -e PORT="${PORT}" \
        -e "API_KEY=${API_KEY:-}" \
        -e "HF_TOKEN=${HF_TOKEN:-}" \
        --entrypoint /custom-entrypoint.sh \
        --restart unless-stopped \
        "${IMAGE}"

    sleep 2
    docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cmd_stop() {
    if ! is_running; then
        echo "Not running"
        return 0
    fi
    echo "Stopping $CONTAINER_NAME (60s grace)..."
    docker stop -t 60 "$CONTAINER_NAME"
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start
}

case "${1:-}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    *)
        echo "Usage: $0 {start|stop|restart}" >&2
        exit 2
        ;;
esac
