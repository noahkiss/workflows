#!/usr/bin/env bash
# Makes the Tauri updater archive of a signed, notarized and stapled .app, and signs it.
#
# Tauri's own `createUpdaterArtifacts` archives the bundle right after the build, before
# macos-sign-notarize replaces its signature and staples the ticket. That archive would
# install an app Gatekeeper has never seen. This script archives the final bundle instead,
# checks the archive's copy, and signs the archive with `tauri signer sign`.
#
# Environment:
#   APP          the .app bundle
#   OUT          the archive to write (<name>.app.tar.gz); the signature goes to $OUT.sig
#   VERSION      the release version, bound into the signature (`requireSignedVersion`)
#   TAURI        the Tauri CLI command (words split on spaces)
#   TAURI_SIGNING_PRIVATE_KEY, TAURI_SIGNING_PRIVATE_KEY_PASSWORD   the updater key
set -euo pipefail

[ -d "$APP" ] || { echo "::error::no bundle at ${APP}"; exit 1; }
[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ] || { echo "::error::updater needs updater-private-key"; exit 1; }
[ -n "${VERSION:-}" ] || { echo "::error::no version for the updater signature"; exit 1; }
[ -n "${TAURI:-}" ] || { echo "::error::no Tauri CLI command"; exit 1; }

# The archive holds the bundle under its own name, as Tauri's does. No AppleDouble files:
# the updater copies the tree as it is, and stray ._ files would break the signature.
dir="$(cd "$(dirname "$APP")" && pwd)"
name="$(basename "$APP")"
rm -f "$OUT" "$OUT.sig"
COPYFILE_DISABLE=1 tar -C "$dir" --no-mac-metadata --no-xattrs -czf "$OUT" "$name"

# What the updater will unpack must still be the signed, stapled app.
check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
tar -xzf "$OUT" -C "$check"
codesign --verify --deep --strict "$check/$name"
xcrun stapler validate "$check/$name"

read -ra tauri <<<"$TAURI"
# An empty password is a key without one; the signer reads the variable when it is set.
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
"${tauri[@]}" signer sign --app-version "$VERSION" "$OUT" </dev/null
[ -s "$OUT.sig" ] || { echo "::error::no signature at ${OUT}.sig"; exit 1; }
echo "updater archive: $(basename "$OUT") ($(wc -c <"$OUT" | tr -d " ") bytes), signed for ${VERSION}"
