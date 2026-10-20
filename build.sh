#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
rapor_arch="${OPENTEX_ARCH:-${RAPOR_ARCH:-$(uname -m)}}"
rapor_signing_identity="${OPENTEX_SIGNING_IDENTITY:-${RAPOR_SIGNING_IDENTITY:-}}"
if [[ -z "$rapor_signing_identity" ]]; then
    rapor_signing_identity=$(security find-identity -v -p codesigning | awk '/Apple Development:|Developer ID Application:/ {print $2; exit}')
fi
if [[ -z "$rapor_signing_identity" || "$rapor_signing_identity" == "-" ]]; then
    if [[ "${OPENTEX_ALLOW_ADHOC:-${RAPOR_ALLOW_ADHOC:-0}}" != "1" ]]; then
        print -u2 'No stable signing identity found. Set OPENTEX_SIGNING_IDENTITY, or explicitly use OPENTEX_ALLOW_ADHOC=1 for a local build (macOS permissions may reset on updates).'
        exit 1
    fi
    rapor_signing_identity="-"
fi
mkdir -p dist/OpenTeX.app/Contents/MacOS dist/OpenTeX.app/Contents/Resources
swiftc -parse-as-library -O -target "${rapor_arch}-apple-macosx14.0" Sources/*.swift -o dist/OpenTeX.app/Contents/MacOS/OpenTeX -framework SwiftUI -framework AppKit -framework PDFKit -framework Combine
/usr/bin/python3 - <<'PLIST'
from pathlib import Path
import plistlib
# Keep the original bundle identifier so upgrades retain project settings and signing identity.
info={'CFBundleExecutable':'OpenTeX','CFBundleIdentifier':'com.ahmetna.rapor','CFBundleIconFile':'AppIcon','CFBundleName':'OpenTeX','CFBundleDisplayName':'OpenTeX','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.7.2','CFBundleVersion':'12','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','tr'],'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'DefaultProjectPath':str(Path.cwd()/'examples/starter'),'NSHumanReadableCopyright':'Copyright 2026 Ahmet Nuri Aydemir. MIT License.'}
Path('dist/OpenTeX.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PLIST
cp Assets/AppIcon.icns dist/OpenTeX.app/Contents/Resources/AppIcon.icns
cp -R Resources/*.lproj dist/OpenTeX.app/Contents/Resources/
codesign --force --sign "$rapor_signing_identity" dist/OpenTeX.app
codesign --verify --deep --strict dist/OpenTeX.app
printf 'Built: %s/dist/OpenTeX.app\n' "$PWD"
