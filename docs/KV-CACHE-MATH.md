# KV Cache Math: why q4_0 vs int8 at 512K context

The 32 GB VRAM constraint on the RTX 5090 is the dominant design choice for
this deployment. This doc shows exactly why `q4_0` KV is the only way to fit
512K context, and what tradeoffs you make.

## Setup

- Model: Qwen3.8-Flash-Next NVFP4 (qwen-nvfp4-mix family)
- 65 layers total, **17 full attention layers**, 48 recurrent (no KV)
- 4 KV heads per attention layer
- Per-token KV cache = `17 layers × 4 heads × RoPE_dim × 2 (K+V) × bytes_per_value`
- RoPE dim = 64 (the model only stores the RoPE-rotating portion of K, not the full 128-dim key)

So per-token KV cache at attention layers (across all 17 full attention layers):
- 17 × 4 × 64 × 2 = 8,704 value-cells per token
- At int8 (1 byte): 8.7 KB/token
- At q4_0 with Hadamard (0.5 byte): 4.3 KB/token
- At fp16 (2 bytes): 17.4 KB/token

Wait — the engine help says int8 is 1056 B/cell. Let me re-check.

## What the engine actually reports

`strata --help`:
- `--kv int8`: int8 codes + fp16 scale per 64 values, "half" of fp16
- `--kv q4_0`: 4-bit, "half of int8's memory"
- `--kv k8v4`: INT8 K + rotated Q4_0 V, 816 B/cell
- `--kv fp16`: 2x int8

So the per-cell sizes are:
- fp16: ~2112 B/cell
- int8: 1056 B/cell
- k8v4: 816 B/cell
- q4_0: ~528 B/cell (= 1056/2)

A "cell" here is one token's KV at one attention layer (K and V together).

## Total VRAM for KV at 512K context

| KV type | B/cell | 17 layers × 524288 cells |
|---|---|---|
| fp16 | 2112 | 18.8 GB |
| int8 | 1056 | 9.4 GB |
| k8v4 | 816 | 7.3 GB |
| **q4_0** | **528** | **4.7 GB** |

## What fits in 32 GB VRAM

- Engine + dense model: ~6 GB
- Expert cache (auto): 22.4 GB
- KV cache: **3.6 GB available** (32 - 6 - 22.4)

| KV type | Full 512K (524K cells) | Fits? |
|---|---|---|
| fp16 | 18.8 GB | ❌ OOM |
| int8 | 9.4 GB | ❌ OOM at 500K |
| k8v4 | 7.3 GB | ❌ OOM at 500K |
| **q4_0** | **4.7 GB** | ⚠️ tight at 500K |
| q4_0 + kv-resident 32K | 588 MB (only 32K cells in VRAM) | ✅ at any context |

`--kv-grow` (default) means the KV cache only allocates as the context grows.
For a 50K request, q4_0 uses 460 MB. For a 200K request, 1.8 GB. Fits.

The 4.7 GB at full 512K is tight — the engine would have to evict part of
the expert cache to fit. In practice, the engine chooses: if the expert
profile says "this expert is needed for the next 100K tokens", it pages it
in and evicts KV, and vice versa. The result is some expert cache misses
on very long contexts, which the engine handles via PCIe reload (the experts
live in RAM, the KV cache lives in VRAM).

## q4_0 vs int8 quality

q4_0 is **Hadamard-rotated 4-bit**, not naive 4-bit quantization. The rotation
spreads the values uniformly before quantization, so 4 bits give almost the
same precision as int8 with much less memory. Strata's PR #21 added this.

The engine help says "slightly lower precision" for q4_0 vs int8. Strata's
own benchmark (`bench/results/2026-09-27-kv-q4`) shows the difference is
sub-percent on standard perplexity tests.

## kv-resident: streaming KV to RAM

For a really-tight VRAM situation, `--kv-resident N` keeps N cells per
attention layer in VRAM and streams the rest to pinned RAM.

```
--kv-resident 32768   # 32K cells per layer in VRAM
```

At q4_0: 32768 × 528 × 17 = 294 MB in VRAM (tiny)
Rest: in RAM

This is slower than pure VRAM (RAM bandwidth < VRAM bandwidth) but works for
huge contexts.

## Practical recommendation

For 32 GB VRAM:
- **256K context** (default): use `int8` KV. Best quality, fits, fastest.
- **512K context**: use `q4_0` KV. Slightly lower quality but 2x memory savings.
- **512K + vision + best quality**: use `q4_0` KV with `kv-resident 32K`.
  Slower but rock-solid.

For 24 GB VRAM (RTX 4090):
- Stick with 256K + int8
- 512K won't fit even with q4_0 (less VRAM headroom)

For 80 GB VRAM (H100, B200):
- 512K + int8 + still room for vision at GPU
- Use 256K + fp16 KV for best quality

## How to verify in your deployment

```bash
# Check VRAM at idle
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader

# Run a long context request
# (use the make-long-test.py from this repo or just paste a large doc)

# Watch VRAM during the request
watch -n 1 nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
```

If VRAM climbs to near 32 GB during a long request, the engine is doing
expert cache eviction. Performance will be lower than peak but still usable.
