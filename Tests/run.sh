#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}/.."
rapor_test_dir=$(mktemp -d /private/tmp/rapor-source-checks.XXXXXX)
trap 'rm -rf -- "$rapor_test_dir"' EXIT
mkdir -p "$rapor_test_dir/Translations.bundle/Contents/Resources"
cp -R Resources/*.lproj "$rapor_test_dir/Translations.bundle/Contents/Resources/"
printf '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.rapor.translation-checks</string><key>CFBundleDevelopmentRegion</key><string>en</string></dict></plist>' > "$rapor_test_dir/Translations.bundle/Contents/Info.plist"
swiftc Sources/Localization.swift Tests/LocalizationTests.swift -o "$rapor_test_dir/localization-checks"
"$rapor_test_dir/localization-checks" "$rapor_test_dir/Translations.bundle"
swiftc Sources/ReportSearch.swift Tests/SearchTests.swift -o "$rapor_test_dir/search-checks"
"$rapor_test_dir/search-checks"
swiftc Sources/ReportSearch.swift Sources/PDFSourceNavigation.swift Tests/PDFSourceNavigationTests.swift -o "$rapor_test_dir/pdf-navigation-checks"
"$rapor_test_dir/pdf-navigation-checks"
swiftc Sources/ReportSearch.swift Sources/PDFSourceNavigation.swift Tests/SourcePDFNavigationTests.swift -o "$rapor_test_dir/source-pdf-checks"
"$rapor_test_dir/source-pdf-checks"
swiftc Sources/Bibliography.swift Tests/BibliographyTests.swift -o "$rapor_test_dir/bibliography-checks"
"$rapor_test_dir/bibliography-checks" "examples/starter/report/kaynaklar.bib"
swiftc Sources/Bibliography.swift Sources/WorkspaceLayout.swift Tests/WorkspaceTests.swift -o "$rapor_test_dir/workspace-checks"
"$rapor_test_dir/workspace-checks"
mkdir -p "$rapor_test_dir/project/report/sections"
printf 'Rust ownership. Rust memory.\n' > "$rapor_test_dir/project/report/sections/01-introduction.tex"
printf 'Rust compiler.\n' > "$rapor_test_dir/project/report/sections/02-analysis.tex"
printf 'Frozen layout\n' > "$rapor_test_dir/project/report/preamble.tex"
mkdir -p "$rapor_test_dir/reference"
printf 'Rust original must not enter working files\n' > "$rapor_test_dir/reference/Original.tex"
ln -s "$rapor_test_dir/reference" "$rapor_test_dir/project/report/template-original"
swiftc -D RAPOR_TEST -parse-as-library Sources/*.swift Tests/AppChecks.swift -o "$rapor_test_dir/app-checks" -framework SwiftUI -framework AppKit -framework PDFKit -framework Combine
"$rapor_test_dir/app-checks" --project "$rapor_test_dir/project"
