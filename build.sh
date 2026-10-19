#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
rapor_arch="${RAPOR_ARCH:-$(uname -m)}"
rapor_signing_identity="${RAPOR_SIGNING_IDENTITY:-}"
if [[ -z "$rapor_signing_identity" ]]; then
    rapor_signing_identity=$(security find-identity -v -p codesigning | awk '/Apple Development:|Developer ID Application:/ {print $2; exit}')
fi
if [[ -z "$rapor_signing_identity" || "$rapor_signing_identity" == "-" ]]; then
    if [[ "${RAPOR_ALLOW_ADHOC:-0}" != "1" ]]; then
        print -u2 'No stable signing identity found. Set RAPOR_SIGNING_IDENTITY, or explicitly use RAPOR_ALLOW_ADHOC=1 for a local build (macOS permissions may reset on updates).'
        exit 1
    fi
    rapor_signing_identity="-"
fi
mkdir -p dist/Rapor.app/Contents/MacOS dist/Rapor.app/Contents/Resources
swiftc -parse-as-library -O -target "${rapor_arch}-apple-macosx14.0" Sources/*.swift -o dist/Rapor.app/Contents/MacOS/Rapor -framework SwiftUI -framework AppKit -framework PDFKit -framework Combine
/usr/bin/python3 - <<'PLIST'
from pathlib import Path
import plistlib
info={'CFBundleExecutable':'Rapor','CFBundleIdentifier':'com.ahmetna.rapor','CFBundleIconFile':'AppIcon','CFBundleName':'Rapor','CFBundleDisplayName':'Rapor','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.4.0','CFBundleVersion':'6','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'DefaultProjectPath':str(Path.cwd()/'examples/starter'),'NSHumanReadableCopyright':'Copyright 2026 Ahmet Nuri Aydemir. MIT License.'}
Path('dist/Rapor.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PLIST
cp Assets/AppIcon.icns dist/Rapor.app/Contents/Resources/AppIcon.icns
codesign --force --sign "$rapor_signing_identity" dist/Rapor.app
codesign --verify --deep --strict dist/Rapor.app
printf 'Built: %s/dist/Rapor.app\n' "$PWD"
