#!/usr/bin/env python3
"""Parse one Strata probe response and print a one-line verdict."""
import json
import sys

path = sys.argv[1]
try:
    with open(path) as f:
        raw = f.read()
    d = json.loads(raw)
except Exception as e:
    print(f"PARSE FAIL: {e} {raw[:90]}")
    sys.exit(0)

if "choices" not in d:
    msg = d.get("error", {}).get("message", str(d))
    print(f"FAIL: {msg[:120]}")
    sys.exit(0)

t = d["timings"]
u = d["usage"]
print(
    f"OK  {u['prompt_tokens']:>8,} tok  "
    f"prefill {t['prompt_per_second']:>7,.0f} t/s  "
    f"decode {t['predicted_per_second']:>6,.1f} t/s  "
    f"cached {u['prompt_tokens_details']['cached_tokens']:,}"
)
