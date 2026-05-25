# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Flutter desktop app (macOS, Linux, Windows) that provides an easy way to edit a local recipe ebook to add new recipes.

## Commands

```bash
# Install dependencies
flutter pub get

# Run in development (pick your platform)
flutter run -d macos
flutter run -d linux
flutter run -d windows

# Build release
flutter build macos --release --no-tree-shake-icons
flutter build linux --release
flutter build windows --release

# Lint / static analysis
flutter analyze

# Tests
flutter test
flutter test test/widget_test.dart  # single test file

# Regenerate app icons after changing assets/icon.png
dart run flutter_launcher_icons
```

## Architecture

**State management:** Flutter Riverpod with `NotifierProvider`. 
