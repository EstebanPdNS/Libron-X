#!/bin/sh
# Audit an original or packaged SQLite resource with the same deterministic
# normalization pipeline used by the application. Original files are read-only.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
if [ "$#" -ne 1 ]; then
    printf 'Usage: %s /path/to/resource.dcti\n' "$0" >&2
    exit 64
fi
swift build --product libronix-inspect >&2
binary_dir=$(swift build --show-bin-path)
exec "$binary_dir/libronix-inspect" import-audit "$1"
