#!/usr/bin/env bash
# Builds the release binary, installs it to ~/.callrec/bin/callrec, signs it, restarts the
# background recorder and checks that it is watching.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sign-lib.sh

swift build -c release 2>&1 | tail -3
mkdir -p "$HOME/.callrec/bin"
cp .build/release/callrec "$HOME/.callrec/bin/callrec.new"
ID=$(signing_identity)
# Explicit identifier: the TCC grants are tied to (identifier + certificate), so it must not drift.
codesign -s "$ID" -f -i com.blaxify.callrec "$HOME/.callrec/bin/callrec.new"
mv -f "$HOME/.callrec/bin/callrec.new" "$HOME/.callrec/bin/callrec"
if [ "$ID" = "-" ]; then
  echo "signed AD-HOC (no stable identity): privacy grants may reset. Run scripts/make-signing-identity.sh"
else
  echo "signed with '$ID'"
fi
codesign -d -r- "$HOME/.callrec/bin/callrec" 2>&1 | grep designated

launchctl kickstart -k "gui/$(id -u)/com.blaxify.callrec"
sleep 3
"$HOME/.callrec/bin/callrec" status | head -1
