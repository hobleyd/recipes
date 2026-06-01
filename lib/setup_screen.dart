import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'epub_service.dart';
import 'providers.dart';

class SetupScreen extends ConsumerWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined, size: 72, color: cs.primary),
            const SizedBox(height: 24),
            Text(
              'Hobley Family Recipes',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Choose the EPUB file to get started.',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Open EPUB File'),
              onPressed: () => _pickFile(context, ref),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.auto_stories_outlined),
              label: const Text('New Cookbook…'),
              onPressed: () => _newCookbook(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFile(BuildContext context, WidgetRef ref) async {
    const typeGroup = XTypeGroup(label: 'EPUB', extensions: ['epub']);
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    await ref.read(epubPathProvider.notifier).setPath(file.path);
  }

  Future<void> _newCookbook(BuildContext context, WidgetRef ref) async {
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
                    validator: (v) => (v?.trim().isEmpty ?? true)
                        ? 'Title is required'
                        : null,
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

    final slug = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final saveLocation = await getSaveLocation(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'EPUB', extensions: ['epub']),
      ],
      suggestedName: '$slug.epub',
    );
    if (saveLocation == null) return;

    try {
      await EpubService.createCookbook(
        path: saveLocation.path,
        title: title,
        coverImagePath: imagePath,
      );
      await ref.read(epubPathProvider.notifier).setPath(saveLocation.path);
    } catch (e) {
      if (context.mounted) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Error'),
            content: Text('Failed to create cookbook: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }
}
