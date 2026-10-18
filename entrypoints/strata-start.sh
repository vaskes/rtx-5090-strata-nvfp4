#!/bin/sh
# strata-start.sh — production default (256K context, vision, int8 KV, uncensored)
#
# This is the entrypoint mounted into the container at /custom-entrypoint.sh.
# It runs setup.py with the given config, then exec's into the server.
#
# Env vars (with defaults):
#   FAMILY=qwen-nvfp4-mix    Model family (this fork's NVFP4+Q8 mix)
#   CONTEXT=262144           Max context. Use 524288 for 512K (special-case,
#                            requires q4_0 KV and more VRAM; see entrypoints/README.md)
#   VISION=yes               GPU image encoder. Set to "no" to skip mmproj download
#   KV=int8                  KV cache: int8 (1056 B/cell) or q4_0 (408 B/cell, Hadamard)
#   UNCENSORED=on            Engine-level censorship off (cvec projection, default ON)
#   HF_TOKEN=...             Required for first-run model download
#   API_KEY=vaskes-strata-2026  Bearer token for OpenAI-compatible API
#   HOST=0.0.0.0             Bind address
#   PORT=8080                Bind port
#   LOW_RAM=off              Use full experts in RAM. Set to "on" for low-RAM mode
#   ROPE_SCALING=yarn        Past the trained 262144: yarn (auto-derives factor)
#   ROPE_SCALE=              Empty = auto-derive from context/trained

set -e
cd /opt/strata || exit 1

FAMILY="${FAMILY:-qwen-nvfp4-mix}"
CONTEXT="${CONTEXT:-262144}"
VISION="${VISION:-yes}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
API_KEY="${API_KEY:-}"
KV="${KV:-int8}"
LOW_RAM="${LOW_RAM:-off}"
GGUF_DIR="${GGUF_DIR:-}"
UNCENSORED="${UNCENSORED:-on}"
ROPE_SCALING="${ROPE_SCALING:-}"
ROPE_SCALE="${ROPE_SCALE:-}"

# CPU sanity check (Strata engine needs AVX2 at minimum; AVX-512/Zen 5 ideal)
cpuinfo="${STRATA_CPUINFO:-/proc/cpuinfo}"
if [ -r "$cpuinfo" ] && grep -q '^flags' "$cpuinfo" && ! grep -m1 '^flags' "$cpuinfo" | grep -qw avx2; then
  echo "WARNING: this host CPU has no AVX2. The engine in this image is built for CPUs with AVX2." >&2
fi

# Vision binary is built at first start from tools/vision (host CUDA arch).
# The image has BUILD_VISION=0; setup.py detects no engine vision and builds it.

ARGS="--family $FAMILY --context $CONTEXT --vision $VISION --data-dir /data --host $HOST --api-key $API_KEY --port $PORT --low-ram $LOW_RAM --yes"
[ -n "$KV" ] && ARGS="$ARGS --kv $KV"
[ -n "$GGUF_DIR" ] && ARGS="$ARGS --gguf-dir $GGUF_DIR"
[ -n "$UNCENSORED" ] && ARGS="$ARGS --uncensored $UNCENSORED"
[ -n "$ROPE_SCALING" ] && ARGS="$ARGS --rope-scaling $ROPE_SCALING"
[ -n "$ROPE_SCALE" ] && ARGS="$ARGS --rope-scale $ROPE_SCALE"

echo "[strata-start] args: $ARGS"

# First-time setup. setup.py is idempotent: detects existing config, only
# downloads missing model files, skips engine rebuild if BUILD.json matches.
.venv/bin/python setup.py --setup --no-start $ARGS < /dev/null

# Start the server. setup.py spawns the engine then exec's into server.py.
echo "[strata-start] setup done, starting server"
exec .venv/bin/python setup.py $ARGS < /dev/null
