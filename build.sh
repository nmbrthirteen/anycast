#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/AnyCast.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun actool "$PWD/Icon/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon --output-partial-info-plist /tmp/anycast-icon.plist >/dev/null
cp .build/release/AnyCast "$APP/Contents/MacOS/AnyCast"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(cat VERSION)" \
    -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
codesign --force --sign "AnyCast Local Signing" --identifier local.anycast.app "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x AnyCast || true
    rm -rf /Applications/AnyCast.app
    ditto "$APP" /Applications/AnyCast.app
    STAGE=$(mktemp -d)
    ditto "$APP" "$STAGE/AnyCast.app"
    ln -s /Applications "$STAGE/Applications"
    rm -f build/AnyCast.dmg
    hdiutil create -volname AnyCast -srcfolder "$STAGE" -format UDZO build/AnyCast.dmg >/dev/null 2>&1
    rm -rf "$STAGE"
    echo "Installed /Applications/AnyCast.app and made $PWD/build/AnyCast.dmg"
fi
