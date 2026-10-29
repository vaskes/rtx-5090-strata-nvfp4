#!/bin/sh
# Strata NVFP4 (sergqwer/strata-nvfp4, 0.2.0-beta-nvfp4.3) — production entrypoint.
#
# Two phases, both from the fork's own setup.py:
#
#   1. setup  — writes the run config (strata-qwen-mix-nvfp4.json) and the start script.
#      Everything it needs is already on disk: the model files are mounted at /data
#      (checked against the repo's SHA-256 pins) and the engine is compiled into the
#      image for this CPU and this card. Nothing is downloaded, nothing is compiled.
#
#   2. serve  — starts the installed model. NOTE: no --family / --setup / --no-start /
#      --data-dir here: those would send setup.py down the "install a model" path again
#      instead of the plain "start what is installed" path.
#
# Every parameter is explicit below so an operator can review the whole setup in one place.
#
# This entrypoint serves BOTH images:
#   - strata-nvfp4:sm120-v020  (the fork at 586dc5e, the production one)  -> /venv
#   - strata-nvfp4:sm120       (the previous revision, kept for rollback)  -> /opt/strata/.venv
# The interpreter is resolved below, so the documented rollback is a one-line image-tag
# swap in run.sh and nothing else.

set -e
cd /opt/strata || exit 1

# --- the interpreter ----------------------------------------------------------
# The 0.2.0 image keeps its venv OUTSIDE the source tree (/venv, like the fork's own
# Dockerfile: a .venv inside /opt/strata breaks the fork's own test suite, which walks
# sys.modules and asserts that every module loaded from the source root belongs to
# serve/strata_cli/strata_control). The previous-revision image keeps its venv inside
# (/opt/strata/.venv). Resolve, don't hardcode: a hardcoded /venv/bin/python makes the
# documented rollback fail with "no such file or directory" instead of starting.
if [ -x /venv/bin/python ]; then
    PY="/venv/bin/python"                          # the 0.2.0 image
elif [ -x /opt/strata/.venv/bin/python ]; then
    PY="/opt/strata/.venv/bin/python"              # the previous-revision image (rollback)
else
    echo "ERROR: no python interpreter found (looked for /venv/bin/python and /opt/strata/.venv/bin/python)" >&2
    exit 1
fi

# --- the CPU the image was built for (the engine is native: no AVX2 baseline)
cpuinfo="${STRATA_CPUINFO:-/proc/cpuinfo}"
if [ -r "$cpuinfo" ] && grep -q '^flags' "$cpuinfo" && ! grep -m1 '^flags' "$cpuinfo" | grep -qw avx2; then
    echo "WARNING: this host CPU has no AVX2. The engine in this image is built for CPUs with AVX2." >&2
fi

# --- the model
STRATA_DATA="${STRATA_DATA:-/data}"          # where the model files are mounted
FAMILY="${FAMILY:-qwen-nvfp4-mix}"            # NVFP4 + Q8_0 mix (the repo's own family)
CONTEXT="${CONTEXT:-262144}"                  # 256K tokens
KV="${KV:-int8}"                              # 8-bit K/V cache
VISION="${VISION:-yes}"                       # images on (the encoder runs on the CPU)
UNCENSORED="${UNCENSORED:-on}"                # this fork's refusal-direction projection: off by default
LOW_RAM="${LOW_RAM:-off}"                     # all 103 GiB of experts live in RAM
# VRAM left free for other programs. The engine's default is 700 MiB, but the expert cache
# grew (5399 experts, 22.78 GiB) and the free VRAM fell to 492 MiB mid-run - below the
# 512 MiB the engine calls LOW (#2065: the driver starts paging GPU memory to system RAM and
# decode collapses). The fork's own warning asks for 768 in exactly this case.
VRAM_RESERVE_MIB="${VRAM_RESERVE_MIB:-768}"
HOST="${HOST:-0.0.0.0}"                       # reachable from other machines
PORT="${PORT:-8080}"                          # the API port (inside the container)
API_KEY="${API_KEY:-}"                        # the key clients must send

if [ -z "$API_KEY" ]; then
    echo "ERROR: API_KEY is empty. Set it in the environment file of the service." >&2
    exit 2
fi

# No --model: every NVFP4 family has exactly one name, and "--model NVFP4" is upstream
# 0.1.44's alias for --family qwen-nvfp4-gptq (setup.py rejects it for this family).
SETUP_ARGS="--family $FAMILY --context $CONTEXT --kv $KV --vision $VISION"
SETUP_ARGS="$SETUP_ARGS --uncensored $UNCENSORED --low-ram $LOW_RAM"
SETUP_ARGS="$SETUP_ARGS --vram-reserve-mib $VRAM_RESERVE_MIB"
SETUP_ARGS="$SETUP_ARGS --data-dir $STRATA_DATA"
SETUP_ARGS="$SETUP_ARGS --host $HOST --api-key $API_KEY --port $PORT --yes"

echo "=== Strata NVFP4: setup (files verified against the repo's pins, config written) ==="
echo "    interpreter: $PY"
"$PY" setup.py --setup --no-start $SETUP_ARGS < /dev/null

# The server replaces this process (os.execve), so it is PID 1 in the container and
# `docker stop`'s SIGTERM reaches it directly - it can then answer the engine with QUIT
# and close the conversation cleanly. Set here, and not as a blanket ENV in the image:
# as a blanket ENV it also replaces the pytest process when the fork's own test suite
# calls setup.main() (see Dockerfile.zen5-v020).
echo "=== Strata NVFP4: serving on port $PORT ==="
export STRATA_EXECV=1
exec "$PY" setup.py --port "$PORT" --yes < /dev/null
