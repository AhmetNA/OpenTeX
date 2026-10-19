# Rapor

A small native macOS workspace for local LaTeX reports: files on the left, source in the middle, and a compiled PDF on the right. Built with SwiftUI, AppKit and PDFKit, without a web server or external application framework. The current interface is Turkish.

## Features

- Edit the original `.tex` and `.bib` files, with syntax highlighting, autosave and undo.
- Compile locally and keep the previous successful PDF when compilation fails.
- Browse references as readable records, edit literal fields in a form, or switch to raw BibTeX. Unknown fields, comments and directives are preserved; macro expressions remain available in raw mode.
- Select PDF text to reveal its matching source. Cover fields prefer editable metadata. This uses text/context matching, not SyncTeX; ambiguous text, equations and generated labels may not resolve.
- Search filenames and content with Turkish/case normalisation and limited typo tolerance.
- Hide the file sidebar, resize panes, zoom the PDF and export it.
- Detect external source changes and protect conflicting unsaved drafts.

![Readable bibliography workspace](docs/bibliography.png)

## Requirements

- macOS 14 or later; build for the current Mac architecture.
- Xcode Command Line Tools (`xcode-select --install`).
- [Tectonic](https://tectonic-typesetting.github.io/) for local PDF compilation (`brew install tectonic`).
- A stable Apple Development or Developer ID Application signing identity is recommended.

## Build and run

```sh
./build.sh
open dist/Rapor.app
```

The build selects an available Apple Development/Developer ID Application identity. You can pin one with `RAPOR_SIGNING_IDENTITY`. Consistent signing allows macOS to recognise updates as the same application and retain file-access consent. The first access, or migration from an ad-hoc build, can still require one macOS approval. The app does not bypass privacy controls.

If you have no signing identity, an explicit local-only build is available:

```sh
RAPOR_ALLOW_ADHOC=1 ./build.sh
```

Ad-hoc builds may ask for file access again after updates. Builds are not notarized or App Store distributions. No signing certificates or private keys are included.

The app initially opens `examples/starter`. To use your own project, choose **Proje Aç** or launch with:

```sh
open -n dist/Rapor.app --args --project /path/to/project
```

## Project layout

```text
project/
  report/
    rapor.tex
    metadata.tex
    kaynaklar.bib
    sections/
  scripts/
    build_report.py
  output/pdf/
    bitirme-raporu.pdf
```

`report/rapor.tex` is the entry point. The app runs `scripts/build_report.py` from the project root and previews `output/pdf/bitirme-raporu.pdf`; this filename is a current project convention. Use the included MIT-licensed starter as a template. Its example compilation script preserves the last PDF on failure. `cover.tex` and `preamble.tex` are read-only in the editor; modify your own template files outside the app as needed. `report/build` and `report/template-original` are excluded from the working file list.

Files are local. There is no application account, hosted compiler, telemetry or built-in AI service. Tectonic may download TeX packages on its first compilation. DOI/source links open in your default browser only when clicked.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Save | Command-S |
| Compile | Command-R |
| Export PDF | Command-Shift-E |
| Open project | Command-O |
| Toggle file sidebar | Control-Command-S |
| Next / previous search match | Command-G / Shift-Command-G |

## Checks

```sh
./Tests/run.sh
python3 examples/starter/scripts/build_report.py
```

Checks cover source search, reverse PDF navigation, bibliography parsing and field-preserving edits, native PDFKit callbacks, autosave and conflicting drafts. They use temporary projects. The starter compile is an additional local integration check.

## Scope and licence

Rapor's source, application icon and original starter files are distributed under the [MIT License](LICENSE). User documents, institutional templates and third-party research datasets are not included. Apple system frameworks and Tectonic remain subject to their own licences; they are not bundled in this repository.
