#!/bin/sh
# Compiles ScanMath.swift with the Mac-side test and runs it.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)
cp "$here/test_scanmath.swift" "$out/main.swift"
swiftc -O -o "$out/test_scanmath" "$here/../ios/Runner/ScanMath.swift" "$out/main.swift"
"$out/test_scanmath"
