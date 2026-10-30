# Long-context benchmark on the live prod (2026-10-30)

Three runs against the **production** container (`strata-nvfp4`, RTX 5090,
`--max-context 524288 --kv int8 --rope-scaling dynamic --rope-scale 2
--pool-workers 10`), each with a prompt of 64K / 128K / 256K tokens and an
answer of **at least 64K tokens**.

Every number below is the engine's own accounting (`timings` in the API
response, llama.cpp's field names) or the server's log. Nothing is rounded to
make a story fit; the raw data is in
`docs/bench-raw/longctx-2026-10-30/`.

## The headline

| prompt (tokens) | prefill | decode | answer (tokens) | wall | MTP accepted | expert cache |
|---|---|---|---|---|---|---|
| **65,544** | 6,388 tok/s (10.26 s) | **81.0 tok/s** (12.35 ms/tok) | 73,728 | 920 s | 78.6 % | 72.5 % hit, +6.6 % over PCIe |
| **131,100** | 6,968 tok/s (18.81 s) | **78.8 tok/s** (12.69 ms/tok) | 94,681 (61,243 + 33,438) | 1,229 s | 77.8 % | 72.2 % hit, +6.5 % over PCIe |
| **262,181** | 6,647 tok/s (39.45 s) | **69.5 tok/s** (14.38 ms/tok) | 76,602 (51,188 + 25,414) | 1,159 s | 70.2 % | 70.0 % hit, +6.8 % over PCIe |

Two things to read off it:

1. **Prefill does not care about the context length.** 64K → 256K is a 4x
   longer prompt, and the prefill rate stays inside 6.4-7.0K tok/s - the spread
   is within this box's usual ±5-7 % start-to-start noise
   (`docs/CALIBRATION.md`). 256K tokens are read in 39 seconds.
2. **Decode does care: −14 % from 64K to 256K** (81.0 → 69.5 tok/s, i.e.
   12.35 → 14.38 ms per token). The mechanism is visible in the same log: the
   speculative acceptance falls (78.6 % → 70.2 %) and the expert cache hit
   falls (72.5 % → 70.0 %), so more of the work arrives over PCIe - and PCIe
   here is **Gen5 x8**, not x16 (`docs/CALIBRATION.md` §4).

## How it was measured

* **The prompt was cut to an exact token count by the model's own tokenizer**,
  not estimated: the pack's `tokenizer/` directory read by the fork's
  `tools/strata_tokenizer.py` (`scripts/strata-token-cut.py`, run inside the
  container - it is the only interpreter on this box with `regex`). The server
  confirmed the result: `usage.prompt_tokens` = 65,544 / 131,100 / 262,181
  against the requested 65,536 / 131,072 / 262,144 (the small surplus is the
  chat template plus the instruction; the template's overhead was measured
  separately with a throwaway request: **52 tokens**).
* **The corpus** is the fork's own English documentation (4.06 MB, 1,270,483
  tokens), sliced at a different offset per run (0 / 25,000 / 60,000) so that
  no two runs share a prefix and the conversation cache cannot hide a prefill
  (`usage.prompt_tokens_details.cached_tokens` = 0, `timings.cache_n` = 0 on
  every first call).
* **Request**: `max_tokens = 73728`, `reasoning_budget_tokens = 2048`,
  `stream = false`, no sampling overrides (the prod defaults). The thinking
  budget is what makes the ≥64K answer possible: `max_tokens` counts the
  thinking too, so an uncapped thinker would eat the whole budget and answer
  nothing (`serve/server.py`: *"max_tokens counts the thinking too"*). With the
  cap the model thought 1,870 / 1,862 / 1,457 tokens and wrote the rest.
* **The answer requirement**: ≥ 65,536 tokens. At 64K the model never stopped -
  it hit the 73,728 cap (`finish_reason: length`). At 128K and 256K it stopped
  on its own (61,243 and 51,188 tokens), so the conversation was continued
  (*"continue the chapter from exactly where it stopped"*) until the total
  passed 65,536. **A continuation's prefill is a cache hit, not a measurement**
  - the second calls report `cache_n` = 131,095 and 262,176 - and they are
  reported separately in the raw JSON for exactly that reason.
* **In parallel**: the engine's `/proc/<pid>/io` (rchar, read_bytes), the GPU
  (utilisation, VRAM, power, PCIe width/gen) every 2 s, and the container's
  log.

## What the disk did

| prompt | rchar (PLE reads) | read_bytes (real block I/O) | GPU util (mean/max) | VRAM | power (max) |
|---|---|---|---|---|---|
| 65,544 | 4.4 MB/s | ≈ 0 | 99.3 % / 100 % | 31,608 MiB | 496 W |
| 131,100 | 7.0 MB/s | ≈ 0 | 99.4 % / 100 % | 31,608 MiB | 511 W |
| 262,181 | 13.5 MB/s | ≈ 0 | 99.4 % / 100 % | 31,608 MiB | 510 W |

The reads scale with the context - the PLE n-gram table is consulted for every
generated token - but **the physical NVMe is not involved**: `read_bytes` stays
at ~0 because the 47.68 GiB table is served from the page cache. This is the
same measurement as in `docs/STRATA-NVFP4-OPERATOR.md` §6a, at 3-8x the rate.

## Caveats, stated plainly

* **Throughput only.** Nobody read the 70K-token chapters and graded them. A
  model at temperature 0 can loop; this run used the prod sampling defaults
  and the answers are long enough, but their quality is not claimed here.
* **The log windows overlap.** `docker logs --since` for the 256K run still
  contained the tail of the 128K run's continuation, so its `done_lines` list
  has two entries. The 64K and 128K windows contain exactly our own requests -
  no other traffic was interleaved (the bot was idle), so the numbers are not
  a contended measurement.
* **The context length is the only variable**, but the engine's own state is
  not: each run starts with the expert cache in whatever state the previous
  request left it. The cache-hit numbers above are the engine's own.
* **512K is extrapolated, not measured.** The trend (decode −14 % from 64K to
  256K) points at roughly 60-65 tok/s at the full 512K context, but nobody ran
  that: the prompt would be 512K tokens plus a 64K answer and the prefill
  would take ~80 s. The x16-slot fix in `docs/CALIBRATION.md` §4 is worth more
  than any of these numbers.

## Re-running it

```bash
cd /opt/rtx-5090-strata-nvfp4-fresh
python3 scripts/longctx-bench.py --sizes 65536,131072,262144 \
        --out-tokens 65536 --max-tokens 73728 --corpus-bytes 4000000
```

It needs the prod container up (it measures the prod engine), it writes
`/opt/strata-data/bench/report-*.json` and the server/IO logs under
`/var/log/strata-nvfp4/`, and it reads the API key from the service's env file
(never printed, never written to a report). It refuses to be a benchmark of
anything but prod: the numbers it prints are the prod container's.

Raw data: `docs/bench-raw/longctx-2026-10-30/`
(`summary.json`, `report-p*.json`, `longctx-p*-server.txt` - the server's own
log lines, `longctx-p*-io-samples.txt` - the 2-second GPU/IO samples,
`bench-transcript.txt` - the runner's stdout).
