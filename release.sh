#!/bin/zsh
# Builds Fleet.app, signs it with Developer ID, notarizes it, publishes it as a GitHub
# release and updates the cask in chetangoel01/homebrew-tap.
#
#   ./release.sh                 the whole thing
#   ./release.sh --no-publish    stop after the notarized disk image
#   ./release.sh --no-notarize   build and sign only; nothing is uploaded or published
#
# Before running it, raise MARKETING_VERSION in project.yml and commit. Needs Developer ID
# cloud signing for team P48VDW72LU, a notarytool keychain profile for that team
# (NOTARY_PROFILE, default "meeting-recorder"), xcodegen and a signed-in gh.
set -euo pipefail
cd "${0:A:h}"

publish=1 notarize=1
for argument in "$@"; do
    case $argument in
        --no-publish) publish=0 ;;
        --no-notarize) notarize=0 publish=0 ;;
        *) print -u2 "usage: $0 [--no-publish] [--no-notarize]"; exit 2 ;;
    esac
done

team=P48VDW72LU
profile=${NOTARY_PROFILE:-meeting-recorder}
out=build/release
version=$(awk '$1 == "MARKETING_VERSION:" { print $2 }' project.yml)
tag=v$version
dmg=$out/Fleet-$version.dmg

if (( publish )); then
    gh auth status >/dev/null
    if git rev-parse $tag >/dev/null 2>&1; then print -u2 "tag $tag exists; raise MARKETING_VERSION in project.yml first"; exit 1; fi
    if [[ -n $(git status --porcelain) ]]; then print -u2 "commit before releasing: the working tree has changes"; exit 1; fi
    # Only commits that build on the public main may be pushed: a branch from before the repo
    # went public would upload that older history along with the tag.
    git fetch -q origin main
    git merge-base --is-ancestor origin/main HEAD || { print -u2 "HEAD does not build on origin/main"; exit 1; }
    git ls-remote -q git@github.com:chetangoel01/homebrew-tap.git HEAD >/dev/null
fi

rm -rf $out
mkdir -p $out
xcodegen generate --quiet

print "==> Archiving $version"
xcodebuild archive -project Fleet.xcodeproj -scheme Fleet -configuration Release \
    -destination 'generic/platform=macOS' -archivePath $out/Fleet.xcarchive -allowProvisioningUpdates -quiet

print "==> Signing with Developer ID"
cat > $out/exportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$team</string>
    <key>signingStyle</key><string>automatic</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath $out/Fleet.xcarchive -exportOptionsPlist $out/exportOptions.plist \
    -exportPath $out/export -allowProvisioningUpdates
app=$out/export/Fleet.app

codesign --verify --deep --strict $app
for code in $app $app/Contents/Helpers/fleetd $app/Contents/Helpers/cooler; do
    details=$(codesign -dvv $code 2>&1)
    [[ $details == *"Authority=Developer ID Application"* ]] || { print -u2 "$code is not signed with Developer ID"; exit 1; }
    [[ $details == *"(runtime)"* ]] || { print -u2 "$code lacks the hardened runtime"; exit 1; }
done
reported=$($app/Contents/Helpers/fleetd --once | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["build"])')
[[ $reported == $version ]] || { print -u2 "the helper reports $reported, not $version"; exit 1; }

if (( notarize )); then
    print "==> Notarizing the app"
    ditto -c -k --keepParent $app $out/Fleet-notarize.zip
    xcrun notarytool submit $out/Fleet-notarize.zip --keychain-profile $profile --wait
    xcrun stapler staple $app
    spctl -a -vv --type execute $app
fi

print "==> Making the disk image"
mkdir $out/dmg-root
cp -R $app $out/dmg-root/
hdiutil create -quiet -volname Fleet -srcfolder $out/dmg-root -format UDZO $dmg

if (( notarize )); then
    # The image is notarized as well as the app: an unstapled image is refused even when its app is fine.
    print "==> Notarizing the disk image"
    xcrun notarytool submit $dmg --keychain-profile $profile --wait
    xcrun stapler staple $dmg
fi

if (( publish )); then
    print "==> Publishing $tag"
    git tag $tag
    git push --atomic origin HEAD:main $tag
    gh release create $tag $dmg --repo chetangoel01/fleet --title "Fleet $version" --generate-notes

    print "==> Updating the Homebrew tap"
    tap=$out/homebrew-tap
    git clone -q git@github.com:chetangoel01/homebrew-tap.git $tap
    sed -e "s/^  version \".*\"/  version \"$version\"/" \
        -e "s/^  sha256 \".*\"/  sha256 \"$(shasum -a 256 $dmg | cut -d' ' -f1)\"/" fleet.rb > $tap/Casks/fleet.rb
    if ! grep -q '^## Fleet' $tap/README.md; then
        cat >> $tap/README.md <<'README'

## Fleet

```bash
brew install --cask chetangoel01/tap/fleet
```

Menu bar status for a few Macs, read from a small helper on each.
Upgrade with `brew upgrade --cask fleet`. Source and releases:
https://github.com/chetangoel01/fleet
README
    fi
    git -C $tap add Casks/fleet.rb README.md
    git -C $tap commit -qm "fleet $version"
    git -C $tap push -q origin main
fi

print "==> Done: $dmg"
