# Changelog

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
