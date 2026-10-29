# Entrypoints

This shell script is the runtime glue between the Strata NVFP4 image and a
production deployment. It handles the things the upstream `docker-entrypoint.sh`
doesn't:

- Skipping `--model` (NVFP4 families have no size variants; upstream passes
  `--model IQ2_XS` which is invalid)
- `setup.py --yes` with stdin redirected to skip the interactive
  "Disable censorship?" prompt
- Resolving the python interpreter, so the SAME script serves both the current
  image (`/venv`) and the previous-revision image kept for rollback
  (`/opt/strata/.venv`) — a hardcoded path makes the documented rollback fail
- The `UNCENSORED` / `CONTEXT` / `VISION` / `KV` / `VRAM_RESERVE_MIB` env vars

## The scripts

| Script | Where it runs | Use case |
|---|---|---|
| `strata-start-v020.sh` | inside the container, at `/custom-entrypoint.sh` | **Production default.** 256K, int8 KV, vision, uncensored. Serves both images (production and rollback). |
| `run.sh` | on the host, called by systemd | The whole `docker run` with every flag explicit — what the operator reviews before going live |

## Usage

Mount the script into the container at `/custom-entrypoint.sh` and set
`--entrypoint /custom-entrypoint.sh`.

```bash
docker run -d --name strata-nvfp4 \
  --gpus '"device=1"' \                        # RTX 5090 (idx 1 in nvidia-smi)
  -p 8081:8080 \                              # host port 8081 -> container 8080
  --ulimit memlock=-1 \
  -v /opt/strata-data:/data \                 # persistent model files
  -v $(pwd)/entrypoints/strata-start-v020.sh:/custom-entrypoint.sh:ro \
  -e FAMILY=qwen-nvfp4-mix \
  -e CONTEXT=262144 \                         # 256K
  -e VISION=yes \                             # images on (the encoder runs on the CPU)
  -e KV=int8 \                                # 1056 B/cell
  -e UNCENSORED=on \                          # engine-level censorship off
  -e VRAM_RESERVE_MIB=768 \                   # free VRAM for other programs
  -e HF_TOKEN=hf_xxx \                        # for first-run model download
  -e API_KEY=STRATA_API_KEY \
  --entrypoint /custom-entrypoint.sh \
  --restart unless-stopped \
  strata-nvfp4:sm120-v020
```

**Port 8081 on the host, 8080 inside the container.** The host's 8080 belongs to
the `llama-qwen5090-256k.service` unit; the container's own port stays 8080.

For 512K context (a special case, not the normal mode): `CONTEXT=524288 KV=q4_0`.
The fork then picks the YaRN extension with a factor of 2 on its own — `dynamic`
is refused with a 4-bit K/V cache. Measured on this build: a needle test
("PURPLEEAGLE42" in 10 270 tokens) was found, `max_context: 524288`. It needs the
whole 32 GB of VRAM, so it runs instead of the 256K instance, not next to it.

## Environment variables

All entrypoints read these env vars:

| Var | Default | Effect |
|---|---|---|
| `FAMILY` | `qwen-nvfp4-mix` | Model family. This fork's NVFP4 + Q8_0 mix for 128 GB PCs. |
| `CONTEXT` | `262144` | Max context in tokens. `524288` for the 512K special mode. |
| `VISION` | `yes` | Images on. The encoder runs on the CPU, so the VRAM stays with the experts. |
| `KV` | `int8` | KV cache precision: `int8` for quality, `q4_0` for memory (needed at 512K). |
| `UNCENSORED` | `on` | Engine-level censorship off via cvec projection. The upstream default is censored. |
| `LOW_RAM` | `off` | Set to `on` if RAM < 100 GB. Will SSD-stream experts (slower). |
| `VRAM_RESERVE_MIB` | `768` | VRAM the engine leaves free for other programs. Its own default is 700; below 512 the driver starts paging GPU memory to system RAM and decode collapses. |
| `HF_TOKEN` | (none) | Required for first-run download. The model `Maximilian228/Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata` is on HF. |
| `API_KEY` | (none) | Bearer token for the OpenAI-compatible API. Pick anything. |
| `HOST` | `0.0.0.0` | Bind address. |
| `PORT` | `8080` | Bind port **inside the container**. The host's published port is set in `run.sh`. |

## What happens on container start

1. setup.py verifies the model files against the repo's SHA-256 pins — they are
   already on disk under `/data`, so nothing is downloaded
2. setup.py writes the run config and the start script
3. The engine starts and loads the experts into RAM (103 GB, ~70 s); the expert
   cache goes into VRAM (~22 GB of the 32 GB)

On a later start, step 1 is a hash check and step 2 rewrites the same config.

## What the engine does at startup with our config

- `--expert-cache auto` — engine auto-sizes based on available VRAM (~22 GB on
  RTX 5090 with int8 KV)
- `--kv-grow` (default) — KV cache allocates only as the context grows
- `--no-low-ram` — all experts stay in RAM (103 GB); engine pages them to
  VRAM as needed
- `--vram-reserve-mib 768` — VRAM left for other programs on the card
- `--uncensored on` (via setup.py) — engine applies cvec projection to
  remove refusal directions

## Why the custom entrypoint and not the upstream one

The upstream `docker-entrypoint.sh` does:
```sh
ARGS="... --model $MODEL ..."    # --model IQ2_XS hardcoded
.venv/bin/python setup.py --setup --no-start $ARGS
exec .venv/bin/python setup.py $ARGS
```

The hardcoded `--model IQ2_XS` is **invalid for NVFP4 families** (they have
no size variants). setup.py accepts it but the engine refuses at start. The
fix: omit `--model` and let setup.py auto-derive from the model files in
`/data/models`.

Also, setup.py asks "Disable censorship?" interactively at first start
(fails without a TTY). The custom entrypoint passes `--uncensored` directly
via the env var and the `--yes` flag.

## Why the interpreter is resolved at runtime

Two images are in play:

| Image | Interpreter | Why |
|---|---|---|
| `strata-nvfp4:sm120-v020` (production) | `/venv/bin/python` | the fork's own Dockerfile keeps the venv **outside** the source tree — a `.venv` inside `/opt/strata` breaks the fork's own test suite, which walks `sys.modules` and asserts that every module loaded from the source root belongs to `serve`/`strata_cli`/`strata_control` |
| `strata-nvfp4:sm120` (rollback) | `/opt/strata/.venv/bin/python` | the previous revision kept its venv inside the tree |

Hardcoding either path breaks the other image, and the rollback is documented as
"swap the image tag and restart". So the entrypoint looks for `/venv/bin/python`
first and falls back to `/opt/strata/.venv/bin/python`. This was verified on a
live run: the previous-revision image started from this same script and served
normally.
