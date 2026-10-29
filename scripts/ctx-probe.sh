#!/bin/bash
# Probe the max usable context on the running Strata server.
# Usage: ctx-probe.sh <bytes> [<bytes> ...]
set -u
# The API key is NEVER stored in this repository. It lives in the service's
# root-only env file on the host: /opt/strata-nvfp4.service.d/env (API_KEY=...).
# Export it before running this script:
#   export STRATA_API_KEY="$(grep -m1 ^API_KEY= /opt/strata-nvfp4.service.d/env | cut -d= -f2-)"
KEY="${STRATA_API_KEY:?STRATA_API_KEY is not set - see the comment above}"
URL="http://127.0.0.1:8081/v1/chat/completions"

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
