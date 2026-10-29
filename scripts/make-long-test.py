#!/usr/bin/env python3
"""Generate a long-context test prompt (needle-in-haystack) for Strata.

Buries `secret_code_word = PurpleEagle42` in paragraph 42 of a 2000-paragraph
"document" and asks the model to find it. Saves a JSON request body to a file.

The test verifies:
1. The server can prefill a long context (~143K tokens)
2. The model can find information buried deep in long context
3. The KV cache works correctly across the full context

Usage:
    python3 scripts/make-long-test.py /tmp/long_test.json
    curl -X POST http://localhost:8081/v1/chat/completions \\
        -H "Authorization: Bearer STRATA_API_KEY" \\
        -H "Content-Type: application/json" \\
        --data @/tmp/long_test.json
"""
import json
import sys


def make_test_prompt() -> dict:
    paras = []
    for i in range(2000):
        if i == 42:
            # The needle. Paragraph 42 contains the answer.
            paras.append(
                "Параграф 42: ВАЖНАЯ ИНФОРМАЦИЯ — secret_code_word = PurpleEagle42. "
            )
        else:
            paras.append(
                f"Параграф {i}: В квантовой механике существует принцип "
                f"суперпозиции, который утверждает что квантовая система может "
                f"находиться в нескольких состояниях одновременно до момента "
                f"измерения. Кубит — это квантовый аналог классического бита, "
                f"который может быть в состоянии 0, 1, или в суперпозиции обоих "
                f"состояний. "
            )

    context = (
        "# Документ: Энциклопедия квантовых вычислений\n\n" + "".join(paras)
    )
    question = (
        "\n\nВопрос: Какой secret_code_word был на Параграфе 42?"
    )

    return {
        "model": "qwen3.8-flash-next-mix-nvfp4",
        "messages": [
            {"role": "user", "content": context + question}
        ],
        "max_tokens": 100,
        "temperature": 0.0
    }


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/long_test.json"
    payload = make_test_prompt()
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    size_mb = len(json.dumps(payload, ensure_ascii=False)) / (1024 * 1024)
    print(f"wrote {out} ({size_mb:.1f} MB, ~140K tokens)")
    print("POST with:")
    print(f'  curl -X POST http://localhost:8081/v1/chat/completions \\')
    print(f'      -H "Authorization: Bearer STRATA_API_KEY" \\')
    print(f'      -H "Content-Type: application/json" \\')
    print(f'      --data @{out}')


if __name__ == "__main__":
    main()
