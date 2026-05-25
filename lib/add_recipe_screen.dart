import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'epub_service.dart';
import 'measurement_converter.dart';
import 'models.dart';
import 'providers.dart';
import 'reorder_screen.dart';

enum _Mode { add, edit }

class _IngRow {
  final key = GlobalKey();
  final name = TextEditingController();
  final imperial = TextEditingController();
  final metric = TextEditingController();
  final nameFocus = FocusNode();
  bool _updating = false;

  _IngRow() {
    imperial.addListener(_onImperialChanged);
    metric.addListener(_onMetricChanged);
  }

  void _onImperialChanged() {
    if (_updating) return;
    _updating = true;
    final converted = MeasurementConverter.imperialToMetric(imperial.text);
    if (converted != null) metric.text = converted;
    _updating = false;
  }

  void _onMetricChanged() {
    if (_updating) return;
    _updating = true;
    final converted = MeasurementConverter.metricToImperial(metric.text);
    if (converted != null) imperial.text = converted;
    _updating = false;
  }

  void dispose() {
    imperial.removeListener(_onImperialChanged);
    metric.removeListener(_onMetricChanged);
    name.dispose();
    imperial.dispose();
    metric.dispose();
    nameFocus.dispose();
  }

  void setInitial(
      {required String name, required String imperial, required String metric}) {
    _updating = true;
    this.name.text = name;
    this.imperial.text = imperial;
    this.metric.text = metric;
    _updating = false;
  }

  Ingredient toIngredient() => Ingredient(
        name: name.text.trim(),
        imperial: imperial.text.trim(),
        metric: metric.text.trim(),
      );
}

class _IngTable {
  final label = TextEditingController();
  final List<_IngRow> rows = [_IngRow()];

  void dispose() {
    label.dispose();
    for (final r in rows) {
      r.dispose();
    }
  }

  IngredientSection toSection() => IngredientSection(
        label: label.text.trim(),
        ingredients: rows.map((r) => r.toIngredient()).toList(),
      );
}

class AddRecipeScreen extends ConsumerStatefulWidget {
  const AddRecipeScreen({super.key});

  @override
  ConsumerState<AddRecipeScreen> createState() => _AddRecipeScreenState();
}

class _AddRecipeScreenState extends ConsumerState<AddRecipeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _methodCtrl = TextEditingController();
  final _footnoteCtrl = TextEditingController();
  final _scrollController = ScrollController();

  _Mode _mode = _Mode.add;
  EpubPage? _insertAfter;
  EpubPage? _editingPage;
  final List<_IngTable> _tables = [_IngTable()];

  bool _saving = false;
  bool _loadingRecipe = false;
  String? _error;
  bool _saved = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _methodCtrl.dispose();
    _footnoteCtrl.dispose();
    _scrollController.dispose();
    for (final t in _tables) {
      t.dispose();
    }
    super.dispose();
  }

  void _populateForm(RecipeData data) {
    _titleCtrl.text = data.title;
    _descCtrl.text = data.description;
    _methodCtrl.text = data.method;
    _footnoteCtrl.text = data.footnote;

    for (final t in _tables) {
      t.dispose();
    }
    _tables.clear();

    for (final section in data.ingredientSections) {
      final table = _IngTable();
      table.label.text = section.label;
      table.rows.first.dispose();
      table.rows.clear();
      final ings =
          section.ingredients.isNotEmpty ? section.ingredients : [Ingredient()];
      for (final ing in ings) {
        final row = _IngRow();
        row.setInitial(
            name: ing.name, imperial: ing.imperial, metric: ing.metric);
        table.rows.add(row);
      }
      _tables.add(table);
    }
    if (_tables.isEmpty) _tables.add(_IngTable());
    setState(() {});
  }

  Future<void> _loadRecipeForEditing(EpubPage page) async {
    setState(() {
      _loadingRecipe = true;
      _error = null;
      _saved = false;
    });
    try {
      final data = await EpubService().loadRecipe(page);
      _populateForm(data);
    } catch (e) {
      setState(() => _error = 'Could not load recipe: $e');
    } finally {
      setState(() => _loadingRecipe = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _error = null;
      _saved = false;
    });

    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);

    try {
      if (_mode == _Mode.edit) {
        await EpubService().updateRecipe(
          page: _editingPage!,
          title: _titleCtrl.text.trim(),
          description: _descCtrl.text.trim(),
          ingredientSections: _tables.map((t) => t.toSection()).toList(),
          method: _methodCtrl.text.trim(),
          footnote: _footnoteCtrl.text.trim(),
        );
      } else {
        await EpubService().saveRecipe(
          title: _titleCtrl.text.trim(),
          description: _descCtrl.text.trim(),
          ingredientSections: _tables.map((t) => t.toSection()).toList(),
          method: _methodCtrl.text.trim(),
          footnote: _footnoteCtrl.text.trim(),
          insertAfterPage: _insertAfter!,
        );
      }
      setState(() {
        _saving = false;
        _saved = true;
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
        title: Text(_mode == _Mode.edit
            ? 'Edit Recipe — Hobley Family Recipes'
            : 'Add Recipe — Hobley Family Recipes'),
        backgroundColor: cs.primaryContainer,
        foregroundColor: cs.onPrimaryContainer,
        actions: [
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: 'Reorder pages & chapters',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const ReorderScreen()),
            ),
          ),
          SegmentedButton<_Mode>(
            segments: const [
              ButtonSegment(
                  value: _Mode.add,
                  label: Text('Add'),
                  icon: Icon(Icons.add)),
              ButtonSegment(
                  value: _Mode.edit,
                  label: Text('Edit'),
                  icon: Icon(Icons.edit_outlined)),
            ],
            selected: {_mode},
            onSelectionChanged: (modes) => setState(() {
              _mode = modes.first;
              _insertAfter = null;
              _editingPage = null;
              _error = null;
              _saved = false;
            }),
            style: ButtonStyle(
              foregroundColor:
                  WidgetStateProperty.all(cs.onPrimaryContainer),
            ),
          ),
          const SizedBox(width: 12),
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
        data: (pages) => _buildForm(pages),
      ),
    );
  }

  Widget _buildForm(List<EpubPage> pages) {
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_mode == _Mode.add) ...[
                  _sectionLabel('Placement'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<EpubPage>(
                    // ignore: deprecated_member_use
                    value: _insertAfter,
                    decoration: const InputDecoration(
                      labelText: 'Insert after page',
                      border: OutlineInputBorder(),
                    ),
                    isExpanded: true,
                    items: _buildPageItems(pages),
                    selectedItemBuilder: (_) => pages
                        .map((p) => Text(p.title,
                            overflow: TextOverflow.ellipsis))
                        .toList(),
                    onChanged: (p) => setState(() => _insertAfter = p),
                    validator: (v) =>
                        v == null ? 'Please select a page' : null,
                  ),
                  const SizedBox(height: 28),
                ] else ...[
                  _sectionLabel('Recipe to edit'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<EpubPage>(
                    // ignore: deprecated_member_use
                    value: _editingPage,
                    decoration: const InputDecoration(
                      labelText: 'Select recipe',
                      border: OutlineInputBorder(),
                    ),
                    isExpanded: true,
                    items: _buildPageItems(pages),
                    selectedItemBuilder: (_) => pages
                        .map((p) => Text(p.title,
                            overflow: TextOverflow.ellipsis))
                        .toList(),
                    onChanged: (p) {
                      setState(() => _editingPage = p);
                      if (p != null) _loadRecipeForEditing(p);
                    },
                    validator: (v) =>
                        v == null ? 'Please select a recipe' : null,
                  ),
                  if (_loadingRecipe) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(),
                  ],
                  const SizedBox(height: 28),
                ],

                _sectionLabel('Recipe'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v?.trim().isEmpty ?? true) ? 'Title is required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _descCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'Short intro — where it came from, who loves it…',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 4,
                  validator: (v) =>
                      (v?.trim().isEmpty ?? true) ? 'Description is required' : null,
                ),
                const SizedBox(height: 28),

                _sectionLabel('Ingredients'),
                const SizedBox(height: 8),
                for (var t = 0; t < _tables.length; t++) ...[
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _tables[t].label,
                          decoration: const InputDecoration(
                            labelText: 'Section title (optional)',
                            hintText: 'e.g. "For the sauce:"',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      if (_tables.length > 1) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () => setState(() {
                            _tables[t].dispose();
                            _tables.removeAt(t);
                          }),
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: 'Remove section',
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildIngredientsTable(t),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() => _tables[t].rows.add(_IngRow()));
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        final newRow = _tables[t].rows.last;
                        final ctx = newRow.key.currentContext;
                        if (ctx != null) {
                          Scrollable.ensureVisible(
                            ctx,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                          );
                        }
                        newRow.nameFocus.requestFocus();
                      });
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add Ingredient'),
                  ),
                  const SizedBox(height: 16),
                ],
                OutlinedButton.icon(
                  onPressed: () => setState(() => _tables.add(_IngTable())),
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: const Text('Add Ingredient Section'),
                ),
                const SizedBox(height: 28),

                _sectionLabel('Method'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _methodCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Method',
                    hintText:
                        'Cooking steps. Leave a blank line between paragraphs.',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 10,
                  validator: (v) =>
                      (v?.trim().isEmpty ?? true) ? 'Method is required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _footnoteCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Footnote / source (optional)',
                    hintText: 'e.g. "From Annette Culshaw" or a URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 28),

                if (_error != null) ...[
                  _statusBanner(
                    icon: Icons.error_outline,
                    text: _error!,
                    isError: true,
                  ),
                  const SizedBox(height: 16),
                ],
                if (_saved) ...[
                  _statusBanner(
                    icon: Icons.check_circle_outline,
                    text: _mode == _Mode.edit
                        ? 'Recipe updated! Backup written to .old.'
                        : 'Recipe saved! Backup written to .old.',
                    isError: false,
                  ),
                  const SizedBox(height: 16),
                ],

                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: (_saving || _loadingRecipe) ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Icon(_mode == _Mode.edit
                            ? Icons.update
                            : Icons.save_outlined),
                    label: Text(_saving
                        ? 'Saving…'
                        : (_mode == _Mode.edit
                            ? 'Update Recipe'
                            : 'Save Recipe')),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIngredientsTable(int tableIdx) {
    final cs = Theme.of(context).colorScheme;
    final headerStyle = TextStyle(
      fontWeight: FontWeight.w600,
      color: cs.onSurfaceVariant,
      fontSize: 13,
    );
    final rows = _tables[tableIdx].rows;

    return Column(
      children: [
        // Header
        Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(8)),
            border: Border.all(color: cs.outlineVariant),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(flex: 4, child: Text('Ingredient', style: headerStyle)),
              const SizedBox(width: 8),
              Expanded(
                  flex: 2,
                  child: Text('Imperial (I)', style: headerStyle)),
              const SizedBox(width: 8),
              Expanded(
                  flex: 2, child: Text('Metric (M)', style: headerStyle)),
              const SizedBox(width: 40),
            ],
          ),
        ),
        // Rows
        Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: cs.outlineVariant),
              right: BorderSide(color: cs.outlineVariant),
              bottom: BorderSide(color: cs.outlineVariant),
            ),
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(8)),
          ),
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) _buildRow(tableIdx, i),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRow(int tableIdx, int idx) {
    final cs = Theme.of(context).colorScheme;
    final rows = _tables[tableIdx].rows;
    final row = rows[idx];
    final isLast = idx == rows.length - 1;

    const fieldDec = InputDecoration(
      border: InputBorder.none,
      isDense: true,
      contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
    );

    return Container(
      key: row.key,
      decoration: isLast
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.5)),
              ),
            ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: TextField(
              controller: row.name,
              focusNode: row.nameFocus,
              decoration:
                  fieldDec.copyWith(hintText: 'Ingredient name'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: row.imperial,
              decoration: fieldDec.copyWith(hintText: '1 tbs'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: row.metric,
              decoration: fieldDec.copyWith(hintText: '15 ml'),
            ),
          ),
          SizedBox(
            width: 40,
            child: IconButton(
              onPressed: rows.length > 1
                  ? () => setState(() {
                        rows[idx].dispose();
                        rows.removeAt(idx);
                      })
                  : null,
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: 'Remove',
            ),
          ),
        ],
      ),
    );
  }

  List<DropdownMenuItem<EpubPage>> _buildPageItems(List<EpubPage> pages) {
    final cs = Theme.of(context).colorScheme;
    final items = <DropdownMenuItem<EpubPage>>[];
    String? lastChapter;

    for (final page in pages) {
      if (page.chapter != null && page.chapter != lastChapter) {
        lastChapter = page.chapter;
        items.add(DropdownMenuItem<EpubPage>(
          enabled: false,
          value: EpubPage(id: '', href: '', title: ''),
          child: Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(
              page.chapter!.toUpperCase(),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: cs.primary,
                fontSize: 11,
                letterSpacing: 0.8,
              ),
            ),
          ),
        ));
      }
      items.add(DropdownMenuItem<EpubPage>(
        value: page,
        child: Padding(
          padding: EdgeInsets.only(left: page.chapter != null ? 12.0 : 0.0),
          child:
              Text(page.title, overflow: TextOverflow.ellipsis),
        ),
      ));
    }
    return items;
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
    );
  }

  Widget _statusBanner(
      {required IconData icon,
      required String text,
      required bool isError}) {
    final cs = Theme.of(context).colorScheme;
    final bg = isError ? cs.errorContainer : cs.primaryContainer;
    final fg = isError ? cs.onErrorContainer : cs.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text, style: TextStyle(color: fg, fontSize: 14))),
        ],
      ),
    );
  }
}
