#!/bin/sh
# Lays out a release folder for one app, after it has been built: dist/<App>-<version>-<os>/
#   sh libs/shared/release/package.sh windows|linux|macos
# Run it from the app's folder (the release workflow does). It reads the app's display name and version from
# src/brand.odin (APP_NAME, APP_VERSION) and fills in the INSTALL guide next to this script.
#   linux: SDL3_LIB=/path/to/libSDL3.so.0   the SDL3 to bundle (the program finds it next to itself, $ORIGIN)
#   macos: SDL3_LIB=/path/to/libSDL3.0.dylib the SDL3 to put in the .app (Contents/Frameworks)
# The folder is left for the caller to zip: Windows and macOS as .zip, Linux as .tar.gz (keeps file modes).
set -e
os="$1"
here="$(cd "$(dirname "$0")" && pwd)"
app="$(basename "$(pwd)")" # PangolinPaints
if [ ! -f "src/brand.odin" ]; then
	echo "package.sh: run it from an app's folder (src/brand.odin not found)" >&2
	exit 1
fi
name="$(sed -n 's/^APP_NAME :: "\(.*\)".*/\1/p' src/brand.odin)"         # Pangolin Paints
version="$(sed -n 's/^APP_VERSION :: "\(.*\)".*/\1/p' src/brand.odin)"   # 0.9.0-beta
out="dist/$app-$version-$os"
rm -rf "$out"
mkdir -p "$out"

# the INSTALL guide, with this app's names filled in
guide() {
	sed -e "s/{{NAME}}/$name/g" -e "s/{{APP}}/$app/g" -e "s/{{VERSION}}/$version/g" "$here/INSTALL-$1.txt" >"$2"
}
# what every bundle carries: the read-me, the licences (the app's, the font's, SDL's)
common() {
	cp README.md "$1/README.md"
	[ -f GUIDE.md ] && cp GUIDE.md "$1/GUIDE.md"
	cp LICENSE "$1/LICENSE.txt"
	for f in assets/fonts/*OFL*.txt; do [ -f "$f" ] && cp "$f" "$1/LICENSE-font-$(basename "$f")"; done
	sdl_license="$(odin root)"
	sdl_license="${sdl_license%/}/vendor/sdl3/LICENSE.txt"
	[ -f "$sdl_license" ] && cp "$sdl_license" "$1/LICENSE-SDL3.txt"
	return 0
}

case "$os" in
windows)
	cp "$app.exe" "$app-console.exe" SDL3.dll "$out/"
	common "$out"
	guide windows "$out/INSTALL.txt"
	# Windows readers expect CRLF in a .txt
	for f in "$out"/*.txt; do sed -i 's/$/\r/' "$f" 2>/dev/null || true; done
	;;
linux)
	if [ -z "$SDL3_LIB" ] || [ ! -f "$SDL3_LIB" ]; then
		echo "package.sh linux: set SDL3_LIB to the libSDL3.so.0 to bundle" >&2
		exit 1
	fi
	cp "$app" "$out/"
	cp -L "$SDL3_LIB" "$out/libSDL3.so.0"
	chmod 755 "$out/$app"
	chmod 644 "$out/libSDL3.so.0"
	# install.sh --no-build adds the app to the menu from this folder; it takes the icons from assets/icon
	cp install.sh "$out/"
	mkdir -p "$out/assets/icon"
	cp assets/icon/icon_*.png "$out/assets/icon/"
	common "$out"
	guide linux "$out/INSTALL.txt"
	;;
macos)
	if [ -z "$SDL3_LIB" ] || [ ! -f "$SDL3_LIB" ]; then
		echo "package.sh macos: set SDL3_LIB to the libSDL3.0.dylib to put in the app" >&2
		exit 1
	fi
	bundle="$out/$name.app"
	mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks" "$bundle/Contents/Resources"
	cp "$app" "$bundle/Contents/MacOS/$app"
	cp -L "$SDL3_LIB" "$bundle/Contents/Frameworks/libSDL3.0.dylib"
	# the program looks for SDL3 inside the app, wherever it was linked from
	old="$(otool -L "$app" | awk '/libSDL3/ {print $1; exit}')"
	install_name_tool -id "@rpath/libSDL3.0.dylib" "$bundle/Contents/Frameworks/libSDL3.0.dylib"
	[ -n "$old" ] && install_name_tool -change "$old" "@rpath/libSDL3.0.dylib" "$bundle/Contents/MacOS/$app"
	# build.sh links macOS builds with the runpath @executable_path/../Frameworks: make sure, before anyone downloads it
	if ! otool -l "$bundle/Contents/MacOS/$app" | grep -q "@executable_path/../Frameworks"; then
		echo "package.sh macos: $app has no runpath to Contents/Frameworks, so it won't find SDL3 (rebuild with build.sh)" >&2
		exit 1
	fi
	# the icon, from the app's PNGs
	set_dir="$(mktemp -d)/$app.iconset"
	mkdir -p "$set_dir"
	cp assets/icon/icon_16.png "$set_dir/icon_16x16.png"
	cp assets/icon/icon_32.png "$set_dir/icon_16x16@2x.png"
	cp assets/icon/icon_32.png "$set_dir/icon_32x32.png"
	cp assets/icon/icon_64.png "$set_dir/icon_32x32@2x.png"
	cp assets/icon/icon_128.png "$set_dir/icon_128x128.png"
	cp assets/icon/icon_256.png "$set_dir/icon_128x128@2x.png"
	cp assets/icon/icon_256.png "$set_dir/icon_256x256.png"
	iconutil -c icns "$set_dir" -o "$bundle/Contents/Resources/$app.icns"
	cat >"$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundleDisplayName</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>io.github.brandonhilde.$app</string>
	<key>CFBundleExecutable</key><string>$app</string>
	<key>CFBundleIconFile</key><string>$app</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$version</string>
	<key>LSMinimumSystemVersion</key><string>11.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
	# Apple silicon runs only signed code: an ad-hoc signature (no developer account) is enough to start it,
	# after Gatekeeper's first-run question (see INSTALL.txt)
	codesign --force --deep --sign - "$bundle"
	common "$out"
	guide macos "$out/INSTALL.txt"
	;;
*)
	echo "usage: sh libs/shared/release/package.sh windows|linux|macos" >&2
	exit 1
	;;
esac
echo "Packaged $out"
