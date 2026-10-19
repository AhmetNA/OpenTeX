# Changelog

## 1.7.1

- Show compact icons for auto compile, compile PDF and PDF export, with translated hover descriptions and keyboard hints.
- Keep the auto-compile state visible through the native toggle button; constrain long titles/status text to avoid toolbar and pane-header overflow.

## 1.7.0

- Select source text to scroll to and highlight its matching PDF passage automatically.
- Match rendered words and surrounding context, cache the PDF text index, and prefer the cover for cover-field selections.
- Keep editor keyboard focus and block feedback loops between forward and reverse selection events. Missing/ambiguous matches leave the PDF position unchanged.
- Added source-to-PDF range checks and native NSTextView/PDFKit integration tests.

## 1.6.0

- Renamed the app and repository from Rapor to OpenTeX, keeping the existing application identity and project preferences.

- Replaced the fixed section-to-group map with project-local, editable groups and display names.
- Added Organize Files: create, rename, reorder and remove groups, assign files, or restore automatic grouping.
- Discover new files and source headings automatically; save layout preferences in `.opentex/workspace.json` without moving sources or changing PDF section order.
- Protect unsaved drafts, read-only templates and concurrent/malformed layout configuration.

## 1.5.0

- Added English across the workspace, bibliography forms, menus, dialogs, accessibility labels and status/error messages.
- Follow the primary macOS language automatically: Turkish for Turkish, English for English or any unsupported language. No separate language preference is stored; report content is unchanged.
- Added checks for regional language codes, unsupported-language fallback and both translation catalogs.

## 1.4.1

Initial open-source release: native three-pane LaTeX workspace, local compilation/PDF export, source search, text-based reverse PDF navigation, structured bibliography editing, external-file conflict protection and stable signing support. Includes BibTeX syntax highlighting, a visible version indicator, direct file launch, an original minimal report starter and source-based tests.
