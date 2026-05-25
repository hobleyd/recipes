import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'add_recipe_screen.dart';

void main() {
  runApp(const ProviderScope(child: RecipesApp()));
}

class RecipesApp extends StatelessWidget {
  const RecipesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hobley Family Recipes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B4513),
        ),
        useMaterial3: true,
      ),
      home: const AddRecipeScreen(),
    );
  }
}
