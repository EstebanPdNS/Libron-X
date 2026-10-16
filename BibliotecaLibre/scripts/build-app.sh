#!/bin/sh
# Produces a local app bundle from the package. No original books or DLLs are copied.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
swift build --build-system native -c release --product LibronX
binary_dir=$(swift build --build-system native -c release --show-bin-path)
bundle_dir="$project_dir/dist/prototype/Libron-X.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$binary_dir/LibronX" "$bundle_dir/Contents/MacOS/LibronX"
cat > "$bundle_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Libron-X</string>
<key>CFBundleDisplayName</key><string>Libron-X</string>
<key>CFBundleIdentifier</key><string>org.libronx.mac</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleExecutable</key><string>LibronX</string>
<key>CFBundleIconFile</key><string>LibronX.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
swift scripts/generate-icon.swift "$project_dir/Resources"
iconutil -c icns "$project_dir/Resources/LibronX.iconset" -o "$bundle_dir/Contents/Resources/LibronX.icns"
cp "$project_dir/Resources/Brand/raster/Libron-X-emblem-red-1024.png" "$bundle_dir/Contents/Resources/Libron-X-emblem-red-1024.png"
codesign --force --sign - "$bundle_dir"
printf '%s\n' "$bundle_dir"
