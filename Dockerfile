# Strata NVFP4 fork — RTX 5090 deployment
#
# Patches vs upstream sergqwer/strata-nvfp4:
#   - Tsinghua pip mirror (pypi.org timeouts on China-based hosts; harmless elsewhere)
#   - BuildKit pip cache mount (faster rebuilds)
#   - BUILD_VISION=0 default (skip vision binary in image; setup.py builds it
#     from tools/vision at first container start with the host CUDA arch)
#   - Symlink third_party/ggml -> llama.cpp/ggml (Strata CMakeLists.txt:444
#     hardcodes this path; llama.cpp is pinned in third_party/llama.cpp/)
#   - Default CUDA arch sm_120 (RTX 5090 Blackwell only)
#
# Build:    docker build -t strata-nvfp4:sm120 .
# Test:     docker run --rm --gpus '"'"'"device=1"'"'"' strata-nvfp4:sm120 /opt/strata/engine/strata --help

FROM nvidia/cuda:13.0.0-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    LANG=C.UTF-8 \
    STRATA_EXECV=1 \
    PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    PIP_RETRIES=10 \
    PIP_TIMEOUT=120

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git libatomic1 libgomp1 \
        python3 python3-pip python3-venv unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/strata
COPY . .

# Strata CMakeLists.txt:444 hardcodes the path third_party/ggml, but the source
# lives in llama.cpp/ggml (pinned commit in third_party/llama.cpp/). Create the
# symlink. Also link ggml-common.h: in llama.cpp, ggml-common.h lives at
# llama.cpp/ggml/ggml-common.h, but Strata expects it at third_party/ggml/.
RUN ln -sfn llama.cpp/ggml /opt/strata/third_party/ggml \
    && ln -sfn ../../src/ggml-common.h /opt/strata/third_party/ggml/ggml-common.h

# RTX 5090 only (Blackwell, sm_120). For other cards change this:
#   75=RTX 20 (Turing), 80=A100, 86=RTX 30 (Ampere), 89=RTX 40 (Ada), 120=RTX 50 (Blackwell)
ARG CUDA_ARCHITECTURES=120
# Skip vision binary in the image. setup.py builds tools/vision at first
# container start with the host's CUDA arch. Smaller image (~250 MB) and the
# vision binary is rebuilt per-host (not portable across CUDA versions).
ARG BUILD_VISION=0

# BuildKit pip cache mount (persists between builds, much faster on rebuilds)
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    python3 -m venv .venv \
    && .venv/bin/pip install --upgrade pip \
    && .venv/bin/pip install -r requirements.txt \
    && chmod +x setup.sh docker-entrypoint.sh

# llama.cpp at the pinned commit (in third_party/llama.cpp/), then the engine.
# The engine is built for the host CPU (native arch) so first container start
# on a different CPU will recompile. setup.py detects this via
# BUILD.json:source=local + matching src hash.
RUN .venv/bin/python - <<'PYEOF'
import json, os, pathlib, shutil
import setup

llama = setup.get_llama_cpp()
nvcc, _ = setup.find_nvcc()
arch = os.environ.get("CUDA_ARCHITECTURES", "120").strip().strip('"').replace(",", ";")
vision = "gpu" if os.environ.get("BUILD_VISION", "0") == "1" else "none"

setup.cmake_build(setup.ROOT, setup.ROOT / "build", "strata",
    ["-DSTRATA_ENABLE_CUDA=ON", "-DSTRATA_BUILD_TESTS=OFF",
     f"-DCMAKE_CUDA_ARCHITECTURES={arch}", f"-DCMAKE_CUDA_COMPILER={nvcc}",
     f"-DSTRATA_GGML_DIR={llama}"], None, "build-strata.bat")

eng = setup.ROOT / "engine"
eng.mkdir(exist_ok=True)
shutil.copy2(setup.ROOT / "build" / setup.EXE, eng / setup.EXE)
if (setup.ROOT / "build" / setup.KQ_LIB).exists():
    shutil.copy2(setup.ROOT / "build" / setup.KQ_LIB, eng / setup.KQ_LIB)
bindir = pathlib.Path(nvcc).parent
meta = {"source": "local", "version": setup.source_version(),
        "archs": [int(a.split("-")[0]) for a in arch.split(";") if a.split("-")[0].isdigit()],
        "vision": vision,
        "cuda_dirs": [str(d) for d in (bindir, bindir / "x64", bindir.parent / "lib64") if d.is_dir()],
        "src": setup.source_hash(setup.ENGINE_SOURCES),
        "vision_src": None}
(eng / "BUILD.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
print("engine built:", eng / setup.EXE, "vision:", vision)
PYEOF

# The actual entrypoint is in entrypoints/ in this repo, mounted into the
# container at /custom-entrypoint.sh. The script accepts these env vars:
#   FAMILY     - model family (default: qwen-nvfp4-mix)
#   CONTEXT    - max context (default: 262144 for 256K)
#   VISION     - yes/no (default: yes)
#   KV         - int8/q4_0 (default: int8)
#   UNCENSORED - on/off (default: on)
#   HF_TOKEN   - HuggingFace token (required for model download)
#   API_KEY    - bearer token for the OpenAI-compatible API
#   HOST, PORT - bind interface and port
# See entrypoints/README.md for the available modes.

CMD ["/custom-entrypoint.sh"]
