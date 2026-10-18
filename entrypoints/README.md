# Entrypoints

These shell scripts are the runtime glue between this Strata NVFP4 image and a
production deployment. They handle the things the upstream `docker-entrypoint.sh`
doesn't:

- Skipping `--model` (NVFP4 families have no size variants; upstream passes
  `--model IQ2_XS` which is invalid)
- `setup.py --yes` with stdin redirected to skip the interactive
  "Disable censorship?" prompt
- Optional `UNCENSORED` / `CONTEXT` / `VISION` / `KV` env vars

## Available entrypoints

| Script | Context | KV | Use case |
|---|---|---|---|
| `strata-start.sh` | 256K (default) | int8 | **Production default.** Fits 32 GB comfortably. Best decode speed. |
| `strata-512k-vision.sh` | 512K | q4_0 | Special case: huge documents (hundreds of K tokens). 2x slower decode than int8 at same context. |

## Usage

Mount the script into the container at `/custom-entrypoint.sh` and set
`--entrypoint /custom-entrypoint.sh`. The image's `CMD` is `["/custom-entrypoint.sh"]`
so this is the only entrypoint you need to configure.

```bash
docker run -d --name strata-nvfp4 \
  --gpus '"'"'"device=1"'"'"' \                        # RTX 5090 (idx 1 in nvidia-smi)
  -p 8080:8080 \
  --ulimit memlock=-1 \
  -v /opt/strata-data:/data \                         # persistent model + config
  -v $(pwd)/entrypoints/strata-start.sh:/custom-entrypoint.sh:ro \
  -e FAMILY=qwen-nvfp4-mix \
  -e CONTEXT=262144 \                                 # 256K
  -e VISION=yes \                                     # GPU image encoder
  -e KV=int8 \                                        # 1056 B/cell
  -e UNCENSORED=on \                                  # engine-level censorship off
  -e HF_TOKEN=hf_xxx \                                # for first-run model download
  -e API_KEY=vaskes-strata-2026 \
  --entrypoint /custom-entrypoint.sh \
  --restart unless-stopped \
  strata-nvfp4:sm120
```

For 512K, swap to `strata-512k-vision.sh` and set `CONTEXT=524288 KV=q4_0`.

## Environment variables

All entrypoints read these env vars:

| Var | Default | Effect |
|---|---|---|
| `FAMILY` | `qwen-nvfp4-mix` | Model family. This fork's NVFP4 + Q8_0 mix for 128 GB PCs. |
| `CONTEXT` | `262144` (start) / `524288` (512k) | Max context in tokens. |
| `VISION` | `yes` | GPU image encoder (`mmproj-Qwen3.8-Flash-Next-BF16.gguf`, 0.9 GB download). Set to `no` to skip. |
| `KV` | `int8` (start) / `q4_0` (512k) | KV cache precision. `int8` for quality, `q4_0` for memory. |
| `UNCENSORED` | `on` | Engine-level censorship off via cvec projection. The default in upstream is censored. |
| `LOW_RAM` | `off` | Set to `on` if RAM < 100 GB. Will SSD-stream experts (slower). |
| `HF_TOKEN` | (none) | Required for first-run download. The model `Maximilian228/Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata` is on HF. |
| `API_KEY` | (none) | Bearer token for the OpenAI-compatible API. Pick anything. |
| `HOST` | `0.0.0.0` | Bind address. |
| `PORT` | `8080` | Bind port. |
| `GGUF_DIR` | (none) | Path to pre-staged GGUF files. Usually not needed. |
| `ROPE_SCALING` | (start: empty) / `yarn` (512k) | For past-trained context: `yarn`, `linear`, `dynamic`, or `none`. |
| `ROPE_SCALE` | (auto) | Factor for yarn/linear. Empty = derive from `context/trained`. |

## What happens on first container start

1. setup.py detects no engine vision binary → builds `strata-vision` from
   `tools/vision` with the host's CUDA arch (one-time, ~2 min)
2. setup.py detects no model files → downloads from HF (~158 GB, ~30-60 min
   on a fast connection, longer on slow)
3. setup.py creates `strata-qwen-mix-nvfp4.json` config
4. Engine starts, loads experts into RAM (103 GB), expert cache into VRAM
5. Server is ready (1-3 min after engine start for experts to page in)

Subsequent restarts skip steps 1-3.

## What the engine does at startup with our config

- `--expert-cache auto` — engine auto-sizes based on available VRAM (~22 GB on
  RTX 5090 with int8 KV)
- `--kv-grow` (default) — KV cache allocates only as the context grows
- `--no-low-ram` — all experts stay in RAM (103 GB); engine pages them to
  VRAM as needed
- `--uncensored on` (via setup.py) — engine applies cvec projection to
  remove refusal directions

## Why the custom entrypoints and not the upstream one

The upstream `docker-entrypoint.sh` does:
```sh
ARGS="... --model $MODEL ..."    # --model IQ2_XS hardcoded
.venv/bin/python setup.py --setup --no-start $ARGS
exec .venv/bin/python setup.py $ARGS
```

The hardcoded `--model IQ2_XS` is **invalid for NVFP4 families** (they have
no size variants). setup.py accepts it but the engine refuses at start. The
fix: omit `--model` and let setup.py auto-derive from the model files in
`/data/models/`.

Also, setup.py asks "Disable censorship?" interactively at first start
(fails without a TTY). The custom entrypoint passes `--uncensored` directly
via the env var and the `--yes` flag.
