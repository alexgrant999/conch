#!/bin/zsh
# Builds, notarizes and publishes a Conch release, then updates the Homebrew cask.
#   scripts/release.sh            build, notarize, staple, zip into build/
#   scripts/release.sh --publish  also create the GitHub release and push the cask to the tap
# One-time setup:
#   1. A "Developer ID Application" certificate in the login keychain (Xcode, Settings, Accounts, Manage Certificates).
#   2. Notary credentials saved once: xcrun notarytool store-credentials conch-notary
set -euo pipefail

cd "${0:A:h}/.."
REPO="alexgrant999/conch"
TAP="alexgrant999/homebrew-conch"
PROFILE="${CONCH_NOTARY_PROFILE:-conch-notary}"
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/Conch/Contract/Types.swift)
ZIP="build/Conch-$VERSION.zip"

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application certificate in the keychain. See the setup notes at the top of this script." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notary credentials saved as '$PROFILE'. Run: xcrun notarytool store-credentials $PROFILE" >&2
  exit 1
fi

CONCH_SIGN_IDENTITY="$IDENTITY" ./scripts/build-app.sh
codesign --verify --strict --deep build/Conch.app

rm -f "$ZIP"
ditto -c -k --keepParent build/Conch.app "$ZIP"
echo "Notarizing (a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/Conch.app
# The stapled ticket lives in the app, so the zip is made again from the stapled copy.
rm -f "$ZIP"
ditto -c -k --keepParent build/Conch.app "$ZIP"
spctl --assess --type execute --verbose build/Conch.app
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "Built $ZIP ($SHA)"

[[ "${1:-}" == "--publish" ]] || { echo "Dry run done. Pass --publish to release."; exit 0; }

gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Conch $VERSION" --generate-notes

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$TAP" "$WORK/tap" -- -q
mkdir -p "$WORK/tap/Casks"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" scripts/conch.rb.template > "$WORK/tap/Casks/conch.rb"
git -C "$WORK/tap" add Casks/conch.rb
git -C "$WORK/tap" commit -q -m "conch $VERSION"
git -C "$WORK/tap" push -q
echo "Released. Install with: brew install --cask alexgrant999/conch/conch"
