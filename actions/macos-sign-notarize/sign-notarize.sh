#!/usr/bin/env bash
# Sign a macOS .app bundle or a bare Mach-O binary with a Developer ID
# identity, notarize it, staple it (bundles only), and verify the result.
#
# Runs in CI through action.yml, and on a Mac by hand. Every input is an
# environment variable:
#
#   SIGN_PATH          .app bundle or Mach-O binary to sign (required)
#   SIGN_IDENTITY      full identity, e.g. "Developer ID Application: Name (TEAMID)" (required)
#   SIGN_TEAM_ID       team ID the signature must carry (required)
#   SIGN_ENTITLEMENTS  entitlements plist for every executable (optional)
#   SIGN_IDENTIFIER    code identifier for a bare binary (optional; a bundle uses its CFBundleIdentifier)
#   SIGN_NOTARIZE      true (default) or false
#   MAC_CERT_P12       base64 .p12; when set, it goes into a throwaway keychain.
#                      When empty, codesign uses the identity from the login keychain.
#   MAC_CERT_PASSWORD  the .p12 password
#   ASC_KEY_P8         App Store Connect API key, PEM text (required to notarize)
#   ASC_KEY_ID         its key ID
#   ASC_ISSUER_ID      its issuer ID
#
# Nothing secret is printed. The keychain and the key file are deleted on exit.

set -euo pipefail

: "${SIGN_PATH:?SIGN_PATH is required}"
: "${SIGN_IDENTITY:?SIGN_IDENTITY is required}"
: "${SIGN_TEAM_ID:?SIGN_TEAM_ID is required}"
SIGN_ENTITLEMENTS="${SIGN_ENTITLEMENTS:-}"
SIGN_IDENTIFIER="${SIGN_IDENTIFIER:-}"
SIGN_NOTARIZE="${SIGN_NOTARIZE:-true}"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sign.XXXXXX")"
keychain=""
old_keychains=()

cleanup() {
  if [ -n "$keychain" ]; then
    if [ "${#old_keychains[@]}" -gt 0 ]; then
      security list-keychains -d user -s "${old_keychains[@]}" || true
    fi
    security delete-keychain "$keychain" || true
  fi
  rm -rf -- "${work:?}"
}
trap cleanup EXIT
trap 'exit 143' INT TERM # run the EXIT trap on a cancelled job too

fail() { echo "::error::$*" >&2; exit 1; }

path="${SIGN_PATH%/}"
[ -e "$path" ] || fail "nothing at ${path}"
if [ -d "$path" ]; then
  [[ "$path" == *.app ]] || fail "${path} is a folder but not an .app bundle"
  kind=bundle
else
  file -b "$path" | grep -q 'Mach-O' || fail "${path} is not a Mach-O binary"
  kind=binary
fi
if [ -n "$SIGN_ENTITLEMENTS" ]; then
  [ -f "$SIGN_ENTITLEMENTS" ] || fail "no entitlements file at ${SIGN_ENTITLEMENTS}"
  plutil -lint -s "$SIGN_ENTITLEMENTS" || fail "${SIGN_ENTITLEMENTS} is not a valid plist"
fi

# --- Keychain --------------------------------------------------------------
keychain_args=()
if [ -n "${MAC_CERT_P12:-}" ]; then
  : "${MAC_CERT_PASSWORD:?MAC_CERT_PASSWORD is required with MAC_CERT_P12}"
  keychain="$work/signing.keychain-db"
  kc_pw="$(openssl rand -base64 24)"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
    [ -n "$line" ] && old_keychains+=("$line")
  done < <(security list-keychains -d user)
  security create-keychain -p "$kc_pw" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$kc_pw" "$keychain"
  ( umask 077; printf '%s' "$MAC_CERT_P12" | base64 --decode > "$work/cert.p12" )
  security import "$work/cert.p12" -k "$keychain" -P "$MAC_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
  rm -f "$work/cert.p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pw" "$keychain" >/dev/null
  security list-keychains -d user -s "$keychain" "${old_keychains[@]}"
  unset kc_pw
  keychain_args=(--keychain "$keychain")
fi
security find-identity -v -p codesigning ${keychain:+"$keychain"} | grep -qF "\"$SIGN_IDENTITY\"" \
  || fail "identity not found in the keychain: ${SIGN_IDENTITY}"

# --- Sign ------------------------------------------------------------------
sign() { # sign <path> <with-entitlements: yes|no> [extra codesign args...]
  local target="$1" ent="$2"; shift 2
  local args=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY" "${keychain_args[@]}")
  if [ "$ent" = yes ] && [ -n "$SIGN_ENTITLEMENTS" ]; then
    args+=(--entitlements "$SIGN_ENTITLEMENTS")
  fi
  echo "codesign ${target}"
  codesign "${args[@]}" "$@" "$target"
}

is_macho() { file -b "$1" | grep -q 'Mach-O'; }
is_executable_macho() { file -b "$1" | grep -q 'Mach-O.*executable'; }

if [ "$kind" = bundle ]; then
  main_exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$path/Contents/Info.plist")"
  # Inside out: loose Mach-O files first (deepest first), then nested
  # bundles (deepest first), then the app itself. Executables and nested
  # apps get the entitlements; libraries and frameworks do not.
  # find -d lists a folder's contents before the folder itself.
  while IFS= read -r -d '' f; do
    [ "$f" = "$path/Contents/MacOS/$main_exe" ] && continue
    is_macho "$f" || continue
    if is_executable_macho "$f"; then sign "$f" yes; else sign "$f" no; fi
  done < <(find -d "$path/Contents" -type f -perm -u+x -print0)
  while IFS= read -r -d '' b; do
    if [[ "$b" == *.framework ]]; then sign "$b" no; else sign "$b" yes; fi
  done < <(find -d "$path/Contents" -mindepth 1 -type d \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -print0)
  sign "$path" yes
else
  ident=()
  [ -n "$SIGN_IDENTIFIER" ] && ident=(--identifier "$SIGN_IDENTIFIER")
  sign "$path" yes "${ident[@]}"
fi

# --- Check the signature -----------------------------------------------------
codesign --verify --deep --strict --verbose=2 "$path"
details="$(codesign -dv --verbose=4 "$path" 2>&1)"
grep -qx "TeamIdentifier=${SIGN_TEAM_ID}" <<<"$details" || fail "signature does not carry TeamIdentifier=${SIGN_TEAM_ID}"
grep -q '^CodeDirectory .*flags=.*runtime' <<<"$details" || fail "hardened runtime is not set"
grep -q '^Timestamp=' <<<"$details" || fail "the signature has no secure timestamp"
grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp)=' <<<"$details"

if [ "$SIGN_NOTARIZE" != true ]; then
  echo "Notarization skipped (SIGN_NOTARIZE=${SIGN_NOTARIZE})."
  exit 0
fi

# --- Notarize ----------------------------------------------------------------
: "${ASC_KEY_P8:?ASC_KEY_P8 is required to notarize}"
: "${ASC_KEY_ID:?ASC_KEY_ID is required to notarize}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required to notarize}"
( umask 077; printf '%s\n' "$ASC_KEY_P8" > "$work/AuthKey.p8" )
notary=(--key "$work/AuthKey.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")

# notarytool takes a zip, pkg or dmg, never a bare binary or a folder.
ditto -c -k --sequesterRsrc --keepParent "$path" "$work/notarize.zip"
# Submit first and print the ID, so a wait that times out still leaves a
# handle for `notarytool info <id>` and `notarytool log <id>`.
submitted="$(xcrun notarytool submit "$work/notarize.zip" "${notary[@]}" --output-format json)" \
  || { echo "$submitted" >&2; fail "notarytool submit failed"; }
id="$(plutil -extract id raw -o - - <<<"$submitted")"
echo "Notary submission ${id}"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "submission-id=${id}" >> "$GITHUB_OUTPUT"
result="$(xcrun notarytool wait "$id" "${notary[@]}" --output-format json)" || true
status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || echo unknown)"
echo "Notarization ${id}: ${status}"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "status=${status}" >> "$GITHUB_OUTPUT"
if [ "$status" != Accepted ]; then
  xcrun notarytool log "$id" "${notary[@]}" >&2 || true
  fail "notarization ${id} ended ${status}"
fi
rm -f "$work/AuthKey.p8"

# --- Staple and verify -------------------------------------------------------
if [ "$kind" = bundle ]; then
  xcrun stapler staple "$path"
  xcrun stapler validate "$path"
  spctl --assess --type execute -vv "$path"
else
  # A bare Mach-O cannot hold a ticket; Gatekeeper looks it up online.
  echo "Bare binary: no staple. Checking the ticket online."
fi
codesign --verify --strict -R='notarized' --check-notarization --verbose=2 "$path"
echo "Signed, notarized and verified: ${path}"
