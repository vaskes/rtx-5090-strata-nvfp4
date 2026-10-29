# KV Cache Math: why 512K context works with `int8` on a 32 GB card

**Status: measured on the live deployment (llmhost1, RTX 5090, 2026-10-29).**
The deployment runs `--max-context 524288 --kv int8` and a needle was found at
520,940 tokens. See `docs/STRATA-NVFP4-OPERATOR.md` §3a for the operator view.

> **This file previously claimed that int8 at 512K does not fit (9.4 GB → OOM).**
> That was wrong: it counted 17 attention layers and ignored that this fork's
> K/V is **elastic** (it grows into VRAM as a request reaches it, taking the
> room from the expert cache). The measured numbers below replace it.

## Where the numbers come from

The engine reports its own K/V budget at startup. On the live container:

```
strata generate: elastic K/V: 16384 of 524288 cells in VRAM (0.25 of 6.70 GiB);
  the expert cache (5267 slots) gives the K/V room below slot 1937 as the context grows
```

⇒ **13.7 KB of K/V per context token** at int8 (12 QSA layers + the draft
layer), i.e.:

| context | K/V if fully resident |
|---|---|
| 262 144 | 3.35 GiB |
| 524 288 | **6.70 GiB** |

(`setup.py` agrees: `kv_streaming_ram_gb()` = `ctx * 13 * KV_CELL_BYTES / 1e9`,
and `KV_CELL_BYTES["int8"] = 1056` per token per layer.)

## Why it fits anyway: the K/V is elastic

The fork's `--kv-grow` (on by default here) does **not** reserve the whole
`--max-context` up front. The engine keeps only the cells a request actually
reaches in VRAM and the expert cache holds the rest; as the context grows, the
expert cache gives slots back:

```
strata: K/V grown to 360448 cells (4.62 GiB); the expert cache gave 798 slots for it,
  194 hotter experts moved to colder ones' slots (4222 of 5267 slots hold experts)
strata: K/V grown to 524288 cells (6.70 GiB); the expert cache gave 49 slots for it,
  14 hotter experts moved to colder ones' slots (3715 of 5267 slots hold experts)
```

So the real trade at 512K is **not** "OOM vs not" — it is **expert cache
slots vs PCIe reloads**:

| prompt tokens | K/V in VRAM | expert cache slots | decode |
|---|---|---|---|
| 358 940 | 4.62 GiB | 4222 / 5267 | 84.0 tok/s |
| 502 940 | 6.50 GiB | 3764 / 5267 | 84.0 tok/s |
| 520 940 | 6.70 GiB (full) | 3715 / 5267 | 84.9 tok/s |

At the full 512K the cache holds ~29 % fewer experts, so more expert reads come
over PCIe. On short dialogs this does not show: the hit rate returns to 76–80 %.

## Why `int8` and not `q4_0`

Because of the **RoPE method**, not because of memory.

Past the trained 262144 the setup picks the extension method:

- `--kv int8` / `fp16` → **dynamic** — the trained angles stay bit-for-bit while
  a dialog fits 262144, and past that it switches to yarn with factor
  `positions / 262144` (rounded up to 0.125, capped by `--rope-scale 2`),
  rotating the cached keys in place:
  `rope dynamic: factor 1.375 -> 2 (request): 294912 cells re-rotated in 10.1 ms`.
- `--kv q4_0` / `k8v4` → **yarn** is forced, because the engine refuses
  dynamic on a 4-bit K/V (`setup.py: rope_dynamic_blocker()` →
  "needs 8-bit or fp16 K/V").

Halving the K/V memory would therefore cost the trained angles on every dialog
shorter than 262144 — the case that actually runs all day. int8 is both more
accurate and, here, sufficient.

## RAM is not the constraint

The K/V lives in VRAM; the experts (103.13 GiB) live in RAM. The host has
125 622 MB total, ~7.4 GB available with the engine loaded — and no KV
streaming is used (`--kv-streaming` is not applicable to this engine: it grows
the K/V in VRAM instead).

## Practical settings

- **256K + int8** — the previous default; same quality, half the K/V ceiling.
- **512K + int8** — current default; costs expert cache slots only when a
  request is genuinely enormous.
- **512K + q4_0** — not recommended here: forces yarn, and memory is not the
  binding constraint.
- **512K + vision** — vision runs on the CPU in this build, so it does not
  compete for VRAM.

## How to verify in this deployment

```bash
# what the engine itself says the K/V budget is
docker exec strata-nvfp4 grep "elastic K/V" /opt/strata/strata-qwen-mix-nvfp4.log

# what it actually reached, and what the expert cache gave up
docker exec strata-nvfp4 grep -E "K/V grown|K/V trimmed" /opt/strata/strata-qwen-mix-nvfp4.log

# the RoPE method it chose
docker exec strata-nvfp4 grep "rope scaling" /opt/strata/strata-qwen-mix-nvfp4.log
```

And the end-to-end proof (needle past the trained range) is
`scripts/needle-512k.py`, described in `docs/STRATA-NVFP4-OPERATOR.md` §3a.
