# Performance

All benchmarks on:
- **Host**: AMD Ryzen 9 9950X3D (Zen 5, AVX-512, 16 cores), 128 GB DDR5
- **GPU**: NVIDIA RTX 5090 32 GB, driver 610.57.04
- **Model**: `Maximilian228/Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata` (qwen-nvfp4-mix)

## Decode tok/s (default build vs Zen 5 build)

| Prompt | Default | Zen 5 + LTO | Δ |
|---|---|---|---|
| Short (10 tok reply) | 80.0 | 84.7 | +6% |
| Medium (50 tok reply) | 82.7 | 98.2 | +19% |
| Long (200 tok reply) | — | **101.4** | (peak) |
| Code (300 tok) | — | 96.3 | — |
| Math (300 tok) | — | 95.1 | — |

**Zen 5 build flags**:
```sh
-O3 -flto -march=native -mtune=znver4 \
-fno-plt -ffunction-sections -fdata-sections \
-fvisibility=hidden -fno-omit-frame-pointer
```

**Result**: 18-19% faster decode, +25% MTP acceptance (53-74% → 72-92%),
75% smaller binary (338 MB → 83 MB).

## MTP acceptance

| Context | MTP accept | Notes |
|---|---|---|
| Short (10 tok) | 92% | Easiest case, draft head predicts almost everything |
| Code (300 tok) | 91% | Structured output, easy to predict |
| Medium (50 tok) | 84% | Russian text |
| Math (300 tok) | 83% | Some math reasoning is hard to predict |
| Long (200 tok) | 75% | Distractor content makes the draft head less confident |
| English long (400 tok) | 72% | Worst case in the test set |

Higher MTP accept = more effective speedup from speculative decoding.

## Context length performance

### 256K mode (production default, int8 KV)

| Operation | tok/s |
|---|---|
| Prefill (1K tokens) | ~150 tok/s |
| Decode (short) | 80-100 tok/s |

### 512K mode (special case, q4_0 KV + YaRN)

| Operation | tok/s |
|---|---|
| Prefill (1K tokens) | ~150 tok/s |
| Prefill (143K tokens) | **6,237 tok/s** |
| Decode (short, 25 tok) | 87-95 tok/s |
| Decode (long, 200 tok) | 86-94 tok/s |

The 6,237 tok/s prefill at 143K context is from the Qwen3.8-Flash-Next sparse
attention (only 17 of 65 layers contribute to KV) plus fast on-GPU attention
kernels. Reading a 600 KB document is ~23 seconds wall time.

**Needle-in-haystack test passed**: 143K context with `secret_code_word =
PurpleEagle42` buried at paragraph 42 of 2000, model retrieved the word
correctly on first read.

## Vision performance

CPU vision path (default, what's running):
- ~2-6 seconds per image (256x256 PNG)
- 0 VRAM hit (all vision work in RAM)
- 16 threads on the CPU

GPU vision path (set `VISION=gpu` env var):
- <1 second per image
- ~1.4 GB VRAM hit (engine chooses smaller expert cache)
- Engine and vision on the same CUDA device

The engine chose CPU by default because the 32 GB VRAM is already nearly full
with the expert cache.

## Latency (time to first token)

| Operation | Time |
|---|---|
| Container start to health=ok | 1-3 min (after first run) |
| First request to first token (cold) | ~2-5 sec (KV cache empty) |
| First request to first token (warm, <8K context) | <1 sec |
| First request to first token (warm, 100K context) | ~3-5 sec (prefill) |

## Engine binary size

| Build | Size | AVX-512 instructions |
|---|---|---|
| Default (cmake Release) | 338 MB | 30,656 |
| Zen 5 + LTO | **83 MB** | **37,699** |

LTO inlines the C++ math into the hot AVX-512 paths, exposing more parallelism
to the scheduler (23% more AVX-512 instructions in 19% less code).

## What didn't help

- **AVX-512 VNNI** (vp4dpwssd): engine binary has 0 of these. The kernels
  don't exist in llama.cpp's ggml CPU backend.
- **BMI2** (pdep/pext): engine has 0. Same reason.
- **vpopcntdq**: engine has 0. No code path uses it.
- **PGO** (Profile-Guided Optimization): would give another 5-10% but
  requires running the engine, collecting profiles, and rebuilding. Not
  worth the complexity for a one-off deployment.
