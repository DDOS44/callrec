# Sourced by make-app.sh and deploy.sh.
#
# signing_identity: prints the name of the stable local identity if it exists in the
# keychain, else "-" (ad-hoc). Ad-hoc is what CI uses; it works, but its identity changes
# on every build, so macOS privacy grants can reset. Create the identity once with
# scripts/make-signing-identity.sh.
signing_identity() {
  local name="${CALLREC_SIGNING_NAME:-callrec local signing}"
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$name\""; then
    printf '%s' "$name"
  else
    printf '%s' "-"
  fi
}
