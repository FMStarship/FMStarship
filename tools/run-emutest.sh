#!/bin/bash
# Runs compiled test functions natively and in the emulator, and requires identical results.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
clang -O2 -fno-inline -w -ISources/CA64/include -ISources/CA64 tools/emutest.c \
    Sources/CA64/a64.c Sources/CA64/simd.c Sources/CA64/memory.c Sources/CA64/math_stubs.c -o "$OUT/emutest" -lm
"$OUT/emutest" | tail -1
