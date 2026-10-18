# Gotchas

Every failure mode hit during deployment of this stack. Read this before
debugging — saves 30-60 min of trial-and-error.

## Build gotchas

### 1. Strata's `CMakeLists.txt:444` hardcodes `third_party/ggml`

The Strata kernel build does:
```cmake
target_include_directories(strata_kernels PRIVATE third_party/ggml)
```

But the ggml source is at `llama.cpp/ggml/` (in the pinned llama.cpp submodule
or directory). If `third_party/ggml` doesn't exist, nvcc fails with:

```
fatal error: ggml-common.h: No such file or directory
```

**Fix**: the Dockerfile creates the symlink:
```dockerfile
RUN ln -sfn llama.cpp/ggml /opt/strata/third_party/ggml \
    && ln -sfn ../../src/ggml-common.h /opt/strata/third_party/ggml/ggml-common.h
```

Both symlinks are required:
- `third_party/ggml` → `llama.cpp/ggml/` (the directory itself)
- `third_party/ggml/ggml-common.h` → `../../src/ggml-common.h` (one specific file)

The second one is needed because Strata's source has `src/ggml-common.h` but
llama.cpp's ggml expects it at `ggml/ggml-common.h`.

### 2. PyPI downloads hang on the build host

Building wheels like `cmake` (30 MB), `ninja`, `scipy` etc. from pypi.org
takes 30+ minutes and times out repeatedly. Not a bandwidth issue — a TCP-level
hang.

**Fix**: the Dockerfile uses the Tsinghua mirror:
```dockerfile
ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    PIP_RETRIES=10 \
    PIP_TIMEOUT=120
```

This is fast from China-based hosts and harmless elsewhere (Tsinghua serves
the same PyPI content).

Plus a BuildKit pip cache mount so rebuilds are nearly instant:
```dockerfile
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    .venv/bin/pip install -r requirements.txt
```

### 3. `BUILD_VISION=1` builds a CUDA vision binary that may not work on all hosts

The image's `tools/vision` builds `strata-vision` with `STRATA_VISION_CUDA=ON`.
The vision binary's CUDA arch is fixed at build time. If the container is
deployed on a different CUDA version, the vision binary may fail to load.

**Fix**: `BUILD_VISION=0` in the image build; let setup.py build `strata-vision`
from `tools/vision` at first container start with the host's CUDA arch.
Smaller image, vision binary is rebuilt per-host.

### 4. `docker-entrypoint.sh` from upstream hardcodes `--model IQ2_XS`

The upstream entrypoint passes `--model IQ2_XS` to setup.py. For NVFP4
families, the model has no size variants — `--model IQ2_XS` is rejected by
the engine at start.

**Fix**: the entrypoints in this repo (`entrypoints/strata-start.sh`,
`entrypoints/strata-512k-vision.sh`) omit `--model` and let setup.py
auto-derive from the model files staged in `/data/models/`.

### 5. setup.py asks "Disable censorship?" interactively

First container start, setup.py asks interactively. Without a TTY, it
errors out with EOF on stdin.

**Fix**: entrypoints pass `--uncensored on` (or `off`) via env var, plus
`--yes` to skip all other interactive prompts, plus `< /dev/null` on stdin.

### 6. `--gguf-dir` is silently ignored for NVFP4 families

Passing `--gguf-dir /path/to/gguf/files` to setup.py with an NVFP4 family
model: setup.py accepts it, but the engine never sees the files because the
NVFP4 setup path uses a different file-resolution logic.

**Fix**: pre-stage model files at `/data/models/<repo-name>/<component>/`
where `<repo-name>` has the org prefix replaced (`Maximilian228/...` becomes
`Maximilian228--...`) and slashes replaced with `--`.

Example: `Maximilian228/Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata` →
`/data/models/Maximilian228--Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata/`

### 7. `.dockerignore` doesn't honor `#` as comment

If you have a line like `# third_party/llama.cpp/` in `.dockerignore`, Docker
BuildKit **still excludes** `third_party/llama.cpp/` because the comment
prefix isn't recognized for all line types.

**Fix**: just remove the line. This repo has no `.dockerignore` — the entire
`third_party/llama.cpp/` is committed directly (220 MB).

### 8. `docker build --no-cache` doesn't fully clear context cache

BuildKit keeps some metadata. If you're iterating on the Dockerfile and
something looks "stuck", use:
```bash
docker builder prune -af
```

### 9. HF download leaves stale `.incomplete` and `.lock` files

If you kill `hf download` mid-flight, it leaves `*.incomplete` and `*.lock`
files in `.cache/huggingface/download/`. Re-running the download may fail
with "lock held" or skip files because of stale partials.

**Fix**: clean before restart:
```bash
find /root/.cache/huggingface/download/ -name "*.incomplete" -delete
find /root/.cache/huggingface/download/ -name "*.lock" -delete
```

### 10. The model needs 110 GB of free disk during download

`experts.bin` is 110 GB. If you have stale partial files or another model
lying around, the download will fail with "no space left on device".

**Fix**: clear before downloading:
```bash
du -sh /opt/strata-data/models/  # check
rm -rf /opt/strata-data/models/<old-model>
```

## Runtime gotchas

### 11. `--kv q4_0` + `--kv-grow` is the only way to fit 512K context

Qwen3.8-Flash-Next has 17 full attention layers (out of 65). At 512K context:
- int8 KV: 9 GB VRAM — OOM on 32 GB card
- q4_0 KV: 3.5 GB VRAM — fits

`--kv-grow` (default) means the KV cache only allocates as the context grows.
At 50K context, q4_0 only uses 350 MB.

**Don't** try to set `--kv int8` at 512K — the engine will OOM at some point
during a long request.

### 12. `--uncensored` is the env var, not `--no-censorship` or `--disable-censorship`

The setup.py argument is `--uncensored on|off`. The env var is `UNCENSORED=on`
(in the custom entrypoint). Engine config key is `uncensored: true|false`.

**Common mistake**: `--no-censorship` or `--disable-censorship` — these don't
exist, the entrypoint silently ignores them, and the engine starts censored
("censorship: on by default" in the startup log).

### 13. The web UI's "API key" error is a frontend issue, not a server issue

Strata's web UI fetches `/v1/models` and `/health` without an API key
header. If the server requires a key (which it does, by default), the UI
shows "This server needs an API key: add it under About > Settings."

**Fix**: open the About page in the web UI, paste the API key (the value of
`-e API_KEY=...`), save. The UI then sends `Authorization: Bearer <key>` on
all requests.

This is cosmetic — direct API calls with the key work fine without setting
anything in the UI.

### 14. nvidia-smi idx vs CUDA device order

On a host with multiple GPUs, `nvidia-smi` lists them in PCIe order, but
CUDA assigns them in reverse. For a host with RTX 5080 (idx 0) + RTX 5090
(idx 1):
- `--gpus '"'"'"device=1"'"'"'` (Docker) → RTX 5090
- `CUDA_VISIBLE_DEVICES=0` (inside container) → RTX 5090
- `CUDA_VISIBLE_DEVICES=1` (inside container) → RTX 5080

Both want the 5090, but with different syntax. **Don't mix them up.**

### 15. The engine binary is per-host

The engine is built for the host CPU's native arch. If you build the image
on a Zen 5 host and run the container on an Intel Sapphire Rapids, the engine
might fail with "illegal instruction" (Zen 5 has AVX-512; Intel has different
extensions).

**Fix**: the image has `BUILD.json:source=local` and a src hash. setup.py at
first container start compares the current host's CPU features against
`BUILD.json`. If mismatched, it rebuilds the engine from source with the
host's native arch. ~3-5 min extra startup on a new CPU.

### 16. MTP acceptance is content-dependent

| Content | Typical accept |
|---|---|
| Boilerplate / structured output (code, JSON) | 90%+ |
| Russian text (predictable structure) | 80-85% |
| Math reasoning | 75-85% |
| Distractor-heavy long context | 70-80% |

Don't expect 90% on every request. The 50-74% reported in the first builds
was because the engine wasn't built with LTO — once LTO is on, accept is
72-92%.

### 17. Strata's setup refuses to run as root by default

The upstream `docker-entrypoint.sh` runs setup.py as root (USER root is the
default). setup.py checks and refuses with a confusing error.

**Fix**: there's a `STRATA_EXECV=1` env var that makes setup.py replace itself
with the server, bypassing the root check. The Dockerfile in this repo sets
this env var, so the container runs as root with no issues.

## Disk / network

### 18. Model download is 158 GB

`Maximilian228/Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata` is 158 GB on disk
(mostly the experts.bin). On a 1 Gbps link this is ~25 min; on a slower
link (China cross-border, 100 Mbps effective) this is 4-5 hours.

**Tip**: setup.py resumes partial downloads. If you kill the container
mid-download, the next start will resume from where it left off. The
`.incomplete` and `.lock` cleanup in gotcha #9 still applies.

### 19. `git clone` of this repo is 220 MB

The `third_party/llama.cpp/` is committed directly. `git clone` is 220 MB
on first fetch, then incremental.

If you only need to inspect the patches and don't need to build, use
`--depth 1` to skip history. The repo doesn't have a long history yet so
this matters less.

## What's not in this list (and why)

The README has the **how to deploy**. This file has the **what goes wrong**.
For performance numbers, see PERFORMANCE.md. For the architecture, see
ARCHITECTURE.md. For why q4_0 vs int8, see KV-CACHE-MATH.md.
