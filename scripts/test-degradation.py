#!/usr/bin/env python3
"""Measure Strata decode speed as context grows toward 256K.

Loads /opt/dreamline/artefacts/russian_accents_full.json (3.26M entries,
172 MB), takes the first N entries as context, asks a fixed question, records
the decode tok/s.

Goal: see how decode speed degrades from ~100 tok/s at small context to
how-much at 220K tokens.

Usage:
    python3 scripts/test-degradation.py
    # or with custom sizes:
    python3 scripts/test-degradation.py --sizes 1000 50000 100000 220000
"""
import os
import argparse
import json
import sys
import time
import urllib.request


URL = "http://127.0.0.1:8081/v1/chat/completions"
# Never hardcoded: the key lives in the host's root-only env file
# (/opt/strata-nvfp4.service.d/env). Export STRATA_API_KEY before running.
API_KEY = os.environ.get("STRATA_API_KEY", "")
if not API_KEY:
    raise SystemExit(
        "STRATA_API_KEY is not set. Read it from the host: "
        "export STRATA_API_KEY=\"$(grep -m1 ^API_KEY= /opt/strata-nvfp4.service.d/env | cut -d= -f2-)\""
    )
MODEL = "qwen3.8-flash-next-mix-nvfp4"

# Russian accent dictionary - 3.26M entries, ~172 MB on disk
DICT_PATH = "/opt/dreamline/artefacts/russian_accents_full.json"

# The fixed question asked at every context size
QUESTION = (
    "\n\n---\nВопрос: Найди в словаре слово 'аароновец' и приведи его"
    " ударение, а также слова 'аароновца' и 'аароновцу'. В ответе"
    " используй только точные данные из словаря."
)


def load_dict() -> dict:
    print(f"Loading {DICT_PATH}...", file=sys.stderr)
    with open(DICT_PATH) as f:
        d = json.load(f)
    print(f"Loaded {len(d)} entries", file=sys.stderr)
    return d


def make_context(d: dict, target_chars: int) -> str:
    """Take the first N entries until we hit ~target_chars total length."""
    parts = ["# Словарь ударений русского языка\n\n"]
    used = len(parts[0])
    entries = []
    for k, v in d.items():
        # each entry: "key=value,\n" ~5 chars overhead
        line = f"{k}={v},\n"
        if used + len(line) > target_chars:
            break
        entries.append(line)
        used += len(line)
    parts.append("".join(entries))
    return "".join(parts) + QUESTION


def send_request(prompt: str) -> dict:
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 100,
        "temperature": 0.0
    }
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        URL,
        data=data,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json"
        }
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=300) as r:
        resp = json.loads(r.read())
    wall = time.time() - t0
    resp["wall_seconds"] = wall
    return resp


def main():
    parser = argparse.ArgumentParser()
    # Default sizes in target character count.
    # Russian Qwen tokenizes ~2.5 chars/token on this content type, so:
    #   1M chars ≈ 400K tokens (more than max)
    #   500K chars ≈ 200K tokens
    #   250K chars ≈ 100K tokens
    parser.add_argument(
        "--chars",
        type=int,
        nargs="+",
        default=[25_000, 100_000, 250_000, 500_000, 750_000, 1_000_000]
    )
    args = parser.parse_args()

    d = load_dict()
    print()
    print(f"{'chars':>10} | {'prompt_n':>8} | {'prefill tok/s':>13} | "
          f"{'decode tok/s':>12} | {'MTP%':>5} | {'wall s':>7}")
    print("-" * 80)

    results = []
    for target_chars in args.chars:
        prompt = make_context(d, target_chars)
        actual_chars = len(prompt)
        try:
            resp = send_request(prompt)
            t = resp["timings"]
            prompt_n = t["prompt_n"]
            decode = t["predicted_per_second"]
            prefill = t["prompt_per_second"]
            mtp_pct = (100 * t["draft_n_accepted"] / t["draft_n"]) if t["draft_n"] else 0
            wall = resp["wall_seconds"]
            print(f"{actual_chars:>10,} | {prompt_n:>8,} | {prefill:>13,.1f} | "
                  f"{decode:>12,.1f} | {mtp_pct:>5.0f} | {wall:>7.1f}")
            results.append({
                "chars": actual_chars,
                "prompt_n": prompt_n,
                "prefill_tps": prefill,
                "decode_tps": decode,
                "mtp_pct": mtp_pct,
                "wall_s": wall
            })
        except Exception as e:
            print(f"{actual_chars:>10,} | ERROR: {e}")
            results.append({"chars": actual_chars, "error": str(e)})

    print()
    print("=== degradation curve (decode tok/s vs context size) ===")
    for r in results:
        if "error" in r:
            print(f"  {r['chars']:>10,} chars  ERROR")
        else:
            print(f"  {r['prompt_n']:>8,} tokens  {r['decode_tps']:>6.1f} tok/s decode")


if __name__ == "__main__":
    main()
