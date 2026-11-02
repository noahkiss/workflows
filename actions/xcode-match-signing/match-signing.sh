#!/usr/bin/env bash
# Install signing certificates and profiles from a fastlane match store,
# read-only, into a throwaway keychain, and write a manual-signing xcconfig.
#
# Runs in CI through action.yml. Every input is an environment variable:
#
#   XMS_CLEANUP        true: delete the keychain, the key folder and the
#                      xcconfig, then stop. Nothing else is read.
#   XMS_TEAM_ID        Apple team id (required)
#   XMS_PROFILES       one match call per line: `<type> <platform> <id>[,<id>...]`,
#                      with `certificates-only` as a fourth word to skip profiles
#   XMS_IDENTITY       signing identity; empty derives it from the first type
#   XMS_GIT_BRANCH     the store's branch (match defaults to master; ours is main)
#   XMS_FASTLANE       the fastlane command, e.g. `fastlane` or `bundle exec fastlane`
#   XMS_KNOWN_HOSTS    known_hosts line(s) for the store's SSH host
#   XMS_XCCONFIG_EXTRA lines appended to the xcconfig
#   MATCH_GIT_URL      SSH URL of the store (a secret: it names a private repo)
#   MATCH_PASSWORD     the store's passphrase (match reads it from the environment)
#   MATCH_DEPLOY_KEY   private SSH key with read access to the store
#
# Writes outputs keychain, xcconfig, identity and profiles (JSON: bundle id to
# profile name) to $GITHUB_OUTPUT. Nothing secret is printed.

set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

temp="${RUNNER_TEMP:?RUNNER_TEMP is not set}"
keychain="$temp/xcode-match-signing.keychain-db"
keys="$temp/xcode-match-signing-keys"
xcconfig="$temp/xcode-match-signing.xcconfig"

if [ "${XMS_CLEANUP:-false}" = true ]; then
  if [ -e "$keychain" ]; then
    security delete-keychain "$keychain" || true
  fi
  rm -rf -- "$keys" "$xcconfig"
  echo "Removed the signing keychain, keys and xcconfig."
  exit 0
fi

[ "$(uname -s)" = Darwin ] || fail "xcode-match-signing needs a macOS runner"
[ -n "${XMS_TEAM_ID:-}" ] || fail "team-id is required"
[ -n "${MATCH_GIT_URL:-}" ] || fail "match-git-url is empty; pass it from a secret"
[ -n "${MATCH_PASSWORD:-}" ] || fail "match-password is empty"
[ -n "${MATCH_DEPLOY_KEY:-}" ] || fail "match-deploy-key is empty"
# A URL that arrived through a variable would print in fastlane's summary table.
echo "::add-mask::$MATCH_GIT_URL"

read -r -a fastlane <<< "${XMS_FASTLANE:-fastlane}"
command -v "${fastlane[0]}" >/dev/null \
  || fail "${fastlane[0]} not found; install fastlane, or set up Ruby and pass fastlane: bundle exec fastlane"

# match's profile name for a type, a platform and a bundle id.
profile_name() {
  local kind
  case "$1" in
    appstore) kind=AppStore ;;
    adhoc) kind=AdHoc ;;
    development) kind=Development ;;
    developer_id) kind=Direct ;;
    enterprise) kind=InHouse ;;
    *) fail "unknown match type $1" ;;
  esac
  if [ "$2" = ios ]; then
    printf 'match %s %s' "$kind" "$3"
  else
    printf 'match %s %s %s' "$kind" "$3" "$2"
  fi
}

identity_for() {
  case "$1" in
    appstore|adhoc|enterprise) echo "Apple Distribution" ;;
    development) echo "Apple Development" ;;
    developer_id) echo "Developer ID Application" ;;
    *) fail "unknown match type $1" ;;
  esac
}

# Xcode's :c99extidentifier, the form the xcconfig looks profiles up by.
c99ext() {
  local s="${1//[^A-Za-z0-9_]/_}"
  case "$s" in [0-9]*) s="_$s" ;; esac
  printf '%s' "$s"
}

# Parse every line before touching anything.
types=() platforms=() ids=() certs_only=()
while read -r type platform list extra rest; do
  [ -n "${type:-}" ] || continue
  case "$type" in \#*) continue ;; esac
  [ -n "${list:-}" ] || fail "profiles line '$type ${platform:-}' needs a type, a platform and bundle ids"
  [ -z "${rest:-}" ] || fail "profiles line for $type $platform has extra words"
  case "$platform" in ios|macos|catalyst|tvos|visionos) ;; *) fail "unknown platform $platform" ;; esac
  case "${extra:-}" in ''|certificates-only) ;; *) fail "unknown option ${extra}; only certificates-only" ;; esac
  identity_for "$type" >/dev/null
  types+=("$type") platforms+=("$platform") ids+=("$list") certs_only+=("${extra:-}")
done <<< "${XMS_PROFILES:-}"
[ "${#types[@]}" -gt 0 ] || fail "profiles is empty"

identity="${XMS_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity=$(identity_for "${types[0]}")
  for type in "${types[@]}"; do
    [ "$(identity_for "$type")" = "$identity" ] \
      || fail "the profiles lines need different identities; pass identity, or use one call per job"
  done
fi

# The throwaway keychain. Its password is random and masked; it stays unlocked
# for six hours, so the archive needs no password.
keychain_password=$(openssl rand -base64 24)
echo "::add-mask::$keychain_password"
security delete-keychain "$keychain" 2>/dev/null || true
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
existing=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line#\"}"
  line="${line%\"}"
  [ -n "$line" ] && existing+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" ${existing[@]+"${existing[@]}"}

# The deploy key lives only while match runs.
rm -rf -- "$keys"
(umask 077 && mkdir -p "$keys" \
  && printf '%s\n' "$MATCH_DEPLOY_KEY" > "$keys/deploy_key" \
  && printf '%s\n' "${XMS_KNOWN_HOSTS:?known-hosts is empty}" > "$keys/known_hosts")
trap 'rm -f -- "$keys/deploy_key"' EXIT
export GIT_SSH_COMMAND="ssh -i $keys/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$keys/known_hosts"
export FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 FASTLANE_OPT_OUT_USAGE=1

for i in "${!types[@]}"; do
  args=(match "${types[$i]}" --readonly
    --platform "${platforms[$i]}" --app_identifier "${ids[$i]}" --team_id "$XMS_TEAM_ID"
    --git_url "$MATCH_GIT_URL" --git_branch "${XMS_GIT_BRANCH:-main}" --skip_docs
    --keychain_name "$keychain" --keychain_password "$keychain_password")
  [ "${certs_only[$i]}" = certificates-only ] && args+=(--skip_provisioning_profiles)
  echo "::group::match ${types[$i]} ${platforms[$i]} ${ids[$i]}"
  "${fastlane[@]}" "${args[@]}" </dev/null
  echo "::endgroup::"
done
rm -f -- "$keys/deploy_key"

security find-identity -v -p codesigning "$keychain"

# The names of every installed profile, to check match installed what we expect.
installed=$(
  for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" \
             "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 1 \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print0 \
      | while IFS= read -r -d '' file; do
          security cms -D -i "$file" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || true
        done
  done
)

flags="--keychain $keychain"
[ "$identity" = "Developer ID Application" ] && flags="$flags --timestamp"
{
  echo "// Written by xcode-match-signing. Manual signing from the match store."
  echo "CODE_SIGN_STYLE = Manual"
  echo "DEVELOPMENT_TEAM = $XMS_TEAM_ID"
  echo "CODE_SIGN_IDENTITY = $identity"
  echo "CODE_SIGN_IDENTITY[sdk=iphoneos*] = $identity"
  echo "CODE_SIGN_IDENTITY[sdk=macosx*] = $identity"
  echo "OTHER_CODE_SIGN_FLAGS = $flags"
} > "$xcconfig"

json="{"
sep=""
for i in "${!types[@]}"; do
  [ "${certs_only[$i]}" = certificates-only ] && continue
  IFS=',' read -r -a list <<< "${ids[$i]}"
  for id in "${list[@]}"; do
    id="${id//[[:space:]]/}"
    [ -n "$id" ] || continue
    name=$(profile_name "${types[$i]}" "${platforms[$i]}" "$id")
    grep -qxF "$name" <<< "$installed" || fail "match installed no profile named '$name'"
    echo "XCODE_CI_PROFILE_$(c99ext "$id") = $name" >> "$xcconfig"
    json="$json$sep\"$id\":\"$name\""
    sep=","
  done
done
json="$json}"
# A target whose bundle id has no profile (a framework, say) gets none.
# shellcheck disable=SC2016 # an xcconfig expression, not shell
echo 'PROVISIONING_PROFILE_SPECIFIER = $(XCODE_CI_PROFILE_$(PRODUCT_BUNDLE_IDENTIFIER:c99extidentifier))' >> "$xcconfig"
if [ -n "${XMS_XCCONFIG_EXTRA:-}" ]; then
  printf '%s\n' "$XMS_XCCONFIG_EXTRA" >> "$xcconfig"
fi
echo "::group::$xcconfig"
cat "$xcconfig"
echo "::endgroup::"

{
  echo "keychain=$keychain"
  echo "xcconfig=$xcconfig"
  echo "identity=$identity"
  echo "profiles=$json"
} >> "${GITHUB_OUTPUT:-/dev/null}"
