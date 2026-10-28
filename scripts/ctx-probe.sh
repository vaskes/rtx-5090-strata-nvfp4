#!/bin/bash
# Probe the max usable context on the running Strata server.
# Usage: ctx-probe.sh <bytes> [<bytes> ...]
set -u
KEY="STRATA_API_KEY"
URL="http://127.0.0.1:8080/v1/chat/completions"

for n in "$@"; do
    F="/tmp/ctx-probe-${n}.json"
    [ -f "$F" ] || { echo "  $n: MISSING $F"; continue; }
    printf "%9s bytes: " "$n"
    curl -sS -m 900 -X POST "$URL" \
        -H "Authorization: Bearer ${KEY}" \
        -H "Content-Type: application/json" \
        --data @"$F" > /tmp/probe-out.json 2>/tmp/probe-err.txt
    if [ ! -s /tmp/probe-out.json ]; then
        echo "CURL FAIL: $(head -c 90 /tmp/probe-err.txt)"
        continue
    fi
    python3 /tmp/ctx-probe-parse.py /tmp/probe-out.json
done
