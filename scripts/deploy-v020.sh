#!/bin/sh
# Deploy Strata NVFP4 (sergqwer/strata-nvfp4 @ 586dc5e) on this host, on the RTX 5090.
#
# What it does, in order:
#   1. checks the host (RAM, the card, the model files)
#   2. builds the image (the engine is compiled here, for this CPU and this card)
#   3. installs the systemd unit (disabled by default) and its environment file
#   4. starts the service
#
# The model files are NOT downloaded: they must already be in $DATA_DIR/models
# (the setup checks every file against the repo's SHA-256 pins).
#
# Usage:  deploy.sh [--skip-build] [--no-start]

set -e

# --- the fork ----------------------------------------------------------------
FORK_REPO="https://github.com/sergqwer/strata-nvfp4.git"
FORK_COMMIT="586dc5e4611bee21b695098921807b71bb4785b3"   # main of 2026-10-28, release 0.2.0-beta-nvfp4.3

# --- the model ---------------------------------------------------------------
MODEL_REPO="Maximilian228/Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata"
MODEL_DIR_NAME="Maximilian228--Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata"

# --- llama.cpp (pinned by the fork) -----------------------------------------
LLAMA_COMMIT="3cf03257f219afbe7334045ff7c6a06ac68c627d"

# --- where things live on the host ------------------------------------------
SRC_DIR="/opt/strata-nvfp4/src-0.2.0"        # the fork's checkout
BUILD_DIR="/opt/strata-nvfp4/build-0.2.0"    # the build context (source + vendored llama.cpp)
LLAMA_SRC="/opt/strata-nvfp4/src/third_party/llama.cpp"
DATA_DIR="/opt/strata-data"                 # the model files
REPO_DIR="/opt/rtx-5090-strata-nvfp4-fresh"  # this repository (Dockerfile, entrypoints, docs)
IMAGE="strata-nvfp4:sm120-v020"
SERVICE_DIR="/opt/strata-nvfp4.service.d"
UNIT="/etc/systemd/system/strata-nvfp4.service"

# --- the service's parameters (every one of them, for review) ---------------
GPU_DEVICE="1"                 # nvidia-smi index of the RTX 5090 (index 0 is the 5080, for ComfyUI)
HOST_PORT="8080"
FAMILY="qwen-nvfp4-mix"
CONTEXT="262144"
KV="int8"
VISION="yes"
UNCENSORED="on"
LOW_RAM="off"
VRAM_RESERVE_MIB="768"         # free VRAM for other programs (the engine's LOW threshold is 512 MiB)
HOST="0.0.0.0"
PORT="8080"

SKIP_BUILD=0
START=1
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        --no-start)   START=0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { echo "=== $* ==="; }

# --- 1. the host -------------------------------------------------------------
say "checking the host"
command -v docker >/dev/null || { echo "docker is not installed" >&2; exit 1; }
command -v nvidia-smi >/dev/null || { echo "nvidia-smi is not there" >&2; exit 1; }

nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader

RAM_GIB=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
say "RAM: ${RAM_GIB} GiB (the experts need ~103 GiB plus room for the OS)"
if [ "$RAM_GIB" -lt 118 ]; then
    echo "WARNING: ${RAM_GIB} GiB is under the ~118 GiB this model wants." >&2
    echo "         The engine's memory guard will refuse to start." >&2
fi

if [ ! -d "$DATA_DIR/models/$MODEL_DIR_NAME" ]; then
    echo "ERROR: $DATA_DIR/models/$MODEL_DIR_NAME not found." >&2
    echo "       The model files (158 GB) are not downloaded by this script:" >&2
    echo "       they must be staged there, each with a .done file holding 'sha256 <hex>'." >&2
    exit 1
fi
say "model files are in place (the setup verifies every one against the repo's pins)"

# --- 2. the image ------------------------------------------------------------
if [ "$SKIP_BUILD" -eq 0 ]; then
    say "building the image"
    # The CUDA+LTO compile needs the RAM the running service holds: stop it first.
    docker stop -t 60 strata-nvfp4 2>/dev/null || true
    cd "$BUILD_DIR"
    docker build --progress=plain -f Dockerfile.zen5-v020 -t "$IMAGE" .
    cd - >/dev/null
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "ERROR: no image $IMAGE" >&2; exit 1; }
say "image: $(docker images "$IMAGE" --format '{{.ID}} {{.Size}}')"

# --- 3. the service ----------------------------------------------------------
say "installing the service"
mkdir -p "$SERVICE_DIR" /var/log/strata-nvfp4
cp "$REPO_DIR/entrypoints/run.sh" "$SERVICE_DIR/run.sh"
cp "$REPO_DIR/entrypoints/strata-start-v020.sh" "$SERVICE_DIR/strata-start-v020.sh"
chmod +x "$SERVICE_DIR/run.sh" "$SERVICE_DIR/strata-start-v020.sh"

if [ ! -f "$SERVICE_DIR/env" ]; then
    echo "ERROR: $SERVICE_DIR/env not found." >&2
    echo "       It must hold API_KEY=... and HF_TOKEN=... (chmod 600)." >&2
    exit 1
fi
chmod 600 "$SERVICE_DIR/env"

cp "$REPO_DIR/systemd/strata-nvfp4.service" "$UNIT" 2>/dev/null || true
if [ -f "$UNIT" ]; then
    systemctl daemon-reload
    systemctl disable strata-nvfp4 >/dev/null 2>&1 || true
    say "unit installed and left disabled (start it by hand: systemctl start strata-nvfp4)"
fi

# --- 4. go -------------------------------------------------------------------
if [ "$START" -eq 1 ]; then
    say "starting"
    "$SERVICE_DIR/run.sh" start
    echo
    echo "Health (takes ~2 min while the experts load into RAM):"
    echo "  curl -s localhost:$HOST_PORT/health"
fi

cat <<EOF

Done. Next:
  systemctl status strata-nvfp4
  journalctl -u strata-nvfp4 -f
  curl -s localhost:$HOST_PORT/health

The service is DISABLED by default - it starts only when you ask for it:
  systemctl start strata-nvfp4
EOF
