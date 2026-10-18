# rtx-5090-strata-nvfp4

Production deployment of [sergqwer/strata-nvfp4](https://github.com/sergqwer/strata-nvfp4)
(the Strata NVFP4 fork by sergqwer) on an NVIDIA RTX 5090 (Blackwell, sm_120)
with 128 GB system RAM. Runs **Qwen3.8-Flash-Next** in NVFP4 + Q8_0 mix
quantization, 256K context by default with optional 512K via YaRN extension.

This is a deployment-tested configuration: every patch and config flag in this
repo is required to make Strata build and run on a 5090. The reasoning is
documented inline.

## Hardware requirements

| Component | Minimum | Recommended |
|---|---|---|
| GPU | NVIDIA RTX 5090 (32 GB, sm_120) | RTX 5090 only — this image is pinned to sm_120 |
| RAM | 96 GB | 128 GB (gives the engine headroom for KV cache spillover) |
| CPU | AVX2 (Haswell 2013+) | AVX-512 (Zen 4/5) — gets ~18% extra decode speed via LTO build |
| SSD | 200 GB free | 500 GB (image + model + engine build cache) |
| Driver | `nvidia-driver-*-open` (non-open fails on Blackwell) | nvidia-driver-610-open or newer |
| CUDA toolkit | 13.0+ | 13.0 (matches the image base) |
| nvidia-container-toolkit | 1.10+ | 1.20 (used during dev) |

## Quick start

```bash
# 1. Clone
git clone --depth 1 https://github.com/vaskes/rtx-5090-strata-nvfp4.git
cd rtx-5090-strata-nvfp4

# 2. Build the image (sm_120, ~15-20 min, ~16 GB output)
docker build -t strata-nvfp4:sm120 .

# 3. Create a persistent data dir (model files + engine + config)
sudo mkdir -p /opt/strata-data
sudo chown $USER:$USER /opt/strata-data

# 4. Run with the default 256K production config
docker run -d --name strata-nvfp4 \
  --gpus '"'"'"device=1"'"'"' \
  -p 8080:8080 \
  --ulimit memlock=-1 \
  -v /opt/strata-data:/data \
  -v $(pwd)/entrypoints/strata-start.sh:/custom-entrypoint.sh:ro \
  -e HF_TOKEN=hf_xxx_xxx \                  # required for first-run model download
  -e API_KEY=vaskes-strata-2026 \           # bearer token for the API
  --entrypoint /custom-entrypoint.sh \
  --restart unless-stopped \
  strata-nvfp4:sm120

# 5. Watch startup logs
docker logs -f strata-nvfp4
# First run: 30-60 min (model download 158 GB), then 2-3 min (engine warmup).
# Subsequent restarts: 1-3 min.
```

## What's in this repo

| Path | What | Why |
|---|---|---|
| `Dockerfile` | Patched from upstream | Tsinghua pip mirror, BuildKit cache, BUILD_VISION=0, sm_120 only, symlink setup |
| `third_party/llama.cpp/` | llama.cpp at commit `3cf0325` | Pinned — pypi/github downloads are unreliable from this host, and untracked commits can break the build |
| `third_party/ggml` (created in Dockerfile) | Symlink to `llama.cpp/ggml/` | Strata CMakeLists.txt:444 hardcodes this path; the source lives in llama.cpp |
| `entrypoints/strata-start.sh` | 256K + vision + int8 KV + uncensored | **Production default** |
| `entrypoints/strata-512k-vision.sh` | 512K + vision + q4_0 KV + YaRN | Special case for huge documents |
| `entrypoints/README.md` | Entrypoint docs | Env var reference, usage examples |
| `docs/ARCHITECTURE.md` | Engine + model architecture | What runs where, why |
| `docs/PERFORMANCE.md` | Benchmarks | Decode, prefill, MTP accept at different configs |
| `docs/GOTCHAS.md` | Every gotcha hit during deployment | Read this before debugging |
| `docs/KV-CACHE-MATH.md` | Why q4_0 vs int8 at 512K | VRAM math for the 32 GB constraint |

## Key deployment properties

- **Container pinned to RTX 5090 only** via `--gpus '"'"'"device=1"'"'"'`. RTX 5080 in the same host stays free.
- **Engine is built per-host** (native arch) — Docker image has a stub engine
  for the build host's CPU; first container start rebuilds for the actual
  host's CPU. Zen 5 with `-O3 -flto -march=native` gives 18-19% extra decode
  speed vs the default build.
- **Model is uncensored by default** via cvec projection. The
  `qwen-nvfp4-gptq-uncensored.gguf` is a *reference* for the projection
  direction, not the model itself. The running model is still
  `Maximilian228/Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata`.
- **Vision works** but runs on CPU by default (engine chose CPU path to avoid
  the 1.4 GB VRAM hit). To force GPU vision: set `VISION=gpu` in the
  container env. CPU vision is ~2-6s per image, GPU is <1s.
- **256K context fits 32 GB VRAM** with int8 KV and `kv-grow` (dynamic
  allocation, not preallocated).
- **512K context requires q4_0 KV** (Hadamard-rotated, ~half memory of int8).
  Int8 would OOM at full 500K.

## GPU mapping gotcha (nvidia-smi vs CUDA order)

On a host with both RTX 5080 and RTX 5090, `nvidia-smi` lists:

```
nvidia-smi idx 0 = RTX 5080
nvidia-smi idx 1 = RTX 5090
```

But inside a CUDA context, **the order is reversed**:

```
CUDA_VISIBLE_DEVICES=0  → RTX 5090 (Blackwell, 32 GB) ← we want this
CUDA_VISIBLE_DEVICES=1  → RTX 5080 (16 GB)
```

For Docker `docker run --gpus`, use the **nvidia-smi order**:
`--gpus '"'"'"device=1"'"'"'` to pin to the 5090.

For PyTorch / vLLM inside the container, use `CUDA_VISIBLE_DEVICES=0` to
target the 5090.

## How any agent should deploy this

```bash
# 0. Verify hardware (one-time)
nvidia-smi                           # driver 610+, both GPUs visible
nvidia-smi -q | grep "Total Memory"  # 5090 has ~32 GB
free -h                              # 96+ GB RAM
nproc                                # 8+ cores
df -h /opt                           # 200+ GB free

# 1. Docker
apt-get install -y docker.io nvidia-container-toolkit
# Edit /etc/docker/daemon.json: {"data-root": "/opt/docker"}
systemctl restart docker
# Verify: docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi

# 2. Clone this repo and build
git clone --depth 1 https://github.com/vaskes/rtx-5090-strata-nvfp4.git
cd rtx-5090-strata-nvfp4
docker build -t strata-nvfp4:sm120 .      # 15-20 min

# 3. Run
sudo mkdir -p /opt/strata-data
docker run -d --name strata-nvfp4 \
  --gpus '"'"'"device=1"'"'"' -p 8080:8080 --ulimit memlock=-1 \
  -v /opt/strata-data:/data \
  -v $(pwd)/entrypoints/strata-start.sh:/custom-entrypoint.sh:ro \
  -e HF_TOKEN=$HF_TOKEN -e API_KEY=vaskes-strata-2026 \
  --entrypoint /custom-entrypoint.sh --restart unless-stopped \
  strata-nvfp4:sm120

# 4. Watch startup (model download + engine warmup)
docker logs -f strata-nvfp4

# 5. Test
curl -s http://localhost:8080/health
# → {"status":"ok","max_context":262144,...}

# 6. Chat
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer vaskes-strata-2026" \
  -H "Content-Type: application/json" \
  -d '"'"'{"model":"qwen3.8-flash-next-mix-nvfp4","messages":[{"role":"user","content":"hi"}],"max_tokens":50}'"'"'
```

## License

Inherits from upstream sergqwer/strata-nvfp4 (Qwen3.8-Flash-Next NVFP4
checkpoint) and Meta's llama.cpp (MIT). Model weights under Qwen Community
License 1.0.
