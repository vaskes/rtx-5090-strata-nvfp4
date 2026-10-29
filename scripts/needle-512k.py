#!/usr/bin/env python3
"""Needle-in-haystack probe for Strata at 512K context.

The needle is buried DEEP in the document, past the model's trained 262144
positions, so a hit proves the extended (dynamic -> yarn) RoPE path works and
not just that the server accepts a long prompt.

Usage:
  python3 scripts/needle-512k.py /tmp/needle.json [paragraphs] [needle_at] [max_tokens]

  paragraphs   how many paragraphs the document has (default 5000)
  needle_at    which paragraph holds the needle (default 4000)
  max_tokens   answer budget (default 8000)

Then:
  export STRATA_API_KEY="$(grep -m1 ^API_KEY= /opt/strata-nvfp4.service.d/env | cut -d= -f2-)"
  curl -sS -X POST http://127.0.0.1:8081/v1/chat/completions \
    -H "Authorization: Bearer ${STRATA_API_KEY}" \
    -H "Content-Type: application/json" \
    --data @/tmp/needle.json

Measured on llmhost1 (RTX 5090, int8 K/V, --max-context 524288):
  358 940 tokens -> PurpleEagle42  (needle at ~281K, past the trained range)
  502 940 tokens -> PurpleEagle42  (needle at ~431K)
  520 940 tokens -> PurpleEagle42  (K/V at the full 524288 cells)
  528 140 tokens -> server refuses: "request exceeds the context window ...
                    requests are never truncated"

max_tokens must stay well above the engine's reasoning budget: at 100 the
answer comes back empty (finish_reason: length) with the real answer inside
reasoning_content.
"""
import json
import sys

FILLER = (
    "В квантовой механике существует принцип суперпозиции, который утверждает что "
    "квантовая система может находиться в нескольких состояниях одновременно до момента "
    "измерения. Кубит — это квантовый аналог классического бита, который может быть в "
    "состоянии 0, 1, или в суперпозиции обоих состояний. "
)

NEEDLE = "Параграф {i}: ВАЖНАЯ ИНФОРМАЦИЯ — secret_code_word = PurpleEagle42. "


def build(paragraphs: int, needle_at: int) -> str:
    out = ["# Документ: Энциклопедия квантовых вычислений\n\n"]
    for i in range(paragraphs):
        if i == needle_at:
            out.append(NEEDLE.format(i=i))
        else:
            out.append(f"Параграф {i}: " + FILLER)
    out.append(
        "\n\nВопрос: Какой secret_code_word был на Параграфе "
        f"{needle_at}? Ответь одним словом."
    )
    return "".join(out)


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/needle512k.json"
    paragraphs = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
    needle_at = int(sys.argv[3]) if len(sys.argv) > 3 else 4000
    max_tokens = int(sys.argv[4]) if len(sys.argv) > 4 else 8000
    prompt = build(paragraphs, needle_at)
    payload = {
        "model": "qwen3.8-flash-next-mix-nvfp4",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    print(f"wrote {out}: {len(prompt):,} chars, {paragraphs} paragraphs, "
          f"needle at paragraph {needle_at}, max_tokens={max_tokens}")


if __name__ == "__main__":
    main()
