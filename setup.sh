#!/usr/bin/env bash
#
# Build s1-mini-engine and fetch the S1-mini GGUF weights from Hugging Face.
#
# Usage:
#   ./setup.sh              # Q6_K (recommended, ~495 MB)
#   MODEL=Q8_0 ./setup.sh   # higher quality, ~640 MB
#   MODEL=F16  ./setup.sh   # full precision, ~1.2 GB
#
# Override the download source when you fork this project:
#   HF_REPO=<user>/<repo> ./setup.sh
#
# The download itself is handled by `s1-mini-engine pull`, so this script and the
# binary can never disagree about where weights come from or where they land.
#
set -euo pipefail

BIN_REL=".build/release/s1-mini-engine"

MODEL="${MODEL:-Q6_K}"
case "$MODEL" in
Q6_K | Q8_0 | F16) ;;
*)
    echo "error: MODEL must be one of Q6_K, Q8_0, F16 (got '$MODEL')" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "error: s1-mini-engine ships an arm64 macOS framework and only builds on macOS." >&2
    exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
    echo "error: the bundled llama.xcframework is arm64-only (Apple Silicon)." >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' not found. Install Xcode or the Swift toolchain first." >&2
    exit 1
fi

echo "Building release binary ..."
swift build -c release

# `pull` reads $MODEL and $HF_REPO itself and stores weights in the directory the
# binary already searches (~/.cache/s1-mini), so no flags are needed here.
echo
"$ROOT/$BIN_REL" pull --model "$MODEL"

echo
echo "Binary: $ROOT/$BIN_REL"
echo
echo "Try it:"
echo "  $BIN_REL \"um so uh the deploy failed again\""
