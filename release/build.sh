#!/bin/sh
# Builds a Developer ID signed, notarized and stapled build/release/peekport.zip for Gumroad.
#
# One-time setup on the release Mac:
#   1. Xcode signed in with an Admin or Account Holder of team 594AMTRFJV (FAMILIA d.o.o.).
#      The Developer ID certificate is cloud-managed, so the export passes
#      -allowProvisioningUpdates and no local certificate is needed.
#   2. Notary credentials stored under the profile name used below:
#      xcrun notarytool store-credentials peekport-notary --apple-id <apple id> --team-id 594AMTRFJV
set -eu
cd "$(dirname "$0")/.."

OUT=build/release
rm -rf "$OUT"

xcodebuild -scheme App -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$OUT/peekport.xcarchive" archive -quiet
xcodebuild -exportArchive -allowProvisioningUpdates -archivePath "$OUT/peekport.xcarchive" \
    -exportOptionsPlist release/ExportOptions.plist -exportPath "$OUT" -quiet

# notarytool takes a zip; the stapled app is zipped again for distribution.
ditto -c -k --keepParent "$OUT/peekport.app" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile peekport-notary --wait
xcrun stapler staple "$OUT/peekport.app"
spctl --assess --type execute --verbose "$OUT/peekport.app"
ditto -c -k --keepParent "$OUT/peekport.app" "$OUT/peekport.zip"
echo "Ready: $OUT/peekport.zip"
