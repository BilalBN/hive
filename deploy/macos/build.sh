#!/bin/bash
# Builds the Hive server package for the Mac: dist-installer/HiveServer-<version>-mac.pkg
#
# Needs Python 3.12 and the built Hive Admin in admin/dist (npm run build
# --prefix admin). FFmpeg is put inside when the one on PATH stands alone
# (a static build); otherwise Hive uses Homebrew's (brew install ffmpeg).
# Run from anywhere:  deploy/macos/build.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
here=deploy/macos

[ -f admin/dist/index.html ] || { echo "Build Hive Admin first (npm run build --prefix admin)." >&2; exit 1; }

python3 -m pip install --quiet --upgrade pip
python3 -m pip install --quiet ./server pyinstaller
version="$(python3 -c 'import hive; print(hive.__version__)')"
echo "Hive server $version ($(uname -m))"

rm -rf build/macos dist/hive
python3 -m PyInstaller --noconfirm --clean --log-level WARN \
  --distpath dist --workpath build/pyinstaller deploy/windows/hive.spec

payload="build/macos/payload/Hive Server"
mkdir -p "$payload" build/downloads
cp -R dist/hive/. "$payload/"
mkdir -p "$payload/tools"

# FFmpeg, if this one needs nothing but the Mac's own libraries.
if ffmpeg="$(command -v ffmpeg)"; then
  if ! otool -L "$ffmpeg" | tail -n +2 | grep -vqE '^\s*(/usr/lib/|/System/)'; then
    cp "$ffmpeg" "$payload/tools/ffmpeg"
    echo "FFmpeg put inside"
  else
    echo "FFmpeg on this Mac needs Homebrew's libraries; the package will use Homebrew's FFmpeg"
  fi
fi

# Chromaprint's fpcalc, for recognising songs.
fpcalc_got=""
for name in macos-universal macos-arm64 macos-x86_64; do
  url="https://github.com/acoustid/chromaprint/releases/download/v1.5.1/chromaprint-fpcalc-1.5.1-$name.tar.gz"
  if curl -fsSL "$url" -o build/downloads/fpcalc.tar.gz; then
    rm -rf build/downloads/fpcalc && mkdir -p build/downloads/fpcalc
    tar -xzf build/downloads/fpcalc.tar.gz -C build/downloads/fpcalc
    cp "$(find build/downloads/fpcalc -name fpcalc -type f | head -1)" "$payload/tools/fpcalc"
    fpcalc_got="$name"
    break
  fi
done
[ -n "$fpcalc_got" ] && echo "fpcalc ($fpcalc_got) put inside" || echo "fpcalc not found; Hive uses one on PATH if there is one"

# Apple silicon runs only signed programs; sign the tools for this Mac (ad hoc).
for tool in "$payload"/tools/*; do [ -f "$tool" ] && codesign --force --sign - "$tool"; done

# Hive Admin, served by hive from admin/.
cp -R admin/dist "$payload/admin"

# What the family sees in the folder.
cp "$here/Uninstall Hive.command" "$payload/"
chmod +x "$payload/Uninstall Hive.command" "$payload/hive"
cat > "$payload/Open Hive Admin.webloc" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>URL</key><string>http://127.0.0.1:8443/admin/</string></dict></plist>
PLIST
cp "$here/family.hive.server.plist" "$payload/"

chmod +x "$here/scripts/preinstall" "$here/scripts/postinstall"
mkdir -p dist-installer build/macos/pkg
pkgbuild --root build/macos/payload --install-location /Applications \
  --scripts "$here/scripts" --identifier family.hive.server --version "$version" \
  build/macos/pkg/hive.pkg
sed "s/@VERSION@/$version/" "$here/distribution.xml" > build/macos/distribution.xml
productbuild --distribution build/macos/distribution.xml --package-path build/macos/pkg \
  --resources "$here/resources" "dist-installer/HiveServer-$version-mac.pkg"
ls -lh dist-installer/*.pkg
