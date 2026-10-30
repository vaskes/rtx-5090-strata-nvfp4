#!/usr/bin/env python3
"""Decode-speed probe for the Strata server: the A/B instrument for a calibration.

Measures the engine's own decode speed (`timings.predicted_per_second` in the
server's answer), not the wall clock, so the prefill and the HTTP overhead do
not colour the number. The prompts are the fork's own calibration prompts
(tools/calibrate.py PROMPTS), so a run here and a calibration run on the same
box talk about the same work.

    STRATA_API_KEY=... ./decode-bench.py --out before.json

The key is read from the environment only; it is never a command-line argument
(it would land in the process list and in the shell history) and never printed.
"""

import argparse
import json
import os
import statistics
import sys
import time
import urllib.request

# The fork's own calibration prompts (tools/calibrate.py, PROMPTS).
PROMPTS = (
    "Write a Python function that merges two sorted lists into one sorted list, with a docstring and two tests.",
    "Explain in two paragraphs how a refrigerator moves heat from inside to outside.",
    "List twelve European capitals with one sentence about each.",
)

MODEL = "qwen3.8-flash-next-mix-nvfp4"


def post(url: str, key: str, body: dict, timeout: float) -> tuple[dict, float]:
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    return data, time.perf_counter() - t0


def one_round(url: str, key: str, max_tokens: int, timeout: float) -> list[dict]:
    """One request per prompt; the numbers the server reported for it."""
    out = []
    for prompt in PROMPTS:
        body = {
            "model": MODEL,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0,
            "stream": False,
        }
        data, wall = post(url, key, body, timeout)
        t = data.get("timings") or {}
        out.append(
            {
                "prompt": prompt[:48],
                "decode_tok_s": t.get("predicted_per_second"),
                "prompt_tok_s": t.get("prompt_per_second"),
                "predicted_n": t.get("predicted_n"),
                "draft_accepted": t.get("draft_n_accepted"),
                "draft_n": t.get("draft_n"),
                "wall_s": round(wall, 3),
                "finish": (data.get("choices") or [{}])[0].get("finish_reason"),
            }
        )
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8081")
    ap.add_argument("--rounds", type=int, default=3, help="rounds over the three prompts")
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("--warmup", type=int, default=1, help="requests to burn before measuring")
    ap.add_argument("--label", default="")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    key = os.environ.get("STRATA_API_KEY", "")
    if not key:
        print("ERROR: STRATA_API_KEY is not set", file=sys.stderr)
        return 2

    url = args.url.rstrip("/") + "/v1/chat/completions"
    for _ in range(args.warmup):
        one_round(url, key, args.max_tokens, args.timeout)

    rounds = []
    for r in range(args.rounds):
        rounds.append(one_round(url, key, args.max_tokens, args.timeout))
        print(f"  round {r + 1}/{args.rounds}: " + "  ".join(
            f"{x['decode_tok_s']:.1f}" if x["decode_tok_s"] else "?" for x in rounds[-1]), flush=True)

    flat = [x for rnd in rounds for x in rnd]
    rates = [x["decode_tok_s"] for x in flat if x["decode_tok_s"]]
    acc = [(x["draft_accepted"] / x["draft_n"]) for x in flat if x["draft_accepted"] and x["draft_n"]]
    summary = {
        "label": args.label,
        "url": args.url,
        "rounds": args.rounds,
        "max_tokens": args.max_tokens,
        "decode_tok_s_median": round(statistics.median(rates), 2) if rates else None,
        "decode_tok_s_min": round(min(rates), 2) if rates else None,
        "decode_tok_s_max": round(max(rates), 2) if rates else None,
        "draft_acceptance_median": round(statistics.median(acc), 4) if acc else None,
        "samples": len(rates),
        "raw": rounds,
    }
    print(json.dumps({k: v for k, v in summary.items() if k != "raw"}, indent=1))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=1)
        print(f"written: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
