#!/bin/zsh
# usage: ./release.sh 1.0.1
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${1:?usage: ./release.sh <version>}
echo "$VERSION" > VERSION
git add -A
git commit -m "Release v$VERSION"
./build.sh install
rm -f build/AnyCast.zip
ditto -c -k --keepParent build/AnyCast.app build/AnyCast.zip
git tag "v$VERSION"
git push origin HEAD --tags
gh release create "v$VERSION" build/AnyCast.zip build/AnyCast.dmg --title "AnyCast $VERSION" --generate-notes
echo "Released v$VERSION. Installed copies update within 6 hours, or right away from Check for updates."
