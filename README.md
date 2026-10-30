# rtx-5090-strata-nvfp4

Production deployment of [sergqwer/strata-nvfp4](https://github.com/sergqwer/strata-nvfp4)
(the Strata NVFP4 fork) on an NVIDIA RTX 5090 (Blackwell, sm_120).

**Deployed fork revision: `586dc5e` (release `0.2.0-beta-nvfp4.3`, engine `0.1.45.3`).**

This repository is the **recipe**, not a copy of the fork: the Dockerfile, the
entrypoints, the deploy script, the systemd unit and the documentation. The fork's
own source tree is fetched at a pinned commit by `scripts/deploy-v020.sh` — it is
never vendored here, so the two can never drift apart.

Runs on a host with 128 GB system RAM. Serves **Qwen3.8-Flash-Next** in NVFP4 +
Q8_0 mix quantization, 512K context on int8 KV with dynamic RoPE (the fork's own
elastic K/V; see `docs/KV-CACHE-MATH.md`).

This is a deployment-tested configuration: every patch and config flag here is
required to make Strata build and run on a 5090. The reasoning is documented inline.

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
# 1. Clone this repo (the recipe) and its pinned llama.cpp
git clone --recurse-submodules https://github.com/vaskes/rtx-5090-strata-nvfp4.git \
    /opt/rtx-5090-strata-nvfp4-fresh

# 2. Stage the model files and check them against the fork's pins
#    /opt/strata-data/models/Maximilian228--Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata/
#      pack/{dense.bin,experts.bin,index.txt,mix.json,native_experts.txt,tokenizer/*}
#      mtp/{dense.bin,dense.txt,draft_vocab.bin,experts.bin}
#      qwen-nvfp4-mix-dense.gguf, ple-fp8.gguf, token-embd-bf16.gguf
#    /opt/strata-data/models/mmproj-Qwen3.8-Flash-Next-BF16.gguf   (the image encoder)

# 3. Deploy: fetches the fork, builds the image, installs the systemd unit, starts
sudo scripts/deploy-v020.sh
```

That is the whole sequence. What it does, and what each step needs, is in
[`docs/STRATA-NVFP4-OPERATOR.md`](docs/STRATA-NVFP4-OPERATOR.md).

### Ports

| Port | What |
|---|---|
| **8081** | Strata NVFP4 (this service), published from the container's internal 8080 |
| 8080 | Free — reserved for the `llama-qwen5090-256k.service` unit |
| 8443 | The telegram bot's webhook |

### Running it by hand (without the script)

```bash
# 1. Clone
git clone --recurse-submodules https://github.com/vaskes/rtx-5090-strata-nvfp4.git
cd rtx-5090-strata-nvfp4

# 2. Build the image from the FORK's tree (sm_120, ~5 min, ~13 GB output)
#    The context is assembled from the pinned fork + the pinned llama.cpp:
sudo scripts/prepare-build-context.sh /opt/strata-nvfp4/build-0.2.0
cd /opt/strata-nvfp4/build-0.2.0
docker build -f Dockerfile.zen5-v020 -t strata-nvfp4:sm120-v020 .

# 3. Create a persistent data dir (model files + engine + config)
sudo mkdir -p /opt/strata-data
sudo chown $USER:$USER /opt/strata-data

# 4. Run with the default 512K production config
docker run -d --name strata-nvfp4 \
  --gpus '"device=1"' \
  -p 8081:8080 \
  --ulimit memlock=-1 \
  -v /opt/strata-data:/data \
  -v $(pwd)/entrypoints/strata-start-v020.sh:/custom-entrypoint.sh:ro \
  -e HF_TOKEN=hf_xxx_xxx \                  # only for a first-run download
  -e API_KEY="$STRATA_API_KEY" \             # bearer token for the API (see below)
  --entrypoint /custom-entrypoint.sh \
  --restart unless-stopped \
  strata-nvfp4:sm120-v020

# 5. Watch startup logs
docker logs -f strata-nvfp4
# The model is already on disk: the setup verifies its hashes and starts.
# The engine loads 103 GiB of experts into RAM: ~90 s to ready.
```

## The API key (and the web UI)

The server refuses to answer `/v1/*` without a bearer token, and the fork
**requires** a key on any non-loopback bind:

```
[strata] a non-loopback bind requires an inference API key
```

There is no flag to bypass it. The key is passed to the engine by the entrypoint
(`--api-key`) and ends up in the run config `strata-qwen-mix-nvfp4.json`.

**The key is not in this repository.** It lives only in the service's root-only
env file on the host:

```sh
# /opt/strata-nvfp4.service.d/env  (chmod 600, root-only)
API_KEY=strata-...
```

Generate your own and write it there — never commit it:

```sh
openssl rand -base64 32 | tr -d '/+=' | head -c 40
```

To use it from a script in this repo:

```sh
export STRATA_API_KEY="$(grep -m1 ^API_KEY= /opt/strata-nvfp4.service.d/env | cut -d= -f2-)"
```

### Which endpoints need it

| Endpoint | Without a key | With a key |
|---|---|---|
| `GET /health` | 200 | 200 |
| `GET /v1/models` | **401** | 200 |
| `POST /v1/chat/completions` | **401** | 200 |
| `GET /mcp`, `/metrics`, `/config` | **401** | 200 |

`?api_key=` in the query string is **not** accepted — only the
`Authorization: Bearer <key>` header (or `x-api-key`).

### The web UI

`http://<host>:8081/` serves the Strata UI. It asks for the key once:
**About → Settings → API key**, and keeps it in the browser's localStorage
under `strata.apikey`. The key stays in the browser — the UI cannot read it from
the server. Paste the value from the env file above.

The port is LAN-only (it is not published to the internet), so the key never
leaves the network.

## What's in this repo

| Path | What | Why |
|---|---|---|
| `Dockerfile.zen5-v020` | **The production build** of the fork's tree (`586dc5e`) | Zen 5 native, sm_120, venv in `/venv`, the pip stamp pre-written |
| `scripts/deploy-v020.sh` | One command: checks the host, fetches the fork, builds, installs the unit, starts | Every parameter in one place, for review |
| `scripts/prepare-build-context.sh` | Assembles the build context from the pinned fork + the pinned llama.cpp | Makes a rebuild reproduce the context byte-for-byte |
| `entrypoints/run.sh` | The `docker run` of the service, every flag explicit | What the operator reads before going live |
| `entrypoints/strata-start-v020.sh` | In-container: setup phase, then serve phase | **Production default** (512K, int8 KV, vision, uncensored). Serves both images — see the rollback |
| `systemd/strata-nvfp4.service` | The unit, **disabled by default** | Started by hand, never at boot |
| `docs/STRATA-NVFP4-OPERATOR.md` | For the operator: paths, parameters, checks, rollback, rebuild | |
| `docs/STRATA-NVFP4-MAVIS-BOT.md` | For an agent: how to point a bot at Strata | The two traps that cost hours |
| `docs/GPU-AB-BENCHMARK.md` | The old fork revision vs this one, measured | Why this build replaced it |
| `docs/CALIBRATION.md` | The engine calibration of 2026-10-30: what was measured, what changed | The PCIe bottleneck of this host, and why the flags are not the fix |
| `docs/KV-CACHE-MATH.md` | The KV cache arithmetic, from measured numbers | int8 at 512K: what it costs and why q4_0 is not wanted |
| `third_party/llama.cpp/` | llama.cpp at commit `3cf0325` | Pinned — the fork's `setup.py` pins the same commit. Downloads are unreliable from this host |
| `scripts/bench-*.sh`, `scripts/ctx-probe*.sh` | The measurement harnesses | The numbers in the docs come from these |
| `scripts/calibrate.sh` | Runs the fork's own calibration on this host | What the fork tunes, and how to re-run it |
| `scripts/decode-bench.py` | The decode-speed probe (A/B instrument) | Every before/after number in the docs comes from it |
| `scripts/needle-512k.py` | Needle probe past the trained context | Proves the 512K context, not that it started |

## Key deployment properties

- **Container pinned to RTX 5090 only** via `--gpus '"device=1"'`. RTX 5080 in the same host stays free.
- **The engine is built for this host, in the image.** Zen 5 with `-O3 -flto
  -march=native -mtune=znver4`; the container never compiles anything and never
  touches the network at start. Measured on the RTX 5090 with the production
  config: **85-104 tok/s decode** (the repo's own A/B run: `decode_only` = 85.7
  tok/s, `docs/bench-raw/ab-raw-rtx5090.jsonl`), prefill ~5000-6600 tok/s, MTP
  draft acceptance 76-86 %.
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
- **512K context on int8 KV works, and it is the production default.** The fork's
  K/V is elastic (`--kv-grow`): only the reached cells take VRAM (13.7 KB/token
  with int8, so 6.70 GiB at the full 524 288), and the rest is taken from the
  expert cache. Verified live with a needle placed past the trained range
  (found at 520 940 tokens; 528 140 tokens are refused, never truncated).
  See `docs/STRATA-NVFP4-OPERATOR.md` §3a.
- **The KV quantization is int8, not q4_0, on purpose.** Past the trained 262 144
  the fork picks the RoPE method by the KV type: int8/fp16 allow *dynamic* (the
  trained angles stay exact while the dialog fits, yarn only beyond that), while
  q4_0/k8v4 force yarn everywhere and lose the trained angles on every short
  dialog. `docs/KV-CACHE-MATH.md` has the numbers.
- **The engine is calibrated for this box** (`docs/CALIBRATION.md`): the PCIe
  share, the draft floor, the CPU worker count and the expert tier were
  measured here; the only setting that changed is `--pool-workers 10`.

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
`--gpus '"device=1"'` to pin to the 5090.

For PyTorch / vLLM inside the container, use `CUDA_VISIBLE_DEVICES=0` to
target the 5090.

## License

This repository's recipe is MIT (see `LICENSE`). The fork it builds,
[sergqwer/strata-nvfp4](https://github.com/sergqwer/strata-nvfp4), is MIT as well
and carries its own copyright. The model weights are under the Qwen Community
License 1.0.
