#!/bin/zsh
# Builds, for Apple silicon and signed for this Mac only:
#   build/Fleet.app   the menu bar item and its window, with the helper inside at Contents/Helpers/fleetd
#   build/fleetd      the helper by itself, for `build/fleetd --once`
# release.sh makes the copy other Macs can run.
set -euo pipefail
cd "${0:A:h}"
xcodegen generate --quiet
xcodebuild -project Fleet.xcodeproj -scheme Fleet -configuration Release \
    -derivedDataPath build/derived CONFIGURATION_BUILD_DIR="$PWD/build" -quiet build
print "built build/Fleet.app, version $(build/fleetd --once | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["build"])')"
