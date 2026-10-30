#!/usr/bin/env python3
"""Cut a text file to an exact number of Strata tokens, using the model's own tokenizer.

WHY THIS RUNS INSIDE THE CONTAINER: the tokenizer is the oracle - the pack's
`tokenizer/` directory (vocab.json + merges.txt + token_type.json) read by the
fork's `tools/strata_tokenizer.py`. The container's `/venv/bin/python` is the
only interpreter on this box with `regex`; the host has no tokenizer at all, and
no host pip install is allowed. So the host hands the container a text file and
gets back a file with an exact token count.

    /venv/bin/python /data/bench/strata-token-cut.py \
        --tokenizer /data/models/<model>/pack/tokenizer \
        --in /data/bench/corpus.txt --out /data/bench/part.txt \
        --tokens 65536 [--start-token 0] [--prefix-file F] [--suffix-file F]

It prints a JSON report on stdout: the token count of the cut part, of the
composed content, and the character lengths. The byte-level BPE is lossless, so
`decode(ids[:N])` is exactly the first N tokens' text - the cut never splits a
multi-byte character when the corpus is UTF-8 text.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time

TOOLS = "/opt/strata/tools"


def load_tokenizer(tokenizer_dir: str):
    sys.path.insert(0, TOOLS)
    import strata_tokenizer as ST  # the fork's reference implementation

    d = pathlib.Path(tokenizer_dir)
    vocab = json.loads((d / "vocab.json").read_text(encoding="utf-8"))
    tokens: list[str | None] = [None] * len(vocab)
    for t, i in vocab.items():
        tokens[i] = t
    merges = (d / "merges.txt").read_text(encoding="utf-8").split("\n")
    types = json.loads((d / "token_type.json").read_text())
    return ST.Tokenizer(tokens, merges, types)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokenizer", required=True)
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="dst", default="")
    ap.add_argument("--tokens", type=int, default=0)
    ap.add_argument("--start-token", type=int, default=0)
    ap.add_argument("--prefix-file", default="")
    ap.add_argument("--suffix-file", default="")
    ap.add_argument("--count-only", action="store_true",
                    help="only count the tokens of the input file")
    a = ap.parse_args()

    if not a.count_only and (not a.dst or a.tokens <= 0):
        ap.error("--out and --tokens are required unless --count-only is given")

    t0 = time.time()
    tk = load_tokenizer(a.tokenizer)
    t_load = time.time() - t0

    src = pathlib.Path(a.src)
    text = src.read_text(encoding="utf-8")
    t1 = time.time()
    ids = tk.encode(text)
    t_encode = time.time() - t1

    report = {
        "source": str(src),
        "source_chars": len(text),
        "source_tokens": len(ids),
        "load_s": round(t_load, 2),
        "encode_s": round(t_encode, 2),
    }

    if a.count_only:
        print(json.dumps(report))
        return 0

    start = a.start_token
    end = start + a.tokens
    if end > len(ids):
        print(json.dumps({**report, "error": f"corpus has {len(ids)} tokens, need {end}"}))
        return 2

    part = tk.decode(ids[start:end])
    prefix = pathlib.Path(a.prefix_file).read_text(encoding="utf-8") if a.prefix_file else ""
    suffix = pathlib.Path(a.suffix_file).read_text(encoding="utf-8") if a.suffix_file else ""
    content = prefix + part + suffix

    t2 = time.time()
    content_tokens = len(tk.encode(content))
    part_tokens = len(tk.encode(part))
    report.update({
        "part_tokens": part_tokens,
        "part_chars": len(part),
        "content_tokens": content_tokens,
        "content_chars": len(content),
        "compose_encode_s": round(time.time() - t2, 2),
        "total_s": round(time.time() - t0, 2),
    })

    pathlib.Path(a.dst).write_text(content, encoding="utf-8")
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
