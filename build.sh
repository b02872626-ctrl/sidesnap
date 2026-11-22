#!/bin/bash
# Builds Sidesnap.app for this Mac with the Swift compiler that comes with
# the command-line tools (no Xcode needed).
#
#   ./build.sh            -> makes build/Sidesnap.app
#   ./build.sh --install  -> also copies it to ~/Applications and opens it
set -euo pipefail
cd "$(dirname "$0")"

tools/fetch_sparkle.sh
SPARKLE=Vendor/Sparkle-2.10.1
APP="build/Sidesnap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Building..."
swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" \
    -F "$SPARKLE" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Sidesnap/*.swift \
    -o "$APP/Contents/MacOS/Sidesnap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Sidesnap.icns "$APP/Contents/Resources/Sidesnap.icns"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

tools/sign_app.sh "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Sidesnap 2>/dev/null && sleep 1 || true
    # The app used to be called Snapshelf: quit and remove the old copy.
    pkill -x Snapshelf 2>/dev/null && sleep 1 || true
    rm -rf "$HOME/Applications/Snapshelf.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Sidesnap.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/Sidesnap.app"
    echo "Installed to ~/Applications/Sidesnap.app and opened it."
fi
