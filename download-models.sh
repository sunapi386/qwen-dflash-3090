#!/usr/bin/env bash
set -euo pipefail

if [ -z "${HF_TOKEN:-}" ]; then
    echo "Set HF_TOKEN first (the draft model is gated)."
    echo "  1. Accept terms at https://huggingface.co/z-lab/Qwen3.6-27B-DFlash"
    echo "  2. Create a token at https://huggingface.co/settings/tokens"
    echo "     (enable 'Access public gated repos' if using a fine-grained token)"
    echo "  3. export HF_TOKEN=hf_..."
    exit 1
fi

mkdir -p models/draft

echo "Downloading target model (~16 GB)..."
hf download unsloth/Qwen3.6-27B-GGUF Qwen3.6-27B-Q4_K_M.gguf --local-dir models/

echo "Downloading draft model (~3.3 GB)..."
HF_TOKEN="$HF_TOKEN" hf download z-lab/Qwen3.6-27B-DFlash --local-dir models/draft/

echo "Done. Models in ./models/"
