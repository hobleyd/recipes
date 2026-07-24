import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'epub_service.dart';
import 'measurement_converter.dart';
import 'models.dart';
import 'ocr_service.dart';
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
  bool _importing = false;
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
      final path = ref.read(epubPathProvider).value!;
      final data = await EpubService(path).loadRecipe(page);
      _populateForm(data);
    } catch (e) {
      setState(() => _error = 'Could not load recipe: $e');
    } finally {
      setState(() => _loadingRecipe = false);
    }
  }

  Future<OcrSettings?> _showImportSettings() async {
    final current = await ref.read(ocrSettingsProvider.future);

    var backend = current.preferred;
    final claudeCtrl = TextEditingController(text: current.claudeApiKey);
    final urlCtrl = TextEditingController(text: current.ollamaUrl);
    String selectedModel = current.ollamaModel;
    final modelCtrl = TextEditingController(text: current.ollamaModel);
    String selectedTextModel = current.effectiveOllamaTextModel;
    final textModelCtrl =
        TextEditingController(text: current.effectiveOllamaTextModel);

    List<String>? ollamaModels;
    bool loadingModels = false;

    if (backend == OcrBackend.ollama) {
      try {
        ollamaModels = await OcrService.fetchOllamaModels(current.ollamaUrl)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    if (!mounted) return null;

    final result = await showDialog<OcrSettings>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) {
          void fetchModels() {
            setDs(() => loadingModels = true);
            OcrService.fetchOllamaModels(urlCtrl.text.trim())
                .timeout(const Duration(seconds: 5))
                .then((models) {
              if (!ctx.mounted) return;
              setDs(() {
                ollamaModels = models;
                loadingModels = false;
                if (models.isNotEmpty && !models.contains(selectedModel)) {
                  selectedModel = models.first;
                  modelCtrl.text = selectedModel;
                }
                if (models.isNotEmpty &&
                    !models.contains(selectedTextModel)) {
                  selectedTextModel = models.first;
                  textModelCtrl.text = selectedTextModel;
                }
              });
            }).catchError((_) {
              if (!ctx.mounted) return;
              setDs(() {
                ollamaModels = null;
                loadingModels = false;
              });
            });
          }

          final hasModels = ollamaModels != null && ollamaModels!.isNotEmpty;

          return AlertDialog(
            title: const Text('LLM Settings'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<OcrBackend>(
                    segments: const [
                      ButtonSegment(
                        value: OcrBackend.ollama,
                        label: Text('Ollama (local)'),
                        icon: Icon(Icons.computer_outlined),
                      ),
                      ButtonSegment(
                        value: OcrBackend.claude,
                        label: Text('Claude API'),
                        icon: Icon(Icons.cloud_outlined),
                      ),
                    ],
                    selected: {backend},
                    onSelectionChanged: (s) {
                      setDs(() => backend = s.first);
                      if (s.first == OcrBackend.ollama &&
                          ollamaModels == null &&
                          !loadingModels) {
                        fetchModels();
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                  if (backend == OcrBackend.ollama) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: urlCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Ollama URL',
                              hintText: 'http://localhost:11434',
                              border: OutlineInputBorder(),
                              helperText: 'Start Ollama with: ollama serve',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: IconButton(
                            onPressed: loadingModels ? null : fetchModels,
                            tooltip: 'Fetch available models',
                            icon: loadingModels
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.refresh),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (hasModels)
                      DropdownButtonFormField<String>(
                        // ignore: deprecated_member_use
                        value: ollamaModels!.contains(selectedModel)
                            ? selectedModel
                            : ollamaModels!.first,
                        decoration: const InputDecoration(
                          labelText: 'Vision model',
                          border: OutlineInputBorder(),
                          helperText:
                              'For image/PDF import — select a vision-capable model',
                        ),
                        isExpanded: true,
                        items: ollamaModels!
                            .map((m) =>
                                DropdownMenuItem(value: m, child: Text(m)))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setDs(() {
                              selectedModel = v;
                              modelCtrl.text = v;
                            });
                          }
                        },
                      )
                    else
                      TextField(
                        controller: modelCtrl,
                        decoration: InputDecoration(
                          labelText: 'Vision model',
                          hintText: 'llama3.2-vision',
                          border: const OutlineInputBorder(),
                          helperText: loadingModels
                              ? 'Fetching models…'
                              : 'For image/PDF import. Must be vision-capable. Pull with: ollama pull llama3.2-vision',
                        ),
                        onChanged: (v) => selectedModel = v,
                      ),
                    const SizedBox(height: 16),
                    if (hasModels)
                      DropdownButtonFormField<String>(
                        // ignore: deprecated_member_use
                        value: ollamaModels!.contains(selectedTextModel)
                            ? selectedTextModel
                            : ollamaModels!.first,
                        decoration: const InputDecoration(
                          labelText: 'Text model',
                          border: OutlineInputBorder(),
                          helperText:
                              'For web page import — select an instruction-following model, not an OCR-only one',
                        ),
                        isExpanded: true,
                        items: ollamaModels!
                            .map((m) =>
                                DropdownMenuItem(value: m, child: Text(m)))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setDs(() {
                              selectedTextModel = v;
                              textModelCtrl.text = v;
                            });
                          }
                        },
                      )
                    else
                      TextField(
                        controller: textModelCtrl,
                        decoration: InputDecoration(
                          labelText: 'Text model',
                          hintText: 'llama3.2 or qwen2.5',
                          border: const OutlineInputBorder(),
                          helperText: loadingModels
                              ? 'Fetching models…'
                              : 'For web page import. Must be instruction-following, not OCR-only.',
                        ),
                        onChanged: (v) => selectedTextModel = v,
                      ),
                  ] else ...[
                    TextField(
                      controller: claudeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Anthropic API key',
                        hintText: 'sk-ant-…',
                        border: OutlineInputBorder(),
                        helperText: 'Get your key at console.anthropic.com',
                      ),
                      obscureText: true,
                      autofocus: current.claudeApiKey.isEmpty,
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  ctx,
                  OcrSettings(
                    claudeApiKey: claudeCtrl.text.trim(),
                    ollamaUrl: urlCtrl.text.trim(),
                    ollamaModel: selectedModel.trim().isEmpty
                        ? 'llama3.2-vision'
                        : selectedModel.trim(),
                    ollamaTextModel: selectedTextModel.trim(),
                    preferred: backend,
                  ),
                ),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    claudeCtrl.dispose();
    urlCtrl.dispose();
    modelCtrl.dispose();
    textModelCtrl.dispose();

    if (result != null) {
      await ref.read(ocrSettingsProvider.notifier).save(result);
      return result;
    }
    return null;
  }

  Future<void> _importRecipe() async {
    OcrSettings? settings = await ref.read(ocrSettingsProvider.future);

    if (settings == null || !settings.isConfigured) {
      settings = await _showImportSettings();
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
      settings = await _showImportSettings();
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

  Future<void> _save() async {
    setState(() {
      _error = null;
      _saved = false;
    });

    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);

    try {
      final path = ref.read(epubPathProvider).value!;
      if (_mode == _Mode.edit) {
        await EpubService(path).updateRecipe(
          page: _editingPage!,
          title: _titleCtrl.text.trim(),
          description: _descCtrl.text.trim(),
          ingredientSections: _tables.map((t) => t.toSection()).toList(),
          method: _methodCtrl.text.trim(),
          footnote: _footnoteCtrl.text.trim(),
        );
      } else {
        await EpubService(path).saveRecipe(
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
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add recipe',
            style: _mode == _Mode.add
                ? IconButton.styleFrom(
                    backgroundColor:
                        cs.onPrimaryContainer.withValues(alpha: 0.15))
                : null,
            onPressed: () => setState(() {
              _mode = _Mode.add;
              _insertAfter = null;
              _editingPage = null;
              _error = null;
              _saved = false;
            }),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit recipe',
            style: _mode == _Mode.edit
                ? IconButton.styleFrom(
                    backgroundColor:
                        cs.onPrimaryContainer.withValues(alpha: 0.15))
                : null,
            onPressed: () => setState(() {
              _mode = _Mode.edit;
              _insertAfter = null;
              _editingPage = null;
              _error = null;
              _saved = false;
            }),
          ),
          PopupMenuButton<String>(
            enabled: !(_importing || _saving || _loadingRecipe),
            tooltip: 'Import recipe',
            icon: _importing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.document_scanner_outlined),
            onSelected: (value) async {
              if (value == 'image_pdf') {
                await _importRecipe();
              } else if (value == 'web_page') {
                await _importFromWebPage();
              } else if (value == 'llm_settings') {
                await _showImportSettings();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'image_pdf',
                child: Row(children: [
                  Icon(Icons.image_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Import Image or PDF…'),
                ]),
              ),
              PopupMenuItem(
                value: 'web_page',
                child: Row(children: [
                  Icon(Icons.language_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Import Web Page…'),
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
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: 'Reorder pages & chapters',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const ReorderScreen()),
            ),
          ),
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
