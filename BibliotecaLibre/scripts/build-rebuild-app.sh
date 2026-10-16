#!/bin/sh
# New application; does not replace the preserved prototype or regenerate branding.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
cache_dir="${LIBRONX_BUILD_DIR:-$project_dir/.build/macos-app}"
swift build --scratch-path "$cache_dir" --build-system native -c release --product LibronXRebuild
binary_dir=$(swift build --scratch-path "$cache_dir" --build-system native -c release --show-bin-path)
bundle_dir="${LIBRONX_APP_PATH:-$project_dir/dist/Libron-X.app}"
if [ -e "$bundle_dir" ]; then
    printf 'Refusing to replace an existing bundle: %s\nChoose a fresh LIBRONX_APP_PATH.\n' "$bundle_dir" >&2
    exit 1
fi
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
# Install the exact resource bundle built with this binary. AppStrings first
# resolves Contents/Resources, so an installed app never needs a build checkout.
cp -R "$binary_dir/LibronX_MacRebuild.bundle" "$bundle_dir/Contents/Resources/"
# Replacing a mapped executable in place invalidates a running app's code pages.
# Install a fresh inode so the current process can keep its existing reading state.
next_binary="$bundle_dir/Contents/MacOS/.LibronXRebuild-next-$$"
cp "$binary_dir/LibronXRebuild" "$next_binary"
mv "$next_binary" "$bundle_dir/Contents/MacOS/LibronXRebuild"
icon_dir="$project_dir/Resources/AppIcons/Approved-Cristal"
cp "$icon_dir/LibronX-Red.icns" "$bundle_dir/Contents/Resources/LibronX-Red.icns"
cp "$icon_dir/LibronX-Black.icns" "$bundle_dir/Contents/Resources/LibronX-Black.icns"
cat > "$bundle_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Libron-X</string>
<key>CFBundleDisplayName</key><string>Libron-X</string>
<key>CFBundleIdentifier</key><string>org.libronx.mac.rebuild</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleExecutable</key><string>LibronXRebuild</string>
<key>CFBundleDevelopmentRegion</key><string>es</string>
<key>CFBundleLocalizations</key><array>
<string>en</string><string>zh-Hans</string><string>hi</string><string>es</string><string>ar</string>
<string>fr</string><string>bn</string><string>pt</string><string>id</string><string>ur</string>
</array>
<key>CFBundleIconFile</key><string>LibronX-Red.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
mkdir -p "$bundle_dir/Contents/Resources/Notices"
cp "$project_dir/LICENSE" "$bundle_dir/Contents/Resources/Notices/LICENSE"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$bundle_dir/Contents/Resources/Notices/THIRD_PARTY_NOTICES.md"
cp "$project_dir/Sources/CLibronxCompression/blast.h" "$bundle_dir/Contents/Resources/Notices/blast.h"
codesign --force --sign - "$bundle_dir"
printf '%s\n' "$bundle_dir"
