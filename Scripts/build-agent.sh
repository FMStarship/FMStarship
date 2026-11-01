#!/bin/bash
# Builds the arm64 agent that FM loads at launch. Any signature will do for FM: its own
# disable-library-validation entitlement lets it load the library.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
clang -O2 -Wall -dynamiclib -arch arm64 -ISources/CStarshipProtocol/include \
    -o build/libStarshipAgent.dylib agent/agent.c
codesign -f -s - build/libStarshipAgent.dylib
