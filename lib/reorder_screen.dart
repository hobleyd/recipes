import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'epub_service.dart';
import 'models.dart';
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

  final _rightScrollController = ScrollController();

  // Heights used to estimate scroll offsets (chapter header vs recipe tile).
  static const _chapterHeaderH = 28.0;
  static const _recipeTileH = 56.0;

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

  Future<void> _addChapterDialog() async {
    final name = await _promptChapterName(title: 'Add Chapter', confirm: 'Add');
    if (name != null) {
      setState(() {
        _chapters!.add(EpubChapter(title: name, pages: []));
        _saved = false;
      });
    }
  }

  Future<void> _renameChapterDialog(int idx) async {
    final ch = _chapters![idx];
    final name = await _promptChapterName(
        title: 'Rename Chapter',
        initial: ch.title ?? '',
        confirm: 'Rename');
    if (name != null) {
      setState(() {
        _chapters![idx] = EpubChapter(title: name, pages: ch.pages);
        _saved = false;
      });
    }
  }

  void _deleteChapter(int idx) {
    setState(() {
      final ch = _chapters!.removeAt(idx);
      if (ch.pages.isNotEmpty) {
        final unchapteredIdx = _chapters!.indexWhere((c) => c.title == null);
        if (unchapteredIdx >= 0) {
          _chapters![unchapteredIdx].pages.insertAll(0, ch.pages);
        } else {
          _chapters!.insert(0, EpubChapter(title: null, pages: List.of(ch.pages)));
        }
      }
      _saved = false;
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
        _deletedPages.clear();
      });
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pagesAsync = ref.watch(epubPagesProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reorder — Recipe Manager'),
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
                  : const Text('Save Order'),
            ),
            const SizedBox(width: 12),
          ],
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
                        onPressed: () => _renameChapterDialog(idx),
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: 'Delete chapter',
                        onPressed: () => _deleteChapter(idx),
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

  // Right panel — flat list of chapter headers (non-draggable) and recipes
  // (draggable). Dragging a recipe past a chapter header moves it to that
  // chapter.
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
            onReorder: (oldIdx, newIdx) {
              setState(() {
                if (newIdx > oldIdx) newIdx--;
                // Recompute so we always work from current _chapters state.
                final mutable = _buildFlatItems();
                // Chapter headers are not draggable; guard just in case.
                if (mutable[oldIdx] is EpubChapter) return;
                final item = mutable.removeAt(oldIdx);
                // If the insertion point lands on a chapter header, advance
                // past it so the recipe lands inside that chapter — but only
                // when the preceding item is a recipe (not another header).
                // Two consecutive headers means an empty chapter: stay put so
                // the recipe drops into the empty chapter, not the one after.
                var insertIdx = newIdx.clamp(0, mutable.length);
                if (insertIdx < mutable.length &&
                    mutable[insertIdx] is EpubChapter &&
                    (insertIdx == 0 ||
                        mutable[insertIdx - 1] is! EpubChapter)) {
                  insertIdx++;
                }
                mutable.insert(insertIdx, item);
                _chapters = _rebuildChapters(mutable);
                _saved = false;
              });
            },
            itemBuilder: (context, idx) {
              final item = flat[idx];
              if (item is EpubChapter) {
                return Container(
                  key: ValueKey(
                      'ch_${item.title ?? "unchaptered_$idx"}'),
                  height: _chapterHeaderH,
                  color: cs.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    item.title?.toUpperCase() ?? 'UNCHAPTERED',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: cs.primary,
                    ),
                  ),
                );
              }
              final page = item as EpubPage;
              return SizedBox(
                key: ValueKey(page.href),
                height: _recipeTileH,
                child: ListTile(
                  title: Text(page.title),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: 'Delete recipe',
                        onPressed: () => _deletePageDialog(page),
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      ReorderableDragStartListener(
                        index: idx,
                        child: const Icon(Icons.drag_handle),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
