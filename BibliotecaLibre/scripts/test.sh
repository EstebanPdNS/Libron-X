#!/bin/sh
# CLT-only macOS toolchains need an explicit path for Swift Testing macros.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
swift_toolchain=$(xcrun --find swift)
toolchain_dir=$(CDPATH= cd -- "$(dirname -- "$swift_toolchain")/.." && pwd)
testing_plugin="$toolchain_dir/lib/swift/host/plugins/testing/libTestingMacros.dylib"
developer_dir=$(xcode-select -p)
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
if [ -f "$testing_plugin" ]; then
    swift test --build-system native --disable-xctest \
        -Xswiftc -F -Xswiftc "$testing_frameworks" \
        -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" \
        -Xlinker -F -Xlinker "$testing_frameworks" \
        -Xlinker -rpath -Xlinker "$testing_frameworks" "$@"
else
    swift test --build-system native --disable-xctest "$@"
fi
