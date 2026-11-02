#!/usr/bin/env bash
# Archive an Xcode scheme, export it with manual signing, and upload it to App
# Store Connect or notarize a Developer ID export.
#
# Runs in CI through action.yml. Every input is an environment variable:
#
#   XAU_PROJECT              .xcodeproj or .xcworkspace; empty lets xcodebuild find one
#   XAU_SCHEME               scheme to archive (required)
#   XAU_CONFIGURATION        build configuration (default Release)
#   XAU_DESTINATION          archive destination (default generic/platform=iOS)
#   XAU_XCCONFIG             signing xcconfig, e.g. from xcode-match-signing
#   XAU_MARKETING_VERSION    MARKETING_VERSION; empty keeps the project's
#   XAU_BUILD_NUMBER         CURRENT_PROJECT_VERSION; empty keeps the project's
#   XAU_XCODEBUILD_ARGS      extra archive arguments, one per line
#   XAU_PACKAGES_DIR         -clonedSourcePackagesDirPath, for a SwiftPM cache
#   XAU_METHOD               app-store-connect, release-testing, enterprise,
#                            debugging or developer-id; empty archives only
#   XAU_TEAM_ID              team id for the export (required to export)
#   XAU_SIGNING_CERTIFICATE  export certificate; empty derives it from the method
#   XAU_PROFILES             JSON object from bundle id to profile name
#   XAU_UPLOAD               app-store-connect: true uploads, false exports to disk
#   XAU_NOTARIZE             developer-id: true notarizes and staples the app
#   ASC_KEY_P8, ASC_KEY_ID, ASC_ISSUER_ID
#                            App Store Connect API key, to upload or notarize
#
# Writes outputs archive-path, export-path, app-path and log-dir. Nothing
# secret is printed; the key file is deleted on exit.

set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }
trim() { local s="$1"; s="${s%$'\r'}"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

[ "$(uname -s)" = Darwin ] || fail "xcode-archive-upload needs a macOS runner"
[ -n "${XAU_SCHEME:-}" ] || fail "scheme is required"

temp="${RUNNER_TEMP:?RUNNER_TEMP is not set}"
work="$temp/xcode-archive-upload"
logs="$work/logs"
keys="$work/keys"
archive="$work/${XAU_SCHEME//[^A-Za-z0-9._-]/_}.xcarchive"
export_path="$work/export"
rm -rf -- "$work"
mkdir -p "$logs"
trap 'rm -rf -- "$keys"' EXIT
trap 'exit 143' INT TERM

out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
out log-dir "$logs"

method="${XAU_METHOD:-}"
case "$method" in
  ''|app-store-connect|release-testing|enterprise|debugging|developer-id) ;;
  *) fail "unknown export-method $method" ;;
esac
upload="${XAU_UPLOAD:-true}"
notarize="${XAU_NOTARIZE:-true}"
needs_key=false
if { [ "$method" = app-store-connect ] && [ "$upload" = true ]; } \
   || { [ "$method" = developer-id ] && [ "$notarize" = true ]; }; then
  needs_key=true
  [ -n "${ASC_KEY_P8:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] \
    || fail "api-key-p8, api-key-id and api-key-issuer-id are required to upload or notarize"
fi
if [ -n "$method" ]; then
  [ -n "${XAU_TEAM_ID:-}" ] || fail "team-id is required to export"
fi

# Run xcodebuild into a log, show errors and signing warnings, keep its status.
xcb() { # log name, then xcodebuild arguments
  local log="$logs/$1.log" status
  shift
  set +e
  xcodebuild "$@" </dev/null 2>&1 \
    | tee "$log" \
    | grep -E --line-buffered '(error:|warning: .*(sign|profile|entitlement)|Upload|\*\* [A-Z ]+ (SUCCEEDED|FAILED) \*\*)'
  status=${PIPESTATUS[0]}
  set -e
  if [ "$status" -ne 0 ]; then
    echo "::error::xcodebuild failed (exit $status); last lines of $log:"
    tail -n 40 "$log"
    exit "$status"
  fi
}

args=()
case "${XAU_PROJECT:-}" in
  '') ;;
  *.xcworkspace) args+=(-workspace "$XAU_PROJECT") ;;
  *) args+=(-project "$XAU_PROJECT") ;;
esac
args+=(-scheme "$XAU_SCHEME" -configuration "${XAU_CONFIGURATION:-Release}"
  -destination "${XAU_DESTINATION:-generic/platform=iOS}" -archivePath "$archive")
if [ -n "${XAU_XCCONFIG:-}" ]; then
  [ -f "$XAU_XCCONFIG" ] || fail "no xcconfig at $XAU_XCCONFIG"
  args+=(-xcconfig "$XAU_XCCONFIG")
fi
[ -n "${XAU_PACKAGES_DIR:-}" ] && args+=(-clonedSourcePackagesDirPath "$XAU_PACKAGES_DIR")
[ -n "${XAU_MARKETING_VERSION:-}" ] && args+=("MARKETING_VERSION=$XAU_MARKETING_VERSION")
[ -n "${XAU_BUILD_NUMBER:-}" ] && args+=("CURRENT_PROJECT_VERSION=$XAU_BUILD_NUMBER")
while IFS= read -r arg; do
  arg=$(trim "$arg")
  [ -n "$arg" ] && args+=("$arg")
done <<< "${XAU_XCODEBUILD_ARGS:-}"

echo "::group::Archive $XAU_SCHEME"
xcb archive "${args[@]}" archive
echo "::endgroup::"
[ -d "$archive" ] || fail "xcodebuild reported success but wrote no archive"
out archive-path "$archive"

[ -n "$method" ] || exit 0

certificate="${XAU_SIGNING_CERTIFICATE:-}"
if [ -z "$certificate" ]; then
  case "$method" in
    developer-id) certificate="Developer ID Application" ;;
    debugging) certificate="Apple Development" ;;
    *) certificate="Apple Distribution" ;;
  esac
fi
destination="export"
[ "$method" = app-store-connect ] && [ "$upload" = true ] && destination=upload

plist="$work/ExportOptions.plist"
XAU_CERTIFICATE="$certificate" XAU_DESTINATION_KIND="$destination" XAU_PLIST="$plist" python3 -I -c '
import json, os, plistlib
method = os.environ["XAU_METHOD"]
profiles = json.loads(os.environ.get("XAU_PROFILES") or "{}")
if not isinstance(profiles, dict) or not all(isinstance(v, str) for v in profiles.values()):
    raise SystemExit("provisioning-profiles must be a JSON object of strings")
options = {
    "method": method,
    "teamID": os.environ["XAU_TEAM_ID"],
    "signingStyle": "manual",
    "signingCertificate": os.environ["XAU_CERTIFICATE"],
    "destination": os.environ["XAU_DESTINATION_KIND"],
}
if profiles:
    options["provisioningProfiles"] = profiles
if method == "app-store-connect":
    options["manageAppVersionAndBuildNumber"] = False
    options["uploadSymbols"] = True
with open(os.environ["XAU_PLIST"], "wb") as f:
    plistlib.dump(options, f)
'
echo "::group::ExportOptions.plist"
plutil -p "$plist"
echo "::endgroup::"

key_args=()
if [ "$needs_key" = true ]; then
  (umask 077 && mkdir -p "$keys" && printf '%s\n' "$ASC_KEY_P8" > "$keys/AuthKey_$ASC_KEY_ID.p8")
  key_args=(-authenticationKeyPath "$keys/AuthKey_$ASC_KEY_ID.p8"
    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

echo "::group::Export ($method, $destination)"
if [ "$method" = app-store-connect ] && [ "$destination" = upload ]; then
  xcb export -exportArchive -archivePath "$archive" -exportOptionsPlist "$plist" \
    -exportPath "$export_path" "${key_args[@]}"
else
  xcb export -exportArchive -archivePath "$archive" -exportOptionsPlist "$plist" \
    -exportPath "$export_path"
fi
echo "::endgroup::"
out export-path "$export_path"

[ "$method" = developer-id ] || exit 0

app=$(find "$export_path" -maxdepth 1 -name '*.app' -print | head -n 1)
[ -n "$app" ] || fail "the export holds no .app"
out app-path "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)' || true

[ "$notarize" = true ] || exit 0

notary=(--key "$keys/AuthKey_$ASC_KEY_ID.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
zip="$work/notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
submitted=$(xcrun notarytool submit "$zip" "${notary[@]}" --output-format json)
id=$(plutil -extract id raw -o - - <<< "$submitted")
echo "Notary submission $id"
set +e
result=$(xcrun notarytool wait "$id" "${notary[@]}" --output-format json)
set -e
status=$(plutil -extract status raw -o - - <<< "$result" 2>/dev/null || echo unknown)
echo "Notarization $id: $status"
if [ "$status" != Accepted ]; then
  xcrun notarytool log "$id" "${notary[@]}" || true
  fail "notarization ended $status"
fi
rm -f -- "$zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
assessment=$(spctl -a -vv "$app" 2>&1) || fail "spctl rejected the app: $assessment"
echo "$assessment"
grep -q 'source=Notarized Developer ID' <<< "$assessment" || fail "spctl does not report a notarized Developer ID app"
