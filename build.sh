#!/bin/zsh
# Builds BitPolish from this folder. Needs only Apple's Command Line Tools
# (xcode-select --install), not Xcode. Apple Silicon only.
#
#   ./build.sh                        build/BitPolish.app for this Mac (ad-hoc signed)
#   ./build.sh --release              build/BitPolish-<version>.dmg for anyone:
#                                     Developer ID signed, notarized, stapled
#   ./build.sh --release --dry-run    the release pipeline with an ad-hoc
#                                     signature and no notarization, to test it
#   ./build.sh --testing              build/BitPolish.app with the developer test
#                                     hooks compiled in (see README)
#   ./build.sh --keys                 create the update-signing key (once; it goes
#                                     in your login Keychain) and print its public half
#   ./build.sh --appcast              write build/updates/appcast.xml from the
#                                     release disk images in build/updates/, with
#                                     ReleaseNotes/<version>.md as the update's notes
#
# Checks for the core logic: swift run BitPolishChecks
#
# Release settings (environment variables, optional):
#   BITPOLISH_SIGN_ID         signing identity; default: the first
#                           "Developer ID Application" certificate in your keychain
#   BITPOLISH_NOTARY_PROFILE  notarytool keychain profile; default: BitPolish-notary
#                           (create once: xcrun notarytool store-credentials BitPolish-notary)
set -euo pipefail
cd "$(dirname "$0")"

MODE=dev
DRY=0
SWIFT_FLAGS=()
for arg in "$@"; do
    case $arg in
        --release) MODE=release ;;
        --dry-run) DRY=1 ;;
        --testing) SWIFT_FLAGS=(-Xswiftc -DBITPOLISH_TESTING) ;;
        --keys) MODE=keys ;;
        --appcast) MODE=appcast ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done
if [[ $MODE == release && ${#SWIFT_FLAGS} -gt 0 ]]; then
    echo "--testing can't be combined with --release." >&2
    exit 2
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)

# Sparkle's command-line tools (generate_keys, generate_appcast), from the
# same pinned release the app embeds, checked against a known checksum.
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
sparkle_tools() {
    local dir=build/sparkle-tools
    [[ -x $dir/bin/generate_appcast ]] && return
    mkdir -p "$dir"
    curl -fsSL -o "$dir/Sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    if [[ $(shasum -a 256 "$dir/Sparkle.tar.xz" | cut -d' ' -f1) != "$SPARKLE_SHA256" ]]; then
        echo "Sparkle's tool download doesn't match its checksum; not using it." >&2
        rm -rf "$dir"; exit 1
    fi
    tar -xf "$dir/Sparkle.tar.xz" -C "$dir" bin
    rm "$dir/Sparkle.tar.xz"
}

if [[ $MODE == keys ]]; then
    sparkle_tools
    echo "==> Creating (or finding) the update-signing key in your login Keychain"
    build/sparkle-tools/bin/generate_keys
    echo "Put the public key above in Support/Info.plist as SUPublicEDKey."
    echo "Back up the private key: build/sparkle-tools/bin/generate_keys -x <file>, then store that file safely."
    exit 0
fi

if [[ $MODE == appcast ]]; then
    sparkle_tools
    FEED=$(/usr/libexec/PlistBuddy -c "Print SUFeedURL" Support/Info.plist 2>/dev/null || true)
    REPO="${BITPOLISH_GITHUB_REPO:-blockstarsoftware/BitPolish}"   # where release disk images live
    if [[ -z $FEED || -z $REPO ]]; then
        echo "Set SUFeedURL in Support/Info.plist and BITPOLISH_GITHUB_REPO=owner/name first." >&2
        exit 1
    fi
    DMG="build/updates/BitPolish-$VERSION.dmg"
    [[ -f $DMG ]] || { echo "No $DMG; run ./build.sh --release first." >&2; exit 1; }
    # Only this version's disk image goes in, merged into the feed as it's
    # published now, so earlier entries keep their own download links (each
    # release lives under its own v<version> tag). No delta updates: only
    # the disk image is uploaded.
    STAGE=build/appcast-stage
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    cp "$DMG" "$STAGE/"
    # Release notes: ReleaseNotes/<version>.md, staged under the disk image's
    # name so generate_appcast pairs them, and embedded in the feed (the site
    # hosts only appcast.xml). Without the file the update window shows none.
    NOTES="ReleaseNotes/$VERSION.md"
    if [[ -f $NOTES ]]; then
        cp "$NOTES" "$STAGE/BitPolish-$VERSION.md"
        echo "==> Release notes: $NOTES"
    else
        echo "    (no $NOTES; this update will show no release notes)"
    fi
    curl -fsSL "$FEED" -o build/updates/appcast.xml 2>/dev/null || echo "    (no published feed yet; starting a new one)"
    echo "==> Writing build/updates/appcast.xml (signed with your Keychain key)"
    build/sparkle-tools/bin/generate_appcast --maximum-deltas 0 --embed-release-notes \
        --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
        -o build/updates/appcast.xml "$STAGE"
    rm -rf "$STAGE"
    echo "Publish build/updates/appcast.xml at $FEED, and attach build/updates/BitPolish-$VERSION.dmg to release v$VERSION."
    exit 0
fi
TRIPLE=arm64-apple-macosx14.0
APP=build/BitPolish.app

# Check release prerequisites before spending time on a build.
if [[ $MODE == release && $DRY == 0 ]]; then
    SIGN_ID="${BITPOLISH_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
    if [[ -z $SIGN_ID ]]; then
        echo "No \"Developer ID Application\" certificate found in your keychain." >&2
        echo "Create one in your Apple Developer account, or set BITPOLISH_SIGN_ID." >&2
        exit 1
    fi
    PROFILE="${BITPOLISH_NOTARY_PROFILE:-BitPolish-notary}"
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "No notarization credentials named \"$PROFILE\" in your keychain." >&2
        echo "Store them once with: xcrun notarytool store-credentials \"$PROFILE\"" >&2
        exit 1
    fi
fi

echo "==> Building BitPolish $VERSION (Apple Silicon)"
swift build -c release --triple "$TRIPLE" --product BitPolish "${SWIFT_FLAGS[@]}"
BIN="$(swift build -c release --triple "$TRIPLE" --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BitPolish" "$APP/Contents/MacOS/BitPolish"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/BitPolish.icns "$APP/Contents/Resources/BitPolish.icns"   # the app icon (Finder, Dock, About)
# Sparkle, for software updates. Its XPC services exist for sandboxed apps;
# BitPolish isn't sandboxed, so they're left out.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle's MIT License travels with the copy of Sparkle inside the app.
cp .build/checkouts/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle License.txt"

if [[ $MODE == dev ]]; then
    # Ad-hoc signatures: run on this Mac. Inside out: Sparkle's helpers, the
    # framework, then the app.
    for part in "$SPARKLE_FW/Versions/B/Autoupdate" "$SPARKLE_FW/Versions/B/Updater.app" "$SPARKLE_FW" "$APP"; do
        codesign --force --sign - "$part"
    done
    echo "Built $PWD/$APP"
    exit 0
fi

# ---- Release ----------------------------------------------------------------

if [[ $DRY == 1 ]]; then
    SIGN_ID="-"
    echo "==> Dry run: ad-hoc signature, no notarization"
fi

# Signs with the hardened runtime (required for notarization) and, for a real
# release, a secure timestamp from Apple.
sign() {
    local args=(--force --options runtime --sign "$SIGN_ID")
    [[ $DRY == 1 ]] || args+=(--timestamp)
    codesign "${args[@]}" "$1"
}

# Submits a file to Apple's notary service, waits, and fails loudly (with the
# command to read Apple's log) unless it's accepted.
notarize() {
    local file=$1 result status id
    echo "==> Notarizing $(basename "$file") (usually a few minutes)"
    # `|| true`: on an upload or sign-in failure, still reach the message below.
    result=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json 2>&1) || true
    status=$(print -r -- "$result" | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' | head -1)
    id=$(print -r -- "$result" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1)
    if [[ $status != "Accepted" ]]; then
        echo "Notarization status: ${status:-unknown}" >&2
        [[ -n $id ]] && echo "See why: xcrun notarytool log $id --keychain-profile \"$PROFILE\"" >&2
        exit 1
    fi
    echo "    Accepted ($id)"
}

echo "==> Signing Sparkle's helpers, Sparkle, then the app"
sign "$SPARKLE_FW/Versions/B/Autoupdate"
sign "$SPARKLE_FW/Versions/B/Updater.app"
sign "$SPARKLE_FW"
sign "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ $DRY == 0 ]]; then
    # Notarize and staple the app itself, so it opens without a network check
    # even after it's copied out of the disk image.
    ditto -c -k --keepParent "$APP" build/BitPolish-notarize.zip
    notarize build/BitPolish-notarize.zip
    rm -f build/BitPolish-notarize.zip
    xcrun stapler staple "$APP"
fi

echo "==> Making the disk image"
DMG="build/BitPolish-$VERSION.dmg"
STAGE=build/dmg-stage
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag BitPolish onto this to install
hdiutil create -volname "BitPolish $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
sign "$DMG"

if [[ $DRY == 0 ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    echo "==> Gatekeeper check"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

# A copy for the update feed (./build.sh --appcast); real releases only.
if [[ $DRY == 0 ]]; then
    mkdir -p build/updates
    cp "$DMG" build/updates/
fi
echo "Built $PWD/$DMG"
