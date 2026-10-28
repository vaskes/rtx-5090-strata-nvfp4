# rtx-5090-strata-nvfp4

Production deployment of [sergqwer/strata-nvfp4](https://github.com/sergqwer/strata-nvfp4)
(the Strata NVFP4 fork by sergqwer) on an NVIDIA RTX 5090 (Blackwell, sm_120)

**Deployed fork revision: `586dc5e` (release `0.2.0-beta-nvfp4.3`, engine `0.1.45.3`).**
The engine is built from the fork's own source tree - this repo holds the recipe
(`Dockerfile.zen5-v020`), the entrypoints and the docs, not a copy of the fork.

Runs on a host with 128 GB system RAM. Serves **Qwen3.8-Flash-Next** in NVFP4 +
Q8_0 mix quantization, 256K context by default with optional 512K via YaRN extension.

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

The model files (158 GB) are **not** downloaded by the build: they are staged on the
host first, each with a `.done` file holding its `sha256`, and the setup verifies
every one of them against the fork's own pins before it starts.

```bash
# 1. Clone this repo (the recipe)
git clone --depth 1 https://github.com/vaskes/rtx-5090-strata-nvfp4.git
cd rtx-5090-strata-nvfp4

# 2. Stage the model files and check them against the fork's pins
#    /opt/strata-data/models/Maximilian228--Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata/
#      pack/{dense.bin,experts.bin,index.txt,mix.json,native_experts.txt,tokenizer/*}
#      mtp/{dense.bin,dense.txt,draft_vocab.bin,experts.bin}
#      qwen-nvfp4-mix-dense.gguf, ple-fp8.gguf, token-embd-bf16.gguf
#    /opt/strata-data/models/mmproj-Qwen3.8-Flash-Next-BF16.gguf   (the image encoder)

# 3. Deploy: builds the image, installs the systemd unit, starts the service
sudo scripts/deploy-v020.sh
```

That is the whole sequence. What it does, and what each step needs, is in
[`docs/STRATA-NVFP4-OPERATOR.md`](docs/STRATA-NVFP4-OPERATOR.md).

### Running it by hand (without the script)

```bash
# 1. Clone
git clone --depth 1 https://github.com/vaskes/rtx-5090-strata-nvfp4.git
cd rtx-5090-strata-nvfp4

# 2. Build the image from the FORK's tree (sm_120, ~5 min, ~13 GB output)
cd /opt/strata-nvfp4/build-0.2.0
docker build -f Dockerfile.zen5-v020 -t strata-nvfp4:sm120-v020 .

# 3. Create a persistent data dir (model files + engine + config)
sudo mkdir -p /opt/strata-data
sudo chown $USER:$USER /opt/strata-data

# 4. Run with the default 256K production config
docker run -d --name strata-nvfp4 \
  --gpus '"'"'"device=1"'"'"' \
  -p 8080:8080 \
  --ulimit memlock=-1 \
  -v /opt/strata-data:/data \
  -v $(pwd)/entrypoints/strata-start-v020.sh:/custom-entrypoint.sh:ro \
  -e HF_TOKEN=hf_xxx_xxx \                  # only for a first-run download
  -e API_KEY=STRATA_API_KEY \           # bearer token for the API
  --entrypoint /custom-entrypoint.sh \
  --restart unless-stopped \
  strata-nvfp4:sm120-v020

# 5. Watch startup logs
docker logs -f strata-nvfp4
# The model is already on disk: the setup verifies its hashes and starts.
# The engine loads 103 GiB of experts into RAM: ~90 s to ready.
```

## What's in this repo

| Path | What | Why |
|---|---|---|
| `Dockerfile.zen5-v020` | **The production build** of the fork's tree (`586dc5e`) | Zen 5 native, sm_120, venv in `/venv`, the pip stamp pre-written |
| `scripts/deploy-v020.sh` | One command: checks the host, builds, installs the unit, starts | Every parameter in one place, for review |
| `entrypoints/run.sh` | The `docker run` of the service, every flag explicit | What the operator reads before going live |
| `entrypoints/strata-start-v020.sh` | In-container: setup phase, then serve phase | **Production default** (256K, int8 KV, vision, uncensored) |
| `systemd/strata-nvfp4.service` | The unit, **disabled by default** | Started by hand, never at boot |
| `docs/STRATA-NVFP4-OPERATOR.md` | For the operator: paths, parameters, checks, rollback | |
| `docs/STRATA-NVFP4-MAVIS-BOT.md` | For an agent: how to point a bot at Strata | The two traps that cost hours |
| `Dockerfile` | The OLD tree's build (kept for rollback) | `strata-nvfp4:sm120` |
| `third_party/llama.cpp/` | llama.cpp at commit `3cf0325` | Pinned — pypi/github downloads are unreliable from this host, and untracked commits can break the build |
| `entrypoints/strata-start.sh` | The OLD tree's entrypoint (kept for rollback) | |
| `entrypoints/strata-512k-vision.sh` | 512K + vision + q4_0 KV + YaRN | Special case for huge documents |
| `entrypoints/README.md` | Entrypoint docs | Env var reference, usage examples |
| `docs/ARCHITECTURE.md` | Engine + model architecture | What runs where, why |
| `docs/PERFORMANCE.md` | Benchmarks | Decode, prefill, MTP accept at different configs |
| `docs/GOTCHAS.md` | Every gotcha hit during deployment | Read this before debugging |
| `docs/KV-CACHE-MATH.md` | Why q4_0 vs int8 at 512K | VRAM math for the 32 GB constraint |

## Key deployment properties

- **Container pinned to RTX 5090 only** via `--gpus '"'"'"device=1"'"'"'`. RTX 5080 in the same host stays free.
- **The engine is built for this host, in the image.** Zen 5 with `-O3 -flto
  -march=native -mtune=znver4`; the container never compiles anything and never
  touches the network at start. Measured on the RTX 5090: **~120-137 tok/s decode**,
  prefill ~6000 tok/s, MTP draft acceptance 85-95 %.
- **`STRATA_PORTABLE` is explicitly OFF.** The upstream Dockerfile sets it, and it
  forces `GGML_NATIVE=OFF` (an AVX2 baseline) - that throws away the whole Zen 5
  win (decode 80-85 tok/s instead of 95-101).
- **`STRATA_EXECV` is not a blanket ENV.** It makes `setup.py` replace itself with
  the server (`os.execve`), which is what the serve phase wants (the server is PID 1,
  so `docker stop`'s SIGTERM reaches it) - but as a blanket ENV it also replaces the
  *pytest* process when the fork's own test suite calls `setup.main()`, and the
  suite stops at ~40% with "Interrupted" and no summary. The serve phase exports it.
- **The venv lives in `/venv`, outside the source tree** (like the fork's own
  Dockerfile). Inside the tree it breaks the fork's own suite:
  `tests/terminal/test_no_acquisition.py` walks `sys.modules` and asserts that
  every module loaded from the source root belongs to `serve`/`strata_cli`/
  `strata_control` - a `.venv` inside the root fails that.
- **The pip stamp is pre-written into the image.** Without it the setup phase runs
  `pip install` on every container start - the one thing that puts the network
  back into a start that should be offline.
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
  -e HF_TOKEN=$HF_TOKEN -e API_KEY=STRATA_API_KEY \
  --entrypoint /custom-entrypoint.sh --restart unless-stopped \
  strata-nvfp4:sm120

# 4. Watch startup (model download + engine warmup)
docker logs -f strata-nvfp4

# 5. Test
curl -s http://localhost:8080/health
# → {"status":"ok","max_context":262144,...}

# 6. Chat
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer STRATA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '"'"'{"model":"qwen3.8-flash-next-mix-nvfp4","messages":[{"role":"user","content":"hi"}],"max_tokens":50}'"'"'
```

## License

Inherits from upstream sergqwer/strata-nvfp4 (Qwen3.8-Flash-Next NVFP4
checkpoint) and Meta's llama.cpp (MIT). Model weights under Qwen Community
License 1.0.
