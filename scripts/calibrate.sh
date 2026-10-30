#!/bin/sh
# Run the fork's own calibration (setup.py --calibrate) on this box.
#
# The Windows instruction the operator quoted (START-HERE.bat --calibrate) is the
# same code path on Linux: setup.sh --calibrate -> setup.py --calibrate. The fork
# measures a few hardware-dependent engine settings on the box it runs on.
#
# Why a throwaway container and not the production one:
#   - the engine needs the whole RTX 5090 (production holds 31.5 of 32 GB) and the
#     103 GiB of experts in RAM, so the production service must be stopped;
#   - the calibration starts the engine ~9 times (once for the PCIe/draft sweeps,
#     then once per CPU-worker candidate and once per expert-tier candidate), so it
#     must not run inside the serving container.
#
# The container gets the same image, the same mounts and the same environment as
# the production one, so the calibration measures the same machine the production
# engine runs on.
#
# The result lands in the container's /root/.config/strata/settings.json (the fork's
# own record of "what was tuned on this PC and model") and in the run config
# /opt/strata/strata-qwen-mix-nvfp4.json. Both are copied out to the host, because
# the production container is recreated on every service restart and would
# otherwise lose the calibration.
#
# Usage: calibrate.sh [--keep]
#   --keep   leave the container on the host (for debugging), do not remove it.

set -e

IMAGE="strata-nvfp4:sm120-v020"
DATA_DIR="/opt/strata-data"
ENTRYPOINT_SRC="/opt/rtx-5090-strata-nvfp4-fresh/entrypoints/strata-start-v020.sh"
ENV_FILE="/opt/strata-nvfp4.service.d/env"
OUT_DIR="/opt/strata-nvfp4.service.d/bench"
NAME="strata-calib"
GPU_DEVICE="1"                       # the RTX 5090 (host index 1; inside the container it is index 0)

# the production configuration, as the service runs it
FAMILY="qwen-nvfp4-mix"
CONTEXT="524288"
KV="int8"
VISION="yes"
UNCENSORED="on"
LOW_RAM="off"
VRAM_RESERVE_MIB="768"
HOST="0.0.0.0"
PORT="8080"

KEEP=0
[ "$1" = "--keep" ] && KEEP=1

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$OUT_DIR/calibrate-$STAMP.log"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"

if docker inspect -f '{{.State.Running}}' strata-nvfp4 2>/dev/null | grep -q true; then
    echo "ERROR: the production container is running - stop it first (it holds the GPU and the RAM)" >&2
    exit 1
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "=== calibration container: $NAME ==="
echo "    image:  $IMAGE"
echo "    log:    $LOG"

# The escaped quotes around "device=1" reach docker correctly.
docker run -d \
    --name "$NAME" \
    --gpus '"device='"${GPU_DEVICE}"'"' \
    --ulimit memlock=-1 \
    -v "${DATA_DIR}:/data" \
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
    --entrypoint /bin/sh \
    "${IMAGE}" -c '
set -e
cd /opt/strata
PY=/venv/bin/python
echo "=== phase 1: the same setup the production entrypoint runs ==="
"$PY" setup.py --setup --no-start \
    --family "$FAMILY" --context "$CONTEXT" --kv "$KV" --vision "$VISION" \
    --uncensored "$UNCENSORED" --low-ram "$LOW_RAM" --vram-reserve-mib "$VRAM_RESERVE_MIB" \
    --data-dir /data --host "$HOST" --api-key "$API_KEY" --port "$PORT" --yes < /dev/null
echo "=== phase 2: the calibration ==="
"$PY" setup.py --calibrate --no-start --yes < /dev/null
echo "=== calibration finished ==="
' > /dev/null

RC=$(docker wait "$NAME" 2>/dev/null || echo 124)
docker logs "$NAME" > "$LOG" 2>&1 || true

echo "=== exit code: $RC ==="
echo "=== log: $LOG ==="

# the two artefacts the calibration produced
mkdir -p "$OUT_DIR/calib-$STAMP"
docker cp "$NAME:/root/.config/strata/settings.json" "$OUT_DIR/calib-$STAMP/settings.json" 2>/dev/null \
    && echo "settings.json -> $OUT_DIR/calib-$STAMP/settings.json" \
    || echo "WARNING: settings.json not found in the container"
docker cp "$NAME:/opt/strata/strata-qwen-mix-nvfp4.json" "$OUT_DIR/calib-$STAMP/strata-qwen-mix-nvfp4.json" 2>/dev/null \
    && echo "run config   -> $OUT_DIR/calib-$STAMP/strata-qwen-mix-nvfp4.json" \
    || echo "WARNING: run config not found in the container"

if [ "$KEEP" -eq 0 ]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
else
    echo "container $NAME kept"
fi

exit "$RC"
