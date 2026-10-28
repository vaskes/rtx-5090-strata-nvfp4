#!/usr/bin/env python3
"""Build request files at specific byte sizes for the context-limit probe.

Usage: bench-prepare-ctx.py <bytes> [<bytes> ...]
Each byte count becomes /tmp/ctx-probe-<bytes>.json
"""
import json
import sys

DICT = "/opt/dreamline/artefacts/russian_accents_full.json"
HEADER = "# Словарь ударений русского языка\n\n"
QUESTION = "\n\n---\nВопрос: приведи ударение слова 'аароновец'."


def raw_prefix(target_bytes):
    with open(DICT, "rb") as f:
        return f.read(target_bytes).decode("utf-8", errors="ignore")


for arg in sys.argv[1:]:
    n = int(arg)
    prompt = HEADER + raw_prefix(n) + QUESTION
    payload = {
        "model": "qwen3.8-flash-next-mix-nvfp4",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 50,
        "temperature": 0.0,
    }
    path = f"/tmp/ctx-probe-{n}.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    print(f"  {n} bytes -> {path} ({len(prompt):,} chars)")
