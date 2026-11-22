#!/bin/bash
# Publishes a Sidesnap update in one go:
#   1. reads the newest version and its notes from RELEASE_NOTES.md
#   2. sets that version in the app (and bumps the build number)
#   3. builds the signed DMG (release.sh; refuses without the certificate)
#   4. signs the update with Sidesnap's private update key (keychain)
#   5. writes the update feed (appcast.xml) the app checks
#   6. puts feed + DMG into site/, updates the version text, deploys the site
#   7. checks the live feed and download match what was built, then commits
#      and tags the release
#
# usage: ./publish.sh            (build + publish)
#        ./publish.sh --dry-run  (build + prepare everything, no deploy/commit)
set -euo pipefail
export WRANGLER_SEND_METRICS=false   # no usage telemetry to Cloudflare
export REQUIRE_SIGNING_CERT=1
cd "$(dirname "$0")"
SITE_URL="https://sidesnap.typewellapp.workers.dev"
DRY=${1:-}

[ -z "$(git status --porcelain -- Sources Resources)" ] || {
    echo "ERROR: Sources/ or Resources/ has uncommitted changes. Commit them first."; exit 1; }

tools/fetch_sparkle.sh
SPARKLE=Vendor/Sparkle-2.10.1

# --- 1. version + notes ------------------------------------------------------
VERSION=$(grep -m1 -E '^## [0-9]+(\.[0-9]+)*\s*$' RELEASE_NOTES.md | sed -E 's/^## //; s/[[:space:]]+$//')
[ -n "$VERSION" ] || { echo "ERROR: no '## <version>' heading in RELEASE_NOTES.md"; exit 1; }
NOTES_HTML=$(awk -v v="## $VERSION" '
    $0 == v {on=1; next}
    on && /^## / {exit}
    on && /^- / {sub(/^- /, ""); gsub(/&/, "\\&amp;"); gsub(/</, "\\&lt;"); gsub(/>/, "\\&gt;"); print "<li>" $0 "</li>"}
' RELEASE_NOTES.md)
[ -n "$NOTES_HTML" ] || { echo "ERROR: version $VERSION has no '- ' bullet points in RELEASE_NOTES.md"; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "ERROR: version $VERSION was already published (tag v$VERSION exists). Add a new version to RELEASE_NOTES.md."
    exit 1
fi

# --- 2. set version, bump build number ----------------------------------------
PB=/usr/libexec/PlistBuddy
BUILD=$(( $($PB -c "Print CFBundleVersion" Resources/Info.plist) + 1 ))
$PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Resources/Info.plist
echo "Publishing Sidesnap $VERSION (build $BUILD)"

# --- 3. build ------------------------------------------------------------------
./release.sh
DMG="dist/Sidesnap-$VERSION.dmg"

# --- 4. sign the update ----------------------------------------------------------
SIG=$("$SPARKLE/bin/sign_update" --account sidesnap "$DMG")   # sparkle:edSignature="..." length="..."
echo "Update signature: ${SIG:0:40}..."

# --- 5. update feed ------------------------------------------------------------
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
mkdir -p site/updates site/downloads
cat > site/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sidesnap</title>
    <link>$SITE_URL</link>
    <description>Sidesnap updates</description>
    <language>en</language>
    <item>
      <title>Sidesnap $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>
$NOTES_HTML
</ul>]]></description>
      <enclosure url="$SITE_URL/updates/Sidesnap-$VERSION.dmg" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
plutil -lint site/appcast.xml >/dev/null 2>&1 || xmllint --noout site/appcast.xml

# --- 6. website ------------------------------------------------------------------
SIZE_MB=$(python3 -c "import os;print(f'{os.path.getsize(\"$DMG\")/1e6:.1f}')")
rm -f site/updates/Sidesnap-*.dmg                 # only the newest is served
cp "$DMG" "site/updates/Sidesnap-$VERSION.dmg"
cp "$DMG" site/downloads/Sidesnap.dmg
# The line under the download button: "Version 1.0 · 3.1 MB · macOS 14 or later"
sed -i '' -E "s/Version [0-9]+(\.[0-9]+)* · [0-9.]+ MB/Version $VERSION · $SIZE_MB MB/g; s#<span>Version [0-9]+(\.[0-9]+)*</span>#<span>Version $VERSION</span>#g" site/index.html

if [ "$DRY" = "--dry-run" ]; then
    git checkout -- Resources/Info.plist site/index.html 2>/dev/null || true
    echo; echo "Dry run: built $DMG and prepared site/, nothing deployed or committed."
    exit 0
fi

npx --yes wrangler deploy

# --- 7. check what's live, then record the release ------------------------------
sleep 3
WANT=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
LIVE_FEED=$(curl -fsS "$SITE_URL/appcast.xml")
echo "$LIVE_FEED" | grep -q "<sparkle:shortVersionString>$VERSION<" || { echo "ERROR: live feed doesn't show $VERSION yet"; exit 1; }
for path in "updates/Sidesnap-$VERSION.dmg" "downloads/Sidesnap.dmg"; do
    GOT=$(curl -fsS -A "Sidesnap-publish-check" "$SITE_URL/$path" | shasum -a 256 | cut -d' ' -f1)
    [ "$GOT" = "$WANT" ] || { echo "ERROR: live $path doesn't match the build"; exit 1; }
done

git add Resources/Info.plist RELEASE_NOTES.md site/appcast.xml site/index.html
git commit -q -m "Release Sidesnap $VERSION (build $BUILD)" || true
git tag "v$VERSION"
git push -q && git push -q origin "v$VERSION"
echo
echo "Published Sidesnap $VERSION. Live feed and download match the build ($SIZE_MB MB)."
