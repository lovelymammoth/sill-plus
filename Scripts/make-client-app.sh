#!/bin/bash
# Builds "Sill Viewer.app", the Mac client (docs/mac-client.md), from this SwiftPM package.
#
#   Scripts/make-client-app.sh                    .build/Sill Viewer.app, signed with your Apple Development identity
#   Scripts/make-client-app.sh --install          …then replace /Applications/Sill Viewer.app
#   Scripts/make-client-app.sh --install --open   …and launch it
#   SILL_CLIENT_BUNDLE_ID=com.example.sill.client Scripts/make-client-app.sh   another bundle identifier
#   SILL_INSTALL_DIR=~/Applications Scripts/make-client-app.sh --install        another install folder
#
# Why a bundle: Local Network access (macOS 15 and later) is asked for and granted per app, with the
# bundle's NSLocalNetworkUsageDescription and NSBonjourServices; a bare executable run from Terminal
# borrows Terminal's. The client needs no Screen Recording and no Accessibility: it only shows another
# Mac's picture and sends it input over the network. Its key is in the login keychain
# (ClientIdentity.swift), which with a real signing identity stays readable across rebuilds; signed ad
# hoc, each rebuild is a new app to the keychain, which asks once to allow it.
set -euo pipefail
cd "$(dirname "$0")/.."

install=0; open_app=0
for arg in "$@"; do
    case "$arg" in
        --install) install=1 ;;
        --open) open_app=1 ;;
        *) echo "usage: $0 [--install] [--open]" >&2; exit 2 ;;
    esac
done

swift build -c release --product SillMacClient
bin="$(swift build -c release --product SillMacClient --show-bin-path)"
app=".build/Sill Viewer.app"
stage=".build/Sill Viewer.app.partial"
rm -rf "$stage"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
# The SDK in use recorded in the executable, as make-app.sh does for Sill.app: SwiftPM records the
# deployment target as the SDK, and macOS 26 and later then draw the app in the pre-26 look.
minos="$(xcrun vtool -show-build "$bin/SillMacClient" | awk '$1 == "minos" && !found { print $2; found = 1 }')"
xcrun vtool -set-build-version macos "${minos:?vtool reported no deployment target}" \
    "$(xcrun --sdk macosx --show-sdk-version)" -output "$stage/Contents/MacOS/SillMacClient" "$bin/SillMacClient"
cp Packaging/ClientInfo.plist "$stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$stage/Contents/Info.plist"
if [ -n "${SILL_CLIENT_BUNDLE_ID:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SILL_CLIENT_BUNDLE_ID" "$stage/Contents/Info.plist"
fi
printf 'APPL????' > "$stage/Contents/PkgInfo"
# Sill.app's icon when make-app.sh has compiled it (.build/icon), else the generic one.
if [ -f .build/icon/compiled/AppIcon.icns ]; then
    cp .build/icon/compiled/AppIcon.icns "$stage/Contents/Resources/AppIcon.icns"
    [ -f .build/icon/compiled/Assets.car ] && cp .build/icon/compiled/Assets.car "$stage/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$stage/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$stage/Contents/Info.plist"
fi

identity="${SILL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }' || true)}"
if [ -z "$identity" ]; then
    identity="-"
    echo "warning: no Apple Development identity in the keychain; signing ad hoc (the keychain asks again after each rebuild)." >&2
fi
codesign --force --options runtime --timestamp=none --sign "$identity" "$stage"
codesign --verify --strict "$stage"
rm -rf "$app"
mv "$stage" "$app"
echo "Built $app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist"), signed by ${identity})"

if [ "$install" = 1 ]; then
    dest="${SILL_INSTALL_DIR:-/Applications}/Sill Viewer.app"
    pkill -x SillMacClient 2>/dev/null || true
    rm -rf "$dest"
    ditto "$app" "$dest"
    echo "Installed $dest"
    if [ "$open_app" = 1 ]; then open "$dest"; fi
elif [ "$open_app" = 1 ]; then
    open "$app"
fi
