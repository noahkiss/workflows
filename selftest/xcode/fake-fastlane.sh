#!/bin/sh
# Stands in for fastlane in the selftest: records its arguments, and checks
# that the deploy key exists while match runs and the passphrase arrived.
set -eu
[ -n "${MATCH_PASSWORD:-}" ] || { echo "MATCH_PASSWORD is empty" >&2; exit 1; }
key=$(printf '%s\n' "$GIT_SSH_COMMAND" | sed -n 's/^ssh -i \([^ ]*\) .*/\1/p')
[ -s "$key" ] || { echo "no deploy key at '$key'" >&2; exit 1; }
printf '%s\n' "$*" >> "$RUNNER_TEMP/fake-fastlane-args"
printf '%s\n' "$key" > "$RUNNER_TEMP/fake-fastlane-key"
