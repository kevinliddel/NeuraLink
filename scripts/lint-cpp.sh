#!/usr/bin/env bash
#
# Lints NeuraLink's own C/C++ bridge code — never the upstream llama.cpp/ tree
# or NeuraLink/Dependencies/:
#   1. clang-format --dry-run -Werror  (style, config in .clang-format)
#   2. cppcheck                        (static analysis, if installed)
#
# Usage: scripts/lint-cpp.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Our first-party C/C++ lives only in NeuraLink/Core/Bridge. Discover it so new
# bridge files are linted automatically; no path here has spaces.
FILES=$(find NeuraLink/Core/Bridge -type f \
    \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' \
       -o -name '*.h' -o -name '*.hpp' -o -name '*.mm' \) | sort)

echo "== clang-format =="
# shellcheck disable=SC2086
clang-format --dry-run -Werror ${FILES}
echo "clang-format: OK"

echo "== cppcheck =="
if command -v cppcheck > /dev/null; then
    # --inline-suppr lets justified suppressions live next to the code. The
    # bridge headers include framework headers we don't analyze (llama / whisper
    # / onnxruntime), so missing-system-include noise stays off by default.
    # shellcheck disable=SC2086
    cppcheck \
        --enable=warning,performance,portability \
        --inconclusive \
        --error-exitcode=1 \
        --inline-suppr \
        --suppress=unusedStructMember \
        --std=c++17 \
        --language=c++ \
        -I NeuraLink/Core/Bridge \
        ${FILES}
    echo "cppcheck: OK"
else
    echo "cppcheck not installed — skipping (brew install cppcheck)" >&2
fi
