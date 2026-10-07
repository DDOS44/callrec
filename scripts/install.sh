#!/usr/bin/env bash
# callrec installer.
#
# Safer than piping straight to bash: download it, read it, then run it.
#   curl -fsSLO https://raw.githubusercontent.com/DDOS44/callrec/main/scripts/install.sh
#   less install.sh && bash install.sh
# (The one-liner `curl ... | bash` still works.)
#
# What is verified: the binary, the app zip, the model script and the model manifest
# are checked against the release's SHA256SUMS before anything is installed, and every
# model file is checked against a pinned SHA-256 (see download-model.sh).
# SHA256SUMS comes from the same GitHub release, so it catches corrupt or swapped
# files, not a compromised release. This script itself cannot verify itself; that is
# why you are encouraged to read it first.
set -euo pipefail
say(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
fail(){ printf '\n%s\n' "$*" >&2; exit 1; }

# `curl | bash` has no stdin to read answers from, so questions go to the terminal.
ask() {   # ask "question"  -> returns 0 only on an explicit yes
  [ -r /dev/tty ] || return 1
  local reply
  printf '%s [y/N] ' "$1" > /dev/tty
  read -r reply < /dev/tty || return 1
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

[ "$(uname -m)" = arm64 ] || fail "callrec needs an Apple Silicon Mac (M1 or newer). This Mac is $(uname -m)."
v=$(sw_vers -productVersion); maj=${v%%.*}; min=$(echo "$v" | cut -d. -f2)
if [ "$maj" -lt 14 ] || { [ "$maj" -eq 14 ] && [ "${min:-0}" -lt 2 ]; }; then
  fail "callrec needs macOS 14.2 or newer. This Mac has $v. Update in System Settings -> General -> Software Update."
fi

if ! command -v brew >/dev/null; then
  echo "callrec needs ffmpeg, and ffmpeg comes from Homebrew, which is not installed."
  echo "Homebrew's installer is a script from https://github.com/Homebrew/install and it will ask for your Mac password."
  ask "Install Homebrew now?" || fail "Not installing Homebrew. Install ffmpeg yourself, then run this again."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

say "Installing ffmpeg"
brew list ffmpeg >/dev/null 2>&1 || brew install ffmpeg

mkdir -p "$HOME/.callrec/bin" "$HOME/.callrec/models"
chmod 700 "$HOME/.callrec"

repo="DDOS44/callrec"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' || true)

source_dir=""
if [ -n "${tag:-}" ]; then
  say "Downloading callrec $tag"
  base="https://github.com/$repo/releases/download/$tag"
  for f in callrec-arm64 callrec.app.zip download-model.sh model-manifest.txt; do
    curl -fsSL -o "$work/$f" "$base/$f" || fail "Could not download $f from release $tag."
  done
  if curl -fsSL -o "$work/SHA256SUMS" "$base/SHA256SUMS"; then
    say "Verifying downloads"
    (cd "$work" && shasum -a 256 -c SHA256SUMS) || fail "CHECKSUM MISMATCH: a downloaded file does not match SHA256SUMS. Nothing was installed."
  elif [ "${CALLREC_ALLOW_UNVERIFIED:-}" = 1 ]; then
    echo "WARNING: release $tag has no SHA256SUMS; installing UNVERIFIED because CALLREC_ALLOW_UNVERIFIED=1."
  else
    fail "Release $tag has no SHA256SUMS, so the download cannot be verified. Nothing was installed.
Wait for a newer release, or accept the risk with: CALLREC_ALLOW_UNVERIFIED=1 bash install.sh"
  fi
  install -m 755 "$work/callrec-arm64" "$HOME/.callrec/bin/callrec"
else
  say "No release found. Building from the main branch (unverified; needs Xcode Command Line Tools)"
  xcode-select -p >/dev/null 2>&1 || { xcode-select --install; fail "Finish installing the Command Line Tools, then run this again."; }
  source_dir="$work/src"
  git clone -q "https://github.com/$repo" "$source_dir"
  (cd "$source_dir" && swift build -c release)
  install -m 755 "$source_dir/.build/release/callrec" "$HOME/.callrec/bin/callrec"
fi

# A symlink in /usr/local/bin needs sudo unless it is already writable. Ask first;
# the alternative (PATH entry in ~/.zprofile) needs nothing.
if [ -w /usr/local/bin ]; then
  ln -sf "$HOME/.callrec/bin/callrec" /usr/local/bin/callrec
elif [ -d /usr/local/bin ] && ask "Link callrec into /usr/local/bin? This runs: sudo ln -sf $HOME/.callrec/bin/callrec /usr/local/bin/callrec"; then
  sudo ln -sf "$HOME/.callrec/bin/callrec" /usr/local/bin/callrec
else
  grep -q '.callrec/bin' "$HOME/.zprofile" 2>/dev/null || echo 'export PATH="$HOME/.callrec/bin:$PATH"' >> "$HOME/.zprofile"
  export PATH="$HOME/.callrec/bin:$PATH"
  echo "Added ~/.callrec/bin to your PATH (open a new Terminal window for it to take effect)."
fi

say "Installing the callrec app"
appdir="/Applications"; [ -w "$appdir" ] || appdir="$HOME/Applications"; mkdir -p "$appdir"
if [ -n "${tag:-}" ]; then
  rm -rf "$appdir/callrec.app"
  ditto -x -k "$work/callrec.app.zip" "$appdir"
elif [ -d "$source_dir" ]; then
  (cd "$source_dir" && ./scripts/make-app.sh >/dev/null 2>&1) && rm -rf "$appdir/callrec.app" && cp -R "$source_dir/build/callrec.app" "$appdir/"
fi
# No quarantine stripping: curl does not set that flag, and if you downloaded the zip in a
# browser, macOS should be allowed to ask (System Settings -> Privacy & Security -> Open Anyway).

if [ -n "${tag:-}" ]; then
  install -m 755 "$work/download-model.sh" "$HOME/.callrec/download-model.sh"
  install -m 644 "$work/model-manifest.txt" "$HOME/.callrec/model-manifest.txt"
else
  install -m 755 "$source_dir/scripts/download-model.sh" "$HOME/.callrec/download-model.sh"
  install -m 644 "$source_dir/scripts/model-manifest.txt" "$HOME/.callrec/model-manifest.txt"
fi
say "Downloading and verifying the transcription model (~1.6 GB, one time)"
"$HOME/.callrec/download-model.sh"

say "Starting the background recorder"
"$HOME/.callrec/bin/callrec" install-agent

say "Almost done - turn on two permissions"
echo "1. System Settings -> Privacy & Security -> Screen & System Audio Recording -> 'System Audio Recording Only' -> turn on callrec"
echo "2. System Settings -> Privacy & Security -> Microphone -> turn on callrec"
echo "Then run: callrec uninstall-agent && callrec install-agent"
echo
echo "Recordings and transcripts go to ~/CallRecordings."
echo "Open the callrec app from Applications, or click the phone icon in the menu bar."
[ -d "$appdir/callrec.app" ] && open "$appdir/callrec.app" || true
