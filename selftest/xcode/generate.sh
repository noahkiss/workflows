#!/bin/sh
# Make Selftest.xcodeproj with a pinned XcodeGen release, downloaded into
# .build/ (ignored by git) when it is not there yet.
set -eu
XCODEGEN_VERSION=2.46.0
here=$(cd "$(dirname "$0")" && pwd)
dir="$here/.build/xcodegen-$XCODEGEN_VERSION"
bin="$dir/xcodegen/bin/xcodegen"
if [ ! -x "$bin" ]; then
  mkdir -p "$dir"
  curl -fsSL -o "$dir/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
  unzip -qo "$dir/xcodegen.zip" -d "$dir"
fi
exec "$bin" generate --spec "$here/project.yml" --project "$here"
