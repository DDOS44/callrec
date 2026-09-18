#!/usr/bin/env bash
set -euo pipefail
dir="$HOME/.callrec/models"; mkdir -p "$dir"

get() {   # get <file> <url> <label>
  local f="$dir/$1"
  [ -s "$f" ] && { echo "already present: $1"; return 0; }
  echo "Downloading $3…"
  curl -L --progress-bar -o "$f.part" "$2"
  mv "$f.part" "$f"
  echo "done: $f"
}

# Speech to text. large-v3 is noticeably better than turbo on Hindi; turbo stays
# as the fallback and is what runs if the big model is missing.
get ggml-large-v3.bin \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin" \
    "whisper large-v3 (~3.1 GB)"
get ggml-large-v3-turbo.bin \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" \
    "whisper large-v3-turbo fallback (~1.6 GB)"

# Cleans up the raw transcript so it reads like a person wrote it.
get Qwen2.5-7B-Instruct-Q4_K_M.gguf \
    "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf" \
    "Qwen2.5 7B Instruct for transcript cleanup (~4.7 GB)"
