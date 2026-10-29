# RTX 5090 vs RTX 5080 — A/B benchmark for Strata NVFP4

**Date**: 2026-10-28
**Host**: llmhost1 (85.136.112.144:12007), AMD Ryzen 9 9950X3D, 122 GiB RAM
**Model**: `Maximilian228/Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata` (158 GB)
**Engine**: `strata-nvfp4:sm120`, Zen 5 build (-O3 -flto -march=native)
**Context in test**: 256K (int8 KV) and 512K config (q4_0 KV)
**Vision**: enabled, uncensored: on, both cards

## Hardware

| | RTX 5080 | RTX 5090 |
|---|---|---|
| nvidia-smi idx | 0 | 1 |
| Chip | GB203 | GB202 |
| VRAM | 16 GB (15.9 usable) | 32 GB (31.8 usable) |
| CUDA | 12.0 (sm_120) | 12.0 (sm_120) |
| PCIe bus | 01:00.0 | 02:00.0 |
| PCIe link (measured) | **Gen5 x8, 28.9 GB/s h2d** | **Gen5 x8, 28.9 GB/s h2d** |

Both cards are on **x8** lanes (not x16) — lane sharing with an M.2 device.
Measured host→device bandwidth: **28.9 GB/s** (engine's own PCIe probe).
This is the same for both cards, so PCIe is not the differentiator — VRAM is.

## Results

### RTX 5090 (32 GB) — int8 KV, 256K context

| Test | prompt tok | prefill tok/s | decode tok/s | MTP | expert cache hit | over PCIe |
|---|---|---|---|---|---|---|
| decode_only | 121 | 243 | **85.7** | 81% | 77.7% | 3.8% |
| ctx_50k | 57,239 | **6,626** | **88.8** | 82% | 76.5% | 5.5% |
| ctx_150k | 168,212 | **6,016** | **98.7** | 76% | 84.5% | 2.1% |
| ctx_243k | 236,501 | **4,948** | **103.9** | 86% | 83.2% | 2.8% |

Expert cache: **5,252 slots, 22.17 GiB VRAM**
Max context: **262,144 tokens** (full config at the time of this benchmark — the deployment now runs 524288; see `docs/STRATA-NVFP4-OPERATOR.md` §3a)

### RTX 5080 (16 GB) — int8 KV, 256K context

| Test | prompt tok | prefill tok/s | decode tok/s | MTP | expert cache hit | over PCIe |
|---|---|---|---|---|---|---|
| decode_only | 121 | 150 | **52.5** | 83% | 58.1% | 10.6% |
| ctx_50k | 57,239 | **2,410** | **53.0** | 75% | 58.6% | 11.2% |
| ctx_66k | 61,879 | 2,269 | 46.9 | — | — | — |
| ctx_67k+ | 158K chars | **FAIL** | — | — | — | — |

Expert cache: **1,646 slots, 6.77 GiB VRAM**
Max context: **~62,000 tokens** — above that:
```
the K/V cannot grow to this prompt: no VRAM is left
verify: instantiate: out of memory
the engine stopped unexpectedly (exit code 1); the next request restarts it
```

The engine **crashes** (CUDA OOM), the server restarts it (60+ s), and the
next long request crashes it again. This is a failure loop, not a graceful
degradation.

### RTX 5080 (16 GB) — q4_0 KV, 512K config

| Test | prompt tok | prefill tok/s | decode tok/s |
|---|---|---|---|
| ctx_57k | 57,232 | 2,311 | 44.8 |
| ctx_65k | 65,379 | 2,053 | 53.0 |
| ctx_68k | 68,337 | 1,970 | 47.3 |
| ctx_88k | 88,407 | 2,261 | 50.1 |
| ctx_110k | — | **FAIL: no VRAM is left** | — |

Max context: **~88,000 tokens** (1.4x better than int8, still far from 256K)

## Verdict: RTX 5090 for the LLM. Unambiguous.

| Metric | 5090 | 5080 | 5090 advantage |
|---|---|---|---|
| Decode tok/s (small ctx) | 85.7 | 52.5 | **1.63x** |
| Decode tok/s (57K ctx) | 88.8 | 53.0 | **1.68x** |
| Decode tok/s (150K ctx) | 98.7 | **crash** | ∞ |
| Prefill tok/s (57K ctx) | 6,626 | 2,410 | **2.75x** |
| Prefill tok/s (168K ctx) | 6,016 | **crash** | ∞ |
| Max context (int8 KV) | 262,144 | ~62,000 | **4.2x** |
| Max context (int8 KV, 512K config) | 524,288 | ~62,000 | **8.4x** |
| Max context (q4_0 KV) | 524,288 | ~88,000 | **6.0x** |
| Expert cache | 5,252 slots / 22.17 GiB | 1,646 slots / 6.77 GiB | 3.2x |
| Expert cache hit rate | 76-85% | 58% | +20-27pp |
| Experts served over PCIe | 2.1-5.5% | 10.6-11.2% | 2-5x less PCIe traffic |

**The 5080 is not a usable LLM card for this model.** It is 1.6x slower on
decode, 2.7x slower on prefill, and it **dies** above ~62K tokens of context
instead of degrading gracefully.

## Why the gap is so large

The model is a 125B-class MoE with ~103 GiB of experts. The engine keeps as
many experts as fit in VRAM and pages the rest over PCIe (28.9 GB/s).

- **5090**: 22.17 GiB expert cache = 5,252 slots = 76-85% hit rate.
  Only 2-5% of routed experts cross PCIe per token.
- **5080**: 6.77 GiB expert cache = 1,646 slots = 58% hit rate.
  10-11% of routed experts cross PCIe per token. That's 2-5x more PCIe
  traffic on a link that is already x8.

The PCIe traffic is what makes decode drop from ~90 to ~52 tok/s: every
missed expert is a PCIe round-trip on the critical path of the token.

Plus the KV cache: at 256K with int8 KV, the 5080 has no VRAM left for the
K/V itself — it fails with "no VRAM is left" before it can even prefetch.

## Recommendation

- **RTX 5090 (nvidia-smi idx 1) → Strata NVFP4 / LLM.** Full 256K context,
  85-104 tok/s decode, 5000-6600 tok/s prefill, vision, uncensored.
- **RTX 5080 (nvidia-smi idx 0) → ComfyUI / image generation.** It already
  runs comfyui80 there. 16 GB VRAM is plenty for diffusion, and the LLM
  workload does not fit it.

Do not try to run both models on the 5080 to "save" the 5090 for something
else: the LLM needs the 32 GB, and 62K context with a crash loop above that
is not a production configuration.

## Reproducing

Scripts live in `scripts/`:

```bash
# 1. build the prompt suite (streams the accent dictionary as raw text)
python3 scripts/bench-prepare.py

# 2. run the benchmark against the running server
bash scripts/bench-gpu-ab.sh rtx5090

# 3. context-limit probe (find where the engine dies)
python3 scripts/bench-prepare-ctx.py 250000 300000 400000 500000
bash scripts/ctx-probe.sh 250000 300000 400000 500000
```

Switching cards: stop the container, change `--gpus '"device=0"'` (5080) or
`--gpus '"device=1"'` (5090), start again. The image is the same — both
cards are sm_120.

## Hardware note

The 128 GiB RAM in this host is **borrowed** from another production machine
(2026-10-20: the engine died with `memory guard: limit 60.9 GiB` when the
stick was removed). The systemd unit is therefore disabled by default and
must be started manually while the RAM is in place.
