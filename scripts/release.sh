#!/bin/sh
# Builds a universal, ad-hoc-signed Stacky.app and zips it for a GitHub release: build/Stacky-<version>.zip
# Ad-hoc so no personal certificate name ships in the download.
set -e
cd "$(dirname "$0")/.."
ARCHS="--arch arm64 --arch x86_64" scripts/bundle.sh -
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Stacky.app/Contents/Info.plist)
rm -f "build/Stacky-$V.zip"
ditto -c -k --keepParent build/Stacky.app "build/Stacky-$V.zip"
echo "Built build/Stacky-$V.zip"
