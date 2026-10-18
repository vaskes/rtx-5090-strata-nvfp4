#!/bin/sh
# Strata NVFP4 service wrapper. Called by systemd strata-nvfp4.service.
# Actions: start | stop | restart

set -e

CONTAINER_NAME="strata-nvfp4"
IMAGE="strata-nvfp4:sm120"
ENTRYPOINT_SRC="/opt/rtx-5090-strata-nvfp4-fresh/entrypoints/strata-start.sh"
DATA_DIR="/opt/strata-data"
LOG_DIR="/var/log/strata-nvfp4"
HOST_PORT=8080
ENV_FILE="/opt/strata-nvfp4.service.d/env"

is_running() {
    docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true
}

# Load env file (HF_TOKEN, API_KEY) into shell vars.
# We do this in a subshell-ish way: source the file, then export what's needed.
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
        echo "Build: docker build -t $IMAGE /opt/rtx-5090-strata-nvfp4-fresh" >&2
        exit 1
    fi

    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    # Compose the docker args. The escaped quotes around "device=1" reach
    # docker correctly because we use eval. API_KEY/HF_TOKEN come from
    # the env file (loaded by load_env above).
    #
    # Security note: eval is safe here because all values are quoted or
    # come from a file we own (chmod 600, root-only). No untrusted input
    # flows into the eval string.
    #
    # shellcheck disable=SC2086
    eval docker run -d \
        --name "${CONTAINER_NAME}" \
        --gpus '\"device=1\"' \
        -p "${HOST_PORT}:8080" \
        --ulimit memlock=-1 \
        -v "${DATA_DIR}:/data" \
        -v "${ENTRYPOINT_SRC}:/custom-entrypoint.sh:ro" \
        -v "${LOG_DIR}:/var/log/strata-nvfp4" \
        -e FAMILY=qwen-nvfp4-mix \
        -e CONTEXT=262144 \
        -e VISION=yes \
        -e KV=int8 \
        -e UNCENSORED=on \
        -e HOST=0.0.0.0 \
        -e PORT=8080 \
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
