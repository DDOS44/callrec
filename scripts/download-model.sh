#!/usr/bin/env bash
# Downloads the transcription models into ~/.callrec/models/ and verifies every file.
#
# Supply chain: files come from third-party Hugging Face repos, so each repo is
# pinned to one commit and every file's SHA-256 is listed in model-manifest.txt.
# A file that does not match is never installed. callrec itself loads the models
# from disk and never touches the network at runtime.
#
# Re-running is safe: files that already match are left alone, files that do not
# match are re-downloaded and only replace the old file once the new one verifies.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
manifest="${CALLREC_MODEL_MANIFEST:-$here/model-manifest.txt}"
root="$HOME/.callrec/models"
[ -f "$manifest" ] || { echo "model manifest not found: $manifest" >&2; exit 1; }
umask 077

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

total=$(grep -vc '^#' "$manifest" || true)
n=0; fetched=0
echo "Checking/downloading $total model files (about 1.6 GB the first time)"
while read -r sha repo commit remote local_path; do
  case "$sha" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  out="$root/$local_path"
  if [ -f "$out" ] && [ "$(sha256_of "$out")" = "$sha" ]; then continue; fi

  mkdir -p "$(dirname "$out")"
  part="$out.part"
  url="https://huggingface.co/$repo/resolve/$commit/$remote"
  printf '  [%d/%d] %s\n' "$n" "$total" "$local_path"
  curl -fL --progress-bar -o "$part" "$url"
  got=$(sha256_of "$part")
  if [ "$got" != "$sha" ]; then
    rm -f "$part"
    echo "CHECKSUM MISMATCH for $local_path" >&2
    echo "  expected $sha" >&2
    echo "  got      $got" >&2
    echo "  from     $url" >&2
    echo "Nothing was installed for this file. Do not use this model; tell the callrec maintainer." >&2
    exit 1
  fi
  mv "$part" "$out"
  fetched=$((fetched + 1))
done < "$manifest"

echo "done: $n files verified ($fetched downloaded) in $root"
echo "First transcription compiles the model for your Mac and takes several minutes, once."
