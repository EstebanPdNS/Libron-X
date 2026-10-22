#!/bin/sh
# Build one installed application; preserve source revisions before replacement.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
destination="${LIBRONX_APP_PATH:-/Applications/Libron-X.app}"
# The headless converter may be running from the checkout. Only the installed
# UI process owns this bundle and needs to close before replacement.
for process_id in $(pgrep -x LibronXRebuild || true); do
    process_command=$(ps -p "$process_id" -o command=)
    case "$process_command" in
        "$destination/Contents/MacOS/LibronXRebuild"*)
            printf 'Close Libron-X before updating its installed application.\n' >&2
            exit 1 ;;
    esac
done
if [ -e "$destination" ]; then
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
    [ "$identifier" = 'org.libronx.mac.rebuild' ] || { printf 'Refusing to replace a different application.\n' >&2; exit 1; }
fi
if [ -f Resources/BundledDictionaries/catalog.json ] && [ ! -d Resources/BundledDictionaries/Packages ]; then
    printf 'Restore the bundled dictionaries from the v0.2 release app before building. See docs/development.md.\n' >&2
    exit 1
fi
archive_dir="${LIBRONX_SOURCE_ARCHIVES:-$project_dir/.source-versions}"
mkdir -p "$archive_dir"
source_revision=$(date -u +%Y%m%dT%H%M%SZ)-$$
# Dictionary packages are reproducible release dependencies, shared by every
# source revision. Keep their catalog and notices without duplicating the payload.
tar --exclude=Resources/BundledDictionaries/sources --exclude=Resources/BundledDictionaries/candidates --exclude=Resources/BundledDictionaries/Packages -czf "$archive_dir/Libron-X-source-$source_revision.tar.gz" Package.swift Sources Tests Resources Localization scripts docs LICENSE THIRD_PARTY_NOTICES.md
if git rev-parse --git-dir >/dev/null 2>&1; then
    git rev-parse HEAD > "$archive_dir/Libron-X-source-$source_revision.git-head.txt"
    git diff --binary > "$archive_dir/Libron-X-source-$source_revision.patch"
fi
cache_dir="${LIBRONX_BUILD_DIR:-$project_dir/.build/macos-app}"
# A local private key is embedded in the executable, never copied into source or
# uploaded with resource collections. Public source builds can omit this key.
key_file="${LIBRONX_RESOURCE_KEY_FILE:-$HOME/Library/Application Support/Libron-X/Distribution/library-key.txt}"
if [ -n "${LIBRONX_RESOURCE_KEY_FILE:-}" ] && [ ! -f "$key_file" ]; then
    printf 'Resource key file does not exist.\n' >&2
    exit 1
fi
if [ -f "$key_file" ]; then
    mkdir -p "$cache_dir/private"
    chmod 700 "$cache_dir/private"
    tr -d '\r\n' < "$key_file" > "$cache_dir/private/library-key.bin"
    chmod 600 "$cache_dir/private/library-key.bin"
    LC_ALL=C grep -Eq '^[A-Za-z0-9]{30}$' "$cache_dir/private/library-key.bin" || { printf 'Resource key must contain 30 ASCII letters or digits.\n' >&2; exit 1; }
    [ "$(wc -c < "$cache_dir/private/library-key.bin" | tr -d ' ')" = 30 ] || exit 1
    swift build --scratch-path "$cache_dir" --build-system native -c release --product LibronXRebuild \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __lxkey -Xlinker "$cache_dir/private/library-key.bin"
else
    swift build --scratch-path "$cache_dir" --build-system native -c release --product LibronXRebuild
fi
binary_dir=$(swift build --scratch-path "$cache_dir" --build-system native -c release --show-bin-path)
mkdir -p "$(dirname -- "$destination")"
staging_dir=$(mktemp -d "$(dirname -- "$destination")/.libron-x-stage.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM
bundle_dir="$staging_dir/Libron-X.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
# Install the exact resource bundle built with this binary. AppStrings first
# resolves Contents/Resources, so an installed app never needs a build checkout.
cp -R "$binary_dir/LibronX_MacRebuild.bundle" "$bundle_dir/Contents/Resources/"
# Ship attributed offline dictionaries; sources remain inside each package.
dictionaries="$project_dir/Resources/BundledDictionaries"
if [ -f "$dictionaries/catalog.json" ]; then
    mkdir -p "$bundle_dir/Contents/Resources/BundledDictionaries"
    cp -R "$dictionaries/Packages" "$bundle_dir/Contents/Resources/BundledDictionaries/"
    cp "$dictionaries/catalog.json" "$bundle_dir/Contents/Resources/BundledDictionaries/"
fi
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
<key>CFBundleVersion</key><string>100</string>
<key>CFBundleShortVersionString</key><string>0.5</string>
<key>LibronXReleaseVersion</key><string>0.5</string>
<key>LibronXUpdateChannel</key><string>beta</string>
<key>CFBundleExecutable</key><string>LibronXRebuild</string>
<key>CFBundleDevelopmentRegion</key><string>es</string>
<key>CFBundleLocalizations</key><array>
<string>en</string><string>zh-Hans</string><string>hi</string><string>es</string><string>ar</string>
<string>fr</string><string>bn</string><string>pt</string><string>id</string><string>ur</string>
</array>
<key>CFBundleIconFile</key><string>LibronX-Red.icns</string>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>org.libron.resource</string>
<key>UTTypeDescription</key><string>Libron resource</string>
<key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>libron</string></array></dict>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Libron resource</string><key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSItemContentTypes</key><array><string>org.libron.resource</string></array><key>LSTypeIsPackage</key><true/>
</dict></array>
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
codesign --verify --deep --strict "$bundle_dir"
if [ -e "$destination" ]; then /usr/bin/trash "$destination"; fi
mv "$bundle_dir" "$destination"
codesign --verify --deep --strict "$destination"
printf '%s\n' "$destination"
