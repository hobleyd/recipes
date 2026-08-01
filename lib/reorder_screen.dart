import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'add_recipe_screen.dart';
import 'epub_service.dart';
import 'models.dart';
import 'ocr_settings_dialog.dart';
import 'providers.dart';

class ReorderScreen extends ConsumerStatefulWidget {
  const ReorderScreen({super.key});

  @override
  ConsumerState<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends ConsumerState<ReorderScreen> {
  List<EpubChapter>? _chapters;
  final List<EpubPage> _deletedPages = [];
  bool _saving = false;
  String? _error;
  bool _saved = false;

  // True when there are reorder/rename/delete edits that haven't been saved
  // to the epub yet. Used to make sure we don't lose them when jumping into
  // the add/edit/import screen from a row action.
  bool _dirty = false;

  final _rightScrollController = ScrollController();

  // Heights used to estimate scroll offsets (chapter header vs recipe tile).
  static const _chapterHeaderH = 40.0;
  static const _recipeTileH = 56.0;

  // Extra right padding on each row so the drag handle doesn't sit under
  // the list's scrollbar, which otherwise steals mouse drags meant for it.
  static const _scrollbarGutter = 16.0;

  @override
  void dispose() {
    _rightScrollController.dispose();
    super.dispose();
  }

  String _chapterId(EpubChapter ch) =>
      ch.title ?? (ch.pages.isNotEmpty ? ch.pages.first.href : '__empty');

  void _scrollToChapter(EpubChapter ch) {
    if (!_rightScrollController.hasClients) return;
    final flat = _buildFlatItems();
    final targetId = _chapterId(ch);
    double offset = 0;
    for (final item in flat) {
      if (item is EpubChapter && _chapterId(item) == targetId) break;
      offset += item is EpubChapter ? _chapterHeaderH : _recipeTileH;
    }
    _rightScrollController.animateTo(
      offset.clamp(0.0, _rightScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  List<EpubChapter> _buildChapters(List<EpubPage> pages) {
    final chapters = <EpubChapter>[];
    String? lastChapterTitle;
    bool lastWasNull = false;

    for (final page in pages) {
      final sameChapter = page.chapter == null
          ? lastWasNull
          : page.chapter == lastChapterTitle;
      if (sameChapter) {
        chapters.last.pages.add(page);
      } else {
        chapters.add(EpubChapter(title: page.chapter, pages: [page]));
        lastChapterTitle = page.chapter;
        lastWasNull = page.chapter == null;
      }
    }
    return chapters;
  }

  // Flat list: alternating EpubChapter (headers) and EpubPage (recipes).
  List<Object> _buildFlatItems() {
    final items = <Object>[];
    for (final ch in _chapters!) {
      items.add(ch);
      items.addAll(ch.pages);
    }
    return items;
  }

  // Scan the flat list and assign each EpubPage to the most recent
  // EpubChapter header above it.
  List<EpubChapter> _rebuildChapters(List<Object> flat) {
    final chapters = <EpubChapter>[];
    for (final item in flat) {
      if (item is EpubChapter) {
        chapters.add(EpubChapter(title: item.title, pages: []));
      } else if (item is EpubPage) {
        if (chapters.isEmpty) {
          chapters.add(EpubChapter(title: null, pages: []));
        }
        chapters.last.pages.add(item);
      }
    }
    return chapters;
  }

  // The page a newly-added recipe should be inserted after when "Add" is
  // triggered from a chapter header row: the chapter's own last page, or
  // failing that, the last page of the nearest preceding non-empty chapter.
  EpubPage? _insertionAnchorForChapter(EpubChapter ch) {
    if (ch.pages.isNotEmpty) return ch.pages.last;
    final idx = _chapters!.indexOf(ch);
    for (var i = idx - 1; i >= 0; i--) {
      if (_chapters![i].pages.isNotEmpty) return _chapters![i].pages.last;
    }
    return null;
  }

  // The page a newly-imported recipe should be inserted after so it lands
  // as the first recipe of the given chapter: the last page of the nearest
  // preceding non-empty chapter (or null if nothing precedes it).
  EpubPage? _startAnchorForChapter(EpubChapter ch) {
    final idx = _chapters!.indexOf(ch);
    for (var i = idx - 1; i >= 0; i--) {
      if (_chapters![i].pages.isNotEmpty) return _chapters![i].pages.last;
    }
    return null;
  }

  int _chapterIndexContainingPage(EpubPage page) {
    for (var i = 0; i < _chapters!.length; i++) {
      if (_chapters![i].pages.any((p) => p.href == page.href)) return i;
    }
    return _chapters!.length - 1;
  }

  Future<void> _addChapterDialog() async {
    final name = await _promptChapterName(title: 'Add Chapter', confirm: 'Add');
    if (name != null) {
      setState(() {
        _chapters!.add(EpubChapter(title: name, pages: []));
        _saved = false;
        _dirty = true;
      });
    }
  }

  Future<void> _addChapterAfterIndex(int idx) async {
    final name = await _promptChapterName(title: 'Add Chapter', confirm: 'Add');
    if (name != null) {
      setState(() {
        _chapters!.insert(idx + 1, EpubChapter(title: name, pages: []));
        _saved = false;
        _dirty = true;
      });
    }
  }

  Future<void> _renameChapterDialog(EpubChapter ch) async {
    final idx = _chapters!.indexOf(ch);
    final name = await _promptChapterName(
        title: 'Rename Chapter',
        initial: ch.title ?? '',
        confirm: 'Rename');
    if (name != null) {
      setState(() {
        _chapters![idx] = EpubChapter(title: name, pages: ch.pages);
        _saved = false;
        _dirty = true;
      });
    }
  }

  void _deleteChapter(EpubChapter ch) {
    setState(() {
      final idx = _chapters!.indexOf(ch);
      final removed = _chapters!.removeAt(idx);
      if (removed.pages.isNotEmpty) {
        final unchapteredIdx = _chapters!.indexWhere((c) => c.title == null);
        if (unchapteredIdx >= 0) {
          _chapters![unchapteredIdx].pages.insertAll(0, removed.pages);
        } else {
          _chapters!
              .insert(0, EpubChapter(title: null, pages: List.of(removed.pages)));
        }
      }
      _saved = false;
      _dirty = true;
    });
  }

  Future<void> _deletePageDialog(EpubPage page) async {
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Recipe'),
        content: Text(
            'Delete "${page.title}"? This cannot be undone once saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() {
        for (final ch in _chapters!) {
          ch.pages.removeWhere((p) => p.href == page.href);
        }
        _deletedPages.add(page);
        _saved = false;
        _dirty = true;
      });
    }
  }

  Future<String?> _promptChapterName({
    required String title,
    String initial = '',
    required String confirm,
  }) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Chapter name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(confirm),
          ),
        ],
      ),
    );
    return (result?.isEmpty ?? true) ? null : result;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _saved = false;
    });
    try {
      final path = ref.read(epubPathProvider).value!;
      await EpubService(path)
          .reorderPages(_chapters!, deletedPages: _deletedPages);
      ref.invalidate(epubPagesProvider);
      setState(() {
        _saving = false;
        _saved = true;
        _dirty = false;
        _deletedPages.clear();
      });
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  // Navigates to the add/edit/import screen, saving any pending reorder
  // edits first so they aren't lost, then refreshes once we come back.
  //
  // `targetChapter` is passed when the recipe is meant to land in a specific
  // chapter and that chapter has no pages yet. A brand-new empty chapter has
  // no marker in the epub yet (reorderPages only creates one for non-empty
  // chapters), so `insertAfter` had to fall back to the end of the nearest
  // preceding chapter — meaning the new recipe lands there on disk. Once it's
  // saved, move it into `targetChapter` in memory and save again so
  // reorderPages creates the chapter's marker for real.
  Future<void> _openRecipeEditor({
    EpubPage? insertAfter,
    EpubPage? editingPage,
    String? autoImportAction,
    EpubChapter? targetChapter,
  }) async {
    if (_dirty) {
      await _save();
      if (_error != null) return;
    }
    if (!mounted) return;

    final needsChapterFixup =
        targetChapter != null && targetChapter.pages.isEmpty;
    final beforeHrefs = needsChapterFixup
        ? _chapters!.expand((c) => c.pages).map((p) => p.href).toSet()
        : const <String>{};

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddRecipeScreen(
          initialInsertAfter: insertAfter,
          initialEditingPage: editingPage,
          autoImportAction: autoImportAction,
        ),
      ),
    );
    if (!mounted) return;
    ref.invalidate(epubPagesProvider);
    var pages = await ref.read(epubPagesProvider.future);
    if (!mounted) return;

    if (needsChapterFixup) {
      final newPages =
          pages.where((p) => !beforeHrefs.contains(p.href)).toList();
      if (newPages.length == 1) {
        final newPage = newPages.first;
        final rebuilt = _buildChapters(pages);
        final hostIdx = rebuilt
            .indexWhere((c) => c.pages.any((p) => p.href == newPage.href));
        if (hostIdx >= 0) {
          rebuilt[hostIdx].pages.removeWhere((p) => p.href == newPage.href);
          rebuilt.insert(hostIdx + 1,
              EpubChapter(title: targetChapter.title, pages: [newPage]));
          _chapters = rebuilt;
          await _save();
          if (_error != null) return;
          if (!mounted) return;
          ref.invalidate(epubPagesProvider);
          pages = await ref.read(epubPagesProvider.future);
          if (!mounted) return;
        }
      }
    }

    setState(() {
      _chapters = _buildChapters(pages);
      _saved = false;
      _dirty = false;
    });
  }

  Future<void> _openInInkworm() async {
    final path = ref.read(epubPathProvider).value;
    if (path == null) return;
    try {
      final result = Platform.isMacOS
          ? await Process.run('open', ['-b', 'au.com.sharpblue.inkworm', path])
          : Platform.isWindows
              ? await Process.run('inkworm.exe', [path])
              : await Process.run('inkworm', [path]);
      if (result.exitCode != 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Could not open Inkworm: ${result.stderr.toString().trim()}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open Inkworm: $e')),
        );
      }
    }
  }

  Future<void> _showNewCookbookDialog() async {
    final formKey = GlobalKey<FormState>();
    final titleCtrl = TextEditingController();
    String? imagePath;
    String? imageName;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: const Text('New Cookbook'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 440),
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: titleCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      hintText: 'e.g. Smith Family Recipes',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v?.trim().isEmpty ?? true) ? 'Title is required' : null,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.image_outlined),
                          label: Text(
                            imageName ?? 'Choose title page image…',
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: () async {
                            final file = await openFile(
                              acceptedTypeGroups: [
                                const XTypeGroup(
                                  label: 'Images',
                                  extensions: ['jpg', 'jpeg', 'png'],
                                ),
                              ],
                            );
                            if (file != null) {
                              setDs(() {
                                imagePath = file.path;
                                imageName = file.name;
                              });
                            }
                          },
                        ),
                      ),
                      if (imagePath != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Remove image',
                          onPressed: () => setDs(() {
                            imagePath = null;
                            imageName = null;
                          }),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Choose location…'),
            ),
          ],
        ),
      ),
    );

    final title = titleCtrl.text.trim();
    titleCtrl.dispose();
    if (confirmed != true || title.isEmpty) return;

    if (!mounted) return;
    final slug = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final saveLocation = await getSaveLocation(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'EPUB', extensions: ['epub']),
      ],
      suggestedName: '$slug.epub',
    );
    if (saveLocation == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await EpubService.createCookbook(
        path: saveLocation.path,
        title: title,
        coverImagePath: imagePath,
      );

      if (!mounted) return;
      final openNow = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cookbook created'),
          content: Text('"$title" is ready. Open it now?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open'),
            ),
          ],
        ),
      );

      if (openNow == true && mounted) {
        await ref.read(epubPathProvider.notifier).setPath(saveLocation.path);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to create cookbook: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pagesAsync = ref.watch(epubPagesProvider);
    final cs = Theme.of(context).colorScheme;

    // Populate _chapters before the appBar is built below, not inside the
    // body's data callback — otherwise the appBar (which gates the Save
    // Order button on _chapters != null) is constructed with the stale
    // pre-load value and the button doesn't appear until some later
    // unrelated rebuild.
    final loadedPages = pagesAsync.value;
    if (loadedPages != null) {
      _chapters ??= _buildChapters(loadedPages);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recipe Manager'),
        backgroundColor: cs.primaryContainer,
        foregroundColor: cs.onPrimaryContainer,
        actions: [
          if (_chapters != null) ...[
            if (_saved)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.check_circle_outline,
                    color: cs.onPrimaryContainer),
              ),
            FilledButton.tonal(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
            const SizedBox(width: 12),
          ],
          IconButton(
            icon: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.asset(
                'assets/inkworm_icon.png',
                width: 22,
                height: 22,
              ),
            ),
            tooltip: 'View in Inkworm',
            onPressed: _openInInkworm,
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'change') {
                ref.read(epubPathProvider.notifier).clearPath();
              } else if (value == 'new_cookbook') {
                await _showNewCookbookDialog();
              } else if (value == 'llm_settings') {
                await showOcrSettingsDialog(context, ref);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'new_cookbook',
                child: Row(children: [
                  Icon(Icons.auto_stories_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('New cookbook…'),
                ]),
              ),
              PopupMenuItem(
                value: 'change',
                child: Row(children: [
                  Icon(Icons.folder_open_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Open EPUB file…'),
                ]),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'llm_settings',
                child: Row(children: [
                  Icon(Icons.settings_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('LLM Settings…'),
                ]),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: pagesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load EPUB: $e',
                style: TextStyle(color: cs.error)),
          ),
        ),
        data: (pages) {
          _chapters ??= _buildChapters(pages);
          return _buildBody(cs);
        },
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    return Column(
      children: [
        if (_error != null)
          Material(
            color: cs.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      color: cs.onErrorContainer, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!,
                        style:
                            TextStyle(color: cs.onErrorContainer)),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: 260,
                child: _buildChapterList(cs),
              ),
              VerticalDivider(width: 1, color: cs.outlineVariant),
              Expanded(child: _buildFlatRecipeList(cs)),
            ],
          ),
        ),
      ],
    );
  }

  // Left panel — drag chapters to reorder them (recipes follow automatically
  // because the right panel is driven by _chapters order).
  Widget _buildChapterList(ColorScheme cs) {
    final chapters = _chapters!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'CHAPTER ORDER',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: cs.primary,
            ),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: chapters.length,
            onReorder: (oldIdx, newIdx) {
              setState(() {
                if (newIdx > oldIdx) newIdx--;
                final item = chapters.removeAt(oldIdx);
                chapters.insert(newIdx, item);
                _saved = false;
                _dirty = true;
              });
            },
            itemBuilder: (context, idx) {
              final ch = chapters[idx];
              final count = ch.pages.length;
              final chKey = ch.title ??
                  (ch.pages.isNotEmpty
                      ? ch.pages.first.href
                      : '__unchaptered_$idx');
              return ListTile(
                key: ValueKey(chKey),
                onTap: () => _scrollToChapter(ch),
                title: Text(
                  ch.title ?? '(Unchaptered)',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle:
                    Text(count == 1 ? '1 recipe' : '$count recipes'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (ch.title != null) ...[
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: 'Rename chapter',
                        onPressed: () => _renameChapterDialog(ch),
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: 'Delete chapter',
                        onPressed: () => _deleteChapter(ch),
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                    ],
                    ReorderableDragStartListener(
                      index: idx,
                      child: const Icon(Icons.drag_handle),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: TextButton.icon(
            onPressed: _addChapterDialog,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Chapter'),
          ),
        ),
      ],
    );
  }

  // Add button shown on every row — offers inserting a new recipe or chapter
  // right after that row, or importing a recipe (via OCR/web scrape/pasted
  // text) inserted right after that row. Each subsection is alphabetical.
  Widget _addPopupButton({
    required VoidCallback onAddRecipe,
    required VoidCallback onAddChapter,
    required VoidCallback onImportImage,
    required VoidCallback onImportWeb,
    required VoidCallback onImportText,
  }) {
    return PopupMenuButton<String>(
      tooltip: 'Add',
      icon: const Icon(Icons.add, size: 18),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      onSelected: (v) {
        if (v == 'chapter') {
          onAddChapter();
        } else if (v == 'recipe') {
          onAddRecipe();
        } else if (v == 'image_pdf') {
          onImportImage();
        } else if (v == 'text') {
          onImportText();
        } else if (v == 'web_page') {
          onImportWeb();
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'chapter',
          child: Row(children: [
            Icon(Icons.menu_book_outlined, size: 18),
            SizedBox(width: 10),
            Text('Add Chapter…'),
          ]),
        ),
        PopupMenuItem(
          value: 'recipe',
          child: Row(children: [
            Icon(Icons.restaurant_menu, size: 18),
            SizedBox(width: 10),
            Text('Add Recipe…'),
          ]),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'image_pdf',
          child: Row(children: [
            Icon(Icons.image_outlined, size: 18),
            SizedBox(width: 10),
            Text('Import Image or PDF…'),
          ]),
        ),
        PopupMenuItem(
          value: 'text',
          child: Row(children: [
            Icon(Icons.text_snippet_outlined, size: 18),
            SizedBox(width: 10),
            Text('Import Text…'),
          ]),
        ),
        PopupMenuItem(
          value: 'web_page',
          child: Row(children: [
            Icon(Icons.language_outlined, size: 18),
            SizedBox(width: 10),
            Text('Import Web Page…'),
          ]),
        ),
      ],
    );
  }

  // The same four action slots (Add, Edit, Delete, drag handle) for both
  // chapter-header and recipe rows, so their icons line up in columns. Pass
  // null for onEdit/onDelete to show a disabled icon in that slot (e.g. the
  // unchaptered header can't be renamed or deleted).
  Widget _rowActions({
    required VoidCallback onAddRecipe,
    required VoidCallback onAddChapter,
    required String editTooltip,
    VoidCallback? onEdit,
    required VoidCallback onImportImage,
    required VoidCallback onImportWeb,
    required VoidCallback onImportText,
    required String deleteTooltip,
    VoidCallback? onDelete,
    required int dragIndex,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _addPopupButton(
          onAddRecipe: onAddRecipe,
          onAddChapter: onAddChapter,
          onImportImage: onImportImage,
          onImportWeb: onImportWeb,
          onImportText: onImportText,
        ),
        IconButton(
          icon: const Icon(Icons.edit_outlined, size: 18),
          tooltip: editTooltip,
          onPressed: onEdit,
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          tooltip: deleteTooltip,
          onPressed: onDelete,
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
        ReorderableDragStartListener(
          index: dragIndex,
          child: const Icon(Icons.drag_handle, size: 18),
        ),
      ],
    );
  }

  // Right panel — flat list of chapter headers and recipes, all draggable.
  // Dragging a chapter header moves it and all of its recipes as one block.
  // Dragging a recipe past a chapter header moves it to that chapter.
  Widget _buildFlatRecipeList(ColorScheme cs) {
    final flat = _buildFlatItems();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'RECIPES',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: cs.primary,
            ),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            scrollController: _rightScrollController,
            buildDefaultDragHandles: false,
            itemCount: flat.length,
            onReorder: _onFlatReorder,
            itemBuilder: (context, idx) {
              final item = flat[idx];
              if (item is EpubChapter) {
                return Container(
                  key: ValueKey(
                      'ch_${item.title ?? "unchaptered_$idx"}'),
                  constraints:
                      const BoxConstraints(minHeight: _chapterHeaderH),
                  color: cs.surfaceContainerHighest,
                  padding: const EdgeInsets.only(
                      left: 16, right: _scrollbarGutter),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title?.toUpperCase() ?? 'UNCHAPTERED',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: cs.primary,
                          ),
                        ),
                      ),
                      _rowActions(
                        onAddRecipe: () => _openRecipeEditor(
                            insertAfter: _insertionAnchorForChapter(item),
                            targetChapter: item),
                        onAddChapter: () =>
                            _addChapterAfterIndex(_chapters!.indexOf(item)),
                        editTooltip: 'Rename chapter',
                        onEdit: item.title != null
                            ? () => _renameChapterDialog(item)
                            : null,
                        onImportImage: () => _openRecipeEditor(
                            insertAfter: _startAnchorForChapter(item),
                            autoImportAction: 'image_pdf',
                            targetChapter: item),
                        onImportWeb: () => _openRecipeEditor(
                            insertAfter: _startAnchorForChapter(item),
                            autoImportAction: 'web_page',
                            targetChapter: item),
                        onImportText: () => _openRecipeEditor(
                            insertAfter: _startAnchorForChapter(item),
                            autoImportAction: 'text',
                            targetChapter: item),
                        deleteTooltip: 'Delete chapter',
                        onDelete: item.title != null
                            ? () => _deleteChapter(item)
                            : null,
                        dragIndex: idx,
                      ),
                    ],
                  ),
                );
              }
              final page = item as EpubPage;
              return Container(
                key: ValueKey(page.href),
                constraints: const BoxConstraints(minHeight: _recipeTileH),
                padding:
                    const EdgeInsets.only(left: 16, right: _scrollbarGutter),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(page.title,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge),
                    ),
                    _rowActions(
                      onAddRecipe: () =>
                          _openRecipeEditor(insertAfter: page),
                      onAddChapter: () => _addChapterAfterIndex(
                          _chapterIndexContainingPage(page)),
                      editTooltip: 'Edit recipe',
                      onEdit: () => _openRecipeEditor(editingPage: page),
                      onImportImage: () => _openRecipeEditor(
                          insertAfter: page, autoImportAction: 'image_pdf'),
                      onImportWeb: () => _openRecipeEditor(
                          insertAfter: page, autoImportAction: 'web_page'),
                      onImportText: () => _openRecipeEditor(
                          insertAfter: page, autoImportAction: 'text'),
                      deleteTooltip: 'Delete recipe',
                      onDelete: () => _deletePageDialog(page),
                      dragIndex: idx,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _onFlatReorder(int oldIdx, int newIdx) {
    final mutable = _buildFlatItems();
    final movingItem = mutable[oldIdx];

    if (movingItem is EpubChapter) {
      // Move the header together with all the recipes that belong to it.
      var end = oldIdx + 1;
      while (end < mutable.length && mutable[end] is! EpubChapter) {
        end++;
      }
      if (newIdx > oldIdx && newIdx < end) {
        return; // dropped inside its own block — no-op
      }
      final blockLen = end - oldIdx;
      final block = mutable.sublist(oldIdx, end);
      mutable.removeRange(oldIdx, end);
      var insertIdx = newIdx > oldIdx ? newIdx - blockLen : newIdx;
      insertIdx = insertIdx.clamp(0, mutable.length);
      mutable.insertAll(insertIdx, block);
    } else {
      if (newIdx > oldIdx) newIdx--;
      final item = mutable.removeAt(oldIdx);
      // Landing exactly at a chapter header's slot means "insert
      // immediately before it" — i.e. stay as the last recipe of the
      // preceding chapter. The only exception is position 0, where there
      // is no preceding chapter to land in, so advance past that header.
      var insertIdx = newIdx.clamp(0, mutable.length);
      if (insertIdx == 0 &&
          insertIdx < mutable.length &&
          mutable[insertIdx] is EpubChapter) {
        insertIdx++;
      }
      mutable.insert(insertIdx, item);
    }

    setState(() {
      _chapters = _rebuildChapters(mutable);
      _saved = false;
      _dirty = true;
    });
  }
}
