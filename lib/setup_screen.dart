import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
              label: const Text('Choose EPUB File'),
              onPressed: () => _pickFile(context, ref),
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
}
