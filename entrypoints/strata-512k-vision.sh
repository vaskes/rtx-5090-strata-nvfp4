#!/bin/sh
# strata-512k-vision.sh — 512K context mode (special case for huge texts)
#
# Same as strata-start.sh but with 512K context via YaRN extension.
# Requires q4_0 KV (int8 would OOM at full 500K context).
#
# Memory math (Qwen3.8-Flash-Next, 17 full attention layers out of 65):
#   q4_0:   408 B/cell × 17 layers × 524288 cells = 3.5 GB at full 512K
#   int8:  1056 B/cell × 17 layers × 524288 cells = 9.0 GB (would OOM on 32 GB)
#
# kv-grow is on by default, so KV is allocated only as the context grows.
# At 50K context q4_0 uses only 350 MB. Full 500K would use 3.5 GB.
#
# For 256K context stick with strata-start.sh (faster int8 decode).

set -e
cd /opt/strata || exit 1

FAMILY="${FAMILY:-qwen-nvfp4-mix}"
CONTEXT="${CONTEXT:-524288}"            # 512K
VISION="${VISION:-yes}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
API_KEY="${API_KEY:-}"
KV="${KV:-q4_0}"                        # 4-bit KV (Hadamard)
LOW_RAM="${LOW_RAM:-off}"
GGUF_DIR="${GGUF_DIR:-}"
UNCENSORED="${UNCENSORED:-on}"

# Always yarn for >256K context
ROPE_SCALING="${ROPE_SCALING:-yarn}"

# CPU sanity check
cpuinfo="${STRATA_CPUINFO:-/proc/cpuinfo}"
if [ -r "$cpuinfo" ] && grep -q '^flags' "$cpuinfo" && ! grep -m1 '^flags' "$cpuinfo" | grep -qw avx2; then
  echo "WARNING: this host CPU has no AVX2." >&2
fi

ARGS="--family $FAMILY --context $CONTEXT --vision $VISION --data-dir /data --host $HOST --api-key $API_KEY --port $PORT --low-ram $LOW_RAM --yes"
ARGS="$ARGS --kv $KV"
[ -n "$GGUF_DIR" ] && ARGS="$ARGS --gguf-dir $GGUF_DIR"
[ -n "$UNCENSORED" ] && ARGS="$ARGS --uncensored $UNCENSORED"
[ -n "$ROPE_SCALING" ] && ARGS="$ARGS --rope-scaling $ROPE_SCALING"

echo "[strata-512k-vision] args: $ARGS"

.venv/bin/python setup.py --setup --no-start $ARGS < /dev/null

echo "[strata-512k-vision] setup done, starting server"
exec .venv/bin/python setup.py $ARGS < /dev/null
