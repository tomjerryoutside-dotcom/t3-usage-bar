#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-$repo/dist}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$repo/Resources/Info.plist")"
app_name='T3 Usage Bar.app'
zip_name="T3-Usage-Bar-v$version-macOS-universal.zip"
for output in "$destination/$app_name" "$destination/$zip_name" "$destination/$zip_name.sha256"; do
    if [[ -e "$output" ]]; then
        printf '产物已存在，请选用新的输出目录。%s\n' "$output" >&2
        exit 1
    fi
done

build_dir="$(mktemp -d "$destination/.build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/$app_name"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 644 "$repo/Resources/Info.plist" "$app/Contents/Info.plist"
install -m 644 "$repo/LICENSE" "$app/Contents/Resources/LICENSE"

for arch in arm64 x86_64; do
    /usr/bin/xcrun --sdk macosx swiftc -parse-as-library -O \
        -target "$arch-apple-macos13.0" -lsqlite3 "$repo"/Sources/*.swift \
        -o "$build_dir/T3UsageBar-$arch"
done

binary="$app/Contents/MacOS/T3UsageBar"
/usr/bin/xcrun lipo -create "$build_dir/T3UsageBar-arm64" "$build_dir/T3UsageBar-x86_64" -output "$binary"
chmod 755 "$binary"
/usr/bin/codesign --sign - "$app"
/usr/bin/codesign --verify --strict --all-architectures "$app"

/usr/bin/ditto -c -k --keepParent "$app" "$build_dir/$zip_name"
(
    cd "$build_dir"
    /usr/bin/shasum -a 256 "$zip_name" > "$zip_name.sha256"
)
mv "$app" "$build_dir/$zip_name" "$build_dir/$zip_name.sha256" "$destination/"
printf '已构建 %s/%s\n' "$destination" "$zip_name"
