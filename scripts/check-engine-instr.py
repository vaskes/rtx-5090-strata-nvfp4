#!/usr/bin/env python3
"""Inspect the compiled Strata engine binary for CPU instruction usage.

Counts EVEX (AVX-512) instructions, AVX-VNNI (int8 matmul), FMA, BMI2, BF16.
Use this to verify a Zen 5 build is actually using AVX-512 / AVX-VNNI.

Usage:
    python3 scripts/check-engine-instr.py /opt/strata/engine/strata
"""
import re
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        print("Usage: check-engine-instr.py <engine-binary>")
        sys.exit(1)
    engine = sys.argv[1]

    print(f"=== {engine} ===")
    try:
        result = subprocess.run(
            ["ls", "-la", engine], capture_output=True, text=True
        )
        print(result.stdout.strip())
    except FileNotFoundError:
        print(f"ERROR: {engine} not found")
        sys.exit(1)

    print()
    print("=== CPU features used by engine ===")
    instr_patterns = [
        ("AVX-512 EVEX (4-byte opcode 0x62)", r"^[[:space:]]*[0-9a-f]+:[[:space:]]+62"),
        ("AVX-512 VNNI (vp4dpwssd, vp4dpwssds, vpclmulqdq)", r"vp4dpwssd|vp4dpwssds|vpclmulqdq"),
        ("AVX-512 vpopcnt (vpopcntdq, vpopcntq)", r"vpopcntdq|vpopcntq"),
        ("AVX-VNNI int8 (vpdpbusd, vpdpwssd, vpshufbitqmb)", r"vpdpbusd|vpdpwssd|vpshufbitqmb"),
        ("FMA (vfmadd, vfmsub, vfnmadd, vfnmsub)", r"vfmadd|vfmsub|vfnmadd|vfnmsub"),
        ("BMI2 (vpdep, vpext)", r"[[:space:]](vpdep|vpext)[[:space:]]"),
        ("BF16 (vcvtne2ps2bf16, vdpbf16ps)", r"vcvtne2ps2bf16|vdpbf16ps"),
    ]

    for name, pattern in instr_patterns:
        result = subprocess.run(
            ["objdump", "-d", engine],
            capture_output=True,
            text=True,
            errors="replace"
        )
        count = len(re.findall(pattern, result.stdout))
        print(f"{name}: {count}")

    total = subprocess.run(
        ["objdump", "-d", engine], capture_output=True, text=True
    )
    total_lines = len(total.stdout.splitlines())
    print(f"\nTotal disasm lines: {total_lines}")


if __name__ == "__main__":
    main()
