#!/bin/bash
# Runs the test suite. With full Xcode, plain `swift test` works; with only the
# Command Line Tools installed, Swift Testing lives outside the default search
# paths, so point the compiler and linker at it.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools* && -d "$CLT/Frameworks/Testing.framework" ]]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
    -Xlinker -F -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/usr/lib" \
    "$@"
fi
exec swift test "$@"
