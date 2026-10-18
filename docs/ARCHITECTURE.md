# Architecture

## What runs where

```
┌─ Host: AMD Ryzen 9 9950X3D (Zen 5, AVX-512), 128 GB RAM
│
├─ GPU 0: RTX 5080 (16 GB)         ← unused (Strata is pinned to 5090)
├─ GPU 1: RTX 5090 (32 GB)         ← this is what --gpus '"'"'"device=1"'"'"' targets
│   └─ VRAM at idle (256K mode):
│       ├─ Expert cache:    ~22.4 GB (auto-sized)
│       ├─ Dense weights:    ~6 GB
│       ├─ KV cache:         ~0 GB (kv-grow allocates lazily)
│       └─ Engine + misc:    ~3 GB
│       Total:               ~31.6 GB / 32 GB used
│
├─ RAM:
│   ├─ /opt/strata-data (volume mount):
│   │   ├─ models/Maximilian228--Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata/  (158 GB)
│   │   │   ├─ pack/             (expert weights, native_experts.txt, index, dense, native, mix.json)
│   │   │   ├─ mtp/              (multi-token prediction draft head)
│   │   │   ├─ ple-fp8.gguf      (FP8 n-gram table, 51 GB)
│   │   │   ├─ qwen-nvfp4-mix-dense.gguf
│   │   │   └─ token-embd-bf16.gguf
│   │   ├─ models/mmproj-Qwen3.8-Flash-Next-BF16.gguf  (0.9 GB, vision projection)
│   │   └─ engine/strata, strata-vision, BUILD.json, expert-profile.bin
│   ├─ experts in RAM:    103 GB (loaded once at engine start, mlock'd)
│   └─ OS + other:        ~25 GB
│
└─ Container: strata-nvfp4
    ├─ Image: strata-nvfp4:sm120 (16.1 GB)
    ├─ Entrypoint: /custom-entrypoint.sh (mounted from entrypoints/strata-start.sh)
    └─ Server: serve/server.py (OpenAI-compatible HTTP API on :8080)
```

## Engine (Strata)

A fork of [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) at
pinned commit `3cf0325`, with significant additions for NVFP4:

- **Cuda kernels** in `src/kernels/cuda/` (compiled into `libstrata_kernels.a`):
  bf16_gemv, s_gemv, elementwise, qsa, shared_expert, native_gdn, rope_dynamic,
  native_moe, route_prior, native_scalar_sigmoid
- **gated/expert routing** logic in `src/native/`:
  - Sparse attention (only 17 of 65 layers are full attention; the rest are
    recurrent). This is what makes 512K context fit.
  - QSA (Query-Sparse Attention) — indexer-based sparse attention for long context
- **PLE** (Position-aware Lookup Engine) — FP8 n-gram lookup table for fast
  prefill of repeated text (51 GB on disk, kept on SSD)
- **MTP** (Multi-Token Prediction) — speculative decoding draft head (6 tokens
  ahead, accepts ~50-92% of drafts)
- **cvec projection** — engine-level "uncensoring" by projecting away the
  refusal direction at runtime. Uses a reference GGUF (the abliterated model)
  but the model being served is still the original Qwen.

## Model: Qwen3.8-Flash-Next (NVFP4 + Q8_0 mix)

A MoE (Mixture of Experts) transformer with:
- 65 layers, hidden size ~4096
- ~5314 experts per layer (this fork's mix profile; varies by layer)
- Trained context: **262144 tokens** (256K native)
- Architecture: hybrid sparse (recurrent + full attention layers), 17 full
  attention layers out of 65

Quantization: NVFP4 for the bulk of weights, Q8_0 for 38 layers (the ones most
sensitive to quantization). This gives near-FP16 quality at ~2-3x smaller
file size.

## Why this image is so big (16.1 GB)

The Docker image contains:
- CUDA toolkit base image: ~5 GB
- llama.cpp source (pinned commit): 220 MB
- Strata source + tools: ~50 MB
- .venv (Python deps: numpy, jinja2, pillow, etc.): ~500 MB
- **Engine binary** (built at image build time): **~340 MB** with default
  flags, **83 MB** with -O3 -flto (Zen 5 build)
- All build caches, headers, intermediate objects: ~10 GB

## Build pipeline

1. `FROM nvidia/cuda:13.0.0-devel-ubuntu24.04` — CUDA 13.0 dev image, Ubuntu 24.04
2. `apt-get install` — build tools, Python 3.12, git, etc.
3. `COPY . .` — copy this repo to `/opt/strata/`
4. **Create symlinks** for `third_party/ggml` (required by Strata's CMakeLists)
5. `pip install -r requirements.txt` (via BuildKit cache)
6. **Engine build** via `setup.cmake_build`:
   - Compiles all CUDA kernels (sm_120 only)
   - Compiles llama.cpp CPU backend (native arch for the build host)
   - Links into `engine/strata` binary
7. `CMD ["/custom-entrypoint.sh"]` — entrypoint is mounted from the host, not baked in
