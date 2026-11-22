#!/bin/bash
# Builds the public download: dist/Sidesnap.dmg
#   - one app that runs on Apple silicon and Intel Macs (macOS 14+)
#   - the Sparkle updater, signed with the "Sidesnap Developer" certificate
#     (REQUIRE_SIGNING_CERT=1: refuses to build a public copy without it)
set -euo pipefail
cd "$(dirname "$0")"
export REQUIRE_SIGNING_CERT=1

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
tools/fetch_sparkle.sh
SPARKLE=Vendor/Sparkle-2.10.1
WORK=build/release
APP="$WORK/Sidesnap.app"
OUT=dist
rm -rf "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT"

echo "Building Sidesnap $VERSION for Apple silicon and Intel..."
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -parse-as-library \
        -target "$arch-apple-macosx14.0" \
        -F "$SPARKLE" -framework Sparkle \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        Sources/Sidesnap/*.swift -o "$WORK/Sidesnap-$arch"
done
lipo -create "$WORK/Sidesnap-arm64" "$WORK/Sidesnap-x86_64" -output "$APP/Contents/MacOS/Sidesnap"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Sidesnap.icns "$APP/Contents/Resources/Sidesnap.icns"
# Anything else the app ships (onboarding pictures etc.) lives in Resources/App.
[ -d Resources/App ] && cp -R Resources/App/. "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

tools/sign_app.sh "$APP"

echo "Making the disk image..."
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT/Sidesnap.dmg" "$OUT/Sidesnap-$VERSION.dmg"
hdiutil create -quiet -volname "Sidesnap" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$OUT/Sidesnap-$VERSION.dmg"
cp "$OUT/Sidesnap-$VERSION.dmg" "$OUT/Sidesnap.dmg"

echo
echo "Done: $OUT/Sidesnap.dmg (version $VERSION)"
echo "Size: $(du -h "$OUT/Sidesnap.dmg" | cut -f1)"
echo "SHA-256: $(shasum -a 256 "$OUT/Sidesnap.dmg" | cut -d' ' -f1)"
