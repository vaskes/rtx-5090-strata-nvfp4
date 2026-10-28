#!/usr/bin/env python3
"""Test the Strata vision encoder via the OpenAI-compatible API.

Creates a 256x256 PNG with text and color, sends it to the server, prints
the model's response. Use this to verify a fresh deployment is working.

Usage:
    python3 scripts/test-vision.py
"""
import base64
import json
import sys
import urllib.request
from io import BytesIO

from PIL import Image, ImageDraw


def make_test_image() -> bytes:
    """256x256 RGB image: slate-blue background, yellow text "Hello Vision",
    red border."""
    img = Image.new("RGB", (256, 256), color=(73, 109, 137))
    draw = ImageDraw.Draw(img)
    draw.text((50, 100), "Hello Vision", fill=(255, 255, 0))
    draw.rectangle([(20, 20), (236, 236)], outline=(255, 0, 0), width=3)
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def main():
    api_key = sys.argv[1] if len(sys.argv) > 1 else "STRATA_API_KEY"
    url = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8080/v1/chat/completions"

    img_bytes = make_test_image()
    b64 = base64.b64encode(img_bytes).decode("ascii")

    payload = {
        "model": "qwen3.8-flash-next-mix-nvfp4",
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Что написано на картинке? Какой цвет фона?"},
                    {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}}
                ]
            }
        ],
        "max_tokens": 300,
        "temperature": 0.0
    }

    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        }
    )

    with urllib.request.urlopen(req, timeout=120) as r:
        resp = json.loads(r.read())

    print("REPLY:", resp["choices"][0]["message"]["content"])
    print()
    t = resp["timings"]
    print(f"decode: {t['predicted_per_second']:.1f} tok/s, MTP: {t['draft_n_accepted']}/{t['draft_n']}")
    print(f"prompt: {t['prompt_n']} tokens, prefill {t['prompt_per_second']:.1f} tok/s")


if __name__ == "__main__":
    main()
