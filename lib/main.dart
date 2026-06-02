import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'add_recipe_screen.dart';
import 'providers.dart';
import 'setup_screen.dart';

void main() {
  runApp(const ProviderScope(child: RecipesApp()));
}

class RecipesApp extends StatelessWidget {
  const RecipesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Recipe Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B4513),
        ),
        useMaterial3: true,
      ),
      home: const _AppRouter(),
    );
  }
}

class _AppRouter extends ConsumerWidget {
  const _AppRouter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pathAsync = ref.watch(epubPathProvider);
    return pathAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => const SetupScreen(),
      data: (path) => path == null ? const SetupScreen() : const AddRecipeScreen(),
    );
  }
}
