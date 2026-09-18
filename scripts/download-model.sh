#!/usr/bin/env bash
set -euo pipefail
dir="$HOME/.callrec/models"; mkdir -p "$dir"
f="$dir/ggml-large-v3-turbo.bin"
[ -s "$f" ] && { echo "model already present: $f"; exit 0; }
echo "Downloading whisper large-v3-turbo (~1.6 GB)…"
curl -L --progress-bar -o "$f.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
mv "$f.part" "$f"; echo "done: $f"
