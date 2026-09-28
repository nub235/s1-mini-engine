#!/usr/bin/env bash
#
# Publish the GGUF exports and the model card to Hugging Face.
#
# Requires the Hugging Face CLI:
#   pip install -U "huggingface_hub[cli]"
#   huggingface-cli login
#
# Usage:
#   HF_REPO=<user>/<repo> ./hf/upload.sh
#
set -euo pipefail

REPO="${HF_REPO:-nub235/s1-mini-GGUF}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v huggingface-cli >/dev/null 2>&1; then
    HF_CLI="huggingface-cli"
elif command -v hf >/dev/null 2>&1; then
    HF_CLI="hf"
else
    echo "error: install the Hugging Face CLI (pip install -U 'huggingface_hub[cli]')" >&2
    exit 1
fi

upload() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        echo "skip (missing): $src"
        return
    fi
    echo "uploading $src -> $REPO/$dst"
    "$HF_CLI" upload "$REPO" "$src" "$dst" --repo-type model
}

# Model card first so the repo exists and renders immediately.
upload "$ROOT/hf/README.md" "README.md"

for quant in Q6_K Q8_0 F16; do
    upload "$ROOT/s1-mini-${quant}.gguf" "s1-mini-${quant}.gguf"
done

echo
echo "Done. View at https://huggingface.co/${REPO}"
