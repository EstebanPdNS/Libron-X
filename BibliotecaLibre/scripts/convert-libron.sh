#!/bin/sh
# Convert with the same native parser and validation used by the application.
# Usage: convert-libron.sh LIBRARY_DIRECTORY [SOURCE_DIRECTORY]
set -eu
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { printf 'Usage: %s LIBRARY_DIRECTORY [SOURCE_DIRECTORY]\n' "$0" >&2; exit 2; }
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
swift build --product LibronXRebuild
binary_dir=$(swift build --show-bin-path)
if [ "$#" -eq 2 ]; then
    NSUnbufferedIO=YES "$binary_dir/LibronXRebuild" --normalize-library "$1" --import-directory "$2"
else
    NSUnbufferedIO=YES "$binary_dir/LibronXRebuild" --normalize-library "$1"
fi
