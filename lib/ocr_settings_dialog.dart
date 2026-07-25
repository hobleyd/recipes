import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ocr_service.dart';
import 'providers.dart';

Future<OcrSettings?> showOcrSettingsDialog(
    BuildContext context, WidgetRef ref) async {
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

  if (!context.mounted) return null;

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
