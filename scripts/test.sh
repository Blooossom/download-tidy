#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TESTING_PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$TESTING_PLUGIN" ]]; then
  swift test -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN"
else
  swift test
fi
