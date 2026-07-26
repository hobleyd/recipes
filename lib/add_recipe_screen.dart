import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharpblue_library/sharpblue_library.dart';
import 'epub_service.dart';
import 'measurement_converter.dart';
import 'models.dart';
import 'ocr_service.dart';
import 'ocr_settings_dialog.dart';
import 'providers.dart';

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
  const AddRecipeScreen({
    super.key,
    this.initialInsertAfter,
    this.initialEditingPage,
    this.autoImportAction,
  });

  /// Page to pre-select as the insertion point when opening in add mode.
  final EpubPage? initialInsertAfter;

  /// Page to open directly in edit mode for.
  final EpubPage? initialEditingPage;

  /// If set ('image_pdf', 'web_page', or 'text'), automatically triggers
  /// that import flow as soon as the screen opens.
  final String? autoImportAction;

  @override
  ConsumerState<AddRecipeScreen> createState() => _AddRecipeScreenState();
}

class _AddRecipeScreenState extends ConsumerState<AddRecipeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descEditorKey = GlobalKey<RichTextEditorState>();
  final _methodEditorKey = GlobalKey<RichTextEditorState>();
  final _footnoteCtrl = TextEditingController();
  final _scrollController = ScrollController();

  String _descHtml = '';
  String _methodHtml = '';

  _Mode _mode = _Mode.add;
  EpubPage? _insertAfter;
  EpubPage? _editingPage;
  final List<_IngTable> _tables = [_IngTable()];

  bool _saving = false;
  bool _loadingRecipe = false;
  bool _importing = false;
  String? _error;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialEditingPage != null) {
      _mode = _Mode.edit;
      _editingPage = widget.initialEditingPage;
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _loadRecipeForEditing(widget.initialEditingPage!));
    } else if (widget.initialInsertAfter != null) {
      _mode = _Mode.add;
      _insertAfter = widget.initialInsertAfter;
    }
    if (widget.autoImportAction != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (widget.autoImportAction == 'image_pdf') {
          _importRecipe();
        } else if (widget.autoImportAction == 'web_page') {
          _importFromWebPage();
        } else if (widget.autoImportAction == 'text') {
          _importFromText();
        }
      });
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _footnoteCtrl.dispose();
    _scrollController.dispose();
    for (final t in _tables) {
      t.dispose();
    }
    super.dispose();
  }

  void _populateForm(RecipeData data) {
    _titleCtrl.text = data.title;
    _descHtml = data.description;
    _methodHtml = data.method;
    _descEditorKey.currentState?.setContent(data.description);
    _methodEditorKey.currentState?.setContent(data.method);
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
      final path = ref.read(epubPathProvider).value!;
      final data = await EpubService(path).loadRecipe(page);
      _populateForm(data);
    } catch (e) {
      setState(() => _error = 'Could not load recipe: $e');
    } finally {
      setState(() => _loadingRecipe = false);
    }
  }

  Future<void> _importRecipe() async {
    OcrSettings? settings = await ref.read(ocrSettingsProvider.future);

    if (settings == null || !settings.isConfigured) {
      settings = await showOcrSettingsDialog(context, ref);
      if (settings == null || !settings.isConfigured) return;
    }

    final typeGroups = [
      const XTypeGroup(
        label: 'Images',
        extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
      ),
      if (settings.preferred == OcrBackend.claude)
        const XTypeGroup(label: 'PDF', extensions: ['pdf']),
    ];

    final file = await openFile(acceptedTypeGroups: typeGroups);
    if (file == null) return;

    setState(() {
      _importing = true;
      _error = null;
      _saved = false;
    });

    try {
      final OcrService service = settings.preferred == OcrBackend.ollama
          ? OcrService.ollama(
              baseUrl: settings.ollamaUrl,
              model: settings.ollamaModel,
              textModel: settings.effectiveOllamaTextModel,
            )
          : OcrService.claude(settings.claudeApiKey);

      final data = await service.extractRecipe(file.path);
      setState(() {
        _mode = _Mode.add;
        _editingPage = null;
      });
      _populateForm(data);
    } catch (e) {
      setState(() => _error = 'Import failed: $e');
    } finally {
      setState(() => _importing = false);
    }
  }

  Future<void> _importFromWebPage() async {
    OcrSettings? settings = await ref.read(ocrSettingsProvider.future);

    if (settings == null || !settings.isConfigured) {
      settings = await showOcrSettingsDialog(context, ref);
      if (settings == null || !settings.isConfigured) return;
    }

    if (!mounted) return;

    final formKey = GlobalKey<FormState>();
    final urlCtrl = TextEditingController();

    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import from Web Page'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 440),
          child: Form(
            key: formKey,
            child: TextFormField(
              controller: urlCtrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Recipe page URL',
                hintText: 'https://example.com/recipe',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty) return 'URL is required';
                final uri = Uri.tryParse(value);
                if (uri == null || !uri.hasScheme) return 'Enter a valid URL';
                return null;
              },
              onFieldSubmitted: (_) {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(ctx, urlCtrl.text.trim());
                }
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, urlCtrl.text.trim());
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) {
      urlCtrl.dispose();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => urlCtrl.dispose());

    setState(() {
      _importing = true;
      _error = null;
      _saved = false;
    });

    try {
      final OcrService service = settings.preferred == OcrBackend.ollama
          ? OcrService.ollama(
              baseUrl: settings.ollamaUrl,
              model: settings.ollamaModel,
              textModel: settings.effectiveOllamaTextModel,
            )
          : OcrService.claude(settings.claudeApiKey);

      final data = await service.extractRecipeFromUrl(url);
      setState(() {
        _mode = _Mode.add;
        _editingPage = null;
      });
      _populateForm(data);
    } catch (e) {
      setState(() => _error = 'Import failed: $e');
    } finally {
      setState(() => _importing = false);
    }
  }

  Future<void> _importFromText() async {
    OcrSettings? settings = await ref.read(ocrSettingsProvider.future);

    if (settings == null || !settings.isConfigured) {
      settings = await showOcrSettingsDialog(context, ref);
      if (settings == null || !settings.isConfigured) return;
    }

    if (!mounted) return;

    final formKey = GlobalKey<FormState>();
    final textCtrl = TextEditingController();

    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import from Text'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 440),
          child: Form(
            key: formKey,
            child: TextFormField(
              controller: textCtrl,
              autofocus: true,
              minLines: 8,
              maxLines: 16,
              decoration: const InputDecoration(
                labelText: 'Recipe text',
                hintText: 'Paste the recipe text here…',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty) return 'Recipe text is required';
                return null;
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, textCtrl.text.trim());
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) {
      textCtrl.dispose();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => textCtrl.dispose());

    setState(() {
      _importing = true;
      _error = null;
      _saved = false;
    });

    try {
      final OcrService service = settings.preferred == OcrBackend.ollama
          ? OcrService.ollama(
              baseUrl: settings.ollamaUrl,
              model: settings.ollamaModel,
              textModel: settings.effectiveOllamaTextModel,
            )
          : OcrService.claude(settings.claudeApiKey);

      final data = await service.extractRecipeFromText(text);
      setState(() {
        _mode = _Mode.add;
        _editingPage = null;
      });
      _populateForm(data);
    } catch (e) {
      setState(() => _error = 'Import failed: $e');
    } finally {
      setState(() => _importing = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _error = null;
      _saved = false;
    });

    if (!(_formKey.currentState?.validate() ?? false)) return;

    final descHtml =
        await _descEditorKey.currentState?.getContent() ?? _descHtml;
    final methodHtml =
        await _methodEditorKey.currentState?.getContent() ?? _methodHtml;
    if (_isHtmlEmpty(descHtml)) {
      setState(() => _error = 'Description is required');
      return;
    }
    if (_isHtmlEmpty(methodHtml)) {
      setState(() => _error = 'Method is required');
      return;
    }
    _descHtml = descHtml;
    _methodHtml = methodHtml;

    setState(() => _saving = true);

    try {
      final path = ref.read(epubPathProvider).value!;
      if (_mode == _Mode.edit) {
        await EpubService(path).updateRecipe(
          page: _editingPage!,
          title: _titleCtrl.text.trim(),
          description: descHtml,
          ingredientSections: _tables.map((t) => t.toSection()).toList(),
          method: methodHtml,
          footnote: _footnoteCtrl.text.trim(),
        );
      } else {
        await EpubService(path).saveRecipe(
          title: _titleCtrl.text.trim(),
          description: descHtml,
          ingredientSections: _tables.map((t) => t.toSection()).toList(),
          method: methodHtml,
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
            ? 'Edit Recipe — Recipe Manager'
            : 'Add Recipe — Recipe Manager'),
        backgroundColor: cs.primaryContainer,
        foregroundColor: cs.onPrimaryContainer,
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
                    selectedItemBuilder: (_) => _buildPageItems(pages)
                        .map((item) => item.value?.id.isEmpty ?? true
                            ? const SizedBox.shrink()
                            : Text(item.value!.title,
                                overflow: TextOverflow.ellipsis))
                        .toList(),
                    onChanged: (p) => setState(() => _insertAfter = p),
                    validator: (v) =>
                        v == null ? 'Please select a page' : null,
                  ),
                  if (_importing) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                        Text('Importing recipe…',
                            style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ],
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
                    selectedItemBuilder: (_) => _buildPageItems(pages)
                        .map((item) => item.value?.id.isEmpty ?? true
                            ? const SizedBox.shrink()
                            : Text(item.value!.title,
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
                _richTextField(
                  label: 'Description',
                  hint: 'Short intro — where it came from, who loves it…',
                  editorKey: _descEditorKey,
                  initialHtml: _descHtml,
                  height: 140,
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
                _richTextField(
                  label: 'Method',
                  hint: 'Cooking steps.',
                  editorKey: _methodEditorKey,
                  initialHtml: _methodHtml,
                  height: 320,
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
                    onPressed:
                        (_saving || _loadingRecipe || _importing) ? null : _save,
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

  Widget _richTextField({
    required String label,
    required String hint,
    required GlobalKey<RichTextEditorState> editorKey,
    required String initialHtml,
    required double height,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Container(
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            border: Border.all(color: cs.outline),
            borderRadius: BorderRadius.circular(4),
          ),
          child: RichTextEditor(
            key: editorKey,
            initialHtml: initialHtml,
            onContentChanged: (_) {},
          ),
        ),
        if (hint.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(hint,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ],
    );
  }

  bool _isHtmlEmpty(String html) =>
      html.replaceAll(RegExp(r'<[^>]*>'), '').trim().isEmpty;

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
