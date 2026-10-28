#!/bin/bash
# A/B benchmark runner for Strata NVFP4.
# Uses pre-generated request files (/tmp/ab-req-*.json from bench-prepare.py).
#
# Usage: bench-gpu-ab.sh <label>
#   reads the server on 127.0.0.1:8080, writes /tmp/ab-raw-<label>.jsonl

set -u

LABEL="${1:-unknown}"
URL="http://127.0.0.1:8080/v1/chat/completions"
KEY="STRATA_API_KEY"
CONTAINER="strata-nvfp4"
RAW="/tmp/ab-raw-${LABEL}.jsonl"

rm -f "$RAW"

echo "=== benchmark: ${LABEL} ==="
echo "GPU in use:"
nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader
echo

for label in decode_only ctx_50k ctx_150k ctx_243k; do
    REQ="/tmp/ab-req-${label}.json"
    [ -f "$REQ" ] || { echo "--- ${label}: MISSING $REQ"; continue; }

    echo "--- ${label} ---"
    LOGFILE="/opt/strata/strata-qwen-mix-nvfp4.log"
    LOGSTART=$(docker exec "$CONTAINER" sh -c "wc -l < $LOGFILE" 2>/dev/null || echo 0)

    RESP=$(curl -sS -m 900 -X POST "$URL" \
        -H "Authorization: Bearer ${KEY}" \
        -H "Content-Type: application/json" \
        --data @"$REQ" 2>&1)

    echo "$RESP" | python3 -c "
import json, sys
label = '${label}'
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception as e:
    print('  PARSE ERROR:', e, raw[:200]); sys.exit(0)
if 'choices' not in d:
    print('  API ERROR:', str(d)[:250]); sys.exit(0)
t = d['timings']; u = d['usage']
out = d['choices'][0]['message']['content'] or ''
mtpa = 100*t['draft_n_accepted']/t['draft_n'] if t['draft_n'] else 0
print(f\"  prompt {u['prompt_tokens']:>8,} tok | prefill {t['prompt_per_second']:>8,.1f} tok/s ({t['prompt_ms']:>7.0f} ms)\")
print(f\"  decode {u['completion_tokens']:>8,} tok | decode  {t['predicted_per_second']:>8,.1f} tok/s ({t['predicted_ms']:>7.0f} ms)\")
print(f\"  MTP {mtpa:.0f}% | cached {u['prompt_tokens_details']['cached_tokens']:,} | {out[:60]!r}\")
rec = {
    'label': label,
    'prompt_tokens': u['prompt_tokens'],
    'completion_tokens': u['completion_tokens'],
    'prefill_tps': round(t['prompt_per_second'], 1),
    'prefill_ms': round(t['prompt_ms'], 0),
    'decode_tps': round(t['predicted_per_second'], 1),
    'decode_ms': round(t['predicted_ms'], 0),
    'mtp_accept_pct': round(mtpa, 1),
    'cached_tokens': u['prompt_tokens_details']['cached_tokens'],
}
open('${RAW}', 'a').write(json.dumps(rec) + '\n')
" 2>&1

    sleep 1
    docker exec "$CONTAINER" tail -n +$((LOGSTART+1)) "$LOGFILE" 2>/dev/null \
        | grep -E "decode expert cache hit rate|strata serve: prompt " | tail -3 | sed 's/^/  /'
done

echo
echo "=== summary: ${LABEL} ==="
python3 -c "
import json
rows = [json.loads(l) for l in open('${RAW}')] if __import__('os').path.exists('${RAW}') else []
print(f\"{'test':<13} {'prompt tok':>10} {'prefill t/s':>12} {'decode t/s':>11} {'MTP%':>6}\")
for r in rows:
    print(f\"{r['label']:<13} {r['prompt_tokens']:>10,} {r['prefill_tps']:>12,.1f} {r['decode_tps']:>11,.1f} {r['mtp_accept_pct']:>6.0f}\")
"
echo
echo "saved: $RAW"
