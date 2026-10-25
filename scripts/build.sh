#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
arch="${ARCH:-$(uname -m)}"
[[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo 'Unsupported architecture' >&2; exit 1; }
mkdir -p build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
for source in PrinterBridge Server; do
  xcrun clang -Os -Wall -Wextra -Werror -arch "$arch" -mmacosx-version-min=13.0 -c "Sources/$source.c" -o "build/$source.o"
done
native_sources=(Sources/Core.swift Sources/Discovery.swift Sources/Registry.swift Sources/Driver.swift Sources/Setup.swift)
flags=(-swift-version 5 -Osize -whole-module-optimization -module-cache-path "$CLANG_MODULE_CACHE_PATH" -target "$arch-apple-macosx13.0" -import-objc-header Sources/PrinterBridge.h)
link=(build/PrinterBridge.o build/Server.o -framework AppKit -framework PDFKit -lcups -Xlinker -dead_strip)
xcrun swiftc "${flags[@]}" "${native_sources[@]}" Sources/main.swift "${link[@]}" -o build/hp-open-print.new
xcrun strip -S -x build/hp-open-print.new
mv -f build/hp-open-print.new build/hp-open-print
codesign --force --sign - build/hp-open-print
cupstestppd -W all resources/HP-M452nw-Open.ppd
app='build/HP M452nw Driver.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp build/hp-open-print "$app/Contents/MacOS/hp-open-print"
cp resources/DriverInfo.plist "$app/Contents/Info.plist"
cp resources/HP-M452nw-Open.ppd "$app/Contents/Resources/HP-M452nw-Open.ppd"
cp LICENSE "$app/Contents/Resources/LICENSE"
codesign --force --sign - "$app"
if [[ "${BUILD_TESTS:-1}" == 1 ]]; then
  xcrun swiftc "${flags[@]}" -D TESTING "${native_sources[@]}" Tests/Diagnostics.swift Tests/DriverTests.swift Tests/SelfTests.swift Sources/main.swift "${link[@]}" -o build/hp-open-print-tests
  codesign --force --sign - build/hp-open-print-tests
fi
echo "Built $arch driver: $(stat -f %z build/hp-open-print) bytes"
