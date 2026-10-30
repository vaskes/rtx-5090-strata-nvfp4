#!/usr/bin/env python3
"""longctx-bench.py - prefill & decode benchmark against the LIVE Strata prod.

WHAT IT MEASURES (per run):
  * prefill: the engine's own clock - `timings.prompt_n` / `prompt_ms` /
    `prompt_per_second` (tokens the engine actually read), plus the server log's
    "reading the prompt: X of Y tokens, T s so far" progression.
  * decode: `timings.predicted_per_second` (llama.cpp's names) and the server
    log's "done: N tokens in T s (X tok/s)".
  * the context cost: the disk read rate of the engine process (the PLE n-gram
    table is read from NVMe), the GPU utilisation/VRAM/power and the PCIe link
    width, sampled every 2 s while the request runs.

HOW THE PROMPT IS SIZED: the corpus is cut to an exact token count by the
model's own tokenizer (scripts/strata-token-cut.py, running inside the
container with the pack's tokenizer/), and the chat template's overhead is
measured with two throwaway requests before the real ones. Every number the
server reports is kept as-is: nothing is rounded to make a story fit.

The API key is read from the service's env file and never printed, never written
to a report, never sent anywhere but 127.0.0.1.

    python3 scripts/longctx-bench.py --sizes 65536,131072,262144 --out-tokens 65536
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import time
import urllib.request

API = "http://127.0.0.1:8081"
ENV_FILE = "/opt/strata-nvfp4.service.d/env"
CONTAINER = "strata-nvfp4"
WORK = pathlib.Path("/opt/strata-data/bench")
HOSTLOG = pathlib.Path("/var/log/strata-nvfp4")
TOKENIZER = ("/data/models/Maximilian228--Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata/"
             "pack/tokenizer")
CUT_HELPER = "/data/bench/strata-token-cut.py"
FORK = "/opt/strata-nvfp4/src-0.2.0"

INSTRUCTION = """You are the author of a long, self-contained technical reference chapter.

Write a complete chapter of AT LEAST 70,000 tokens of prose from the SOURCE MATERIAL below.
Rules:
- Cover the source material exhaustively, section by section: numbered sections (1, 1.1, 1.1.1, ...),
  detailed explanations, worked examples, edge cases, and quoted excerpts from the source.
- Never summarise, never abbreviate, never write "as an AI", never write a placeholder such as
  "[continued]" or "the rest follows".
- Keep writing, section after section, until the chapter is at least 70,000 tokens long.

SOURCE MATERIAL:
"""


# --------------------------------------------------------------------------- helpers
def sh(cmd: list[str], timeout: int = 600) -> tuple[int, str, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def api_key() -> str:
    for line in pathlib.Path(ENV_FILE).read_text().splitlines():
        if line.startswith("API_KEY="):
            return line.split("=", 1)[1].strip()
    raise SystemExit(f"API_KEY not found in {ENV_FILE}")


def http_json(path: str, body: dict | None = None, timeout: int = 300) -> dict:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    data = None
    headers = {"Authorization": f"Bearer {api_key()}"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=data, headers=headers,
                                 method="POST" if body is not None else "GET")
    with opener.open(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def build_corpus(target_bytes: int) -> pathlib.Path:
    """Concatenate the fork's English markdown docs into one corpus file."""
    WORK.mkdir(parents=True, exist_ok=True)
    out = WORK / "corpus.txt"
    files = sorted(pathlib.Path(FORK).rglob("*.md"),
                   key=lambda p: (-p.stat().st_size, str(p)))
    total = 0
    with out.open("w", encoding="utf-8") as fh:
        for f in files:
            if total >= target_bytes:
                break
            try:
                text = f.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            fh.write(f"\n\n===== FILE: {f} =====\n\n")
            fh.write(text)
            total += len(text)
    return out


def cut(container_path: str, out_path: str, tokens: int, start_token: int,
        prefix_file: str = "") -> dict:
    cmd = ["docker", "exec", CONTAINER, "/venv/bin/python", CUT_HELPER,
           "--tokenizer", TOKENIZER, "--in", container_path, "--out", out_path,
           "--tokens", str(tokens), "--start-token", str(start_token)]
    if prefix_file:
        cmd += ["--prefix-file", prefix_file]
    rc, out, err = sh(cmd, timeout=1800)
    if rc != 0:
        raise SystemExit(f"token cut failed rc={rc}: {err[-800:]}\n{out[-800:]}")
    return json.loads(out.strip().splitlines()[-1])


def count_tokens(container_path: str) -> int:
    cmd = ["docker", "exec", CONTAINER, "/venv/bin/python", CUT_HELPER,
           "--tokenizer", TOKENIZER, "--in", container_path, "--count-only"]
    rc, out, err = sh(cmd, timeout=600)
    if rc != 0:
        raise SystemExit(f"token count failed rc={rc}: {err[-800:]}\n{out[-800:]}")
    return int(json.loads(out.strip().splitlines()[-1])["source_tokens"])


def start_sampler(tag: str, seconds: int) -> None:
    script = HOSTLOG / "longctx-sampler.sh"
    script.write_text(
        "#!/bin/sh\n"
        f"tag=$1; dur=$2\n"
        "pid=$(pgrep -f '/opt/strata/engine/strata --serve' | head -1)\n"
        "end=$(( $(date +%s) + dur ))\n"
        "out=/var/log/strata-nvfp4/longctx-$tag.io.log\n"
        "echo 'ts|rchar|read_bytes|wchar|gpu_util|gpu_mem_mib|power_w|pcie_w|pcie_gen' > $out\n"
        "while [ $(date +%s) -lt $end ]; do\n"
        "  io=$(awk '/^rchar:|^read_bytes:|^wchar:/{printf \"%s \", $2}' /proc/$pid/io 2>/dev/null)\n"
        "  gpu=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw,"
        "pcie.link.width.current,pcie.link.gen.current --format=csv,noheader,nounits 2>/dev/null | head -1)\n"
        "  echo \"$(date +%s.%N)|$io|$gpu\" >> $out\n"
        "  sleep 2\n"
        "done\n",
        encoding="utf-8")
    script.chmod(0o755)
    sh(["docker", "exec", "-d", CONTAINER, "sh", str(script), tag, str(seconds)])


def stop_sampler() -> None:
    sh(["docker", "exec", CONTAINER, "pkill", "-f", "longctx-sampler.sh"], timeout=60)


def docker_logs_since(epoch: int) -> str:
    rc, out, err = sh(["docker", "logs", "--since", str(epoch), CONTAINER], timeout=120)
    return out + err


RE_PROMPT = re.compile(r"reading the prompt: ([\d,]+) of ([\d,]+) tokens, (\d+) s so far")
RE_DONE = re.compile(r"done: ([\d,]+) tokens in (\d+) s \(([\d.]+) tok/s\) \(([^)]*)\)(.*)")
RE_THINK = re.compile(r"thinking: ([\d,]+) of budget ([\d,]+) \(max ([\d,]+)\) tokens, ([\d.]+) tok/s, (\d+) s")


def parse_log(log: str, prompt_tokens: int) -> dict:
    """Pull our request's lines out of the server log (the total prompt size is the key)."""
    prefills, done, thinks = [], [], []
    for line in log.splitlines():
        m = RE_PROMPT.search(line)
        if m and int(m.group(2).replace(",", "")) == prompt_tokens:
            prefills.append({"seen": int(m.group(1).replace(",", "")),
                             "total": int(m.group(2).replace(",", "")),
                             "seconds": int(m.group(3))})
        m = RE_THINK.search(line)
        if m:
            thinks.append({"tokens": int(m.group(1).replace(",", "")),
                           "budget": int(m.group(2).replace(",", "")),
                           "max": int(m.group(3).replace(",", "")),
                           "tok_s": float(m.group(4)), "seconds": int(m.group(5))})
        m = RE_DONE.search(line)
        if m:
            done.append({"tokens": int(m.group(1).replace(",", "")),
                         "seconds": int(m.group(2)),
                         "tok_s": float(m.group(3)),
                         "finish": m.group(4),
                         "expert_cache": m.group(5).strip()})
    return {"prefill_lines": prefills[-3:], "done_lines": done[-3:], "thinking_lines": thinks[-2:]}


def parse_samples(path: pathlib.Path) -> dict:
    if not path.exists():
        return {}
    rows = []
    for line in path.read_text(errors="ignore").splitlines()[1:]:
        parts = line.split("|")
        if len(parts) < 3:
            continue
        try:
            ts = float(parts[0])
            io = [int(x) for x in parts[1].split() if x]
            gpu = [x.strip() for x in parts[2].split(",")] if len(parts) > 2 else []
            rows.append({"ts": ts, "io": io, "gpu": gpu})
        except ValueError:
            continue
    if len(rows) < 1:
        return {}
    first, last = rows[0], rows[-1]
    dt = last["ts"] - first["ts"]
    read_b = (last["io"][1] - first["io"][1]) if len(last["io"]) > 1 else 0
    rchar = (last["io"][0] - first["io"][0]) if last["io"] else 0
    utils = []
    for r in rows:
        try:
            utils.append(float(r["gpu"][0]))
        except (IndexError, ValueError):
            pass
    return {
        "samples": len(rows),
        "seconds": round(dt, 1),
        "disk_read_MBps": round(read_b / dt / 1e6, 2) if dt > 0 else None,
        "disk_rchar_MBps": round(rchar / dt / 1e6, 2) if dt > 0 else None,
        "gpu_util_mean": round(sum(utils) / len(utils), 1) if utils else None,
        "gpu_util_max": max(utils) if utils else None,
        "gpu_mem_mib_max": max((int(r["gpu"][1]) for r in rows if len(r["gpu"]) > 1), default=None),
        "power_w_max": max((float(r["gpu"][2]) for r in rows if len(r["gpu"]) > 2), default=None),
        "pcie_width": sorted({r["gpu"][3] for r in rows if len(r["gpu"]) > 3}),
        "pcie_gen": sorted({r["gpu"][4] for r in rows if len(r["gpu"]) > 4}),
    }


# --------------------------------------------------------------------------- the run
def run_one(size: int, out_tokens: int, max_tokens: int, tag: str, start_token: int,
            instruction_tokens: int, overhead: int, model: str) -> dict:
    print(f"[{tag}] building the prompt for {size} tokens ...", flush=True)
    want_content = size - overhead
    corpus_c = "/data/bench/corpus.txt"
    part_c = f"/data/bench/part-{tag}.txt"
    instr_c = "/data/bench/instruction.txt"
    report = cut(corpus_c, part_c, want_content - instruction_tokens, start_token,
                 prefix_file=instr_c)

    content = (WORK / f"part-{tag}.txt").read_text(encoding="utf-8")
    body = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": max_tokens,
        "reasoning_budget_tokens": 2048,
        "stream": False,
    }

    print(f"[{tag}] request: prompt ~{size} tok, max_tokens={max_tokens} -> {API}", flush=True)
    t0 = int(time.time())
    start_sampler(tag, 3600)
    t_start = time.time()
    try:
        resp = http_json("/v1/chat/completions", body, timeout=3600)
    finally:
        wall = time.time() - t_start
        time.sleep(3)      # let the sampler's last line land before it is killed
        stop_sampler()

    log = docker_logs_since(t0)
    (HOSTLOG / f"longctx-{tag}.server.log").write_text(log, encoding="utf-8")

    usage = resp.get("usage") or {}
    timings = resp.get("timings") or {}
    choice = (resp.get("choices") or [{}])[0]
    msg = choice.get("message") or {}
    prompt_tokens = int(usage.get("prompt_tokens") or 0)

    calls = [{
        "wall_s": round(wall, 1),
        "finish_reason": choice.get("finish_reason"),
        "usage": usage,
        "timings": timings,
        "content_chars": len(msg.get("content") or ""),
        "reasoning_chars": len(msg.get("reasoning_content") or ""),
        "log": parse_log(log, prompt_tokens),
    }]
    total_completion = int(usage.get("completion_tokens") or 0)

    # The answer must be at least out_tokens long. If the model stopped early, keep
    # the conversation going - the prefix is cached then, so the continuation's
    # prefill is NOT a prefill measurement; it is only counted into the total.
    round_no = 1
    while total_completion < out_tokens and round_no < 6:
        round_no += 1
        follow = {
            "model": model,
            "messages": body["messages"] + [
                {"role": "assistant", "content": msg.get("content") or ""},
                {"role": "user", "content": "Continue the chapter from exactly where it stopped. "
                                            "Keep writing the next sections; the chapter must reach "
                                            "at least 70,000 tokens in total. Do not summarise, "
                                            "do not repeat what you already wrote."},
            ],
            "max_tokens": max_tokens,
            "reasoning_budget_tokens": 2048,
            "stream": False,
        }
        print(f"[{tag}] continuation {round_no}: have {total_completion} of {out_tokens} tokens",
              flush=True)
        t0c = int(time.time())
        t_start = time.time()
        resp2 = http_json("/v1/chat/completions", follow, timeout=3600)
        wall2 = time.time() - t_start
        log2 = docker_logs_since(t0c)
        (HOSTLOG / f"longctx-{tag}-cont{round_no}.server.log").write_text(log2, encoding="utf-8")
        usage2 = resp2.get("usage") or {}
        timings2 = resp2.get("timings") or {}
        choice2 = (resp2.get("choices") or [{}])[0]
        msg2 = choice2.get("message") or {}
        total_completion += int(usage2.get("completion_tokens") or 0)
        calls.append({
            "wall_s": round(wall2, 1),
            "finish_reason": choice2.get("finish_reason"),
            "usage": usage2,
            "timings": timings2,
            "content_chars": len(msg2.get("content") or ""),
            "reasoning_chars": len(msg2.get("reasoning_content") or ""),
            "log": parse_log(log2, 0),
            "note": "continuation: the prompt is cached, so its prefill is not a measurement",
        })
        msg = msg2
        body = follow

    samples = parse_samples(HOSTLOG / f"longctx-{tag}.io.log")
    out = {
        "tag": tag,
        "requested_prompt_tokens": size,
        "requested_output_tokens": out_tokens,
        "max_tokens": max_tokens,
        "reasoning_budget_tokens": 2048,
        "instruction_tokens": instruction_tokens,
        "template_overhead_tokens": overhead,
        "prompt_build": report,
        "calls": calls,
        "total_completion_tokens": total_completion,
        "samples": samples,
        "at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    path = WORK / f"report-{tag}.json"
    path.write_text(json.dumps(out, indent=1), encoding="utf-8")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default="65536,131072,262144")
    ap.add_argument("--out-tokens", type=int, default=65536)
    ap.add_argument("--max-tokens", type=int, default=73728)
    ap.add_argument("--corpus-bytes", type=int, default=4_000_000)
    a = ap.parse_args()

    WORK.mkdir(parents=True, exist_ok=True)
    HOSTLOG.mkdir(parents=True, exist_ok=True)

    # the instruction, as a file the container can read (it is the prefix of the prompt)
    (WORK / "instruction.txt").write_text(INSTRUCTION, encoding="utf-8")
    for name in ("strata-token-cut.py",):
        src = pathlib.Path(__file__).resolve().parent / name
        if src.exists():
            (WORK / name).write_bytes(src.read_bytes())

    models = http_json("/v1/models")
    model = (models.get("data") or [{}])[0].get("id") or "strata"
    print(f"model alias: {model}", flush=True)

    corpus = build_corpus(a.corpus_bytes)
    print(f"corpus: {corpus} ({corpus.stat().st_size} bytes)", flush=True)

    instruction_tokens = count_tokens("/data/bench/instruction.txt")

    # the chat template's overhead, measured with a throwaway request
    (WORK / "probe.txt").write_text("CALIBRATION PROBE", encoding="utf-8")
    probe_content_tokens = count_tokens("/data/bench/probe.txt")
    probe = http_json("/v1/chat/completions", {
        "model": model,
        "messages": [{"role": "user", "content": "CALIBRATION PROBE"}],
        "max_tokens": 1,
        "stream": False,
    }, timeout=120)
    probe_tokens = int((probe.get("usage") or {}).get("prompt_tokens") or 0)
    overhead = probe_tokens - probe_content_tokens
    print(f"template overhead: {overhead} tokens (probe prompt_tokens={probe_tokens}, "
          f"content={probe_content_tokens})", flush=True)

    sizes = [int(x) for x in a.sizes.split(",") if x.strip()]
    results = []
    offsets = {65536: 0, 131072: 25_000, 262144: 60_000}
    for size in sizes:
        tag = f"p{size}"
        r = run_one(size, a.out_tokens, a.max_tokens, tag,
                    offsets.get(size, size // 4), instruction_tokens, overhead, model)
        results.append(r)
        c = r["calls"][0]
        t = c["timings"]
        print(f"[{tag}] prompt_tokens={c['usage'].get('prompt_tokens')} "
              f"completion={c['usage'].get('completion_tokens')} "
              f"prefill={t.get('prompt_per_second')} tok/s "
              f"decode={t.get('predicted_per_second')} tok/s "
              f"total_completion={r['total_completion_tokens']}", flush=True)

    summary = WORK / "summary.json"
    summary.write_text(json.dumps({"results": results}, indent=1), encoding="utf-8")
    print(f"summary: {summary}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
