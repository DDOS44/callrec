#!/usr/bin/env bash
# curl -fsSL https://raw.githubusercontent.com/DDOS44/callrec/main/scripts/install.sh | bash
set -euo pipefail
say(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

[ "$(uname -m)" = arm64 ] || { echo "callrec needs an Apple Silicon Mac (M1 or newer). This Mac is $(uname -m)."; exit 1; }
v=$(sw_vers -productVersion); maj=${v%%.*}; min=$(echo "$v" | cut -d. -f2)
if [ "$maj" -lt 14 ] || { [ "$maj" -eq 14 ] && [ "${min:-0}" -lt 2 ]; }; then
  echo "callrec needs macOS 14.2 or newer. This Mac has $v. Update in System Settings -> General -> Software Update."; exit 1
fi

command -v brew >/dev/null || {
  say "Installing Homebrew (you'll be asked for your Mac password)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
}

say "Installing ffmpeg and whisper (local transcription)"
brew list ffmpeg >/dev/null 2>&1 || brew install ffmpeg
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp

mkdir -p "$HOME/.callrec/bin" "$HOME/.callrec/models"

say "Downloading callrec"
tag=$(curl -fsSL https://api.github.com/repos/DDOS44/callrec/releases/latest | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
if [ -n "${tag:-}" ] && curl -fsSL -o "$HOME/.callrec/bin/callrec" "https://github.com/DDOS44/callrec/releases/download/$tag/callrec-arm64"; then
  chmod +x "$HOME/.callrec/bin/callrec"
  xattr -d com.apple.quarantine "$HOME/.callrec/bin/callrec" 2>/dev/null || true
else
  say "No release found, building from source (needs Xcode Command Line Tools)"
  xcode-select -p >/dev/null 2>&1 || xcode-select --install
  tmp=$(mktemp -d); git clone -q https://github.com/DDOS44/callrec "$tmp"; (cd "$tmp" && swift build -c release)
  cp "$tmp/.build/release/callrec" "$HOME/.callrec/bin/callrec"
fi

if [ -w /usr/local/bin ] || sudo -n true 2>/dev/null; then
  sudo ln -sf "$HOME/.callrec/bin/callrec" /usr/local/bin/callrec
else
  grep -q '.callrec/bin' "$HOME/.zprofile" 2>/dev/null || echo 'export PATH="$HOME/.callrec/bin:$PATH"' >> "$HOME/.zprofile"
  export PATH="$HOME/.callrec/bin:$PATH"
fi

curl -fsSL -o "$HOME/.callrec/download-model.sh" https://raw.githubusercontent.com/DDOS44/callrec/main/scripts/download-model.sh
chmod +x "$HOME/.callrec/download-model.sh"
say "Downloading the transcription model (~1.6 GB, one time)"
"$HOME/.callrec/download-model.sh"

say "Starting the background recorder"
"$HOME/.callrec/bin/callrec" install-agent

say "Almost done - turn on two permissions"
echo "1. System Settings -> Privacy & Security -> Screen & System Audio Recording -> 'System Audio Recording Only' -> turn on callrec"
echo "2. System Settings -> Privacy & Security -> Microphone -> turn on callrec"
echo "Then run: callrec uninstall-agent && callrec install-agent"
echo
echo "Recordings and transcripts go to ~/CallRecordings. Check anytime with: callrec status"
