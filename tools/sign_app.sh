#!/bin/bash
# Signs Sidesnap.app (and the Sparkle updater inside it) with the
# "Sidesnap Developer" certificate from your login keychain.
#
# Why a certificate: macOS remembers the Screen Recording permission for
# "app.sidesnap.mac signed by this certificate". Every update signed with it
# keeps the permission, and no other app can pass as Sidesnap without the
# certificate's private key.
#
# Building someone else's copy (a fork) without that certificate still works:
# the app gets a plain local signature and macOS asks for Screen Recording
# again after each rebuild. Official releases set REQUIRE_SIGNING_CERT=1 so
# they can never ship without it.
#
# usage: tools/sign_app.sh path/to/Sidesnap.app
set -euo pipefail
APP="$1"
NAME="Sidesnap Developer"
ID=$(security find-identity -p codesigning | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}')
if [ -z "$ID" ]; then
    if [ "${REQUIRE_SIGNING_CERT:-0}" = "1" ]; then
        echo "ERROR: the '$NAME' signing certificate isn't in your keychain."
        echo "Restore it from your backup (docs/MAINTAINING.md > Keys and backups) and try again."
        exit 1
    fi
    echo "Note: no '$NAME' certificate here, so using a plain local signature."
    ID="-"
fi
xattr -cr "$APP"
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    B="$FW/Versions/B"
    for x in "$B/XPCServices/Installer.xpc" "$B/XPCServices/Downloader.xpc"; do
        [ -e "$x" ] && codesign --force --sign "$ID" --preserve-metadata=entitlements "$x"
    done
    codesign --force --sign "$ID" "$B/Autoupdate"
    codesign --force --sign "$ID" "$B/Updater.app"
    codesign --force --sign "$ID" "$FW"
fi
codesign --force --sign "$ID" --identifier app.sidesnap.mac "$APP"
codesign --verify --deep --strict "$APP"
