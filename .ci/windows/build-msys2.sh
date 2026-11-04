#!/usr/bin/env bash
# Native MSYS2 UCRT64 build of the Windows installer.
set -euo pipefail

ROOT=$(pwd)
BUILD=$ROOT/build-msys2
STAGE=$BUILD/stage
PREFIX=$MINGW_PREFIX

# Interception has no MSYS2 package; build its small user-mode library.
if [ ! -f "$PREFIX/lib/libinterception.dll.a" ]; then
	git clone --depth 1 https://github.com/oblitum/Interception.git "$BUILD-interception"
	gcc -shared -O2 -DINTERCEPTION_EXPORT= "$BUILD-interception/library/interception.c" \
		-o "$PREFIX/bin/interception.dll" -Wl,--out-implib,"$PREFIX/lib/libinterception.dll.a"
	cp "$BUILD-interception/library/interception.h" "$PREFIX/include/"
fi

.ci/common/strip-ultravnc-sources.sh

cmake -S "$ROOT" -B "$BUILD" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DWITH_BUNDLED_LIBVNC=ON \
	-DWITH_LTO=OFF
cmake --build "$BUILD"

rm -rf "$STAGE"
mkdir -p "$STAGE"/{interception,plugins,translations,crypto,imageformats,platforms,styles,tls}
cd "$BUILD"

cp "$ROOT"/3rdparty/interception/* "$STAGE/interception/"
cp "$ROOT/3rdparty/ddengine/ddengine64.dll" "$STAGE/"
cp core/veyon-core.dll "$STAGE/"
find . -path ./stage -prune -o -mindepth 2 -name 'veyon-*.exe' -exec cp '{}' "$STAGE/" ';'
find plugins/ -name '*.dll' -exec cp '{}' "$STAGE/plugins/" ';'
if ls "$STAGE"/plugins/lib*.dll >/dev/null 2>&1; then mv "$STAGE"/plugins/lib*.dll "$STAGE/"; fi
mv "$STAGE/plugins/vnchooks.dll" "$STAGE/"
cp translations/*qm "$STAGE/translations/"

QT_PLUGINS=$PREFIX/share/qt6/plugins
cp "$PREFIX"/lib/qca-qt6/crypto/libqca-ossl.dll "$STAGE/crypto/"
cp "$QT_PLUGINS/imageformats/qjpeg.dll" "$STAGE/imageformats/"
cp "$QT_PLUGINS/platforms/qwindows.dll" "$STAGE/platforms/"
cp "$QT_PLUGINS"/styles/*.dll "$STAGE/styles/"
cp "$QT_PLUGINS/tls/qopensslbackend.dll" "$STAGE/tls/"

# Pull in every MSYS2 DLL the staged binaries load, until nothing new appears.
collect_dlls() {
	local count=-1
	while [ "$count" != "$(ls "$STAGE"/*.dll | wc -l)" ]; do
		count=$(ls "$STAGE"/*.dll | wc -l)
		find "$STAGE" -name '*.dll' -o -name '*.exe' | grep -v '/interception/' | while read -r file; do
			PATH="$STAGE:$PATH" ldd "$file" | awk '{print $3}' | grep -i "^$PREFIX/bin/" || true
		done | sort -u | while read -r dll; do
			cp -n "$dll" "$STAGE/" || true
		done
	done
}
collect_dlls
test -f "$STAGE/Qt6HttpServer.dll"
test -f "$STAGE/plugins/webapi.dll"

strip "$STAGE"/*.exe "$STAGE"/plugins/*.dll
cp "$ROOT/COPYING" "$STAGE/"
cp "$ROOT/COPYING" "$STAGE/LICENSE.TXT"
cp "$ROOT/README.md" "$STAGE/README.TXT"
unix2dos "$STAGE"/*.TXT
cp -r "$ROOT/nsis" "$STAGE/"
cp "$BUILD/nsis/veyon.nsi" "$STAGE/"

(cd "$STAGE" && makensis veyon.nsi)
mv "$STAGE"/tinsharelab-classroom-*-setup.exe "$ROOT/"
