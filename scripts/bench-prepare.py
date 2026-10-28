#!/usr/bin/env python3
"""Build the A/B benchmark prompt suite for Strata.

Streams the first N bytes of the accent dictionary as raw text (no JSON parse —
it only needs to be prompt text, not a valid document), so this stays fast and
light on RAM.

Labels:
  decode_only  - short prompt, 500 max_tokens -> pure decode measurement
  ctx_50k      - ~50K token context  (100K chars)
  ctx_150k     - ~150K token context (300K chars)
  ctx_243k     - ~243K token context (500K chars)
"""
import json

DICT = "/opt/dreamline/artefacts/russian_accents_full.json"
HEADER = "# Словарь ударений русского языка\n\n"
QUESTION = "\n\n---\nВопрос: приведи ударение слова 'аароновец' и 'аароновца'."

Q_LONG = (
    "Напиши подробный технический текст на 400 слов о том, как работает "
    "спекулятивное декодирование в больших языковых моделях: Multi-Token "
    "Prediction, черновик-слой, окно верификации, вероятность принятия "
    "черновика. Объясни математику и приведи пример расчёта."
)


def raw_prefix(target_bytes):
    """First target_bytes bytes of the dictionary, as text."""
    with open(DICT, "rb") as f:
        raw = f.read(target_bytes)
    return raw.decode("utf-8", errors="ignore")


def main():
    suite = [
        ("decode_only", Q_LONG, 500),
        ("ctx_50k", HEADER + raw_prefix(250_000) + QUESTION, 300),
        ("ctx_150k", HEADER + raw_prefix(750_000) + QUESTION, 300),
        ("ctx_243k", HEADER + raw_prefix(1_050_000) + QUESTION, 300),
    ]

    for label, prompt, max_tokens in suite:
        payload = {
            "model": "qwen3.8-flash-next-mix-nvfp4",
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0.0,
        }
        path = f"/tmp/ab-req-{label}.json"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        print(f"  {label}: {len(prompt):,} chars -> {path}", flush=True)


if __name__ == "__main__":
    main()
