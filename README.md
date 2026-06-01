# Recipe Manager

A Flutter desktop app for managing a personal recipe ebook. It reads and writes a local EPUB file directly, letting you add new recipes, edit existing ones, and reorganise chapters — without needing a separate ebook editor.

## Features

- **Add recipes** — fill in a title, description, ingredients (with optional labelled sections), method, and footnote, then choose where in the book to insert the new recipe.
- **Edit recipes** — select any existing recipe from the book to load and modify it.
- **Measurement conversion** — entering a quantity in imperial automatically fills in the metric equivalent (and vice versa), using built-in conversion rules.
- **Reorder recipes and chapters** — a two-panel drag-and-drop screen lets you reorder chapters on the left and drag individual recipes between chapters on the right.
- **Chapter management** — add new chapters, rename existing ones, delete them (recipes are moved to the unchaptered group), and drag them into any order. New chapters are written as proper chapter title pages in the EPUB.

## Architecture

- **Flutter** desktop app (macOS, Linux, Windows); Material 3 design.
- **Riverpod** (`FutureProvider` / `NotifierProvider`) for state management.
- **`EpubService`** reads and writes the EPUB ZIP directly using the `archive` package — no intermediate format. It parses `toc.ncx`, `content.opf`, the HTML table of contents, and individual XHTML recipe files.
- The EPUB path is hardcoded in `EpubService` to the Calibre library location.

## Requirements

- Flutter SDK ≥ 3.11
- The EPUB file at the path configured in `lib/epub_service.dart`

## Commands

```bash
# Install dependencies
flutter pub get

# Run in development
flutter run -d macos
flutter run -d linux
flutter run -d windows

# Build release
flutter build macos --release --no-tree-shake-icons
flutter build linux --release
flutter build windows --release

# Lint
flutter analyze

# Tests
flutter test

# Regenerate app icons after changing assets/icon.png
dart run flutter_launcher_icons
```
